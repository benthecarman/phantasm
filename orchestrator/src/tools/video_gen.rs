//! Configurable video-generation tool backed by an operator-owned ComfyUI workflow.
//!
//! The model supplies only bounded semantic inputs. The graph, model choice,
//! sampler, and output encoding remain deployment configuration.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome, TurnContext};
use crate::orchestrator::TurnEvent;
use crate::tools::{comfy, error_outcome};

const WORKFLOW_FILE_CAP: u64 = 2 * 1024 * 1024;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct VideoGenArgs {
    /// A description of the video to generate, including subject, action, scene, and camera movement.
    pub prompt: String,
    /// Visual qualities or content to avoid (optional).
    #[serde(default)]
    pub negative_prompt: Option<String>,
    /// Video width in pixels (optional; otherwise uses the workflow default).
    #[serde(default)]
    pub width: Option<u64>,
    /// Video height in pixels (optional; otherwise uses the workflow default).
    #[serde(default)]
    pub height: Option<u64>,
    /// Number of frames (optional; workflow-specific, so prefer its default).
    #[serde(default)]
    pub frames: Option<u64>,
    /// Playback frames per second (optional; otherwise uses the workflow default).
    #[serde(default)]
    pub fps: Option<f64>,
    /// Seed for reproducibility (optional; randomized when omitted).
    #[serde(default)]
    pub seed: Option<u64>,
}

pub fn schema() -> Value {
    tool_envelope(
        "video_generation",
        "Generate a short video from a text description. The video is shown with playback controls.",
        serde_json::to_value(schemars::schema_for!(VideoGenArgs))
            .unwrap_or_else(|_| serde_json::json!({"type":"object"})),
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
    let args: VideoGenArgs = match call.function.arguments.parse() {
        Ok(args) => args,
        Err(e) => {
            return error_outcome(
                "video_generation",
                call_id,
                format!("invalid arguments: {e}"),
            )
        }
    };
    let _ = tx.send(TurnEvent::Status("preparing video…".into())).await;
    let result = tokio::select! {
        result = generate(cfg, http, ctx, &args, tx) => result,
        _ = cancel.cancelled() => Err("cancelled".into()),
    };
    match result {
        Ok(markdown) => ToolOutcome {
            message: ChatMessage::tool_result(
                call_id,
                "video_generation",
                "Video generated and already displayed. Do not repeat its URL or Markdown.",
            ),
            append_to_answer: Some(markdown),
            is_error: false,
        },
        Err(error) => {
            tracing::warn!(error = %error, "video_generation failed");
            error_outcome("video_generation", call_id, error)
        }
    }
}

async fn generate(
    cfg: &Config,
    http: &reqwest::Client,
    ctx: &TurnContext,
    args: &VideoGenArgs,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<String, String> {
    let path = cfg
        .comfy_video_workflow
        .as_ref()
        .ok_or_else(|| "no ComfyUI video workflow configured".to_string())?;
    let metadata = tokio::fs::metadata(path)
        .await
        .map_err(|e| format!("cannot stat video workflow: {e}"))?;
    if metadata.len() > WORKFLOW_FILE_CAP {
        return Err("video workflow exceeds 2 MiB cap".into());
    }
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|e| format!("cannot read video workflow: {e}"))?;
    let mut workflow: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("invalid video workflow JSON: {e}"))?;
    inject_inputs(cfg, &mut workflow, args)?;
    let artifact = comfy::run_video_workflow(cfg, http, workflow, tx).await?;
    let mime = crate::images::recognized_video_type(&artifact.bytes).ok_or_else(|| {
        format!(
            "video workflow returned unsupported file {}",
            artifact.filename
        )
    })?;
    let store = ctx
        .images
        .as_ref()
        .ok_or_else(|| "artifact store unavailable".to_string())?;
    let id = store
        .put(&artifact.bytes)
        .await
        .map_err(|e| format!("cannot store generated video: {e}"))?;
    let label: String = artifact
        .filename
        .chars()
        .filter(|c| !c.is_control() && *c != '[' && *c != ']')
        .take(100)
        .collect();
    tracing::debug!(mime, bytes = artifact.bytes.len(), "video artifact stored");
    Ok(format!("[Video: {label}]({})", store.signed_ref(&id)))
}

