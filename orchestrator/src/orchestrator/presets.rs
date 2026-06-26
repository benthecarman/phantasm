//! Research **mode presets** and model-id resolution.
//!
//! Deep Research is selected by the *model id*, not a request flag (mirroring how
//! OpenAI selects `o3-deep-research`). The app sends `model = "<base>:<modeId>"`;
//! the server splits on the **last** `:`, and if the suffix exactly matches a
//! known mode id the matching preset applies and `base` is the prefix. Otherwise
//! the whole string is the base model and there is no research mode.
//!
//! A mode resolves to **data** (a [`ResearchPreset`]), not to a hardcoded branch
//! in `turn.rs`: depth tiers are just additional rows. The preset declares which
//! tools it offers, flowing through the existing `select_schemas` narrowing — one
//! tool-scoping mechanism, not two.
//!
//! The numeric/boolean knobs (`fanout`, `searches_per_subq`, `verify`) are
//! env-overridable; their defaults live in [`crate::config::Config`] and are
//! applied via [`PresetTable::from_config`]. Mode ids, labels, and the tool list
//! are server-side data.

use crate::config::Config;

/// One research depth tier. The prompt fields are stubs for stage 1 — the real
/// engine (plan / sub-agent / synth / verify) lands in stage 3 and will fill
/// them in. Stage 1 only uses `tools` (web_search-only narrowing) and prepends
/// the legacy `RESEARCH_SYSTEM_PROMPT` to reproduce today's behavior.
#[derive(Debug, Clone)]
pub struct ResearchPreset {
    /// Mode id as it appears in the model suffix and in `capabilities.modes`.
    pub id: &'static str,
    /// Human-facing label for the app's mode picker.
    pub label: &'static str,
    /// Max parallel sub-questions (stage 3 fan-out).
    pub fanout: usize,
    /// Search budget per sub-agent (stage 3).
    pub searches_per_subq: usize,
    /// Whether to run the citation/verify pass (stage 3, preset-gated).
    pub verify: bool,
    /// Tools this mode offers, resolved through `select_schemas`. Web search only.
    pub tools: &'static [&'static str],
    // ---- prompt fields (stubs for stage 1; filled in stage 3) ----
    /// Planner prompt that decomposes the question into sub-questions.
    pub plan_prompt: &'static str,
    /// System prompt for each isolated sub-agent loop.
    pub subagent_prompt: &'static str,
    /// Prompt that compresses a sub-agent transcript into a finding + sources.
    pub compress_prompt: &'static str,
    /// Synthesis prompt over the brief + findings.
    pub synth_prompt: &'static str,
    /// Citation-verification prompt (used only when `verify`).
    pub verify_prompt: &'static str,
}

/// The mode ids the server knows about, in advertised order. The actual presets
/// (with env-applied knobs) are built per-`Config` by [`PresetTable::from_config`];
/// only the ids/labels/tools are static here.
pub const MODE_IDS: &[&str] = &[DEEP_RESEARCH_ID, QUICK_RESEARCH_ID];

pub const DEEP_RESEARCH_ID: &str = "deep-research";
pub const QUICK_RESEARCH_ID: &str = "quick-research";

const DEEP_RESEARCH_LABEL: &str = "Deep Research";
const QUICK_RESEARCH_LABEL: &str = "Quick Research";

/// Web-search-only tool list shared by every research preset (research offers
/// `web_search` exclusively, resolved through `select_schemas`).
const RESEARCH_TOOLS: &[&str] = &["web_search"];

/// Planner prompt (stage 1 of the engine). Decomposes the user's question into a
/// short brief plus focused sub-questions and returns STRICT JSON so the
/// orchestrator can parse it. Shared by every tier — the tier controls how many
/// sub-questions are kept (`fanout`), not how planning is phrased.
const PLAN_PROMPT: &str = "\
You are the planning step of a deep-research system. Read the conversation and \
the user's latest request, then decompose it into focused sub-questions that, \
researched independently and combined, fully answer it.\n\n\
Respond with ONLY a JSON object, no prose and no code fences:\n\
{\"brief\": \"<one-paragraph restatement of what the user wants answered, \
self-contained so a researcher who cannot see the conversation understands the \
task>\", \"sub_questions\": [\"<focused sub-question>\", ...]}\n\n\
Rules: each sub-question must be independently researchable via web search; \
avoid redundancy; prefer 3-5 sub-questions; never exceed what is needed. The \
brief is the ONLY context downstream researchers get, so make it complete.";

