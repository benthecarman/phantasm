//! Image editing tool backed by ComfyUI (FR-O5).
//!
//! Unlike generation, editing needs an input image: by default the most recent
//! image in the conversation (surfaced via [`crate::orchestrator::tools::TurnContext`]),
//! or a specific one when the model passes an `image_ref`. It uploads that image
//! into ComfyUI's input folder, injects it plus the instruction into the
//! configured edit workflow, runs it, and embeds the result as markdown.
//! The output size is determined by the workflow (e.g. Klein mirrors the input).

use base64::Engine;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::{Config, NodeInput};
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome, TurnContext};
use crate::orchestrator::TurnEvent;
use crate::tools::comfy;
use crate::tools::image_delivery::deliver_image;
use crate::tools::image_gen::seed_value;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ImageEditArgs {
    /// An instruction describing the edit, e.g. "add sunglasses" or "make it night".
    pub prompt: String,
    /// Seed for reproducibility (optional; randomized when omitted).
    #[serde(default)]
    pub seed: Option<u64>,
    /// Optional reference to a specific image already in the conversation: its
    /// `/v1/files/<id>` link (or just the bare `<id>`). Omit to edit the most
    /// recent image, which is the usual case.
    #[serde(default)]
    pub image_ref: Option<String>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(ImageEditArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "image_edit",
        "Edit an existing image by following an instruction (e.g. 'add a hat', \
         'make it look like winter'). Operates on the most recent image in the \
         conversation — whether the user attached it or it was generated \
         earlier — so use this (not image_generation) when the user asks to \
         change or modify a picture already in the chat. To target a specific \
         earlier image instead of the most recent, pass its /v1/files/<id> \
         reference as image_ref. The edited image is shown to the user.",
        params,
    )
}

pub async fn run(
    cfg: &Config,
    http: &reqwest::Client,
    call: &ToolCall,
    call_id: &str,
    ctx: &TurnContext,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: ImageEditArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };

    // The image to edit: the model's explicit `image_ref` resolved against the
    // store when given, else the most recent image in the conversation.
    let input_b64 = match resolve_input_image(&args, ctx).await {
        Ok(b64) => b64,
        Err(detail) => return error_outcome(call_id, detail),
    };

    let _ = tx.send(TurnEvent::Status("preparing edit…".into())).await;

    let result = tokio::select! {
        r = edit(cfg, http, &args, &input_b64, tx) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok((bytes, mime)) => {
            let markdown = deliver_image(ctx, &bytes, &mime, "edited").await;
            ToolOutcome {
                message: ChatMessage::tool_result(
                    call_id,
                    "image_edit",
                    "Image edited successfully and shown to the user.",
                ),
                append_to_answer: Some(markdown),
            }
        }
        Err(detail) => {
            tracing::warn!(error = %detail, "image_edit failed");
            let _ = tx
                .send(TurnEvent::Status("image editing unavailable".into()))
                .await;
            error_outcome(call_id, detail)
        }
    }
}

/// The base64 of the image to edit. An explicit `image_ref` is resolved against
/// the store and **must** resolve — a missing/unknown/garbled ref is an error
/// (non-fatal: it folds into the tool message, so the model can retry with a
/// valid ref), never a silent fall-back to a different image. Only when no
/// `image_ref` is given do we default to the most recent image in the turn.
async fn resolve_input_image(args: &ImageEditArgs, ctx: &TurnContext) -> Result<String, String> {
    if let Some(reference) = args
        .image_ref
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        // The model sometimes pastes a whole inline image it saw (`data:…;base64,…`)
        // rather than a store reference. The bytes are right there — use them
        // directly instead of failing (and echoing megabytes back in the error).
        if let Some((_, b64)) = reference.split_once(";base64,") {
            return Ok(b64.to_string());
        }
        let id = extract_ref_id(reference);
        let store = ctx.images.as_ref().ok_or_else(|| {
            "image references aren't available (no image store configured); omit \
             image_ref to edit the most recent image"
                .to_string()
        })?;
        let blob = store.get(id).await.ok_or_else(|| {
            format!(
                "no image with reference \"{}\" found in the conversation",
                truncate_for_error(reference)
            )
        })?;
        return Ok(base64::engine::general_purpose::STANDARD.encode(&blob.bytes));
    }
    ctx.input_images
        .last()
        .cloned()
        .ok_or_else(|| "no image to edit; ask the user to attach or generate one".to_string())
}

