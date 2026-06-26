# Deep Research — redesign sketch (holistic)

A target architecture for Deep Research across **both halves** — orchestrator and
iOS app — done the way the **OpenAI API itself** models Deep Research, so the
orchestrator stays a drop-in OpenAI server and any standard client could drive
it. Replaces the bolted-on single-context loop in
[`research-problems.md`](research-problems.md) and the bespoke wire flag in
[`x-research-problems.md`](x-research-problems.md).

Engine shape borrows the field's converged design (Anthropic Research, LangChain
Open Deep Research): an **orchestrator/worker pipeline with context isolation and
a separate synthesis stage** — sized down to one self-hosted Ollama backend.

This doc takes positions; alternatives are noted inline.

## 0. The two docs are one redesign

- `x-research-problems.md` wants a **thinner, standards-based wire** (not a
  bespoke boolean).
- `research-problems.md` wants a **thicker engine** (plan / parallel retrieve /
  synthesize / verify).

The wire change *enables* the engine change: once mode selection rides a standard
OpenAI field (§2), the engine behind it can grow — and gain depth tiers —
without touching the contract again. Build the wire standard first.

## 1. How OpenAI actually exposes Deep Research (the model we're matching)

From OpenAI's Deep Research API guide:

- It runs on the **Responses API**, selected by the **`model` id**
  (`o3-deep-research` / `o4-mini-deep-research`) — **a model choice, not a
  request flag.**
- Tools are passed as standard typed entries (`web_search_preview`,
  `file_search`, `code_interpreter`); plain function-calling isn't used.
- **No built-in clarification step** — you implement it yourself with a fast
  model before handing off.
- **Background mode** is recommended because runs take many minutes.
- Citations come back as structured **annotations** (`url`, `title`,
  `start_index`, `end_index`) on the final message.

The load-bearing lesson: **Deep Research is a model, not a flag.** That is the
spec-compliant shape, and it happens to be the cleanest fix for every problem in
`x-research-problems.md`.

### What we adopt vs. diverge

| OpenAI | Phantasm | Why |
|---|---|---|
| Selected by `model` id | **Selected by `model` id** ✓ | Standard field; kills the `x_research` flag |
| Responses API (`/v1/responses`) | **Chat Completions** (`/v1/chat/completions`) | SPEC principle 2 + 2.2: one endpoint that works against **raw Ollama**. Responses API would break drop-in compatibility. |
| Tools as typed entries | Standard `tools`/`tool_choice` (already present) | Already spec-compliant in this repo |
| Manual clarification | Plan stage doubles as decomposition (§3.1) | Same idea, server-side |
| Background + poll | **SSE stream + `x_status` heartbeats** | Single-endpoint principle; our target is minutes, not tens of minutes (§1.1). Background mode deferred (§10). |
| `annotations` on message | **Markdown `[n]` + Sources list** | Chat Completions has no standard citation field; markdown renders in *any* client (§5) |

## 1.1 The budget is time, not tokens (self-hosting inverts the usual constraint)

The field's headline cost number — a multi-agent run uses **~15× the tokens** of
normal chat (Anthropic; LangChain) — is a **billing** concern. OpenAI/Anthropic
sell tokens, so they ration fan-out to protect margin. **Self-hosted, tokens are
free**: you pay in **wall-clock and GPU contention**, which is a dial *you*
control, not a cost the hardware forces low. So the constraint inverts — Phantasm
can legitimately research *wider/deeper* than a cost-conscious hosted product,
bounded only by patience.

That makes fan-out a **time-preference knob**, not a budget cap. The real ceilings
are *not* token cost:

- **Diminishing returns / decomposition quality** — past ~5–7 sub-questions you
  get redundant or low-relevance searches unless the planner is genuinely good. A
  quality ceiling, not a cost one.
- **Synthesis context** — grows with N findings, but findings are compressed, so
  this stays generous.
- **Wall-clock** — on a single GPU, sub-agents largely **serialize at
  `upstream_sem`** (`ollama_concurrency` + Ollama batching), so more sub-questions
  ≈ proportionally more wait. That's a wait *the user chooses*, not a limit.

So: a sensible **default** target, freely cranked up via preset values (not code):

> **default ≈ 3–5 sub-questions × ~2–3 searches; cranked higher when the user
> wants exhaustive and will wait. Every claim grounded in a page actually
> fetched.**

