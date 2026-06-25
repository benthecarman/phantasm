//! Shared ComfyUI plumbing for the image-generation and image-edit tools.
//!
//! Both tools build an API-format workflow graph (a `serde_json::Value` keyed by
//! node ID) by injecting their inputs into configured nodes, then hand it to
//! [`run_workflow`], which: opens the progress WebSocket *first* (so no early
//! frames are missed), submits via `POST /prompt`, relays progress to the app as
//! `x_status`, and fetches the finished image from `/history` + `/view`,
//! returning it as a base64 `data:` URI ready to embed as markdown.
//!
//! The edit tool additionally needs the user's image inside ComfyUI's input
//! folder first; [`upload_image`] handles that via `POST /upload/image`.

use std::time::Duration;

use base64::Engine;
use futures_util::StreamExt;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::config::{Config, NodeInput};
use crate::orchestrator::TurnEvent;

/// Inject `value` into `workflow[target.node]["inputs"][target.key]`.
pub fn set_input(workflow: &mut Value, target: &NodeInput, value: Value) -> Result<(), String> {
    let inputs = workflow
        .get_mut(&target.node)
        .ok_or_else(|| format!("node {} not found in workflow", target.node))?
        .get_mut("inputs")
        .ok_or_else(|| format!("node {} has no inputs", target.node))?;
    let obj = inputs.as_object_mut().ok_or("inputs is not an object")?;
    obj.insert(target.key.clone(), value);
    Ok(())
}

