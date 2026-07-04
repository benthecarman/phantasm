//! Fallback parser for XML-style tool calls emitted as plain text.
//!
//! Some models served by Ollama (notably the qwen3-coder family) stop using
//! the native structured `tool_calls` field once offered many tools (~6+) and
//! instead write the calls into the assistant text as
//! `<function=name><parameter=key>value</parameter>…</function>`. Without a
//! fallback that XML would stream to the app as visible answer text and no
//! tool would ever run.
//!
//! [`XmlToolScan`] sits in the streaming tool-resolution path: it lets normal
//! text through token-by-token (holding back only a trailing partial marker),
//! and once a full `<function=` marker appears it buffers the rest of the
//! stream and parses it into tool calls when the stream finishes. Native
//! structured tool calls always take precedence — this only engages when the
//! model produced none.
//!
//! Parameter values are kept as JSON strings (the XML carries no types); a
//! tool that needs another type surfaces a normal, non-fatal tool error the
//! model can react to (NFR-O6).
//!
//! Known tradeoff: this is text sniffing, so with tools offered, prose that
//! *quotes* a well-formed block (a user asking about the syntax itself) is
//! indistinguishable from a real call attempt and will be executed. Accepted:
//! the marker is specific enough that misfires need the model to reproduce a
//! complete, valid block verbatim.

use serde_json::Value;

use crate::openai::types::{mint_call_id, FunctionCall, RawArguments, ToolCall};

/// The opening tag prefix whose presence flips the scanner into XML mode.
pub(crate) const XML_MARKER: &str = "<function=";

/// Incremental scanner for one streamed assistant response.
///
/// State is just the withheld text: before a marker is seen, `buf` holds at
/// most a partial-marker suffix (≤ 9 bytes); once one is seen, `buf` starts
/// with [`XML_MARKER`] and accumulates the candidate block. "XML mode" is
/// therefore `buf.starts_with(XML_MARKER)` — derived, so it can't desync.
#[derive(Default)]
pub(crate) struct XmlToolScan {
    buf: String,
}

impl XmlToolScan {
    /// Feed a content delta; returns the text that is safe to emit now.
    /// Empty once a marker has been detected (the block is being buffered).
    pub(crate) fn push(&mut self, content: &str) -> String {
        if self.buf.starts_with(XML_MARKER) {
            self.buf.push_str(content);
            return String::new();
        }
        self.buf.push_str(content);
        if let Some(idx) = self.buf.find(XML_MARKER) {
            // Text before the marker is ordinary assistant prose ("I'll look
            // that up.") — release it, keep the block itself.
            let prefix: String = self.buf.drain(..idx).collect();
            return prefix;
        }
        // Hold back a suffix that could still grow into the marker (`<fun`…);
        // it is flushed as soon as the next delta disambiguates, or at finish.
        let hold = trailing_marker_prefix_len(&self.buf);
        if hold == 0 {
            // Common case (no marker fragment): move the buffer out instead of
            // copying it — this runs once per streamed token.
            return std::mem::take(&mut self.buf);
        }
        self.buf.drain(..self.buf.len() - hold).collect()
    }

    /// The withheld text, verbatim, without parsing it (for callers that only
    /// excise blocks rather than execute them).
    pub(crate) fn into_raw(self) -> String {
        self.buf
    }

    /// End of stream: hand back the withheld text verbatim plus whatever tool
    /// calls it parsed into. Used by the tool-resolution path, which discards
    /// `raw` when calls parsed and flushes it as content otherwise. (The
    /// post-tools final-answer path uses [`Self::into_raw`] + excision
    /// instead — it never executes calls.)
    pub(crate) fn finish(self) -> ScanEnd {
        // Cheap when nothing was withheld: parse_xml_tool_calls returns
        // immediately without a marker to find.
        let calls = parse_xml_tool_calls(&self.buf);
        ScanEnd {
            raw: self.buf,
            calls,
        }
    }
}

/// What a stream's withheld text resolved to (see [`XmlToolScan::finish`]).
pub(crate) struct ScanEnd {
    /// The withheld text, verbatim: a partial-marker holdback, or the whole
    /// buffered candidate XML block.
    pub(crate) raw: String,
    /// Tool calls parsed from the block; empty when it wasn't XML after all
    /// (or didn't parse into anything usable).
    pub(crate) calls: Vec<ToolCall>,
}

/// Length of the longest suffix of `text` that is a proper prefix of
/// [`XML_MARKER`] (a full marker is handled by `find` before this runs).
/// The marker is pure ASCII, so the returned length is a char boundary.
fn trailing_marker_prefix_len(text: &str) -> usize {
    let max = (XML_MARKER.len() - 1).min(text.len());
    (1..=max)
        .rev()
        .find(|&k| text.ends_with(&XML_MARKER[..k]))
        .unwrap_or(0)
}

