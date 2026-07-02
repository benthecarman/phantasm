//! Weather tool backed by Open-Meteo. No API key and no persistence.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::ToolCall;
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;
use crate::tools::http_util;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct WeatherArgs {
    /// Place name to geocode, e.g. "Chicago, IL". Optional when latitude/longitude are supplied.
    #[serde(default)]
    pub location: Option<String>,
    /// Latitude in decimal degrees.
    #[serde(default)]
    pub latitude: Option<f64>,
    /// Longitude in decimal degrees.
    #[serde(default)]
    pub longitude: Option<f64>,
    /// Number of forecast days, 1-7. Defaults to 3.
    #[serde(default)]
    pub forecast_days: Option<u8>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(WeatherArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "weather",
        "Get current weather and a short forecast for a place name or coordinates.",
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
    crate::tools::run_simple(
        "weather",
        call,
        call_id,
        tx,
        cancel,
        |_: &WeatherArgs| "checking weather…".into(),
        |args| async move { weather(cfg, http, &args).await },
    )
    .await
}

async fn weather(
    cfg: &Config,
    http: &reqwest::Client,
    args: &WeatherArgs,
) -> Result<String, String> {
    let place = resolve_place(cfg, http, args).await?;
    let days = args.forecast_days.unwrap_or(3).clamp(1, 7).to_string();
    let url = http_util::join_base(&cfg.open_meteo_base, "/v1/forecast");
    let resp: ForecastResponse = http_util::get_json(
        http.get(url)
        .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
        .query(&[
            ("latitude", place.latitude.to_string()),
            ("longitude", place.longitude.to_string()),
            (
                "current",
                "temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,wind_direction_10m".into(),
            ),
            (
                "daily",
                "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum".into(),
            ),
            ("forecast_days", days),
            ("timezone", "auto".into()),
        ]),
    )
    .await?;

    Ok(format_forecast(&place, &resp))
}

async fn resolve_place(
    cfg: &Config,
    http: &reqwest::Client,
    args: &WeatherArgs,
) -> Result<ResolvedPlace, String> {
    match (args.latitude, args.longitude) {
        (Some(latitude), Some(longitude)) => {
            if !(-90.0..=90.0).contains(&latitude) || !(-180.0..=180.0).contains(&longitude) {
                return Err("coordinates are out of range".into());
            }
            Ok(ResolvedPlace {
                name: args
                    .location
                    .clone()
                    .unwrap_or_else(|| "coordinates".into()),
                latitude,
                longitude,
                country: None,
                admin1: None,
            })
        }
        _ => {
            let name = args
                .location
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or("provide either location or latitude+longitude")?;
            let url = http_util::join_base(&cfg.open_meteo_geocoding_base, "/v1/search");
            let geo: GeocodeResponse = http_util::get_json(
                http.get(url)
                    .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
                    .query(&[
                        ("name", name),
                        ("count", "1"),
                        ("language", "en"),
                        ("format", "json"),
                    ]),
            )
            .await?;
            geo.results
                .into_iter()
                .next()
                .map(|g| ResolvedPlace {
                    name: g.name,
                    latitude: g.latitude,
                    longitude: g.longitude,
                    country: g.country,
                    admin1: g.admin1,
                })
                .ok_or_else(|| format!("no geocoding match for `{name}`"))
        }
    }
}

fn format_forecast(place: &ResolvedPlace, resp: &ForecastResponse) -> String {
    let mut out = format!(
        "Weather for {} ({:.4}, {:.4})",
        place.display_name(),
        place.latitude,
        place.longitude
    );
    if let Some(tz) = &resp.timezone {
        out.push_str(&format!("\ntimezone: {tz}"));
    }
    if let Some(c) = &resp.current {
        out.push_str(&format!(
            "\ncurrent: {:.1}°C, feels like {:.1}°C, humidity {}%, precipitation {:.1} mm, wind {:.1} km/h {}, conditions: {}",
            c.temperature_2m.unwrap_or_default(),
            c.apparent_temperature.unwrap_or_default(),
            c.relative_humidity_2m.unwrap_or_default(),
            c.precipitation.unwrap_or_default(),
            c.wind_speed_10m.unwrap_or_default(),
            c.wind_direction_10m
                .map(compass)
                .unwrap_or("unknown"),
            c.weather_code.map(weather_code).unwrap_or("unknown")
        ));
    }
    if let Some(daily) = &resp.daily {
        out.push_str("\nforecast:");
        for i in 0..daily.time.len().min(7) {
            let high = daily.temperature_2m_max.get(i).copied().unwrap_or_default();
            let low = daily.temperature_2m_min.get(i).copied().unwrap_or_default();
            let rain = daily.precipitation_sum.get(i).copied().unwrap_or_default();
            let code = daily
                .weather_code
                .get(i)
                .copied()
                .map(weather_code)
                .unwrap_or("unknown");
            out.push_str(&format!(
                "\n- {}: {} (high {:.1}°C, low {:.1}°C, precip {:.1} mm)",
                daily.time[i], code, high, low, rain
            ));
        }
    }
    out
}

#[derive(Debug)]
struct ResolvedPlace {
    name: String,
    latitude: f64,
    longitude: f64,
    country: Option<String>,
    admin1: Option<String>,
}

impl ResolvedPlace {
    fn display_name(&self) -> String {
        let mut parts = vec![self.name.clone()];
        if let Some(admin1) = &self.admin1 {
            parts.push(admin1.clone());
        }
        if let Some(country) = &self.country {
            parts.push(country.clone());
        }
        parts.join(", ")
    }
}

#[derive(Debug, Deserialize)]
struct GeocodeResponse {
    #[serde(default)]
    results: Vec<GeocodeResult>,
}

#[derive(Debug, Deserialize)]
struct GeocodeResult {
    name: String,
    latitude: f64,
    longitude: f64,
    #[serde(default)]
    country: Option<String>,
    #[serde(default)]
    admin1: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ForecastResponse {
    #[serde(default)]
    timezone: Option<String>,
    #[serde(default)]
    current: Option<CurrentWeather>,
    #[serde(default)]
    daily: Option<DailyWeather>,
}

#[derive(Debug, Deserialize)]
struct CurrentWeather {
    #[serde(default)]
    temperature_2m: Option<f64>,
    #[serde(default)]
    relative_humidity_2m: Option<u64>,
    #[serde(default)]
    apparent_temperature: Option<f64>,
    #[serde(default)]
    precipitation: Option<f64>,
    #[serde(default)]
    weather_code: Option<u64>,
    #[serde(default)]
    wind_speed_10m: Option<f64>,
    #[serde(default)]
    wind_direction_10m: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct DailyWeather {
    #[serde(default)]
    time: Vec<String>,
    #[serde(default)]
    weather_code: Vec<u64>,
    #[serde(default)]
    temperature_2m_max: Vec<f64>,
    #[serde(default)]
    temperature_2m_min: Vec<f64>,
    #[serde(default)]
    precipitation_sum: Vec<f64>,
}

fn compass(degrees: f64) -> &'static str {
    const DIRS: [&str; 16] = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW",
        "NW", "NNW",
    ];
    let idx = ((degrees / 22.5) + 0.5).floor() as usize % 16;
    DIRS[idx]
}

fn weather_code(code: u64) -> &'static str {
    match code {
        0 => "clear sky",
        1 | 2 => "partly cloudy",
        3 => "overcast",
        45 | 48 => "fog",
        51 | 53 | 55 => "drizzle",
        56 | 57 => "freezing drizzle",
        61 | 63 | 65 => "rain",
        66 | 67 => "freezing rain",
        71 | 73 | 75 => "snow",
        77 => "snow grains",
        80..=82 => "rain showers",
        85 | 86 => "snow showers",
        95 => "thunderstorm",
        96 | 99 => "thunderstorm with hail",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compass_formats_cardinal_direction() {
        assert_eq!(compass(0.0), "N");
        assert_eq!(compass(90.0), "E");
        assert_eq!(compass(225.0), "SW");
    }

    #[test]
    fn formats_place_name() {
        let p = ResolvedPlace {
            name: "Chicago".into(),
            latitude: 41.8,
            longitude: -87.6,
            country: Some("United States".into()),
            admin1: Some("Illinois".into()),
        };
        assert_eq!(p.display_name(), "Chicago, Illinois, United States");
    }
}
