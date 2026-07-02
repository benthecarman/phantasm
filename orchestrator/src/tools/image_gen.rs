//! Image generation tool backed by ComfyUI (FR-O5).
//!
//! Loads the configured generation workflow, injects the prompt (and optional
//! negative / width / height / seed) into the nodes mapped in config, then runs
//! it via [`crate::tools::comfy`] and embeds the produced image in the assistant
//! answer as base64-data-URI markdown.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome, TurnContext};
use crate::orchestrator::TurnEvent;
use crate::tools::comfy;
use crate::tools::image_delivery::deliver_image;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ImageGenArgs {
    /// A description of the image to generate.
    pub prompt: String,
    /// Things to avoid in the image (optional; ignored by guidance-distilled models).
    #[serde(default)]
    pub negative_prompt: Option<String>,
    /// Image width in pixels (optional; defaults to the workflow's own value).
    #[serde(default)]
    pub width: Option<u64>,
    /// Image height in pixels (optional; defaults to the workflow's own value).
    #[serde(default)]
    pub height: Option<u64>,
    /// Seed for reproducibility (optional; randomized when omitted).
    #[serde(default)]
    pub seed: Option<u64>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(ImageGenArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "image_generation",
        "Generate an image from a text prompt. The image is shown to the user.",
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
    let args: ImageGenArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };

    let _ = tx.send(TurnEvent::Status("preparing image…".into())).await;

    let result = tokio::select! {
        r = generate(cfg, http, &args, tx) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok((bytes, mime)) => {
            let markdown = deliver_image(ctx, &bytes, &mime, "generated").await;
            ToolOutcome {
                message: ChatMessage::tool_result(
                    call_id,
                    "image_generation",
                    "Image generated and already displayed to the user inline. \
                     It is shown automatically — do NOT output the image, a URL, \
                     markdown, or any placeholder such as \"[image goes here]\".",
                ),
                append_to_answer: Some(markdown),
            }
        }
        Err(detail) => {
            // The detail never contains message content (NFR-O7) — only the
            // backend failure cause — so log it so operators can diagnose
            // "image generation unavailable" instead of it vanishing silently.
            tracing::warn!(error = %detail, "image_generation failed");
            let _ = tx
                .send(TurnEvent::Status("image generation unavailable".into()))
                .await;
            error_outcome(call_id, detail)
        }
    }
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    crate::tools::error_outcome("image_generation", call_id, detail)
}

