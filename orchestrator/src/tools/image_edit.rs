//! Image editing tool backed by ComfyUI (FR-O5).
//!
//! Unlike generation, editing needs an input image: it takes the user's most
//! recent attached image (surfaced via [`crate::orchestrator::tools::TurnContext`]),
//! uploads it into ComfyUI's input folder, injects it plus the instruction into
//! the configured edit workflow, runs it, and embeds the result as markdown.
//! The output size is determined by the workflow (e.g. Klein mirrors the input).

use base64::Engine;
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
use crate::tools::image_gen::seed_value;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ImageEditArgs {
    /// An instruction describing the edit, e.g. "add sunglasses" or "make it night".
    pub prompt: String,
    /// Seed for reproducibility (optional; randomized when omitted).
    #[serde(default)]
    pub seed: Option<u64>,
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
         change or modify a picture already in the chat. The edited image is \
         shown to the user.",
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

    // Edit the most recent image in the conversation (attached or generated).
    let Some(input_b64) = ctx.input_images.last() else {
        return error_outcome(
            call_id,
            "no image to edit; ask the user to attach or generate one".into(),
        );
    };

    let _ = tx.send(TurnEvent::Status("preparing edit…".into())).await;

    let result = tokio::select! {
        r = edit(cfg, http, &args, input_b64, tx) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok(data_uri) => ToolOutcome {
            message: ChatMessage::tool_result(
                call_id,
                "image_edit",
                "Image edited successfully and shown to the user.",
            ),
            append_to_answer: Some(format!("![edited]({data_uri})")),
        },
        Err(detail) => {
            tracing::warn!(error = %detail, "image_edit failed");
            let _ = tx
                .send(TurnEvent::Status("image editing unavailable".into()))
                .await;
            error_outcome(call_id, detail)
        }
    }
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
) -> Result<String, String> {
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

    let image_node = cfg
        .comfy_edit_image
        .as_ref()
        .ok_or("no image node configured")?;
    comfy::set_input(workflow, image_node, Value::String(image_name.to_string()))
        .map_err(|e| format!("image node: {e}"))?;

    if let Some(node) = &cfg.comfy_edit_seed {
        let _ = comfy::set_input(workflow, node, Value::from(seed_value(args.seed)));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
            "4": { "inputs": { "image": "" } },
            "16": { "inputs": { "noise_seed": 0 } },
        });
        let args = ImageEditArgs {
            prompt: "add a hat".into(),
            seed: Some(7),
        };
        inject_inputs(&cfg, &mut wf, &args, "uploaded.png").unwrap();
        assert_eq!(wf["8"]["inputs"]["text"], "add a hat");
        assert_eq!(wf["4"]["inputs"]["image"], "uploaded.png");
        assert_eq!(wf["16"]["inputs"]["noise_seed"], 7);
    }
}
