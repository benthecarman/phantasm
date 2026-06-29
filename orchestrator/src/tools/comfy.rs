//! Shared ComfyUI plumbing for the image-generation and image-edit tools.
//!
//! Both tools build an API-format workflow graph (a `serde_json::Value` keyed by
//! node ID) by injecting their inputs into configured nodes, then hand it to
//! [`run_workflow`], which: opens the progress WebSocket *first* (so no early
//! frames are missed), submits via `POST /prompt`, relays progress to the app as
//! `x_status`, and fetches the finished image from `/history` + `/view`,
//! returning it as a base64 `data:` URI ready to embed as markdown.
//!
//! The edit tool additionally needs the user's image available to ComfyUI first;
//! [`upload_temp_image`] handles that via `POST /upload/image` with
//! `type=temp`, then references it as an annotated `LoadImage` path.

use std::time::Duration;

use base64::Engine;
use futures_util::StreamExt;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use url::Url;

use crate::config::{Config, NodeInput};
use crate::orchestrator::TurnEvent;

// The progress phases surfaced to the app as `x_status`, in order. `GENERATING`
// and `DOWNLOADING` are each emitted twice — first as an indeterminate `Status`,
// then as the label on the determinate `Progress` bar — so the label must match
// across both for the pill to read as one continuous phase. Naming them keeps
// those pairs in lockstep.
const STATUS_QUEUED: &str = "queued…";
const STATUS_GENERATING: &str = "generating image…";
const STATUS_RETRIEVING: &str = "retrieving image…";
const STATUS_DOWNLOADING: &str = "downloading image…";

/// Tells ComfyUI to abandon a submitted prompt, freeing the GPU. Best-effort:
/// `POST /interrupt` stops the prompt if it is currently executing, and
/// `POST /queue {delete:[id]}` removes it if it is still queued. Errors are
/// ignored — this runs on a cancellation/cleanup path where there is no caller
/// left to surface them to.
async fn interrupt_comfy(comfy_base: &Url, http: &reqwest::Client, prompt_id: &str) {
    if let Ok(url) = comfy_base.join("/interrupt") {
        let _ = http.post(url).send().await;
    }
    if let Ok(url) = comfy_base.join("/queue") {
        let _ = http
            .post(url)
            .json(&serde_json::json!({ "delete": [prompt_id] }))
            .send()
            .await;
    }
    tracing::info!(prompt_id, "interrupted ComfyUI generation");
}

/// Drop guard that interrupts a submitted-but-unfinished ComfyUI prompt. The
/// turn-level tool `select!` (and the image tool's own) cancel a backgrounded or
/// stopped generation by *dropping* the `run_workflow` future — so the only
/// reliable place to tell ComfyUI to stop is here, on drop. Without it the GPU
/// job runs on orphaned. `prompt_id` is the live state: `Some` once submitted,
/// cleared to `None` on success (so a normal completion fires no pointless
/// interrupt) or by drop (so the spawned interrupt fires at most once).
struct InterruptOnDrop {
    comfy_base: Url,
    http: reqwest::Client,
    prompt_id: Option<String>,
}

impl Drop for InterruptOnDrop {
    fn drop(&mut self) {
        let Some(prompt_id) = self.prompt_id.take() else {
            return; // never submitted, or completed — nothing to interrupt
        };
        // Drop is synchronous, so the interrupt is spawned detached. Guard on a
        // live runtime: during shutdown the drop can run with no runtime, where
        // `tokio::spawn` would panic. Then the process is exiting anyway, so the
        // GPU job is the OS/ComfyUI's problem, not a panic-in-Drop → abort.
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let comfy_base = self.comfy_base.clone();
        let http = self.http.clone();
        handle.spawn(async move {
            interrupt_comfy(&comfy_base, &http, &prompt_id).await;
        });
    }
}

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

/// Upload raw image bytes into ComfyUI's temp folder so a `LoadImage` node can
/// reference them without placing user attachments in ComfyUI's durable input
/// library. Returns an annotated filename like `foo.png [temp]` (ComfyUI's
/// `LoadImage` resolves `[temp]` via `folder_paths.get_annotated_filepath`).
pub async fn upload_temp_image(
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
        .text("type", "temp")
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
    Ok(temp_image_ref(
        name,
        v.get("subfolder").and_then(|s| s.as_str()).unwrap_or(""),
    ))
}