async fn generate(
    cfg: &Config,
    http: &reqwest::Client,
    args: &ImageGenArgs,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<(Vec<u8>, String), String> {
    let mut workflow = load_workflow(cfg.comfy_gen_workflow.as_ref()).await?;
    inject_inputs(cfg, &mut workflow, args)?;
    comfy::run_workflow(cfg, http, workflow, tx).await
}

async fn load_workflow(path: Option<&std::path::PathBuf>) -> Result<Value, String> {
    let path = path.ok_or_else(|| "no ComfyUI workflow configured".to_string())?;
    let raw = tokio::fs::read_to_string(path)
        .await
        .map_err(|e| format!("cannot read workflow {}: {e}", path.display()))?;
    serde_json::from_str(&raw).map_err(|e| format!("bad workflow JSON: {e}"))
}

/// Inject prompt/negative/width/height/seed into the configured nodes. Only the
/// prompt node is required; the rest are skipped when unmapped or unset, falling
/// back to the workflow's own baked-in values.
fn inject_inputs(cfg: &Config, workflow: &mut Value, args: &ImageGenArgs) -> Result<(), String> {
    let prompt_node = cfg
        .comfy_gen_prompt
        .as_ref()
        .ok_or("no prompt node configured")?;
    comfy::set_input(workflow, prompt_node, Value::String(args.prompt.clone()))
        .map_err(|e| format!("prompt node: {e}"))?;

    if let (Some(node), Some(neg)) = (&cfg.comfy_gen_negative, &args.negative_prompt) {
        let _ = comfy::set_input(workflow, node, Value::String(neg.clone()));
    }
    if let (Some(node), Some(w)) = (&cfg.comfy_gen_width, args.width) {
        let _ = comfy::set_input(workflow, node, Value::from(clamp_dimension(w)));
    }
    if let (Some(node), Some(h)) = (&cfg.comfy_gen_height, args.height) {
        let _ = comfy::set_input(workflow, node, Value::from(clamp_dimension(h)));
    }
    if let Some(node) = &cfg.comfy_gen_seed {
        let _ = comfy::set_input(workflow, node, Value::from(seed_value(args.seed)));
    }
    Ok(())
}

/// Clamp a model-supplied pixel dimension to a sane range, snapped down to a
/// multiple of 8 (the latent-space stride the SD-family workflows expect).
/// These values are model-controlled: an unclamped 16384×16384 request would
/// be a one-call VRAM OOM on the ComfyUI box.
fn clamp_dimension(px: u64) -> u64 {
    (px.clamp(64, 2048) / 8) * 8
}

/// Use the caller's seed, else derive a pseudo-random one without an extra dep.
pub(crate) fn seed_value(requested: Option<u64>) -> u64 {
    requested.unwrap_or_else(|| (uuid::Uuid::new_v4().as_u128() as u64) & 0xFFFF_FFFF_FFFF)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg_with_gen_nodes() -> Config {
        let mut c = crate::config::tests_support::minimal();
        c.comfy_gen_prompt = crate::config::NodeInput::parse("6.text");
        c.comfy_gen_negative = crate::config::NodeInput::parse("7.text");
        c.comfy_gen_width = crate::config::NodeInput::parse("27.width");
        c.comfy_gen_height = crate::config::NodeInput::parse("27.height");
        c.comfy_gen_seed = crate::config::NodeInput::parse("25.noise_seed");
        c
    }

    #[test]
    fn injects_prompt_and_dimensions() {
        let cfg = cfg_with_gen_nodes();
        let mut wf = serde_json::json!({
            "6": { "inputs": { "text": "" } },
            "7": { "inputs": { "text": "" } },
            "27": { "inputs": { "width": 512, "height": 512 } },
            "25": { "inputs": { "noise_seed": 0 } },
        });
        let args = ImageGenArgs {
            prompt: "a cat".into(),
            negative_prompt: Some("blurry".into()),
            width: Some(1024),
            height: Some(768),
            seed: Some(42),
        };
        inject_inputs(&cfg, &mut wf, &args).unwrap();
        assert_eq!(wf["6"]["inputs"]["text"], "a cat");
        assert_eq!(wf["7"]["inputs"]["text"], "blurry");
        assert_eq!(wf["27"]["inputs"]["width"], 1024);
        assert_eq!(wf["27"]["inputs"]["height"], 768);
        assert_eq!(wf["25"]["inputs"]["noise_seed"], 42);
    }

    #[test]
    fn oversized_dimensions_are_clamped() {
        assert_eq!(clamp_dimension(16384), 2048, "VRAM-OOM sizes are capped");
        assert_eq!(clamp_dimension(1), 64, "degenerate sizes are floored");
        assert_eq!(
            clamp_dimension(1023),
            1016,
            "snapped down to a multiple of 8"
        );
        assert_eq!(clamp_dimension(1024), 1024, "in-range values untouched");

        let cfg = cfg_with_gen_nodes();
        let mut wf = serde_json::json!({
            "6": { "inputs": { "text": "" } },
            "27": { "inputs": { "width": 512, "height": 512 } },
            "25": { "inputs": { "noise_seed": 0 } },
        });
        let args = ImageGenArgs {
            prompt: "a cat".into(),
            negative_prompt: None,
            width: Some(16384),
            height: Some(16384),
            seed: None,
        };
        inject_inputs(&cfg, &mut wf, &args).unwrap();
        assert_eq!(wf["27"]["inputs"]["width"], 2048);
        assert_eq!(wf["27"]["inputs"]["height"], 2048);
    }

    #[test]
    fn omitted_dimensions_keep_workflow_defaults() {
        let cfg = cfg_with_gen_nodes();
        let mut wf = serde_json::json!({
            "6": { "inputs": { "text": "" } },
            "7": { "inputs": { "text": "" } },
            "27": { "inputs": { "width": 512, "height": 512 } },
            "25": { "inputs": { "noise_seed": 0 } },
        });
        let args = ImageGenArgs {
            prompt: "a dog".into(),
            negative_prompt: None,
            width: None,
            height: None,
            seed: None,
        };
        inject_inputs(&cfg, &mut wf, &args).unwrap();
        assert_eq!(wf["27"]["inputs"]["width"], 512, "default kept");
        assert_eq!(
            wf["7"]["inputs"]["text"], "",
            "negative untouched when unset"
        );
        // Seed is always randomized into the mapped node when no arg is given.
        assert_ne!(wf["25"]["inputs"]["noise_seed"], 0);
    }
}
