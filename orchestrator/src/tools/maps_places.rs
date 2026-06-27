//! Place search / geocoding tool backed by Nominatim. Read-only and stateless.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct MapsPlacesArgs {
    /// Place/address/business/category query, e.g. "coffee near Wicker Park Chicago".
    pub query: String,
    /// Maximum results to return, 1-10. Defaults to 5.
    #[serde(default)]
    pub limit: Option<u8>,
    /// Optional ISO country code filter, e.g. "us".
    #[serde(default)]
    pub country_code: Option<String>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(MapsPlacesArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "maps_places",
        "Search for places, addresses, or points of interest and return coordinates plus OpenStreetMap metadata.",
        params,
    )
}

pub async fn run(
    cfg: &Config,
    http: &reqwest::Client,
    call: &ToolCall,
    call_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: MapsPlacesArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };
    let _ = tx.send(TurnEvent::Status("searching places…".into())).await;

    let result = tokio::select! {
        r = search(cfg, http, &args) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok(text) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "maps_places", text),
            append_to_answer: None,
        },
        Err(e) => {
            tracing::warn!(error = %e, "maps_places failed");
            error_outcome(call_id, e)
        }
    }
}

async fn search(
    cfg: &Config,
    http: &reqwest::Client,
    args: &MapsPlacesArgs,
) -> Result<String, String> {
    let query = args.query.trim();
    if query.is_empty() {
        return Err("query is empty".into());
    }
    let limit = args.limit.unwrap_or(5).clamp(1, 10).to_string();
    let url = cfg
        .nominatim_base
        .join("/search")
        .map_err(|e| e.to_string())?;
    let mut req = http
        .get(url)
        .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
        .query(&[
            ("q", query),
            ("format", "jsonv2"),
            ("addressdetails", "1"),
            ("limit", &limit),
        ]);
    if let Some(country) = args
        .country_code
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        req = req.query(&[("countrycodes", country)]);
    }
    let places: Vec<PlaceResult> = req
        .send()
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())?;
    Ok(format_places(query, &places))
}

fn format_places(query: &str, places: &[PlaceResult]) -> String {
    let mut out = format!("Place search results for \"{query}\":");
    if places.is_empty() {
        out.push_str("\n(no results)");
        return out;
    }
    for (i, p) in places.iter().enumerate() {
        out.push_str(&format!(
            "\n{}. {} ({}, {})",
            i + 1,
            p.display_name,
            p.lat,
            p.lon
        ));
        if let Some(kind) = p.kind() {
            out.push_str(&format!(" — {kind}"));
        }
        if let Some(osm_type) = &p.osm_type {
            out.push_str(&format!(
                "; osm: {osm_type} {}",
                p.osm_id.unwrap_or_default()
            ));
        }
    }
    out
}

#[derive(Debug, Deserialize)]
struct PlaceResult {
    display_name: String,
    lat: String,
    lon: String,
    #[serde(default, rename = "class")]
    class_name: Option<String>,
    #[serde(default, rename = "type")]
    type_name: Option<String>,
    #[serde(default)]
    osm_type: Option<String>,
    #[serde(default)]
    osm_id: Option<u64>,
}

impl PlaceResult {
    fn kind(&self) -> Option<String> {
        match (&self.class_name, &self.type_name) {
            (Some(class), Some(kind)) => Some(format!("{class}/{kind}")),
            (Some(class), None) => Some(class.clone()),
            (None, Some(kind)) => Some(kind.clone()),
            _ => None,
        }
    }
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "maps_places",
            format!("maps_places failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_empty_results() {
        let out = format_places("x", &[]);
        assert!(out.contains("(no results)"));
    }
}