/// Submit a fully-prepared workflow, relay progress, and return the produced
/// image as raw bytes plus its content type. The caller decides delivery —
/// inline base64 data URI, or persist to the blob store and hand back a URL.
pub async fn run_workflow(
    cfg: &Config,
    http: &reqwest::Client,
    mut workflow: Value,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<(Vec<u8>, String), String> {
    force_temporary_outputs(&mut workflow);

    let client_id = uuid::Uuid::new_v4().simple().to_string();

    // Open the progress WS *before* submitting so we never miss early frames.
    let ws_url = ws_url(cfg, &client_id)?;
    let (mut ws, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .map_err(|e| format!("cannot open ComfyUI websocket: {e}"))?;

    // From here on, if this future is dropped (turn cancelled / app stopped) or
    // we bail on timeout/error, tell ComfyUI to abandon the prompt so the GPU is
    // freed instead of running the generation orphaned.
    let mut interrupt = InterruptOnDrop {
        comfy_base: cfg.comfy_base.clone(),
        http: http.clone(),
        prompt_id: None,
    };

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
    interrupt.prompt_id = Some(prompt_id.clone());

    // Submitted but not yet dequeued: until ComfyUI starts the graph (model load
    // can take seconds) there are no progress frames, so announce the wait rather
    // than leaving the app frozen on the caller's "preparing…"/"uploading…" status.
    let _ = tx.send(TurnEvent::Status(STATUS_QUEUED.into())).await;

    // Consume progress until completion / timeout. `last_pct` is a 3-state marker:
    // -2 = nothing seen yet, -1 = execution started (indeterminate heartbeat sent),
    // 0..=100 = determinate sampling progress.
    let deadline = tokio::time::sleep(Duration::from_secs(cfg.comfy_timeout_s));
    tokio::pin!(deadline);
    let mut last_pct: i64 = -2;
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

    // Generation finished (or the WS closed): the image is in ComfyUI's history,
    // so disarm the guard. A timeout/WS-error bails earlier with it still armed,
    // which is what frees the GPU on those paths.
    interrupt.prompt_id = None;

    // Fetch the produced image: first locate it in ComfyUI's history…
    let _ = tx.send(TurnEvent::Status(STATUS_RETRIEVING.into())).await;
    fetch_image(cfg, http, &prompt_id, tx).await
}

/// Encode produced bytes as a `data:<mime>;base64,…` URI (inline delivery).
pub fn to_data_uri(bytes: &[u8], mime: &str) -> String {
    let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
    format!("data:{mime};base64,{b64}")
}

fn temp_image_ref(name: &str, subfolder: &str) -> String {
    let path = if subfolder.is_empty() {
        name.to_string()
    } else {
        format!("{subfolder}/{name}")
    };
    format!("{path} [temp]")
}

/// Convert durable built-in image output nodes into temp previews. This lets
/// ComfyUI expose the image through `/history` + `/view` without writing it to
/// the durable output library. Custom workflows may still use `SaveImage`; the
/// orchestrator rewrites it at submission time so the privacy boundary does not
/// depend on every workflow author remembering to use `PreviewImage`.
fn force_temporary_outputs(workflow: &mut Value) {
    let Some(nodes) = workflow.as_object_mut() else {
        return;
    };
    for node in nodes.values_mut() {
        let Some(obj) = node.as_object_mut() else {
            continue;
        };
        if obj.get("class_type").and_then(Value::as_str) == Some("SaveImage") {
            obj.insert("class_type".into(), Value::String("PreviewImage".into()));
            if let Some(inputs) = obj.get_mut("inputs").and_then(Value::as_object_mut) {
                inputs.remove("filename_prefix");
            }
        }
    }
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
                    .send(TurnEvent::Progress {
                        status: STATUS_GENERATING.into(),
                        progress: pct as f64 / 100.0,
                    })
                    .await;
            }
            Some(false)
        }
        "executing" => {
            let node_is_null = data?.get("node").map(|n| n.is_null()).unwrap_or(false);
            let same_prompt = data?.get("prompt_id").and_then(|p| p.as_str()) == Some(prompt_id);
            // `node: null` for our prompt signals completion (older ComfyUI).
            if node_is_null {
                return Some(same_prompt);
            }
            // First sign of execution, before any determinate progress (`last_pct`
            // still at its -2 start): emit a one-time heartbeat so the pre-sampling
            // stretch (model load, VAE encode of the edit input) shows movement
            // instead of a frozen "queued…". Mark it sent by advancing to -1; once
            // `progress` frames flow, the determinate bar takes over the same label.
            if same_prompt && *last_pct == -2 {
                *last_pct = -1;
                let _ = tx.send(TurnEvent::Status(STATUS_GENERATING.into())).await;
            }
            Some(false)
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
    tx: &mpsc::Sender<TurnEvent>,
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
    // Known body length, if usable for a determinate bar (absent on chunked/gzip).
    let total = resp.content_length().map(|l| l as usize).filter(|l| *l > 0);
    // Fast reject on an advertised oversized body before streaming it.
    if let Some(len) = total {
        if len > cap {
            return Err(format!("image too large ({len} bytes > {cap} cap)"));
        }
    }
    // …then transfer the bytes: a distinct step from the history lookup. When the
    // body length is known this is a determinate bar; otherwise it stays an
    // indeterminate "downloading…" heartbeat (no number to report).
    let _ = tx.send(TurnEvent::Status(STATUS_DOWNLOADING.into())).await;
    // Stream-accumulate so a missing/lying Content-Length can't blow past the cap.
    let mut bytes = Vec::new();
    let mut stream = resp.bytes_stream();
    let mut last_pct: i64 = -1;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        if bytes.len() + chunk.len() > cap {
            return Err(format!("image exceeds {cap} byte cap"));
        }
        bytes.extend_from_slice(&chunk);
        if let Some(total) = total {
            let pct = (bytes.len() * 100 / total).min(100) as i64;
            if pct != last_pct {
                last_pct = pct;
                let _ = tx
                    .send(TurnEvent::Progress {
                        status: STATUS_DOWNLOADING.into(),
                        progress: pct as f64 / 100.0,
                    })
                    .await;
            }
        }
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

    #[test]
    fn temp_image_ref_marks_comfy_temp_folder() {
        assert_eq!(temp_image_ref("in.png", ""), "in.png [temp]");
        assert_eq!(temp_image_ref("in.png", "turns"), "turns/in.png [temp]");
    }

    #[test]
    fn force_temporary_outputs_rewrites_save_image() {
        let mut wf = serde_json::json!({
            "9": {
                "class_type": "SaveImage",
                "inputs": { "filename_prefix": "phantasm", "images": ["8", 0] }
            },
            "8": {
                "class_type": "VAEDecode",
                "inputs": { "samples": ["3", 0] }
            }
        });

        force_temporary_outputs(&mut wf);

        assert_eq!(wf["9"]["class_type"], "PreviewImage");
        assert_eq!(wf["9"]["inputs"]["images"], serde_json::json!(["8", 0]));
        assert!(wf["9"]["inputs"].get("filename_prefix").is_none());
        assert_eq!(wf["8"]["class_type"], "VAEDecode");
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

    #[tokio::test]
    async fn executing_emits_one_presampling_heartbeat() {
        let (tx, mut rx) = mpsc::channel(4);
        // -2 is the start sentinel: nothing seen yet.
        let mut last = -2;
        let frame = r#"{"type":"executing","data":{"node":"3","prompt_id":"pid"}}"#;

        // First non-null executing frame for our prompt → one heartbeat, not done.
        assert_eq!(
            handle_ws_message(frame, "pid", &mut last, &tx).await,
            Some(false)
        );
        assert!(matches!(rx.try_recv(), Ok(TurnEvent::Status(s)) if s == STATUS_GENERATING));

        // Subsequent executing frames stay quiet (heartbeat already advanced to -1).
        assert_eq!(
            handle_ws_message(frame, "pid", &mut last, &tx).await,
            Some(false)
        );
        assert!(rx.try_recv().is_err());

        // Once determinate progress has been seen, no late heartbeat either.
        let mut last = 50;
        assert_eq!(
            handle_ws_message(frame, "pid", &mut last, &tx).await,
            Some(false)
        );
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn executing_null_node_marks_completion() {
        let (tx, _rx) = mpsc::channel(4);
        let mut last = -2;
        let done = r#"{"type":"executing","data":{"node":null,"prompt_id":"pid"}}"#;
        assert_eq!(
            handle_ws_message(done, "pid", &mut last, &tx).await,
            Some(true)
        );
    }

    #[test]
    fn ws_url_uses_ws_scheme_and_port() {
        let cfg = crate::config::tests_support::minimal();
        let url = ws_url(&cfg, "abc").unwrap();
        assert_eq!(url, "ws://localhost:8188/ws?clientId=abc");
    }
}
