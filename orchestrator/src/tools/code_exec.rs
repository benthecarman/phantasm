//! Code-execution tool. Runs untrusted, model-authored code in a sandboxed,
//! one-shot container borrowed from the warm pool (see [`code_exec_pool`]). This
//! module is language-agnostic: it validates the requested language against the
//! deployment's configured set, enforces a source-size cap, and hands the work to
//! the pool. The pool/image own the per-language knowledge and all sandboxing
//! (resource caps, read-only FS, filtered network egress).
//!
//! [`code_exec_pool`]: crate::tools::code_exec_pool

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;
use crate::tools::code_exec_pool::{CodeExecPool, ExecOutput};

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CodeExecArgs {
    /// Programming language to run the code in. Must be one of the server's
    /// supported languages.
    pub language: String,
    /// The program source to execute. It runs in a fresh sandbox with no access to
    /// prior runs; print results to stdout.
    pub code: String,
}

/// Build the `code_exec` tool schema. The `language` field is constrained to the
/// deployment's configured languages (an `enum`), so the model only ever picks a
/// runnable one. The same tool backs both network lanes; whether a given run gets
/// internet is decided per turn by whether web access is enabled, so the
/// description states that conditionally rather than picking a lane here.
pub fn schema(languages: &[String]) -> Value {
    let mut params = serde_json::to_value(schemars::schema_for!(CodeExecArgs))
        .unwrap_or_else(|_| json!({"type": "object"}));
    if let Some(language) = params.pointer_mut("/properties/language") {
        if let Some(obj) = language.as_object_mut() {
            obj.insert(
                "enum".into(),
                Value::Array(languages.iter().cloned().map(Value::String).collect()),
            );
        }
    }
    let description = format!(
        "Execute code in a sandboxed container and return its stdout/stderr. \
         Internet access is available only when web access is enabled for this \
         conversation (and even then the code cannot reach the server's internal \
         services or local network); otherwise the code has no network at all. \
         Each run is isolated and leaves nothing behind; there is no state between \
         calls and no access to the server's files. Supported languages: {}.",
        languages.join(", ")
    );
    tool_envelope("code_exec", &description, params)
}

pub async fn run(
    cfg: &Config,
    pool: &CodeExecPool,
    call: &ToolCall,
    call_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: CodeExecArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };

    let language = match normalize_language(cfg, &args.language) {
        Ok(l) => l,
        Err(e) => return error_outcome(call_id, e),
    };
    if args.code.len() > cfg.code_exec_max_code_bytes {
        return error_outcome(
            call_id,
            format!(
                "code too large ({} bytes > {} cap)",
                args.code.len(),
                cfg.code_exec_max_code_bytes
            ),
        );
    }

    let _ = tx
        .send(TurnEvent::Status(format!("running {language} code…")))
        .await;

    match pool.execute(&language, &args.code, cancel).await {
        Ok(out) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "code_exec", format_output(&language, &out)),
            append_to_answer: None,
        },
        Err(e) => {
            tracing::warn!(error = %e, "code_exec failed");
            error_outcome(call_id, e)
        }
    }
}

/// Validate the requested language against the configured set, returning the
/// canonical (lowercased) name. Defense-in-depth behind the schema `enum`.
fn normalize_language(cfg: &Config, requested: &str) -> Result<String, String> {
    let want = requested.trim().to_ascii_lowercase();
    if cfg
        .code_exec_languages
        .iter()
        .any(|l| l.eq_ignore_ascii_case(&want))
    {
        Ok(want)
    } else {
        Err(format!(
            "unsupported language `{requested}`; available: {}",
            cfg.code_exec_languages.join(", ")
        ))
    }
}

fn format_output(language: &str, out: &ExecOutput) -> String {
    if out.timed_out {
        return format!("Code execution ({language}) timed out before finishing.");
    }
    let mut s = format!("Code execution result ({language}):\n");
    match out.exit_code {
        Some(0) => {}
        Some(code) => s.push_str(&format!("exit code: {code}\n")),
        None => s.push_str("exit code: unknown (process was killed)\n"),
    }
    if !out.stdout.is_empty() {
        s.push_str("stdout:\n");
        s.push_str(&out.stdout);
        if !out.stdout.ends_with('\n') {
            s.push('\n');
        }
    }
    if !out.stderr.is_empty() {
        s.push_str("stderr:\n");
        s.push_str(&out.stderr);
        if !out.stderr.ends_with('\n') {
            s.push('\n');
        }
    }
    if out.stdout.is_empty() && out.stderr.is_empty() {
        s.push_str("(no output)\n");
    }
    if out.truncated {
        s.push_str("[output truncated]\n");
    }
    s
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "code_exec",
            format!("code execution failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        let mut c = crate::config::tests_support::minimal();
        c.code_exec_languages = vec!["python".into(), "bash".into()];
        c
    }

    #[test]
    fn schema_constrains_language_to_configured_set() {
        let langs = vec!["python".to_string(), "node".to_string()];
        let s = schema(&langs);
        assert_eq!(s.pointer("/function/name").unwrap(), "code_exec");
        let enum_vals = s
            .pointer("/function/parameters/properties/language/enum")
            .and_then(Value::as_array)
            .expect("language enum present");
        assert_eq!(enum_vals.len(), 2);
        assert!(enum_vals.iter().any(|v| v == "python"));
        assert!(enum_vals.iter().any(|v| v == "node"));
    }

    #[test]
    fn normalize_accepts_configured_language_case_insensitively() {
        assert_eq!(normalize_language(&cfg(), "Python").unwrap(), "python");
    }

    #[test]
    fn normalize_rejects_unknown_language() {
        let err = normalize_language(&cfg(), "ruby").unwrap_err();
        assert!(err.contains("unsupported language `ruby`"));
        assert!(err.contains("python"));
    }

    #[test]
    fn format_reports_stdout_and_nonzero_exit() {
        let out = ExecOutput {
            stdout: "42".into(),
            exit_code: Some(1),
            ..Default::default()
        };
        let s = format_output("python", &out);
        assert!(s.contains("exit code: 1"));
        assert!(s.contains("stdout:\n42"));
    }

    #[test]
    fn format_marks_timeout_and_truncation() {
        let timed = ExecOutput {
            timed_out: true,
            ..Default::default()
        };
        assert!(format_output("bash", &timed).contains("timed out"));

        let trunc = ExecOutput {
            stdout: "x".into(),
            truncated: true,
            ..Default::default()
        };
        assert!(format_output("bash", &trunc).contains("[output truncated]"));
    }
}
