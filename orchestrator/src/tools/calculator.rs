//! Calculator tool backed by a tiny arithmetic parser. No filesystem, shell,
//! code execution, or network access.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::openai::types::ToolCall;
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;

const MAX_EXPR_LEN: usize = 512;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CalculatorArgs {
    /// Mathematical expression to evaluate, e.g. "(12.5 * 4) / sin(pi / 2)".
    pub expression: String,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(CalculatorArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "calculator",
        "Evaluate a bounded mathematical expression exactly enough for arithmetic, powers, and common functions. No code execution.",
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
        "calculator",
        call,
        call_id,
        tx,
        cancel,
        |_: &CalculatorArgs| "calculating…".into(),
        |args| async move { evaluate(&args.expression) },
    )
    .await
}

fn evaluate(expression: &str) -> Result<String, String> {
    let expression = expression.trim();
    if expression.is_empty() {
        return Err("expression is empty".into());
    }
    if expression.len() > MAX_EXPR_LEN {
        return Err(format!(
            "expression too long ({} > {MAX_EXPR_LEN})",
            expression.len()
        ));
    }

    if !expression.is_ascii() {
        return Err("expression must be ASCII math syntax".into());
    }

    let value = Parser::new(expression).parse()?;
    if !value.is_finite() {
        return Err("result is not finite".into());
    }
    Ok(format!(
        "Calculation result:\nexpression: {expression}\nvalue: {value:.15}"
    ))
}