/// Parse every complete `<function=…>…</function>` block in `text` into tool
/// calls, minting synthetic call ids like the native conversion does. Calls
/// with names a tool registry could never match (non `[a-zA-Z0-9_-]`) are
/// skipped. Stray text between or after blocks (qwen3-coder emits a trailing
/// `</tool_call>`) is ignored.
pub(crate) fn parse_xml_tool_calls(text: &str) -> Vec<ToolCall> {
    let mut calls = Vec::new();
    let mut rest = text;
    while let Some((name, body, tail)) = next_call_block(rest) {
        rest = tail;
        if !is_plausible_tool_name(name) {
            continue;
        }
        calls.push(ToolCall {
            id: Some(mint_call_id()),
            kind: "function".into(),
            function: FunctionCall {
                name: name.to_string(),
                arguments: RawArguments::Obj(Value::Object(parse_parameters(body))),
            },
        });
    }
    calls
}

/// Remove every structurally complete `<function=…>…</function>` block from
/// `text`, keeping the surrounding prose (before, between, and after blocks).
/// When anything was removed, stray `</tool_call>` close-tags (qwen3-coder
/// appends one after its last block) are dropped too. Returns the cleaned
/// text and the number of blocks removed. Used by the post-tools final-answer
/// pass, where a block is a call attempt that can no longer be executed and
/// must not be shown as answer text.
pub(crate) fn excise_call_blocks(text: &str) -> (String, usize) {
    let mut cleaned = String::new();
    let mut removed = 0usize;
    let mut rest = text;
    while let Some(start) = rest.find(XML_MARKER) {
        let Some((_, _, tail)) = next_call_block(&rest[start..]) else {
            break; // incomplete block: keep it as text (matches the flush path)
        };
        cleaned.push_str(&rest[..start]);
        removed += 1;
        rest = tail;
    }
    cleaned.push_str(rest);
    if removed > 0 {
        cleaned = cleaned.replace("</tool_call>", "");
        if cleaned.trim().is_empty() {
            cleaned.clear();
        }
    }
    (cleaned, removed)
}

/// Split off the first structurally complete call block: `(name, body, tail)`
/// where `tail` is everything after its `</function>`. `None` when no
/// complete block remains.
fn next_call_block(text: &str) -> Option<(&str, &str, &str)> {
    let (_, after_marker) = text.split_once(XML_MARKER)?;
    let (name, body_and_rest) = after_marker.split_once('>')?;
    let (body, tail) = body_and_rest.split_once("</function>")?;
    Some((name.trim(), body, tail))
}

fn parse_parameters(body: &str) -> serde_json::Map<String, Value> {
    let mut args = serde_json::Map::new();
    let mut rest = body;
    while let Some((_, after_open)) = rest.split_once("<parameter=") {
        let Some((name, value_and_rest)) = after_open.split_once('>') else {
            break;
        };
        let Some((value, tail)) = value_and_rest.split_once("</parameter>") else {
            break;
        };
        args.insert(
            name.trim().to_string(),
            Value::String(strip_wrapping_newlines(value).to_string()),
        );
        rest = tail;
    }
    args
}

/// Strip one leading and one trailing newline — the emission style puts the
/// value on its own line(s) inside the tags, so that wrapping is formatting.
/// Deliberately NOT a full `trim()`: interior and intentional whitespace
/// (leading indentation of a code fragment's first line, padded values) is
/// significant to tools like code_exec and must survive verbatim.
fn strip_wrapping_newlines(value: &str) -> &str {
    let value = value
        .strip_prefix("\r\n")
        .or_else(|| value.strip_prefix('\n'))
        .unwrap_or(value);
    value
        .strip_suffix("\r\n")
        .or_else(|| value.strip_suffix('\n'))
        .unwrap_or(value)
}