Two honest caveats the field's blog posts gloss over: (1) on one GPU, concurrent
decode often doesn't *speed up* — it can slow each stream — so the win of the
orchestrator/worker split is **context isolation** (§4) more than parallelism
(true parallelism arrives with a second backend / multi-GPU); (2) wider fan-out
is "free" in tokens but not in time, so the preset, not the hardware, sets the
patience/thoroughness trade.

## 2. Wire (spec-compliant): mode = model id

Delete `x_research` entirely. **No request field.** Deep Research is selected by
the standard `model` field, exactly like OpenAI.

### 2.1 Model id convention

The app sends a **mode-suffixed model id** in the standard `model` field:

```jsonc
{ "model": "qwen2.5:14b:deep-research", "messages": [...], "stream": true }
```

The orchestrator parses `"<base>:<mode>"`, resolves `<mode>` against a server-side
preset table, and runs `<base>` underneath. To the wire it's an opaque model
string — which is all `model` ever is in the OpenAI spec (cf.
`gpt-4o-2024-08-06`, `ft:…:custom:id`). A bare OpenAI client that never sends the
suffix simply never does research — correct graceful degradation (XR-1).

*Alternative considered:* advertise standalone virtual models (a `deep-research`
entry in `/v1/models` with a server-configured base). Rejected — it throws away
the user's base-model choice. The suffix **composes** mode with the model the
user already picked.

### 2.2 Server-side preset table

A mode resolves to data, not hardcoded `turn.rs` branches (kills
`x-research-problems.md` §2):

```rust
struct ResearchPreset {
    plan_prompt: &'static str,
    subagent_prompt: &'static str,
    synth_prompt: &'static str,
    fanout: usize,              // max parallel sub-questions (default 3)
    searches_per_subq: usize,   // budget per sub-agent (default 3)
    verify: bool,               // run the citation/verify pass
    tools: &'static [&'static str], // e.g. ["web_search"]
}
// "deep-research" and "quick-research" are two rows → depth tiers (§3-fix).
```

This fixes §3 (depth = multiple presets) and §4 (the preset *declares* its tools
and they flow through the existing `select_schemas` narrowing — one tool-scoping
mechanism, not two silently fighting).

### 2.3 Discoverability (`/v1/capabilities`)

Advertise modes so the app discovers them instead of inferring research from
`web_search` being present (fixes §5). Additive, ignorable by standard clients:

```jsonc
{
  "version": "0.2.0", "chat": true,
  "models": ["qwen2.5:14b"], "tool_models": ["qwen2.5:14b"],
  "tools": { "web_search": true, "image_generation": true },
  "modes": [
    { "id": "deep-research",  "label": "Deep Research",  "needs": ["web_search"] },
    { "id": "quick-research", "label": "Quick Research", "needs": ["web_search"] }
  ],
  "streaming": "sse"
}
```

The app composes `model + ":" + mode.id` for a turn, gated on `needs` ⊆ available
tools **and** base model ∈ `tool_models` (same gating logic the tool toggles
already use).

`/v1/models` keeps listing real base ids only — standard OpenAI clients see a
normal model list; modes live in the Phantasm-aware superset, consistent with how
§2.1 of SPEC treats `/v1/capabilities` as the superset of `/v1/models`.

## 3. Engine: stages, and where each lives

Four stages, each with its **own** message context. Reuse insight: a research
sub-agent is almost exactly today's `run_turn` web_search loop, scoped to one
sub-question. Keep that loop as the worker; add a thin orchestrator above it.

```
  model=…:deep-research  ─resolve preset─▶
        ┌─────────────────────────────────────────────┐
        │ PLAN        plan_subquestions()              │ 1 chat_once → {brief, subqs}
        ├─────────────────────────────────────────────┤
        │ RESEARCH    run_subagent() ×N (isolated ctx) │ reuses today's loop,
        │   └─ web_search loop in its OWN ctx,         │ one per sub-question
        │      returns COMPRESSED finding + URLs       │
        ├─────────────────────────────────────────────┤
        │ SYNTHESIZE  stream_synthesis()               │ 1 streaming call,
        │   └─ one-shot over brief + findings only     │ streams to app as today
        ├─────────────────────────────────────────────┤
        │ VERIFY/CITE verify_citations()  (preset-gated)│ 1 chat_once
        └─────────────────────────────────────────────┘
```