fn inject_inputs(cfg: &Config, workflow: &mut Value, args: &VideoGenArgs) -> Result<(), String> {
    let prompt = cfg
        .comfy_video_prompt
        .as_ref()
        .ok_or_else(|| "COMFYUI_VIDEO_PROMPT is not configured".to_string())?;
    comfy::set_input(workflow, prompt, Value::String(args.prompt.clone()))?;
    if let (Some(target), Some(negative)) =
        (&cfg.comfy_video_negative, args.negative_prompt.as_ref())
    {
        comfy::set_input(workflow, target, Value::String(negative.clone()))?;
    }
    if let (Some(target), Some(width)) = (&cfg.comfy_video_width, args.width) {
        comfy::set_input(workflow, target, Value::from(clamp_dimension(width)))?;
    }
    if let (Some(target), Some(height)) = (&cfg.comfy_video_height, args.height) {
        comfy::set_input(workflow, target, Value::from(clamp_dimension(height)))?;
    }
    if let (Some(target), Some(frames)) = (&cfg.comfy_video_frames, args.frames) {
        comfy::set_input(workflow, target, Value::from(frames.clamp(1, 481)))?;
    }
    if let (Some(target), Some(fps)) = (&cfg.comfy_video_fps, args.fps) {
        if !(1.0..=60.0).contains(&fps) || !fps.is_finite() {
            return Err("fps must be between 1 and 60".into());
        }
        comfy::set_input(workflow, target, serde_json::json!(fps))?;
    }
    if let Some(target) = &cfg.comfy_video_seed {
        comfy::set_input(
            workflow,
            target,
            Value::Number(crate::tools::image_gen::seed_value(args.seed).into()),
        )?;
    }
    Ok(())
}

fn clamp_dimension(px: u64) -> u64 {
    (px.clamp(128, 1920) / 32) * 32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn injects_configured_video_inputs() {
        let mut cfg = crate::config::tests_support::minimal();
        cfg.comfy_video_prompt = crate::config::NodeInput::parse("1.text");
        cfg.comfy_video_negative = crate::config::NodeInput::parse("2.text");
        cfg.comfy_video_width = crate::config::NodeInput::parse("3.width");
        cfg.comfy_video_height = crate::config::NodeInput::parse("3.height");
        cfg.comfy_video_frames = crate::config::NodeInput::parse("3.length");
        cfg.comfy_video_fps = crate::config::NodeInput::parse("4.frame_rate");
        cfg.comfy_video_seed = crate::config::NodeInput::parse("5.seed");
        let mut workflow = serde_json::json!({
            "1":{"inputs":{"text":""}},
            "2":{"inputs":{"text":""}},
            "3":{"inputs":{"width":512,"height":512,"length":25}},
            "4":{"inputs":{"frame_rate":24.0}},
            "5":{"inputs":{"seed":0}}
        });
        inject_inputs(
            &cfg,
            &mut workflow,
            &VideoGenArgs {
                prompt: "a fox running".into(),
                negative_prompt: Some("text".into()),
                width: Some(641),
                height: Some(385),
                frames: Some(49),
                fps: Some(24.0),
                seed: Some(42),
            },
        )
        .unwrap();
        assert_eq!(workflow["1"]["inputs"]["text"], "a fox running");
        assert_eq!(workflow["2"]["inputs"]["text"], "text");
        assert_eq!(workflow["3"]["inputs"]["width"], 640);
        assert_eq!(workflow["3"]["inputs"]["height"], 384);
        assert_eq!(workflow["3"]["inputs"]["length"], 49);
        assert_eq!(workflow["4"]["inputs"]["frame_rate"], 24.0);
        assert_eq!(workflow["5"]["inputs"]["seed"], 42);
    }

    #[test]
    fn rejects_invalid_fps() {
        let mut cfg = crate::config::tests_support::minimal();
        cfg.comfy_video_prompt = crate::config::NodeInput::parse("1.text");
        cfg.comfy_video_fps = crate::config::NodeInput::parse("1.fps");
        let mut workflow = serde_json::json!({"1":{"inputs":{"text":"","fps":24.0}}});
        let error = inject_inputs(
            &cfg,
            &mut workflow,
            &VideoGenArgs {
                prompt: "x".into(),
                negative_prompt: None,
                width: None,
                height: None,
                frames: None,
                fps: Some(120.0),
                seed: None,
            },
        )
        .unwrap_err();
        assert!(error.contains("between 1 and 60"));
    }
}
