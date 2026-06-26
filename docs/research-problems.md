# Deep Research — current problems

Snapshot of what's wrong with Deep Research mode **as implemented today**, to
feed a redesign. No solutions here — just the problems and where they live in
the code.

## How it works today (recap)

Deep Research is the `x_research: true` request flag (SPEC §2.3). When set, the
turn loop (`orchestrator/src/orchestrator/turn.rs`) does four things differently
from an ordinary turn:

1. Prepends a fixed system prompt (`RESEARCH_SYSTEM_PROMPT`, turn.rs:65) telling
   the model to decompose → search → reflect → synthesize with `[n]` citations.
2. Restricts tools to **only** `web_search` (turn.rs:125-129).
3. Sets `TurnContext.research = true`, which forces `web_search` to fetch full
   pages regardless of the `SEARCH_FETCH_PAGES` gate or the per-call `depth` arg
   (`tools/web_search.rs:116`, `:210`).
4. Raises the tool-loop cap from `MAX_TOOL_ITERS` (5) to `MAX_RESEARCH_ITERS`
   (default **6**, config.rs:141).

Otherwise it reuses the **exact same machinery** as a normal turn: one model, one
linear non-streaming `chat_once` loop, one growing message list, then a single
streaming synthesis call. That reuse is the root of most problems below.

## 1. It isn't actually "research" — it's a longer prompt on the normal loop

The decompose/reflect/synthesize structure exists **only as English in the system
prompt**. The orchestrator enforces none of it. There is no planner, no
sub-question fan-out, no separate synthesis stage, no verification — just one
model looping `web_search` against a single context up to 6 times
(turn.rs:160-198). Quality is entirely at the mercy of whether the model happens
to follow the prompt. "Deep research" and "a normal search turn" share one code
path; the only real differences are the prompt, the forced fetch, and `+1` on the
iteration cap.

## 2. Sequential and tiny — no parallelism, 6-round ceiling

- Every round is strictly sequential: `chat_once` → execute one tool → `chat_once`
  again (turn.rs:165-197). Sub-questions that are independent **cannot** be
  searched concurrently.
- `MAX_RESEARCH_ITERS` defaults to **6** (config.rs:141). Real deep research runs
  dozens of queries. Six sequential rounds, and the model can burn the whole
  budget on a single sub-question — nothing enforces a per-sub-question budget or
  dedups repeated queries (the prompt asks for this; nothing checks it).
- Hitting the cap just emits `"finishing up…"` and asks the model to wrap up with
  whatever it has (turn.rs:200-202).

## 3. Context blowup — everything accumulates in one window

Each round's tool result is appended to the single `messages` vec that is resent
to the model on every subsequent iteration (turn.rs:185-194). With forced
full-page fetches over 6 rounds, the context grows monotonically: later rounds
get slower and more expensive, and the model loses earlier detail. There is **no
compaction, summarization, or eviction** between rounds. Combined with XR-2
(stateless server — the app resends full history each turn), a follow-up research
question resends the entire prior research answer and re-runs from scratch; no
fetched page or prior artifact is cached across turns.

## 4. "Reading pages" barely reads pages

The forced thorough path is shallow:

- **Naive extraction.** `html_to_text` (web_search.rs:309) just strips `<…>`
  tags and collapses whitespace. No readability/main-content isolation — nav,
  footer, cookie banners, and boilerplate all survive; scripts/styles between
  tags survive as text.
- **Starvation cap.** `per_extract_cap = search_context_char_cap / results.len()`
  (web_search.rs:269). With the defaults (`SEARCH_CONTEXT_CHARS=4000`, 5 results)
  that's **~800 chars per page** — a slightly longer snippet, not a read. More
  results ⇒ *less* of each page.
- **Whole-round cap too.** `format_snippets` also caps the entire round's output
  at `search_context_char_cap` (~4000 chars total, web_search.rs:240-246), so all
  sources for a round must share one 4KB budget. Too small for cross-source
  synthesis.
- **Silent straggler drops.** Any page slower than `SEARCH_FETCH_TIMEOUT_MS`
  (default 1500ms) is dropped (web_search.rs:280-286). Slow-but-authoritative
  sources (PDFs, heavy pages) just vanish, and neither the model nor the user is
  told a source was dropped vs. never existed.

## 5. Single provider, single shape

Only Brave web search, snippet API (web_search.rs). No news/recency filtering,
site-restriction, link-following, academic/primary-source modes, or any
non-web source. Forcing tools to `web_search` only (turn.rs:126) also means a
research turn can't combine search with anything else.

## 6. Citations are unverified and fabrication-prone

The prompt asks for inline `[n]` citations and a Sources list, but **nothing
verifies** that a cited URL was actually fetched, that the claim matches the
source, or that the numbering is internally consistent. This is the classic
hallucinated-citation failure mode, with no grounding/verification pass to catch
it.

## 7. No verification / adversarial pass

The model synthesizes from whatever it gathered in a single pass and streams it
out (turn.rs:179-182). There is no second pass — no contradiction check, no
claim verification, no gap analysis — so confidently-wrong findings sail straight
through to the user.

## 8. Hard mode switch, not adaptive

- `x_research` flips the **whole turn**, and the iOS toggle is per-conversation
  (`deepResearchEnabled`), so once on, *every* turn in that chat pays the research
  cost. The model can't decide mid-conversation that a question warrants deep
  research, nor scope it to a single message.
- It also forces web-search-only, so a research turn can't, say, generate a chart
  or use other tools as part of the answer.

## 9. Progress and cancellation are coarse

- Progress is a flat string (`"searching the web (reading pages)…"`,
  web_search.rs:117-122) via `x_status`. No per-sub-question progress, source
  counts, or sense of how far along a multi-minute run is.
- On cancel or cap-exit there's **no partial synthesis** — `stream_final` just
  streams whatever the model emits at that moment. Rounds of gathered material can
  be wasted if the model hasn't synthesized yet.

## 10. Thin testing / observability

The only research-specific test is `research_mode_injects_prompt_and_uses_research_cap`
(turn.rs:604), which checks *plumbing* (prompt prepended, research cap used).
Nothing exercises retrieval quality, citation integrity, or context growth. Logs
record only the `research` bool and `tools_offered` count (routes/chat.rs:76).

## Root cause

Deep Research is bolted onto the single-context, sequential, one-model turn loop
that was built for ordinary chat-with-tools. True deep research wants a different
shape — planning, parallel retrieval, compaction, synthesis, and verification as
distinct stages — which `turn.rs` is not structured to express. Any redesign
probably starts there rather than by tuning the prompt and the iteration cap.

## Reference — knobs involved

| Env / const | Default | Where |
|---|---|---|
| `MAX_RESEARCH_ITERS` | 6 | config.rs:141 |
| `MAX_TOOL_ITERS` | 5 | config.rs:140 |
| `SEARCH_FETCH_PAGES` | false (forced on for research) | config.rs:148 |
| `SEARCH_CONTEXT_CHARS` | 4000 | config.rs:147 |
| `SEARCH_MAX_RESULTS` | 5 | config.rs:146 |
| `SEARCH_FETCH_CONCURRENCY` | 3 | config.rs:149 |
| `SEARCH_FETCH_TIMEOUT_MS` | 1500 | config.rs:150 |
| `RESEARCH_SYSTEM_PROMPT` | — | turn.rs:65 |