struct Parser<'a> {
    input: &'a str,
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(input: &'a str) -> Self {
        Self { input, pos: 0 }
    }

    fn parse(mut self) -> Result<f64, String> {
        let value = self.expr()?;
        self.skip_ws();
        if self.peek().is_some() {
            return Err(format!("unexpected token at byte {}", self.pos));
        }
        Ok(value)
    }

    fn expr(&mut self) -> Result<f64, String> {
        let mut value = self.term()?;
        loop {
            self.skip_ws();
            match self.peek() {
                Some('+') => {
                    self.bump();
                    value += self.term()?;
                }
                Some('-') => {
                    self.bump();
                    value -= self.term()?;
                }
                _ => return Ok(value),
            }
        }
    }

    fn term(&mut self) -> Result<f64, String> {
        let mut value = self.unary()?;
        loop {
            self.skip_ws();
            match self.peek() {
                Some('*') => {
                    self.bump();
                    value *= self.unary()?;
                }
                Some('/') => {
                    self.bump();
                    value /= self.unary()?;
                }
                _ => return Ok(value),
            }
        }
    }

    // Unary sign binds *looser* than `^` (mathematical convention, matching
    // Python): `-2^2` is `-(2^2) = -4`, while `(-2)^2 = 4` needs the parens.
    fn unary(&mut self) -> Result<f64, String> {
        self.skip_ws();
        match self.peek() {
            Some('+') => {
                self.bump();
                self.unary()
            }
            Some('-') => {
                self.bump();
                Ok(-self.unary()?)
            }
            _ => self.power(),
        }
    }

    // `^` is right-associative; the exponent goes through `unary` so `2^-3`
    // parses (and `2^3^2` recurses into another power on the right).
    fn power(&mut self) -> Result<f64, String> {
        let base = self.primary()?;
        self.skip_ws();
        if self.peek() == Some('^') {
            self.bump();
            let exponent = self.unary()?;
            Ok(base.powf(exponent))
        } else {
            Ok(base)
        }
    }

    fn primary(&mut self) -> Result<f64, String> {
        self.skip_ws();
        match self.peek() {
            Some('0'..='9') | Some('.') => self.number(),
            Some('a'..='z') | Some('A'..='Z') => self.identifier(),
            Some('(') => {
                self.bump();
                let value = self.expr()?;
                self.skip_ws();
                if self.peek() != Some(')') {
                    return Err("missing closing `)`".into());
                }
                self.bump();
                Ok(value)
            }
            Some(c) => Err(format!("unexpected `{c}` at byte {}", self.pos)),
            None => Err("unexpected end of expression".into()),
        }
    }

    fn number(&mut self) -> Result<f64, String> {
        let start = self.pos;
        let mut saw_digit = false;
        while matches!(self.peek(), Some('0'..='9')) {
            saw_digit = true;
            self.bump();
        }
        if self.peek() == Some('.') {
            self.bump();
            while matches!(self.peek(), Some('0'..='9')) {
                saw_digit = true;
                self.bump();
            }
        }
        if matches!(self.peek(), Some('e') | Some('E')) {
            self.bump();
            if matches!(self.peek(), Some('+') | Some('-')) {
                self.bump();
            }
            let exp_start = self.pos;
            while matches!(self.peek(), Some('0'..='9')) {
                self.bump();
            }
            if self.pos == exp_start {
                return Err("bad exponent".into());
            }
        }
        if !saw_digit {
            return Err("bad number".into());
        }
        self.input[start..self.pos]
            .parse::<f64>()
            .map_err(|e| e.to_string())
    }

    fn identifier(&mut self) -> Result<f64, String> {
        let start = self.pos;
        while matches!(
            self.peek(),
            Some('a'..='z') | Some('A'..='Z') | Some('0'..='9') | Some('_')
        ) {
            self.bump();
        }
        let name = self.input[start..self.pos].to_ascii_lowercase();
        match name.as_str() {
            "pi" => return Ok(std::f64::consts::PI),
            "e" => return Ok(std::f64::consts::E),
            _ => {}
        }

        self.skip_ws();
        if self.peek() != Some('(') {
            return Err(format!("unknown constant `{name}`"));
        }
        self.bump();
        let arg = self.expr()?;
        self.skip_ws();
        if self.peek() != Some(')') {
            return Err(format!("missing closing `)` after function `{name}`"));
        }
        self.bump();
        match name.as_str() {
            "abs" => Ok(arg.abs()),
            "sqrt" => Ok(arg.sqrt()),
            "sin" => Ok(arg.sin()),
            "cos" => Ok(arg.cos()),
            "tan" => Ok(arg.tan()),
            "asin" => Ok(arg.asin()),
            "acos" => Ok(arg.acos()),
            "atan" => Ok(arg.atan()),
            "ln" => Ok(arg.ln()),
            "log10" | "log" => Ok(arg.log10()),
            "exp" => Ok(arg.exp()),
            "floor" => Ok(arg.floor()),
            "ceil" => Ok(arg.ceil()),
            "round" => Ok(arg.round()),
            _ => Err(format!("unknown function `{name}`")),
        }
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(c) if c.is_ascii_whitespace()) {
            self.bump();
        }
    }

    fn peek(&self) -> Option<char> {
        self.input[self.pos..].chars().next()
    }

    fn bump(&mut self) {
        if let Some(c) = self.peek() {
            self.pos += c.len_utf8();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evaluates_arithmetic() {
        let out = evaluate("2 + 3 * 4").unwrap();
        assert!(out.contains("value: 14"));
    }

    #[test]
    fn evaluates_functions_and_constants() {
        let out = evaluate("sin(pi / 2) + sqrt(9)").unwrap();
        assert!(out.contains("value: 4"));
    }

    #[test]
    fn rejects_long_expression() {
        assert!(evaluate(&"1+".repeat(300)).is_err());
    }

    #[test]
    fn exponent_binds_tighter_than_unary_minus() {
        // Mathematical convention (and Python): -2^2 == -(2^2) == -4.
        assert!(evaluate("-2^2").unwrap().contains("value: -4"));
        assert!(evaluate("(-2)^2").unwrap().contains("value: 4"));
        assert!(evaluate("-2^-2").unwrap().contains("value: -0.25"));
    }

    #[test]
    fn exponent_accepts_negative_and_stays_right_associative() {
        assert!(evaluate("2^-3").unwrap().contains("value: 0.125"));
        // Right associativity: 2^3^2 == 2^(3^2) == 512.
        assert!(evaluate("2^3^2").unwrap().contains("value: 512"));
    }
}
