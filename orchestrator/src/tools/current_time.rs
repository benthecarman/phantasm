//! Current date/time tool. Purely local and stateless.

use chrono::{DateTime, FixedOffset, SecondsFormat, TimeZone, Utc};
use chrono_tz::Tz;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CurrentTimeArgs {
    /// IANA timezone like "America/Chicago", "UTC", or a fixed offset like "-05:00".
    #[serde(default)]
    pub timezone: Option<String>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(CurrentTimeArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "current_time",
        "Get the current date and time for UTC, an IANA timezone, or a fixed UTC offset.",
        params,
    )
}

pub async fn run(
    call: &ToolCall,
    call_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: CurrentTimeArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };
    let _ = tx.send(TurnEvent::Status("checking time…".into())).await;

    tokio::select! {
        result = async { format_time(args.timezone.as_deref()) } => match result {
            Ok(text) => ToolOutcome {
                message: ChatMessage::tool_result(call_id, "current_time", text),
                append_to_answer: None,
            },
            Err(e) => error_outcome(call_id, e),
        },
        _ = cancel.cancelled() => error_outcome(call_id, "cancelled".into()),
    }
}

fn format_time(timezone: Option<&str>) -> Result<String, String> {
    let requested = timezone.unwrap_or("UTC").trim();
    let now = Utc::now();
    let utc = now.to_rfc3339_opts(SecondsFormat::Secs, true);

    if requested.eq_ignore_ascii_case("utc") || requested.is_empty() {
        return Ok(format!(
            "Current time:\ntimezone: UTC\nclock: {}\niso8601: {utc}",
            clock_12h(&now)
        ));
    }

    if let Ok(tz) = requested.parse::<Tz>() {
        let local = now.with_timezone(&tz);
        return Ok(format!(
            "Current time:\ntimezone: {requested}\nclock: {}\niso8601: {}\nutc: {utc}",
            clock_12h(&local),
            local.to_rfc3339_opts(SecondsFormat::Secs, true)
        ));
    }

    if let Some(offset) = parse_offset(requested) {
        let local = now.with_timezone(&offset);
        return Ok(format!(
            "Current time:\ntimezone: UTC{requested}\nclock: {}\niso8601: {}\nutc: {utc}",
            clock_12h(&local),
            local.to_rfc3339_opts(SecondsFormat::Secs, true)
        ));
    }

    Err(format!(
        "unknown timezone `{requested}`; use UTC, an IANA timezone like America/Chicago, or an offset like -05:00"
    ))
}

/// Human-readable 12-hour clock, e.g. "Friday, June 26, 2026 at 3:07:42 PM".
fn clock_12h<Tz: TimeZone>(dt: &DateTime<Tz>) -> String
where
    Tz::Offset: std::fmt::Display,
{
    dt.format("%A, %B %-d, %Y at %-I:%M:%S %p").to_string()
}

fn parse_offset(raw: &str) -> Option<FixedOffset> {
    let sign = match raw.as_bytes().first()? {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let (hh, mm) = raw[1..].split_once(':')?;
    let hours: i32 = hh.parse().ok()?;
    let minutes: i32 = mm.parse().ok()?;
    if hours > 23 || minutes > 59 {
        return None;
    }
    FixedOffset::east_opt(sign * (hours * 3600 + minutes * 60))
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "current_time",
            format!("current_time failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_fixed_offset() {
        assert!(parse_offset("-05:00").is_some());
        assert!(parse_offset("+14:00").is_some());
        assert!(parse_offset("05:00").is_none());
        assert!(parse_offset("+24:00").is_none());
    }

    #[test]
    fn formats_iana_timezone() {
        let out = format_time(Some("America/Chicago")).unwrap();
        assert!(out.contains("timezone: America/Chicago"));
        assert!(out.contains("utc: "));
        assert!(out.contains("clock: "));
        // 12-hour clock always carries an AM/PM marker.
        assert!(out.contains(" AM") || out.contains(" PM"));
    }
}
