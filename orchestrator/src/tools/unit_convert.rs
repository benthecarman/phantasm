//! Unit conversion tool. Purely local and stateless.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct UnitConvertArgs {
    /// Numeric value to convert.
    pub value: f64,
    /// Source unit, e.g. "mile", "kg", "fahrenheit", "mph", "gb".
    pub from_unit: String,
    /// Destination unit, e.g. "km", "lb", "celsius", "m/s", "mb".
    pub to_unit: String,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(UnitConvertArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "unit_convert",
        "Convert common units of length, area, mass, volume, temperature, speed, and data size.",
        params,
    )
}

pub async fn run(
    call: &ToolCall,
    call_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: UnitConvertArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };
    let _ = tx.send(TurnEvent::Status("converting units…".into())).await;

    tokio::select! {
        result = async { convert(args.value, &args.from_unit, &args.to_unit) } => match result {
            Ok(text) => ToolOutcome {
                message: ChatMessage::tool_result(call_id, "unit_convert", text),
                append_to_answer: None,
            },
            Err(e) => error_outcome(call_id, e),
        },
        _ = cancel.cancelled() => error_outcome(call_id, "cancelled".into()),
    }
}

fn convert(value: f64, from_unit: &str, to_unit: &str) -> Result<String, String> {
    if !value.is_finite() {
        return Err("value is not finite".into());
    }
    let from = normalize(from_unit);
    let to = normalize(to_unit);

    if let (Some(from_temp), Some(to_temp)) = (temperature_unit(&from), temperature_unit(&to)) {
        let c = match from_temp {
            "c" => value,
            "f" => (value - 32.0) * 5.0 / 9.0,
            "k" => value - 273.15,
            _ => unreachable!(),
        };
        let out = match to_temp {
            "c" => c,
            "f" => c * 9.0 / 5.0 + 32.0,
            "k" => c + 273.15,
            _ => unreachable!(),
        };
        return Ok(format_conversion(value, from_unit, out, to_unit));
    }

    let from = unit_factor(&from).ok_or_else(|| format!("unknown source unit `{from_unit}`"))?;
    let to = unit_factor(&to).ok_or_else(|| format!("unknown destination unit `{to_unit}`"))?;
    if from.category != to.category {
        return Err(format!(
            "incompatible units: `{from_unit}` is {}, `{to_unit}` is {}",
            from.category, to.category
        ));
    }

    let out = value * from.factor_to_base / to.factor_to_base;
    Ok(format_conversion(value, from_unit, out, to_unit))
}

fn format_conversion(value: f64, from_unit: &str, out: f64, to_unit: &str) -> String {
    format!("Unit conversion:\n{value:.15} {from_unit} = {out:.15} {to_unit}")
}

fn normalize(unit: &str) -> String {
    let mut out = unit
        .trim()
        .to_ascii_lowercase()
        .replace([' ', '_'], "")
        .to_string();
    if out.ends_with('s') && !out.contains('/') && out != "celsius" {
        out.pop();
    }
    out
}

struct Unit {
    category: &'static str,
    factor_to_base: f64,
}