New module `orchestrator/research.rs`, entered from `run_turn` when the resolved
model carries a research preset. Plain and tool turns keep their existing fast
paths untouched (NFR-O3 preserved).

**3.1 Plan.** One `chat_once` with the planner prompt → `{ brief, sub_questions }`.
The **brief** is the only thing downstream stages see of the original
conversation — this is what stops XR-2's full-history resend from bloating every
sub-agent. Parse defensively; prose → single-sub-question fallback (graceful, per
NFR-O6).

**3.2 Research (isolated workers).** Per sub-question, a scoped copy of the
existing tool loop with its **own** `messages` vec
(`[system(subagent_prompt), user(sub_q)]`) — not the shared growing context (the
fix for `research-problems.md` §3). `web_search` only, budget
`searches_per_subq`. On finish, a compression call distills the transcript into a
short finding + the URLs actually fetched (LangChain's "clean findings before
returning"). The lead never sees raw pages. Run via bounded `join` on the
existing `upstream_sem`.

This is where retrieval quality (§4 of problems) gets fixed cheaply: each
sub-agent owns the **whole** `search_context_char_cap` for one sub-question, so
the `cap / results.len()` ≈ 800-char starvation disappears. Do alongside: real
readability extraction (vs `html_to_text` tag-strip) and **reporting** dropped
stragglers ("3 of 5 read; 2 timed out") instead of silently dropping them.

**3.3 Synthesize.** One **streaming** call over `brief + findings` (never raw
pages). Single-agent deliberately — LangChain found multi-agent *writing*
produces disjointed reports; parallelize research, centralize writing. Streams
via the existing `stream_final`, so the app needs no streaming changes.

**3.4 Verify / cite (preset-gated).** A `chat_once` that checks each `[n]`
resolves to a URL actually fetched and supported by its finding. This is §6+§7 of
the problems doc as **one** pass (citation integrity is the first instance of
verification). Cheapest useful version drops/flags unmapped citations rather than
re-researching. `verify: false` lets `quick-research` skip it.

## 4. Context flow (the actual fix for blowup)

```
history ─plan─▶ brief ─┬─▶ sub-agent 1 (own ctx) ─▶ finding 1 ─┐
                       ├─▶ sub-agent 2 (own ctx) ─▶ finding 2 ─┼─▶ synth ─▶ answer
                       └─▶ sub-agent 3 (own ctx) ─▶ finding 3 ─┘
```

Nothing accumulates monotonically. Raw pages live and die inside a sub-agent.
Synthesis context = `brief + N short findings`, bounded regardless of pages read.

## 4.1 Caching: within-turn (do it) vs cross-turn (modest, careful)

**Within-turn dedup cache — clear win, no contract impact.** Today nothing dedups
repeated queries or re-fetches the same URL across sub-agents in one run
(problems §2). A per-turn `URL → extracted_text` and `query → results` map (lives
and dies with the turn) kills that waste directly. Belongs in the redesign
regardless; pairs naturally with §3.2. Zero statelessness concern — it never
outlives the request.

**Cross-turn page cache — worth it, but know what it actually buys.** The benefit
is real but bounded, for a reason that cuts against intuition:

- In a research run, **page-fetch time is a small fraction of wall-clock** —
  fetches are timeout-bounded (1.5s) and parallel; the dominant cost is **LLM
  decode** (plan + each sub-agent's loop + synthesis), which a page cache doesn't
  touch. So caching pages speeds up the *minority* slice.
- "It's in the model's context anyway" was true of the **old** design (pages
  piled into one window, resent via history). The **new** isolated design
  *evicts* raw pages — only the compressed finding reaches synthesis, only the
  answer reaches history. So cross-turn the raw page is **not** in context; a
  cross-turn page cache *re-retains* data the new design deliberately threw away.
  It's net-new state, not free.
- Where the *big* follow-up speedup actually lives — caching **findings** or
  prior synthesis — is genuine **session state**: it collides with XR-2 and is
  staleness-prone (silently reusing a stale finding corrupts a follow-up). Avoid
  unless/until the deferred sync/state layer exists (SPEC §7).

**Recommendation:** add cross-turn caching *only* as a droppable,
correctness-neutral **HTTP-style cache** — `URL → (text, fetched_at)` LRU with a
TTL, opt-in via config, single-instance in-memory. The discipline that keeps it
spec-honest: it MUST be invisible and droppable with **zero behavior change**
(like any HTTP cache), so the server still satisfies XR-2 in spirit —
statelessness is about not *requiring* server state for correctness, and an empty
cache must produce identical results. The line not to cross is caching
conversation/session-keyed state. Multi-instance (shared cache) is deferred. Net:
a modest latency win on iterative same-topic sessions, not a game-changer —
because it saves the fetch slice, not the LLM slice.

## 5. Output & citations (spec-compliant)

OpenAI returns structured `annotations` — but that's a Responses-API shape we
don't serve. On Chat Completions there is **no standard citation field**, so we
keep inline markdown `[n]` + a numbered Sources list embedded in the assistant
`content`. It renders in *any* OpenAI client with zero special handling
(consistent with how images already ride as markdown data-URIs, SPEC §2.3) and
the verify pass (§3.4) is what makes those `[n]`s trustworthy.

*If* we ever want machine-readable citations, add them as an **additive
`x_`-prefixed** field on the final chunk (e.g. `x_citations: [...]`), never by
adopting the Responses schema — same rule as `x_status`.

## 6. Progress & cancellation

`TurnEvent` (`orchestrator/mod.rs`) needs no new variant — `Status(String)` rides
`x_status`, already additive and ignored by standard clients. Make it
**structured per stage** (fixes `research-problems.md` §9):
`"planning…"`, `"researching 2/3: <sub-q>…"`, `"reading 4 sources…"`,
`"synthesizing…"`. Emit often enough to keep the SSE keep-alive (15s, set in
`routes/chat.rs`) honest during non-streaming plan/research stages.

**Partial synthesis on cancel/cap** (fixes §9's wasted rounds): cancel after
research but before synthesis → run a fast synth over whatever findings exist
rather than dropping them. The `CancellationToken` already reaches every stage;
this is a `select!` branch.

## 7. iOS app changes (the holistic half)

The app is a plain OpenAI client; the model-as-mode design keeps it that way —
the change is mostly **deletion**.

- **`WireTypes.swift` `ChatRequest`:** delete `xResearch` and its init param.
  Research no longer touches the request body at all — it rides the existing
  `model` string. Add `modes` to `Capabilities` (mirrors §2.3), as an optional
  field (older orchestrator → `nil` → no research UI, graceful per FR-A2).
- **`Persistence/Models.swift` `Conversation`:** `deepResearchEnabled: Bool` can
  stay as the **UI preference**, but it stops being a wire concept — at send time
  the app resolves the model id to `"<base>:deep-research"` instead of setting a
  flag. (Or model it as a selected `modeID: String?` for when there are multiple
  modes — cleaner than one bool per future mode, and matches §2.3's list.)
- **`reasoningEffort(thinkingEnabled:)`:** today research force-bundles thinking
  on (`Models.swift:80`) — `x-research-problems.md` §6's bundling smell. Keep
  `reasoning_effort` as the **separate standard field** it already is; let the
  preset (server) or the user (client) decide thinking independently of mode.
  Don't weld them.
- **Composer toggle:** flips the per-send `modeID`, not sticky conversation
  state — a per-message intent, matching how `model` is already chosen per turn.
- **Model picker / `resolvedChatModel`:** unchanged for base models; the mode
  suffix is applied at request construction, so the picker still shows clean base
  names.
- **Rendering:** unchanged — markdown `[n]` + Sources and `x_status` are already
  handled (FR-A4, FR-A8).

Net app surface: one field deleted from the wire type, one capabilities field
added, one toggle re-pointed from a bool to a model-id suffix. No new rendering,
no new streaming, no new endpoint.

## 8. SPEC.md changes

- **§2.1 capabilities:** add the `modes` array; document `/v1/models` lists base
  ids while `modes` is the superset detail.
- **§2.3:** replace the entire "Deep Research mode (additive `x_research`)"
  paragraph with "Deep Research is a **mode**, selected via a mode-suffixed
  `model` id resolved server-side against a preset table; discoverable via
  `capabilities.modes`. No request flag." Keep the markdown-citations + `x_status`
  consequences.
- **§8 resolved decisions:** strike `x_research` from "the only non-standard wire
  elements" — after this, `x_status` is the *only* one again. That's the headline
  win: research stops being proprietary surface.

## 9. Testing (fixes problems §10)

Extend the existing scripted `ChatBackend` + `ToolExecutor` (no network):

- **Mode resolution:** `model:"m:deep-research"` → preset applied; `model:"m"` →
  ordinary turn; unknown mode → ordinary turn (graceful).
- **Plan parsing:** N sub-questions → N sub-agents; prose → single-subq fallback.
- **Context isolation (core invariant):** assert each sub-agent's `seen` messages
  contain neither other findings nor raw pages.
- **Citation integrity:** synthesis cites `[3]` with no fetched URL → verify pass
  drops/flags it.
- **Cancel mid-research:** cancel after 2 findings → a partial synthesis still
  streams.
- **App:** `ChatRequest` with a mode model id encodes a plain standard body (no
  `x_research`); capabilities decode tolerates missing `modes`.

## 10. Phasing (each step shippable alone)

1. **Wire genericization** — delete `x_research`; model-as-mode + preset table +
   capabilities `modes`; app deletions. `deep-research` preset initially maps to
   *today's* loop behavior. Pure contract cleanup; standard clients unaffected;
   unblocks the rest. (Server + iOS + SPEC together — this is the holistic step.)
2. **Retrieval quality** — per-sub-question char budget, readability, straggler
   reporting. Standalone win even before the orchestrator exists.
3. **Plan → isolated sub-agents → synthesis** — the orchestrator/worker core in
   `research.rs`. Where context blowup actually dies.
4. **Verify/cite pass** — preset-gated citation grounding.
5. **Progress + partial synthesis** — structured `x_status`, cancel-safe synth.

## 11. Explicitly deferred

- **Background/poll mode** (OpenAI's pattern for tens-of-minutes runs) — needs an
  endpoint beyond Chat Completions, which breaks the single-endpoint principle
  (SPEC 2.2). Our target is minutes; SSE + `x_status` keep-alive covers it.
  Revisit only if runs routinely exceed a few minutes.
- **Multiple search providers / source types** (problems §5) — still Brave-only;
  the sub-agent structure makes adding providers a per-worker change later.
- **Caching** — promoted out of "deferred" into §4.1: within-turn dedup (do it),
  cross-turn as a droppable HTTP-style URL cache (modest). *Finding/session*
  caching stays deferred (collides with XR-2 + the sync layer, SPEC §7).
- **Machine-readable citations** (`x_citations`) — additive, only if a client
  needs it (§5).
- **Fine-tuned research model** — OpenAI/Gemini get behavior from an RL-trained
  model; we can't on Ollama, which is *why* the structure lives in orchestrator
  code, not weights.
- **Cost/time budget UI** — real once fan-out lands (user pays in own compute),
  but UX, not engine.

## Reference — what changes where

| Concern | File | Change |
|---|---|---|
| Wire flag removal | `openai/types.rs` `ChatRequest` | delete `research`/`x_research` |
| Model→preset resolve | new `orchestrator/presets.rs` | parse `<base>:<mode>`, table lookup |
| Preset table | `orchestrator/presets.rs` | `deep-research`, `quick-research` rows |
| Capabilities | `state.rs` `CapabilitySnapshot` | add `modes: Vec<ModeInfo>` |
| Engine | new `orchestrator/research.rs` | plan / sub-agent / synth / verify |
| Loop entry | `orchestrator/turn.rs` | branch to `research.rs` on research preset; reuse loop as worker |
| Retrieval | `tools/web_search.rs` | per-sub-q budget, readability, straggler reporting |
| Caching | `tools/web_search.rs` (within-turn); new opt-in URL LRU (cross-turn) | dedup fetches/queries; droppable HTTP-style cache (§4.1) |
| Progress | `orchestrator/mod.rs`, `routes/chat.rs` | structured per-stage `x_status` |
| App wire | `ios/.../WireTypes.swift` | delete `xResearch`; add `Capabilities.modes` |
| App state | `ios/.../Persistence/Models.swift` | `deepResearchEnabled`→`modeID`; unbundle `reasoningEffort` |
| Spec | `docs/SPEC.md` §2.1, §2.3, §8 | modes manifest; mode-as-model; drop `x_research` |
