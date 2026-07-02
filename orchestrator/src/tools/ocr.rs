//! OCR tool backed by `tesseract`. It uses a request-scoped temp file only for
//! process handoff and deletes it when the call finishes.

use std::io::Write;
use std::time::Duration;

use base64::Engine;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tempfile::Builder;
use tokio::process::Command;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome, TurnContext};
use crate::orchestrator::TurnEvent;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct OcrArgs {
    /// Optional raw base64 image payload. When omitted, OCR uses the most recent image in the chat.
    #[serde(default)]
    pub image_base64: Option<String>,
    /// Tesseract language code, e.g. "eng" or "eng+spa". Defaults to "eng".
    #[serde(default)]
    pub language: Option<String>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(OcrArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "ocr",
        "Extract text from an image using OCR. Uses the most recent chat image if no image_base64 is provided.",
        params,
    )
}

pub async fn run(
    cfg: &Config,
    call: &ToolCall,
    call_id: &str,
    ctx: &TurnContext,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: OcrArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };
    let _ = tx
        .send(TurnEvent::Status("reading image text…".into()))
        .await;

    let result = tokio::select! {
        r = ocr(cfg, &args, ctx) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok(text) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "ocr", text),
            append_to_answer: None,
        },
        Err(e) => {
            tracing::warn!(error = %e, "ocr failed");
            error_outcome(call_id, e)
        }
    }
}

async fn ocr(cfg: &Config, args: &OcrArgs, ctx: &TurnContext) -> Result<String, String> {
    let payload = args
        .image_base64
        .as_deref()
        .or_else(|| ctx.input_images.last().map(String::as_str))
        .ok_or("no image available for OCR")?;
    let language = args.language.as_deref().unwrap_or("eng").trim();
    validate_language(language)?;

    let bytes = base64::engine::general_purpose::STANDARD
        .decode(payload)
        .map_err(|e| format!("image is not valid base64: {e}"))?;
    if bytes.len() > cfg.comfy_max_image_bytes {
        return Err(format!(
            "image too large ({} bytes > {} cap)",
            bytes.len(),
            cfg.comfy_max_image_bytes
        ));
    }

    let mut temp = Builder::new()
        .prefix("phantasm_ocr_")
        .suffix(".png")
        .tempfile()
        .map_err(|e| e.to_string())?;
    temp.write_all(&bytes).map_err(|e| e.to_string())?;
    let path = temp.path().to_path_buf();

    let mut cmd = Command::new(&cfg.tesseract_bin);
    cmd.arg(&path)
        .arg("stdout")
        .arg("-l")
        .arg(language)
        // If the future is dropped (timeout, or the turn's cancel `select!`),
        // kill the tesseract process rather than leaving it spinning orphaned.
        .kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(cfg.ocr_timeout_s), cmd.output())
        .await
        .map_err(|_| "OCR timed out".to_string())?
        .map_err(|e| format!("cannot run tesseract: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("tesseract failed: {}", stderr.trim()));
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let text = text
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(cfg.ocr_context_chars)
        .collect::<String>();
    Ok(format!("OCR result:\n{text}"))
}

fn validate_language(language: &str) -> Result<(), String> {
    if language.is_empty() || language.len() > 64 {
        return Err("language must be a non-empty tesseract language code".into());
    }
    if !language
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '_' | '-'))
    {
        return Err("language contains unsupported characters".into());
    }
    Ok(())
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(call_id, "ocr", format!("ocr failed: {detail}")),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_language_codes() {
        assert!(validate_language("eng").is_ok());
        assert!(validate_language("eng+spa").is_ok());
        assert!(validate_language("../eng").is_err());
    }
}
