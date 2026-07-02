//! Unit conversion tool. Purely local and stateless.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::openai::types::ToolCall;
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
    crate::tools::run_simple(
        "unit_convert",
        call,
        call_id,
        tx,
        cancel,
        |_: &UnitConvertArgs| "converting units…".into(),
        |args| async move { convert(args.value, &args.from_unit, &args.to_unit) },
    )
    .await
}

fn convert(value: f64, from_unit: &str, to_unit: &str) -> Result<String, String> {
    if !value.is_finite() {
        return Err("value is not finite".into());
    }
    let from = normalize(from_unit);
    let to = normalize(to_unit);

    if let (Some(from_temp), Some(to_temp)) = (
        resolve(&from, temperature_unit),
        resolve(&to, temperature_unit),
    ) {
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

    let from =
        resolve(&from, unit_factor).ok_or_else(|| format!("unknown source unit `{from_unit}`"))?;
    let to =
        resolve(&to, unit_factor).ok_or_else(|| format!("unknown destination unit `{to_unit}`"))?;
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
    unit.trim().to_ascii_lowercase().replace([' ', '_'], "")
}

/// Look up a normalized unit, trying the string as sent first and stripping a
/// trailing `s` (plural) only as a fallback. Stripping *before* lookup broke
/// units that legitimately end in `s` — "mps" became "mp" (its alias was dead
/// code) and "celsius" needed a special case — while irregular plurals such as
/// "feet"/"inches" are handled by their own aliases in the tables.
fn resolve<T>(unit: &str, lookup: impl Fn(&str) -> Option<T>) -> Option<T> {
    lookup(unit).or_else(|| unit.strip_suffix('s').and_then(lookup))
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
        "inch" | "inches" | "in" => Unit {
            category: "length",
            factor_to_base: 0.0254,
        },
        "foot" | "feet" | "ft" => Unit {
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

    #[test]
    fn mps_alias_resolves_without_plural_stripping() {
        // "mps" used to be singularized to "mp" before lookup, making its
        // alias dead code and failing the conversion.
        let out = convert(1.0, "mps", "km/h").unwrap();
        assert!(out.contains("3.6"), "{out}");
    }

    #[test]
    fn irregular_plurals_feet_and_inches_convert() {
        let feet = convert(3.0, "feet", "m").unwrap();
        assert!(feet.contains("0.9144"), "{feet}");
        let inches = convert(2.0, "inches", "cm").unwrap();
        assert!(inches.contains("5.08"), "{inches}");
    }

    #[test]
    fn regular_plurals_still_convert() {
        let out = convert(2.0, "meters", "cm").unwrap();
        assert!(out.contains("200"), "{out}");
    }

    #[test]
    fn celsius_is_not_singularized() {
        let out = convert(100.0, "celsius", "fahrenheit").unwrap();
        assert!(out.contains("212"), "{out}");
        // And plural temperature spellings still fall back cleanly.
        let k = convert(0.0, "kelvins", "celsius").unwrap();
        assert!(k.contains("-273.14"), "{k}"); // -273.15 modulo f64 rounding
    }
}