/// System prompt for each isolated sub-agent (stage 2). It investigates exactly
/// one sub-question with web_search and reports tersely. It never sees siblings'
/// work or the synthesis stage, so it must be self-contained.
const SUBAGENT_PROMPT: &str = "\
You are a research sub-agent investigating ONE sub-question with the web_search \
tool. Before each search, decide in one short sentence what you need. Issue \
searches, read the returned pages, and stop as soon as you can answer the \
sub-question well — do not run redundant searches. When done, state your finding \
plainly and reference the URLs you actually used. You are responsible for this \
sub-question only; another agent will combine your finding with others.";

/// Compression prompt (stage 2, post-loop). Distills a sub-agent's transcript
/// into a short finding plus the URLs actually fetched, so synthesis never sees
/// raw pages. Returns STRICT JSON.
const COMPRESS_PROMPT: &str = "\
Summarize your research on this sub-question into a compact finding for a writer \
who will NOT see the pages you read. Respond with ONLY a JSON object, no prose \
and no code fences:\n\
{\"finding\": \"<the key facts you established, 1-2 short paragraphs, concrete \
and self-contained>\", \"sources\": [\"<url you actually used>\", ...]}\n\n\
Include only URLs you genuinely relied on. If you could not find an answer, say \
so in the finding and return an empty sources list.";

/// Synthesis prompt (stage 3). Writes the final answer over the brief + findings
/// only (never raw pages), with inline `[n]` citations keyed to the numbered
/// Sources list it is given.
const SYNTH_PROMPT: &str = "\
You are the writer of a deep-research answer. You are given the user's brief, a \
set of findings from research sub-agents, and a numbered list of sources. Write \
one cohesive answer that directly addresses the brief, grounded ONLY in the \
findings provided.\n\n\
Support claims with inline citations like [1], [2] that refer to the numbered \
sources. Cite only sources that actually back the claim. End with a numbered \
\"Sources:\" list reproducing the provided source URLs in order. Do not invent \
sources or citation numbers beyond the list you were given.";

/// Verify/cite prompt (stage 4, preset-gated). Takes the draft + the valid
/// citation map and removes or repairs any `[n]` not backed by a real source,
/// returning a corrected answer.
const VERIFY_PROMPT: &str = "\
You are the citation-checking step. You are given a draft answer and the list of \
VALID numbered sources (each [n] that is allowed, with its URL). Return a \
corrected version of the answer: keep every [n] that appears in the valid list, \
and for any citation marker NOT in the valid list, remove the bracketed marker \
(keep the surrounding prose). Do not add new citations. Ensure the trailing \
numbered \"Sources:\" list contains exactly the valid sources, in order. Output \
ONLY the corrected answer text, no commentary.";

/// The resolved set of presets for a given deployment: defaults baked in, env
/// knobs applied. Held on `Config` so resolution needs no globals.
///
/// We leak the per-config presets into `'static` memory once at startup. There is
/// exactly one `Config` for the process lifetime, so this is a bounded one-time
/// leak (two presets) — it lets every downstream API keep an ergonomic
/// `Option<&'static ResearchPreset>` without threading a lifetime through the
/// turn loop.
#[derive(Debug)]
pub struct PresetTable {
    presets: &'static [ResearchPreset],
}

