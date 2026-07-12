//! Configurable audio-generation tool backed by a fixed ComfyUI workflow.
//!
//! The model supplies only prompt-level inputs. The operator owns the graph and
//! node mappings, keeping this predictable for small local tool-calling models.

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
pub struct AudioGenArgs {
    /// A description of the music, ambience, or sound to generate.
    pub prompt: String,
    /// Sounds or qualities to avoid (optional).
    #[serde(default)]
    pub negative_prompt: Option<String>,
    /// Optional song lyrics. Omit for instrumental music or sound effects.
    #[serde(default)]
    pub lyrics: Option<String>,
    /// Requested duration in seconds (optional; 0.5-300, otherwise the workflow default).
    #[serde(default)]
    pub duration_seconds: Option<f64>,
    /// Seed for reproducibility (optional; randomized when omitted).
    #[serde(default)]
    pub seed: Option<u64>,
}

pub fn schema() -> Value {
    tool_envelope(
        "audio_generation",
        "Generate music, ambience, or a sound effect from a text description. The audio is shown with playback controls.",
        serde_json::to_value(schemars::schema_for!(AudioGenArgs))
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
    let args: AudioGenArgs = match call.function.arguments.parse() {
        Ok(args) => args,
        Err(e) => {
            return error_outcome(
                "audio_generation",
                call_id,
                format!("invalid arguments: {e}"),
            )
        }
    };
    let _ = tx.send(TurnEvent::Status("preparing audio…".into())).await;
    let result = tokio::select! {
        result = generate(cfg, http, ctx, &args, tx) => result,
        _ = cancel.cancelled() => Err("cancelled".into()),
    };
    match result {
        Ok(markdown) => ToolOutcome {
            message: ChatMessage::tool_result(
                call_id,
                "audio_generation",
                "Audio generated and already displayed. Do not repeat its URL or Markdown.",
            ),
            append_to_answer: Some(markdown),
            is_error: false,
        },
        Err(error) => {
            tracing::warn!(error = %error, "audio_generation failed");
            error_outcome("audio_generation", call_id, error)
        }
    }
}

async fn generate(
    cfg: &Config,
    http: &reqwest::Client,
    ctx: &TurnContext,
    args: &AudioGenArgs,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<String, String> {
    let path = cfg
        .comfy_audio_workflow
        .as_ref()
        .ok_or_else(|| "no ComfyUI audio workflow configured".to_string())?;
    let metadata = tokio::fs::metadata(path)
        .await
        .map_err(|e| format!("cannot stat audio workflow: {e}"))?;
    if metadata.len() > WORKFLOW_FILE_CAP {
        return Err("audio workflow exceeds 2 MiB cap".into());
    }
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|e| format!("cannot read audio workflow: {e}"))?;
    let mut workflow: Value =
        serde_json::from_slice(&bytes).map_err(|e| format!("invalid audio workflow JSON: {e}"))?;
    inject_inputs(cfg, &mut workflow, args)?;
    let artifact = comfy::run_audio_workflow(cfg, http, workflow, tx).await?;
    let mime = crate::images::recognized_audio_type(&artifact.bytes).ok_or_else(|| {
        format!(
            "audio workflow returned unsupported file {}",
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
        .map_err(|e| format!("cannot store generated audio: {e}"))?;
    let label: String = artifact
        .filename
        .chars()
        .filter(|c| !c.is_control() && *c != '[' && *c != ']')
        .take(100)
        .collect();
    tracing::debug!(mime, bytes = artifact.bytes.len(), "audio artifact stored");
    Ok(format!("[Audio: {label}]({})", store.signed_ref(&id)))
}

fn inject_inputs(cfg: &Config, workflow: &mut Value, args: &AudioGenArgs) -> Result<(), String> {
    let prompt = cfg
        .comfy_audio_prompt
        .as_ref()
        .ok_or_else(|| "COMFYUI_AUDIO_PROMPT is not configured".to_string())?;
    comfy::set_input(workflow, prompt, Value::String(args.prompt.clone()))?;
    if let Some(target) = &cfg.comfy_audio_negative {
        comfy::set_input(
            workflow,
            target,
            Value::String(args.negative_prompt.clone().unwrap_or_default()),
        )?;
    }
    if let Some(target) = &cfg.comfy_audio_lyrics {
        comfy::set_input(
            workflow,
            target,
            Value::String(
                args.lyrics
                    .clone()
                    .unwrap_or_else(|| "[Instrumental]".into()),
            ),
        )?;
    }
    if let (Some(target), Some(duration)) = (&cfg.comfy_audio_duration, args.duration_seconds) {
        if !(0.5..=300.0).contains(&duration) || !duration.is_finite() {
            return Err("duration_seconds must be between 0.5 and 300".into());
        }
        comfy::set_input(workflow, target, serde_json::json!(duration))?;
    }
    if let Some(target) = &cfg.comfy_audio_seed {
        comfy::set_input(
            workflow,
            target,
            Value::Number(crate::tools::image_gen::seed_value(args.seed).into()),
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn injects_configured_audio_inputs() {
        let mut cfg = crate::config::tests_support::minimal();
        cfg.comfy_audio_prompt = crate::config::NodeInput::parse("1.text");
        cfg.comfy_audio_negative = crate::config::NodeInput::parse("2.text");
        cfg.comfy_audio_lyrics = crate::config::NodeInput::parse("2.lyrics");
        cfg.comfy_audio_duration = crate::config::NodeInput::parse("3.seconds");
        cfg.comfy_audio_seed = crate::config::NodeInput::parse("4.seed");
        let mut workflow = serde_json::json!({
            "1":{"inputs":{"text":""}},
            "2":{"inputs":{"text":"","lyrics":""}},
            "3":{"inputs":{"seconds":10.0}},
            "4":{"inputs":{"seed":0}}
        });
        inject_inputs(
            &cfg,
            &mut workflow,
            &AudioGenArgs {
                prompt: "ocean ambience".into(),
                negative_prompt: Some("voices".into()),
                lyrics: Some("[Verse]\nHello".into()),
                duration_seconds: Some(12.5),
                seed: Some(42),
            },
        )
        .unwrap();
        assert_eq!(workflow["1"]["inputs"]["text"], "ocean ambience");
        assert_eq!(workflow["2"]["inputs"]["text"], "voices");
        assert_eq!(workflow["2"]["inputs"]["lyrics"], "[Verse]\nHello");
        assert_eq!(workflow["3"]["inputs"]["seconds"], 12.5);
        assert_eq!(workflow["4"]["inputs"]["seed"], 42);
    }

    #[test]
    fn rejects_oversized_duration() {
        let mut cfg = crate::config::tests_support::minimal();
        cfg.comfy_audio_prompt = crate::config::NodeInput::parse("1.text");
        cfg.comfy_audio_duration = crate::config::NodeInput::parse("1.seconds");
        let mut workflow = serde_json::json!({"1":{"inputs":{"text":"","seconds":1.0}}});
        let err = inject_inputs(
            &cfg,
            &mut workflow,
            &AudioGenArgs {
                prompt: "x".into(),
                negative_prompt: None,
                lyrics: None,
                duration_seconds: Some(999.0),
                seed: None,
            },
        )
        .unwrap_err();
        assert!(err.contains("between 0.5 and 300"));
    }
}