/// Clamp a model-supplied reference for safe inclusion in an error message — a
/// stray long paste must not bloat the tool result (which re-enters context).
fn truncate_for_error(reference: &str) -> String {
    const MAX: usize = 80;
    if reference.chars().count() <= MAX {
        return reference.to_string();
    }
    let head: String = reference.chars().take(MAX).collect();
    format!("{head}…")
}

/// Pull the content id out of whatever the model passed as an image reference: a
/// full `…/v1/files/<id>/content?…` URL, a site-relative path, or a bare id. The
/// id is the run of our base64url charset after the marker (or the whole string
/// when no marker is present). `store.get` rejects a malformed id, so a garbage
/// reference resolves to `None` and errors upstream.
fn extract_ref_id(reference: &str) -> &str {
    const MARKER: &str = "/v1/files/";
    let tail = match reference.find(MARKER) {
        Some(i) => &reference[i + MARKER.len()..],
        None => reference,
    };
    let end = tail
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
        .unwrap_or(tail.len());
    &tail[..end]
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "image_edit",
            format!("image_edit failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

async fn edit(
    cfg: &Config,
    http: &reqwest::Client,
    args: &ImageEditArgs,
    input_b64: &str,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<(Vec<u8>, String), String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(input_b64)
        .map_err(|e| format!("input image is not valid base64: {e}"))?;
    let filename = format!("phantasm_edit_{}.png", uuid::Uuid::new_v4().simple());
    let image_name = comfy::upload_temp_image(cfg, http, bytes, &filename).await?;

    let mut workflow = load_workflow(cfg.comfy_edit_workflow.as_ref()).await?;
    inject_inputs(cfg, &mut workflow, args, &image_name)?;
    comfy::run_workflow(cfg, http, workflow, tx).await
}

async fn load_workflow(path: Option<&std::path::PathBuf>) -> Result<Value, String> {
    let path = path.ok_or_else(|| "no ComfyUI edit workflow configured".to_string())?;
    let raw = tokio::fs::read_to_string(path)
        .await
        .map_err(|e| format!("cannot read workflow {}: {e}", path.display()))?;
    serde_json::from_str(&raw).map_err(|e| format!("bad workflow JSON: {e}"))
}

/// ComfyUI ships every `LoadImage` node with this placeholder filename. If it
/// survives injection, our uploaded image never reached the node that feeds the
/// graph — so we'd silently edit the placeholder instead of the user's image.
const PLACEHOLDER_IMAGE: &str = "example.png";

fn inject_inputs(
    cfg: &Config,
    workflow: &mut Value,
    args: &ImageEditArgs,
    image_name: &str,
) -> Result<(), String> {
    let prompt_node = cfg
        .comfy_edit_prompt
        .as_ref()
        .ok_or("no prompt node configured")?;
    comfy::set_input(workflow, prompt_node, Value::String(args.prompt.clone()))
        .map_err(|e| format!("prompt node: {e}"))?;

    let image_node = resolve_image_node(cfg, workflow)?;
    comfy::set_input(workflow, &image_node, Value::String(image_name.to_string()))
        .map_err(|e| format!("image node: {e}"))?;

    if let Some(node) = &cfg.comfy_edit_seed {
        let _ = comfy::set_input(workflow, node, Value::from(seed_value(args.seed)));
    }

    // Guard against the "hooked in wrong" failure: if any LoadImage node still
    // holds ComfyUI's placeholder, COMFYUI_EDIT_IMAGE targeted the wrong node and
    // the edit would run on example.png. Fail loudly instead of silently.
    if let Some(node_id) = load_image_with_placeholder(workflow) {
        let configured = cfg
            .comfy_edit_image
            .as_ref()
            .map(|n| format!("{}.{}", n.node, n.key))
            .unwrap_or_else(|| "unset".into());
        return Err(format!(
            "LoadImage node {node_id} still references the \"{PLACEHOLDER_IMAGE}\" \
             placeholder after injection — COMFYUI_EDIT_IMAGE ({configured}) does \
             not point at this workflow's LoadImage node"
        ));
    }
    Ok(())
}

/// Choose the node the uploaded image is injected into. Honors an explicit
/// `COMFYUI_EDIT_IMAGE` when it actually resolves to a `LoadImage` node;
/// otherwise auto-locates the workflow's sole `LoadImage` node, so a missing or
/// stale config still does the right thing. Errors when no single LoadImage node
/// can be chosen (none, or several without a valid config to disambiguate).
fn resolve_image_node(cfg: &Config, workflow: &Value) -> Result<NodeInput, String> {
    if let Some(cfg_node) = &cfg.comfy_edit_image {
        if is_load_image(workflow, &cfg_node.node) {
            return Ok(cfg_node.clone());
        }
        tracing::warn!(
            configured = %format!("{}.{}", cfg_node.node, cfg_node.key),
            "COMFYUI_EDIT_IMAGE does not point at a LoadImage node; auto-locating"
        );
    }

    let load_image_nodes = find_load_image_nodes(workflow);
    match load_image_nodes.as_slice() {
        [only] => Ok(NodeInput {
            node: only.clone(),
            key: "image".to_string(),
        }),
        [] => Err("workflow has no LoadImage node to receive the input image".into()),
        many => Err(format!(
            "workflow has {} LoadImage nodes ({}); set COMFYUI_EDIT_IMAGE to the \
             intended one",
            many.len(),
            many.join(", ")
        )),
    }
}

fn is_load_image(workflow: &Value, node_id: &str) -> bool {
    workflow
        .get(node_id)
        .and_then(|n| n.get("class_type"))
        .and_then(Value::as_str)
        == Some("LoadImage")
}

fn find_load_image_nodes(workflow: &Value) -> Vec<String> {
    let Some(obj) = workflow.as_object() else {
        return Vec::new();
    };
    obj.iter()
        .filter(|(_, node)| node.get("class_type").and_then(Value::as_str) == Some("LoadImage"))
        .map(|(id, _)| id.clone())
        .collect()
}

fn load_image_with_placeholder(workflow: &Value) -> Option<String> {
    let obj = workflow.as_object()?;
    obj.iter().find_map(|(id, node)| {
        let is_li = node.get("class_type").and_then(Value::as_str) == Some("LoadImage");
        let img = node
            .get("inputs")
            .and_then(|i| i.get("image"))
            .and_then(Value::as_str);
        (is_li && img == Some(PLACEHOLDER_IMAGE)).then(|| id.clone())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(dir: std::path::PathBuf) -> crate::images::BlobStore {
        crate::images::BlobStore::new(dir, "k", 3600, 1 << 20, None).unwrap()
    }

    #[test]
    fn extract_ref_id_parses_url_relative_and_bare() {
        assert_eq!(
            extract_ref_id("https://host/v1/files/abc123/content?exp=1&sig=z"),
            "abc123"
        );
        assert_eq!(extract_ref_id("/v1/files/DEF-_4/content"), "DEF-_4");
        assert_eq!(extract_ref_id("abc123"), "abc123");
    }

    #[tokio::test]
    async fn explicit_ref_edits_the_referenced_image_not_most_recent() {
        let tmp = tempfile::tempdir().unwrap();
        let store = store(tmp.path().to_path_buf());
        let png: &[u8] = &[0x89, b'P', b'N', b'G', 1, 2, 3];
        let id = store.put(png).await.unwrap();
        let ctx = TurnContext {
            images: Some(store),
            input_images: vec!["MOSTRECENT".into()],
            ..Default::default()
        };
        let args = ImageEditArgs {
            prompt: "x".into(),
            seed: None,
            image_ref: Some(format!("/v1/files/{id}/content?exp=1&sig=z")),
        };
        let want = base64::engine::general_purpose::STANDARD.encode(png);
        assert_eq!(resolve_input_image(&args, &ctx).await.unwrap(), want);
    }

    #[tokio::test]
    async fn omitted_ref_defaults_to_most_recent() {
        let ctx = TurnContext {
            input_images: vec!["OLD".into(), "RECENT".into()],
            ..Default::default()
        };
        let args = ImageEditArgs {
            prompt: "x".into(),
            seed: None,
            image_ref: None,
        };
        assert_eq!(resolve_input_image(&args, &ctx).await.unwrap(), "RECENT");
    }

    #[tokio::test]
    async fn unresolvable_ref_errors_without_falling_back() {
        let tmp = tempfile::tempdir().unwrap();
        let ctx = TurnContext {
            images: Some(store(tmp.path().to_path_buf())),
            // A most-recent image exists but must NOT be substituted for a bad ref.
            input_images: vec!["MOSTRECENT".into()],
            ..Default::default()
        };
        let args = ImageEditArgs {
            prompt: "x".into(),
            seed: None,
            image_ref: Some("/v1/files/deadbeef/content".into()),
        };
        let err = resolve_input_image(&args, &ctx).await.unwrap_err();
        assert!(err.contains("deadbeef"), "{err}");
    }

    #[tokio::test]
    async fn full_url_and_markdown_refs_resolve() {
        let tmp = tempfile::tempdir().unwrap();
        let store = store(tmp.path().to_path_buf());
        let png: &[u8] = &[0x89, b'P', b'N', b'G', 4, 2];
        let id = store.put(png).await.unwrap();
        let want = base64::engine::general_purpose::STANDARD.encode(png);
        let ctx = TurnContext {
            images: Some(store),
            ..Default::default()
        };
        // A model may paste the whole signed URL, or the entire markdown link it saw.
        for reference in [
            format!("https://host.example/v1/files/{id}/content?exp=1&sig=abc"),
            format!("![edited](https://host.example/v1/files/{id}/content?exp=1&sig=abc)"),
        ] {
            let args = ImageEditArgs {
                prompt: "x".into(),
                seed: None,
                image_ref: Some(reference.clone()),
            };
            assert_eq!(
                resolve_input_image(&args, &ctx).await.unwrap(),
                want,
                "ref {reference:?} should resolve to the stored image"
            );
        }
    }

    #[tokio::test]
    async fn data_uri_ref_uses_its_bytes_directly() {
        // No store needed: a pasted inline image carries its own payload.
        let ctx = TurnContext::default();
        let args = ImageEditArgs {
            prompt: "x".into(),
            seed: None,
            image_ref: Some("data:image/png;base64,SGVsbG8=".into()),
        };
        assert_eq!(resolve_input_image(&args, &ctx).await.unwrap(), "SGVsbG8=");
    }

    #[test]
    fn truncate_for_error_clamps_long_refs() {
        assert_eq!(truncate_for_error("abc123"), "abc123");
        let long = "x".repeat(500);
        let out = truncate_for_error(&long);
        assert!(out.ends_with('…'));
        assert!(
            out.chars().count() <= 81,
            "clamped, got {}",
            out.chars().count()
        );
    }

    fn cfg_with_edit_nodes() -> Config {
        let mut c = crate::config::tests_support::minimal();
        c.comfy_edit_prompt = crate::config::NodeInput::parse("8.text");
        c.comfy_edit_image = crate::config::NodeInput::parse("4.image");
        c.comfy_edit_seed = crate::config::NodeInput::parse("16.noise_seed");
        c
    }

    #[test]
    fn injects_prompt_and_image_name() {
        let cfg = cfg_with_edit_nodes();
        let mut wf = serde_json::json!({
            "8": { "inputs": { "text": "" } },
            "4": { "class_type": "LoadImage", "inputs": { "image": "example.png" } },
            "16": { "inputs": { "noise_seed": 0 } },
        });
        let args = ImageEditArgs {
            prompt: "add a hat".into(),
            seed: Some(7),
            image_ref: None,
        };
        inject_inputs(&cfg, &mut wf, &args, "uploaded.png").unwrap();
        assert_eq!(wf["8"]["inputs"]["text"], "add a hat");
        assert_eq!(wf["4"]["inputs"]["image"], "uploaded.png");
        assert_eq!(wf["16"]["inputs"]["noise_seed"], 7);
    }

    // The original "hooked in wrong" bug: COMFYUI_EDIT_IMAGE points at a real
    // node that isn't the LoadImage, so injection lands elsewhere and the actual
    // LoadImage keeps "example.png". Auto-location rescues it.
    #[test]
    fn auto_locates_load_image_when_config_points_at_wrong_node() {
        let mut cfg = cfg_with_edit_nodes();
        cfg.comfy_edit_image = NodeInput::parse("4.image"); // node 4 is the checkpoint, not LoadImage
        let mut wf = serde_json::json!({
            "8": { "inputs": { "text": "" } },
            "4": { "class_type": "CheckpointLoaderSimple", "inputs": { "ckpt_name": "x" } },
            "11": { "class_type": "LoadImage", "inputs": { "image": "example.png" } },
            "16": { "inputs": { "noise_seed": 0 } },
        });
        let args = ImageEditArgs {
            prompt: "make it night".into(),
            seed: None,
            image_ref: None,
        };
        inject_inputs(&cfg, &mut wf, &args, "uploaded.png").unwrap();
        assert_eq!(wf["11"]["inputs"]["image"], "uploaded.png");
        // The misconfigured node 4 must not have gained a bogus image input.
        assert!(wf["4"]["inputs"].get("image").is_none());
    }

    #[test]
    fn errors_when_no_load_image_node_exists() {
        let cfg = cfg_with_edit_nodes();
        let mut wf = serde_json::json!({
            "8": { "inputs": { "text": "" } },
            "4": { "class_type": "CheckpointLoaderSimple", "inputs": {} },
            "16": { "inputs": { "noise_seed": 0 } },
        });
        let args = ImageEditArgs {
            prompt: "x".into(),
            seed: None,
            image_ref: None,
        };
        let err = inject_inputs(&cfg, &mut wf, &args, "uploaded.png").unwrap_err();
        assert!(err.contains("no LoadImage node"), "{err}");
    }

    #[test]
    fn errors_on_ambiguous_load_image_without_valid_config() {
        let mut cfg = cfg_with_edit_nodes();
        cfg.comfy_edit_image = NodeInput::parse("4.image"); // not a LoadImage → can't disambiguate
        let mut wf = serde_json::json!({
            "8": { "inputs": { "text": "" } },
            "4": { "class_type": "CheckpointLoaderSimple", "inputs": {} },
            "11": { "class_type": "LoadImage", "inputs": { "image": "example.png" } },
            "12": { "class_type": "LoadImage", "inputs": { "image": "example.png" } },
        });
        let args = ImageEditArgs {
            prompt: "x".into(),
            seed: None,
            image_ref: None,
        };
        let err = inject_inputs(&cfg, &mut wf, &args, "uploaded.png").unwrap_err();
        assert!(err.contains("LoadImage nodes"), "{err}");
    }

    // With two LoadImage nodes, an explicit valid config wins; the guard then
    // catches that the *other* one still holds the placeholder.
    #[test]
    fn placeholder_guard_fires_when_a_load_image_is_left_unset() {
        let mut cfg = cfg_with_edit_nodes();
        cfg.comfy_edit_image = NodeInput::parse("11.image");
        let mut wf = serde_json::json!({
            "8": { "inputs": { "text": "" } },
            "11": { "class_type": "LoadImage", "inputs": { "image": "example.png" } },
            "12": { "class_type": "LoadImage", "inputs": { "image": "example.png" } },
            "16": { "inputs": { "noise_seed": 0 } },
        });
        let args = ImageEditArgs {
            prompt: "x".into(),
            seed: None,
            image_ref: None,
        };
        let err = inject_inputs(&cfg, &mut wf, &args, "uploaded.png").unwrap_err();
        assert!(err.contains("placeholder"), "{err}");
    }
}