fn is_plausible_tool_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call_args(call: &ToolCall) -> &serde_json::Map<String, Value> {
        match &call.function.arguments {
            RawArguments::Obj(Value::Object(map)) => map,
            other => panic!("expected object arguments, got {other:?}"),
        }
    }

    #[test]
    fn parses_single_call_with_parameters() {
        let text = "<function=web_search>\n<parameter=query>rust ndjson</parameter>\n<parameter=depth>thorough</parameter>\n</function>";
        let calls = parse_xml_tool_calls(text);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].function.name, "web_search");
        assert!(calls[0].id.as_deref().unwrap().starts_with("call_"));
        let args = call_args(&calls[0]);
        assert_eq!(args["query"], "rust ndjson");
        assert_eq!(args["depth"], "thorough");
    }

    #[test]
    fn parses_multiple_calls_and_ignores_stray_text() {
        // qwen3-coder has been observed appending a stray `</tool_call>`.
        let text = "<function=time>\n</function>\n<function=weather>\n<parameter=location>Berlin</parameter>\n</function>\n</tool_call>";
        let calls = parse_xml_tool_calls(text);
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].function.name, "time");
        assert!(call_args(&calls[0]).is_empty());
        assert_eq!(calls[1].function.name, "weather");
    }

    #[test]
    fn parameter_values_keep_inner_newlines() {
        let text =
            "<function=code_exec>\n<parameter=code>\nprint(1)\nprint(2)\n</parameter>\n</function>";
        let calls = parse_xml_tool_calls(text);
        assert_eq!(call_args(&calls[0])["code"], "print(1)\nprint(2)");
    }

    #[test]
    fn parameter_values_keep_significant_whitespace() {
        // Only the single wrapping newline pair is formatting; a code
        // fragment's first-line indentation and trailing newline survive.
        let text = "<function=code_exec>\n<parameter=code>\n    if x:\n        y()\n\n</parameter>\n</function>";
        let calls = parse_xml_tool_calls(text);
        assert_eq!(call_args(&calls[0])["code"], "    if x:\n        y()\n");
    }

    #[test]
    fn skips_implausible_names_and_incomplete_blocks() {
        assert!(parse_xml_tool_calls("<function=bad name>x</function>").is_empty());
        assert!(parse_xml_tool_calls("<function=web_search><parameter=q>x</parameter>").is_empty());
        assert!(parse_xml_tool_calls("no calls here").is_empty());
    }

    #[test]
    fn excise_keeps_surrounding_prose_and_counts_blocks() {
        let text = "Checking.\n<function=weather>\n<parameter=location>Berlin</parameter>\n</function>\nThe answer is 42.";
        let (cleaned, removed) = excise_call_blocks(text);
        assert_eq!(removed, 1);
        assert_eq!(cleaned, "Checking.\n\nThe answer is 42.");
    }

    #[test]
    fn excise_drops_stray_tool_call_tags_and_clears_whitespace_only_leftovers() {
        let (cleaned, removed) = excise_call_blocks("<function=time>\n</function>\n</tool_call>\n");
        assert_eq!(removed, 1);
        assert_eq!(cleaned, "");

        // Incomplete blocks are kept as text, matching the flush path.
        let (cleaned, removed) = excise_call_blocks("<function=weather>never closed");
        assert_eq!(removed, 0);
        assert_eq!(cleaned, "<function=weather>never closed");

        // Plain text is untouched (and stray close-tags survive when nothing
        // was excised — they are just text then).
        let (cleaned, removed) = excise_call_blocks("a </tool_call> in prose");
        assert_eq!(removed, 0);
        assert_eq!(cleaned, "a </tool_call> in prose");
    }

    #[test]
    fn scan_passes_plain_text_through() {
        let mut scan = XmlToolScan::default();
        assert_eq!(scan.push("Hello "), "Hello ");
        assert_eq!(scan.push("world"), "world");
        let end = scan.finish();
        assert!(end.raw.is_empty());
        assert!(end.calls.is_empty());
    }

    #[test]
    fn scan_holds_back_partial_marker_then_flushes_false_alarm() {
        let mut scan = XmlToolScan::default();
        // `a < b` releases immediately (space cannot start the marker) but a
        // real partial like `<fun` is withheld until disambiguated.
        assert_eq!(scan.push("a < b, then <fun"), "a < b, then ");
        assert_eq!(scan.push("ky beat"), "<funky beat");
        let end = scan.finish();
        assert!(end.raw.is_empty());
        assert!(end.calls.is_empty());
    }

    #[test]
    fn scan_buffers_xml_across_deltas_and_parses_at_finish() {
        let mut scan = XmlToolScan::default();
        let mut emitted = String::new();
        for delta in [
            "I'll check.\n<fun",
            "ction=weather>\n<parameter=loc",
            "ation>Berlin</parameter>\n</function>",
        ] {
            emitted.push_str(&scan.push(delta));
        }
        assert_eq!(emitted, "I'll check.\n", "prose streams, XML does not");
        let end = scan.finish();
        assert!(
            end.raw.starts_with(XML_MARKER),
            "raw block handed back verbatim"
        );
        assert_eq!(end.calls.len(), 1);
        assert_eq!(end.calls[0].function.name, "weather");
        assert_eq!(call_args(&end.calls[0])["location"], "Berlin");
    }

    #[test]
    fn scan_flushes_unparseable_block_as_text() {
        let mut scan = XmlToolScan::default();
        assert_eq!(scan.push("<function=weather>never closed"), "");
        let end = scan.finish();
        assert_eq!(end.raw, "<function=weather>never closed");
        assert!(end.calls.is_empty());
    }
}
