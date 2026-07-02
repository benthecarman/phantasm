//! Market data tool backed by Alpha Vantage. Read-only and key-gated.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;
use crate::tools::http_util;

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum MarketDataKind {
    /// Stock/ETF quote by symbol, e.g. AAPL.
    StockQuote,
    /// Fiat or crypto exchange rate, e.g. BTC to USD or EUR to USD.
    ExchangeRate,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct MarketDataArgs {
    pub kind: MarketDataKind,
    /// Stock/ETF symbol for kind=stock_quote.
    #[serde(default)]
    pub symbol: Option<String>,
    /// Source currency for kind=exchange_rate, e.g. BTC, EUR.
    #[serde(default)]
    pub from_currency: Option<String>,
    /// Destination currency for kind=exchange_rate, e.g. USD.
    #[serde(default)]
    pub to_currency: Option<String>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(MarketDataArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "market_data",
        "Get current stock/ETF quotes or fiat/crypto exchange rates. Requires the deployment's Alpha Vantage API key.",
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
    let args: MarketDataArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };
    let _ = tx
        .send(TurnEvent::Status("checking market data…".into()))
        .await;

    let result = tokio::select! {
        r = market_data(cfg, http, &args) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok(text) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "market_data", text),
            append_to_answer: None,
        },
        Err(e) => {
            tracing::warn!(error = %e, "market_data failed");
            error_outcome(call_id, e)
        }
    }
}

async fn market_data(
    cfg: &Config,
    http: &reqwest::Client,
    args: &MarketDataArgs,
) -> Result<String, String> {
    let key = cfg
        .alpha_vantage_token
        .as_deref()
        .ok_or("no Alpha Vantage API key configured")?;
    match args.kind {
        MarketDataKind::StockQuote => {
            let symbol = required(&args.symbol, "symbol")?;
            let v = alpha_query(
                cfg,
                http,
                &[
                    ("function", "GLOBAL_QUOTE"),
                    ("symbol", symbol),
                    ("apikey", key),
                ],
            )
            .await?;
            format_stock_quote(symbol, &v)
        }
        MarketDataKind::ExchangeRate => {
            let from = required(&args.from_currency, "from_currency")?;
            let to = required(&args.to_currency, "to_currency")?;
            let v = alpha_query(
                cfg,
                http,
                &[
                    ("function", "CURRENCY_EXCHANGE_RATE"),
                    ("from_currency", from),
                    ("to_currency", to),
                    ("apikey", key),
                ],
            )
            .await?;
            format_exchange_rate(from, to, &v)
        }
    }
}

async fn alpha_query(
    cfg: &Config,
    http: &reqwest::Client,
    params: &[(&str, &str)],
) -> Result<Value, String> {
    let url = http_util::join_base(&cfg.alpha_vantage_base, "/query");
    // Via the shared helper: per-request deadline, capped body, and errors
    // rendered without the URL (the `apikey` rides the query string).
    let v: Value = http_util::get_json(
        http.get(url)
            .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
            .query(params),
    )
    .await?;
    alpha_error(&v)?;
    Ok(v)
}

fn alpha_error(v: &Value) -> Result<(), String> {
    for key in ["Error Message", "Note", "Information"] {
        if let Some(msg) = v.get(key).and_then(Value::as_str) {
            return Err(msg.to_string());
        }
    }
    Ok(())
}

fn required<'a>(value: &'a Option<String>, name: &str) -> Result<&'a str, String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("missing required `{name}`"))
}

fn format_stock_quote(symbol: &str, v: &Value) -> Result<String, String> {
    let q = v
        .get("Global Quote")
        .and_then(Value::as_object)
        .ok_or("missing Global Quote in Alpha Vantage response")?;
    let price = field(q, "05. price");
    let change = field(q, "09. change");
    let change_pct = field(q, "10. change percent");
    let volume = field(q, "06. volume");
    let latest = field(q, "07. latest trading day");
    Ok(format!(
        "Market data:\nkind: stock_quote\nsymbol: {symbol}\nprice: {price}\nchange: {change} ({change_pct})\nvolume: {volume}\nlatest trading day: {latest}"
    ))
}

fn format_exchange_rate(from: &str, to: &str, v: &Value) -> Result<String, String> {
    let q = v
        .get("Realtime Currency Exchange Rate")
        .and_then(Value::as_object)
        .ok_or("missing exchange rate in Alpha Vantage response")?;
    let rate = field(q, "5. Exchange Rate");
    let bid = field(q, "8. Bid Price");
    let ask = field(q, "9. Ask Price");
    let refreshed = field(q, "6. Last Refreshed");
    Ok(format!(
        "Market data:\nkind: exchange_rate\npair: {from}/{to}\nrate: {rate}\nbid: {bid}\nask: {ask}\nlast refreshed: {refreshed}"
    ))
}

fn field(map: &serde_json::Map<String, Value>, key: &str) -> String {
    map.get(key)
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string()
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "market_data",
            format!("market_data failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_stock_quote() {
        let v = serde_json::json!({
            "Global Quote": {
                "05. price": "123.45",
                "09. change": "1.23",
                "10. change percent": "1.0%",
                "06. volume": "100",
                "07. latest trading day": "2026-06-26"
            }
        });
        let out = format_stock_quote("AAPL", &v).unwrap();
        assert!(out.contains("price: 123.45"));
    }

    #[test]
    fn reports_alpha_errors() {
        let v = serde_json::json!({"Note": "rate limited"});
        assert!(alpha_error(&v).is_err());
    }
}