fn unit_factor(unit: &str) -> Option<Unit> {
    let u = match unit {
        "meter" | "metre" | "m" => Unit {
            category: "length",
            factor_to_base: 1.0,
        },
        "kilometer" | "kilometre" | "km" => Unit {
            category: "length",
            factor_to_base: 1000.0,
        },
        "centimeter" | "centimetre" | "cm" => Unit {
            category: "length",
            factor_to_base: 0.01,
        },
        "millimeter" | "millimetre" | "mm" => Unit {
            category: "length",
            factor_to_base: 0.001,
        },
        "inch" | "in" => Unit {
            category: "length",
            factor_to_base: 0.0254,
        },
        "foot" | "ft" => Unit {
            category: "length",
            factor_to_base: 0.3048,
        },
        "yard" | "yd" => Unit {
            category: "length",
            factor_to_base: 0.9144,
        },
        "mile" | "mi" => Unit {
            category: "length",
            factor_to_base: 1609.344,
        },
        "nauticalmile" | "nmi" => Unit {
            category: "length",
            factor_to_base: 1852.0,
        },

        "squaremeter" | "sqm" | "m2" => Unit {
            category: "area",
            factor_to_base: 1.0,
        },
        "squarekilometer" | "sqkm" | "km2" => Unit {
            category: "area",
            factor_to_base: 1_000_000.0,
        },
        "acre" => Unit {
            category: "area",
            factor_to_base: 4046.8564224,
        },
        "hectare" | "ha" => Unit {
            category: "area",
            factor_to_base: 10_000.0,
        },
        "squarefoot" | "sqft" | "ft2" => Unit {
            category: "area",
            factor_to_base: 0.09290304,
        },
        "squaremile" | "sqmi" | "mi2" => Unit {
            category: "area",
            factor_to_base: 2_589_988.110336,
        },

        "gram" | "g" => Unit {
            category: "mass",
            factor_to_base: 1.0,
        },
        "kilogram" | "kg" => Unit {
            category: "mass",
            factor_to_base: 1000.0,
        },
        "milligram" | "mg" => Unit {
            category: "mass",
            factor_to_base: 0.001,
        },
        "pound" | "lb" => Unit {
            category: "mass",
            factor_to_base: 453.59237,
        },
        "ounce" | "oz" => Unit {
            category: "mass",
            factor_to_base: 28.349523125,
        },
        "ton" | "shortton" => Unit {
            category: "mass",
            factor_to_base: 907_184.74,
        },
        "tonne" | "metricton" => Unit {
            category: "mass",
            factor_to_base: 1_000_000.0,
        },

        "liter" | "litre" | "l" => Unit {
            category: "volume",
            factor_to_base: 1.0,
        },
        "milliliter" | "millilitre" | "ml" => Unit {
            category: "volume",
            factor_to_base: 0.001,
        },
        "gallon" | "gal" => Unit {
            category: "volume",
            factor_to_base: 3.785411784,
        },
        "quart" | "qt" => Unit {
            category: "volume",
            factor_to_base: 0.946352946,
        },
        "pint" | "pt" => Unit {
            category: "volume",
            factor_to_base: 0.473176473,
        },
        "cup" => Unit {
            category: "volume",
            factor_to_base: 0.2365882365,
        },
        "fluidounce" | "floz" => Unit {
            category: "volume",
            factor_to_base: 0.0295735295625,
        },

        "meterpersecond" | "m/s" | "mps" => Unit {
            category: "speed",
            factor_to_base: 1.0,
        },
        "kilometerperhour" | "km/h" | "kph" => Unit {
            category: "speed",
            factor_to_base: 1000.0 / 3600.0,
        },
        "mileperhour" | "mph" => Unit {
            category: "speed",
            factor_to_base: 1609.344 / 3600.0,
        },
        "knot" | "kt" => Unit {
            category: "speed",
            factor_to_base: 1852.0 / 3600.0,
        },

        "byte" | "b" => Unit {
            category: "data",
            factor_to_base: 1.0,
        },
        "kilobyte" | "kb" => Unit {
            category: "data",
            factor_to_base: 1000.0,
        },
        "megabyte" | "mb" => Unit {
            category: "data",
            factor_to_base: 1_000_000.0,
        },
        "gigabyte" | "gb" => Unit {
            category: "data",
            factor_to_base: 1_000_000_000.0,
        },
        "kibibyte" | "kib" => Unit {
            category: "data",
            factor_to_base: 1024.0,
        },
        "mebibyte" | "mib" => Unit {
            category: "data",
            factor_to_base: 1024.0 * 1024.0,
        },
        "gibibyte" | "gib" => Unit {
            category: "data",
            factor_to_base: 1024.0 * 1024.0 * 1024.0,
        },
        _ => return None,
    };
    Some(u)
}

fn temperature_unit(unit: &str) -> Option<&'static str> {
    match unit {
        "c" | "celsius" => Some("c"),
        "f" | "fahrenheit" => Some("f"),
        "k" | "kelvin" => Some("k"),
        _ => None,
    }
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "unit_convert",
            format!("unit_convert failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_lengths() {
        let out = convert(1.0, "mile", "km").unwrap();
        assert!(out.contains("1.609344"));
    }

    #[test]
    fn converts_temperatures() {
        let out = convert(32.0, "fahrenheit", "celsius").unwrap();
        assert!(out.contains("0.000000"));
    }

    #[test]
    fn rejects_incompatible_units() {
        assert!(convert(1.0, "kg", "mile").is_err());
    }
}