/// Upload raw image bytes into ComfyUI's `input` folder so a `LoadImage` node can
/// reference them. Returns the filename ComfyUI stored it under (it may rename to
/// avoid collisions, so we use the returned name, not the one we sent).
pub async fn upload_image(
    cfg: &Config,
    http: &reqwest::Client,
    bytes: Vec<u8>,
    filename: &str,
) -> Result<String, String> {
    let url = cfg
        .comfy_base
        .join("/upload/image")
        .map_err(|e| e.to_string())?;
    let part = reqwest::multipart::Part::bytes(bytes)
        .file_name(filename.to_string())
        .mime_str("image/png")
        .map_err(|e| e.to_string())?;
    let form = reqwest::multipart::Form::new()
        .part("image", part)
        .text("type", "input")
        .text("overwrite", "true");
    let resp = http
        .post(url)
        .multipart(form)
        .send()
        .await
        .map_err(|e| format!("backend unreachable: {e}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("ComfyUI rejected upload ({status}): {body}"));
    }
    let v: Value = resp.json().await.map_err(|e| e.to_string())?;
    let name = v
        .get("name")
        .and_then(|n| n.as_str())
        .ok_or_else(|| "upload response missing name".to_string())?;
    // A non-root subfolder is referenced as `subfolder/name` by LoadImage.
    match v.get("subfolder").and_then(|s| s.as_str()) {
        Some(sub) if !sub.is_empty() => Ok(format!("{sub}/{name}")),
        _ => Ok(name.to_string()),
    }
}

/// Submit a fully-prepared workflow, relay progress, and return the produced
/// image as a `data:<mime>;base64,…` URI.
pub async fn run_workflow(
    cfg: &Config,
    http: &reqwest::Client,
    workflow: Value,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<String, String> {
    let client_id = uuid::Uuid::new_v4().simple().to_string();

    // Open the progress WS *before* submitting so we never miss early frames.
    let ws_url = ws_url(cfg, &client_id)?;
    let (mut ws, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .map_err(|e| format!("cannot open ComfyUI websocket: {e}"))?;

    // Submit the workflow.
    let prompt_url = cfg.comfy_base.join("/prompt").map_err(|e| e.to_string())?;
    let submit = serde_json::json!({ "prompt": workflow, "client_id": client_id });
    let resp = http
        .post(prompt_url)
        .json(&submit)
        .send()
        .await
        .map_err(|e| format!("backend unreachable: {e}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("ComfyUI rejected workflow ({status}): {body}"));
    }
    let submit_resp: Value = resp.json().await.map_err(|e| e.to_string())?;
    let prompt_id = submit_resp
        .get("prompt_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "ComfyUI did not return a prompt_id".to_string())?
        .to_string();

    // Consume progress until completion / timeout.
    let deadline = tokio::time::sleep(Duration::from_secs(cfg.comfy_timeout_s));
    tokio::pin!(deadline);
    let mut last_pct: i64 = -1;
    loop {
        tokio::select! {
            _ = &mut deadline => return Err("image generation timed out".into()),
            msg = ws.next() => match msg {
                Some(Ok(Message::Text(txt))) => {
                    if let Some(done) = handle_ws_message(&txt, &prompt_id, &mut last_pct, tx).await {
                        if done { break; }
                    }
                }
                Some(Ok(Message::Close(_))) | None => break,
                Some(Ok(_)) => {} // binary preview frames, pings — ignore
                Some(Err(e)) => return Err(format!("websocket error: {e}")),
            }
        }
    }
    drop(ws);

    // Fetch the produced image.
    let _ = tx.send(TurnEvent::Status("retrieving image…".into())).await;
    let (bytes, mime) = fetch_image(cfg, http, &prompt_id).await?;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    Ok(format!("data:{mime};base64,{b64}"))
}

/// Returns `Some(true)` when generation for our prompt completed.
async fn handle_ws_message(
    txt: &str,
    prompt_id: &str,
    last_pct: &mut i64,
    tx: &mpsc::Sender<TurnEvent>,
) -> Option<bool> {
    let v: Value = serde_json::from_str(txt).ok()?;
    let kind = v.get("type")?.as_str()?;
    let data = v.get("data");
    match kind {
        "progress" => {
            let value = data?.get("value")?.as_i64()?;
            let max = data?.get("max")?.as_i64().filter(|m| *m > 0)?;
            let pct = (value * 100 / max).clamp(0, 100);
            if pct != *last_pct {
                *last_pct = pct;
                let _ = tx
                    .send(TurnEvent::Status(format!("generating image… {pct}%")))
                    .await;
            }
            Some(false)
        }
        "executing" => {
            let node_is_null = data?.get("node").map(|n| n.is_null()).unwrap_or(false);
            let same_prompt = data?.get("prompt_id").and_then(|p| p.as_str()) == Some(prompt_id);
            Some(node_is_null && same_prompt)
        }
        // Newer ComfyUI signals completion with `execution_success` instead of an
        // `executing` frame carrying `node: null`. Honor both so generation
        // doesn't run to `comfy_timeout_s` on those versions.
        "execution_success" => {
            let same_prompt = data?.get("prompt_id").and_then(|p| p.as_str()) == Some(prompt_id);
            Some(same_prompt)
        }
        _ => Some(false),
    }
}

async fn fetch_image(
    cfg: &Config,
    http: &reqwest::Client,
    prompt_id: &str,
) -> Result<(Vec<u8>, String), String> {
    let hist_url = cfg
        .comfy_base
        .join(&format!("/history/{prompt_id}"))
        .map_err(|e| e.to_string())?;
    let hist: Value = http
        .get(hist_url)
        .send()
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())?;

    let image = find_first_image(&hist, prompt_id)
        .ok_or_else(|| "no image in ComfyUI output".to_string())?;

    let view_url = cfg.comfy_base.join("/view").map_err(|e| e.to_string())?;
    let resp = http
        .get(view_url)
        .query(&[
            ("filename", image.filename.as_str()),
            ("subfolder", image.subfolder.as_str()),
            ("type", image.kind.as_str()),
        ])
        .timeout(Duration::from_secs(cfg.comfy_timeout_s))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let mime = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/png")
        .to_string();
    let cap = cfg.comfy_max_image_bytes;
    // Fast reject on an advertised oversized body before streaming it.
    if let Some(len) = resp.content_length() {
        if len as usize > cap {
            return Err(format!("image too large ({len} bytes > {cap} cap)"));
        }
    }
    // Stream-accumulate so a missing/lying Content-Length can't blow past the cap.
    let mut bytes = Vec::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        if bytes.len() + chunk.len() > cap {
            return Err(format!("image exceeds {cap} byte cap"));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok((bytes, mime))
}

struct ImageRef {
    filename: String,
    subfolder: String,
    kind: String,
}

fn find_first_image(history: &Value, prompt_id: &str) -> Option<ImageRef> {
    let outputs = history.get(prompt_id)?.get("outputs")?.as_object()?;
    for node in outputs.values() {
        if let Some(images) = node.get("images").and_then(|i| i.as_array()) {
            if let Some(img) = images.first() {
                return Some(ImageRef {
                    filename: img.get("filename")?.as_str()?.to_string(),
                    subfolder: img
                        .get("subfolder")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    kind: img
                        .get("type")
                        .and_then(|v| v.as_str())
                        .unwrap_or("output")
                        .to_string(),
                });
            }
        }
    }
    None
}

fn ws_url(cfg: &Config, client_id: &str) -> Result<String, String> {
    let scheme = if cfg.comfy_base.scheme() == "https" {
        "wss"
    } else {
        "ws"
    };
    let host = cfg.comfy_base.host_str().ok_or("ComfyUI URL has no host")?;
    let port = cfg
        .comfy_base
        .port_or_known_default()
        .map(|p| format!(":{p}"))
        .unwrap_or_default();
    Ok(format!("{scheme}://{host}{port}/ws?clientId={client_id}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_input_inserts_into_node() {
        let target = NodeInput::parse("6.text").unwrap();
        let mut wf = serde_json::json!({
            "6": { "class_type": "CLIPTextEncode", "inputs": { "text": "", "clip": ["4", 1] } }
        });
        set_input(&mut wf, &target, Value::String("a cat".into())).unwrap();
        assert_eq!(wf["6"]["inputs"]["text"], "a cat");
    }

    #[test]
    fn set_input_errors_on_missing_node() {
        let target = NodeInput::parse("99.text").unwrap();
        let mut wf = serde_json::json!({ "6": { "inputs": {} } });
        assert!(set_input(&mut wf, &target, Value::Null).is_err());
    }

    #[test]
    fn finds_image_in_history() {
        let hist = serde_json::json!({
            "pid": { "outputs": { "9": { "images": [
                {"filename": "out.png", "subfolder": "", "type": "output"}
            ]}}}
        });
        let img = find_first_image(&hist, "pid").unwrap();
        assert_eq!(img.filename, "out.png");
        assert_eq!(img.kind, "output");
    }

    #[tokio::test]
    async fn execution_success_marks_completion() {
        let (tx, _rx) = mpsc::channel(4);
        let mut last = -1;
        let msg = r#"{"type":"execution_success","data":{"prompt_id":"pid"}}"#;
        assert_eq!(
            handle_ws_message(msg, "pid", &mut last, &tx).await,
            Some(true)
        );
        // A success frame for a different prompt must not end our wait.
        let other = r#"{"type":"execution_success","data":{"prompt_id":"nope"}}"#;
        assert_eq!(
            handle_ws_message(other, "pid", &mut last, &tx).await,
            Some(false)
        );
    }

    #[test]
    fn ws_url_uses_ws_scheme_and_port() {
        let cfg = crate::config::tests_support::minimal();
        let url = ws_url(&cfg, "abc").unwrap();
        assert_eq!(url, "ws://localhost:8188/ws?clientId=abc");
    }
}