impl PresetTable {
    /// Build the preset table from config-supplied knob values and leak it for
    /// the process lifetime. Call once (it is invoked lazily and cached on
    /// `Config`); repeated calls leak again, so prefer [`Config::presets`].
    pub fn from_config(cfg: &Config) -> PresetTable {
        let presets: Vec<ResearchPreset> = vec![
            ResearchPreset {
                id: DEEP_RESEARCH_ID,
                label: DEEP_RESEARCH_LABEL,
                fanout: cfg.research_deep_fanout,
                searches_per_subq: cfg.research_deep_searches_per_subq,
                verify: cfg.research_deep_verify,
                tools: RESEARCH_TOOLS,
                plan_prompt: PLAN_PROMPT,
                subagent_prompt: SUBAGENT_PROMPT,
                compress_prompt: COMPRESS_PROMPT,
                synth_prompt: SYNTH_PROMPT,
                verify_prompt: VERIFY_PROMPT,
            },
            ResearchPreset {
                id: QUICK_RESEARCH_ID,
                label: QUICK_RESEARCH_LABEL,
                fanout: cfg.research_quick_fanout,
                searches_per_subq: cfg.research_quick_searches_per_subq,
                verify: cfg.research_quick_verify,
                tools: RESEARCH_TOOLS,
                plan_prompt: PLAN_PROMPT,
                subagent_prompt: SUBAGENT_PROMPT,
                compress_prompt: COMPRESS_PROMPT,
                synth_prompt: SYNTH_PROMPT,
                verify_prompt: VERIFY_PROMPT,
            },
        ];
        PresetTable {
            presets: Box::leak(presets.into_boxed_slice()),
        }
    }

    /// All presets, in advertised order. Used to populate `capabilities.modes`.
    pub fn all(&self) -> &'static [ResearchPreset] {
        self.presets
    }

    /// Resolve a request `model` string into its base model and (optionally) the
    /// research preset selected by a mode suffix.
    ///
    /// The string is split on the **last** `:`. If the suffix exactly matches a
    /// known mode id, the matched preset applies and the base is the prefix;
    /// otherwise the **whole** string is the base model and there is no mode.
    ///
    /// This is deliberately last-colon: Ollama base ids contain colons.
    ///   * `"qwen2.5:14b"` → suffix `"14b"` is not a mode → base `"qwen2.5:14b"`, no mode.
    ///   * `"qwen2.5:14b:deep-research"` → suffix `"deep-research"` is a mode →
    ///     base `"qwen2.5:14b"`, deep-research preset.
    ///   * `"m:quick-research"` → base `"m"`, quick-research preset.
    ///   * `"m:unknown"` → suffix is not a mode → base `"m:unknown"`, no mode.
    pub fn resolve_model(&self, model: &str) -> (String, Option<&'static ResearchPreset>) {
        if let Some((base, suffix)) = model.rsplit_once(':') {
            if let Some(preset) = self.presets.iter().find(|p| p.id == suffix) {
                return (base.to_string(), Some(preset));
            }
        }
        (model.to_string(), None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table() -> PresetTable {
        PresetTable::from_config(&crate::config::tests_support::minimal())
    }

    #[test]
    fn bare_ollama_id_with_colon_has_no_mode() {
        // "14b" is not a mode id, so the WHOLE string is the base model.
        let (base, preset) = table().resolve_model("qwen2.5:14b");
        assert_eq!(base, "qwen2.5:14b");
        assert!(preset.is_none());
    }

    #[test]
    fn deep_research_suffix_strips_to_ollama_base() {
        let (base, preset) = table().resolve_model("qwen2.5:14b:deep-research");
        assert_eq!(base, "qwen2.5:14b");
        assert_eq!(preset.map(|p| p.id), Some(DEEP_RESEARCH_ID));
    }

    #[test]
    fn quick_research_suffix_on_simple_base() {
        let (base, preset) = table().resolve_model("m:quick-research");
        assert_eq!(base, "m");
        assert_eq!(preset.map(|p| p.id), Some(QUICK_RESEARCH_ID));
    }

    #[test]
    fn unknown_suffix_keeps_whole_string_as_base() {
        let (base, preset) = table().resolve_model("m:not-a-mode");
        assert_eq!(base, "m:not-a-mode");
        assert!(preset.is_none());
    }

    #[test]
    fn no_colon_at_all_is_bare_base() {
        let (base, preset) = table().resolve_model("llama3.1");
        assert_eq!(base, "llama3.1");
        assert!(preset.is_none());
    }

    #[test]
    fn presets_offer_web_search_only() {
        for p in table().all() {
            assert_eq!(p.tools, &["web_search"]);
        }
    }
}
