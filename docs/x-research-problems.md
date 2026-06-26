# `x_research` — wire/contract problems

Problems with **how Deep Research is exposed on the app↔orchestrator contract** —
i.e. the `x_research` request flag itself, not what the research loop does
internally (that's [`research-problems.md`](research-problems.md)). This is the
genericness/proprietariness angle: `x_research` is the kind of bespoke wire
surface the recent `tools`/`tool_choice` and `/v1/models` cleanups were removing.

## What it is today

`x_research: true` is an additive, `x_`-prefixed boolean on the chat request
(SPEC §2.3; `orchestrator/src/openai/types.rs` `ChatRequest.research`, renamed
from `x_research`). When set, the server applies a hardcoded bundle (turn.rs):
a fixed research system prompt, `web_search`-only tools, and a larger iteration
cap. The app sends it from a per-conversation toggle (`deepResearchEnabled`,
iOS `Persistence/Models.swift:37`).

## 1. It's the last bespoke request flag — and the start of boolean sprawl

After the recent cleanup, tool selection rides standard `tools`/`tool_choice`,
so `x_research` is now the **only** non-standard *request* field left
(types.rs `ChatRequest` is otherwise model/messages/stream/tools/tool_choice +
passthrough). It stands out. Worse, it sets the precedent that **every new
server-side mode is another `x_` boolean** — `x_research`, then `x_code_mode`,
`x_shopping`, … The contract grows one field per feature, each one a separate
client/server change. That's exactly the proprietary-creep we just reversed for
tools.

## 2. It puts server-side policy on the wire as an opaque switch

`x_research` is not a protocol concept; it's a **preset** — the bundle of
(research system prompt) + (web_search only) + (`MAX_RESEARCH_ITERS` budget),
hardcoded in `turn.rs` (`RESEARCH_SYSTEM_PROMPT` at turn.rs:65, the forced
`web_search` selection at turn.rs:125-129, the cap swap at turn.rs:155-159). The
client sends a boolean that triggers this bundle blind: it can't see what the
preset contains, choose among presets, or know why a turn behaves differently.
The wire flag and the policy are welded together in code.

## 3. Boolean shape — no parameterization

It's on/off. A client cannot express research *depth*, a source/budget ceiling, a
recency window, or which preset. All tuning lives in deployment env vars
(`MAX_RESEARCH_ITERS`, `SEARCH_*`), which are **global to the server**, not
per-request. So "quick research" vs "exhaustive research" is impossible from the
client — the shape of the field forecloses it.

## 4. It silently overrides the standard tool-selection mechanism

We just made `tools`/`tool_choice` the way a client scopes tools. But a research
turn forces `web_search`-only on the server (turn.rs:125-129) **regardless** of
what the client sent in `tools`. So a request with
`tools: [{name: "image_generation"}]` **and** `x_research: true` silently drops
the client's selection. Two tool-scoping mechanisms now coexist on the contract
with `x_research` quietly winning — an inconsistency introduced purely by having
research be its own flag instead of going through the standard path.

## 5. Not discoverable via capabilities

`/v1/capabilities` advertises *tools* (`web_search`, `image_generation`) but has
no notion of *modes/presets* (`state.rs` `CapabilitySnapshot`). The app can't ask
"does this server support deep research?"; it infers it from `web_search` being
present and hardcodes knowledge of the `x_research` feature
(`Conversation.requestedToolNames` / the composer toggle). A server that didn't
implement `x_research` would silently ignore the flag with no way for the client
to know. Modes are undiscoverable in a manifest built to make features
discoverable (XR-3).

## 6. The boolean shape pushes sticky client state

Because the trigger is a bare boolean, the app models it as **sticky
per-conversation state** (`deepResearchEnabled`, Models.swift:37) rather than a
per-message intent — every turn in the chat re-asserts the flag. It also leaks
into adjacent behavior: research implicitly forces thinking on
(`reasoningEffort(thinkingEnabled:…)`, Models.swift:80-84), another behavior
bundled behind the one boolean.

## Root cause

`x_research` encodes a *server-side preset* as a *bespoke wire boolean*. That
makes it proprietary (only Phantasm clients trigger it), unparameterized
(on/off), undiscoverable (absent from capabilities), and a precedent for one new
flag per future mode — while also conflicting with the now-standard
`tools`/`tool_choice` selection. The earlier thread's suggested direction (item
#1) was to collapse it into a single generic, capabilities-advertised preset
mechanism (e.g. `x_mode`/`x_preset: "deep_research"`) resolved against a
server-side preset table, so research becomes data rather than protocol. This
doc just records the problems; the redesign is separate.

## Reference — where `x_research` lives

| Concern | Location |
|---|---|
| Wire field | `orchestrator/src/openai/types.rs` (`ChatRequest.research`, `rename = "x_research"`) |
| Server policy bundle | `orchestrator/src/orchestrator/turn.rs:65, :125-129, :155-159` |
| Forced page-fetch coupling | `orchestrator/src/tools/web_search.rs:116, :210` |
| Contract spec | `docs/SPEC.md` §2.3 ("Deep Research mode") |
| App request field | `ios/.../Models/WireTypes.swift` (`ChatRequest.xResearch`) |
| App sticky state | `ios/.../Persistence/Models.swift:37`, `Conversation.reasoningEffort` :80 |
| Capabilities (no mode entry) | `orchestrator/src/state.rs` (`CapabilitySnapshot`) |
