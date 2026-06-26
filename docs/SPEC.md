# Phantasm — Requirements Specification (v0.1 MVP)

The two components needed to ship a working free product: the iOS app and the
orchestration server. Premium/business features (accounts, sync, relay, billing)
are out of scope (§7).

## 1. Overview

A fast, self-hostable AI chat app for iOS that talks to a user-supplied backend.
The app is a thin client; an optional orchestration server adds web search and
image generation on top of plain inference.

- **iOS app** — chat client. Configurable endpoint + token. Speaks
  OpenAI-compatible streaming as its baseline so it can point at a bare Ollama
  instance *or* the orchestrator.
- **Orchestration server** — co-located with Ollama/ComfyUI on the user's
  network. Runs the tool loop (web search, image gen), exposes a single endpoint
  to the app, and advertises its capabilities so the app can adapt.

### Design principles

1. The app never knows how the backend is hosted. URL + token, nothing else.
2. Baseline is OpenAI-compatible; tools are a runtime-detected extension.
3. The orchestrator owns all complexity, co-located with the heavy services.
4. One app binary, many backend configs.

## 2. Interface contract (the shared boundary)

### 2.1 Capabilities manifest

`GET /v1/capabilities` → JSON. The app calls this on connect and shows/hides UI.

```json
{
  "version": "0.1.0",
  "chat": true,
  "models": ["llama3.3:70b", "qwen2.5:14b"],
  "vision_models": ["llama3.3:70b"],
  "tool_models": ["qwen2.5:14b"],
  "tools": {
    "web_search": true,
    "web_fetch": true,
    "current_time": true,
    "calculator": true,
    "unit_convert": true,
    "weather": true,
    "maps_places": true,
    "market_data": false,
    "github": true,
    "ocr": true,
    "image_generation": true
  },
  "streaming": "sse"
}
```

A bare Ollama won't serve this route; the app MUST treat 404/connection failure
as "plain chat only" and degrade gracefully. The `tools` block is advisory — it
only tells the app whether to *show* affordances. The app never executes tools.

The orchestrator also serves the standard `GET /v1/models` (OpenAI list shape)
backed by the same probe, so any standard OpenAI client can discover models;
`/v1/capabilities` is the Phantasm-aware superset the app prefers. `/v1/models`
lists the real **base** model ids only — a standard OpenAI client sees a normal
model list — while research **modes** live in the capabilities superset as the
Phantasm-aware detail (see below).

An optional `modes` array advertises the research modes the deployment offers
(see §2.3). It is present **only** when `web_search` is usable; older clients
tolerate its absence (a missing/`nil` field simply means no research UI):

```jsonc
{
  // …the fields above, plus:
  "modes": [
    { "id": "deep-research",  "label": "Deep Research",  "needs": ["web_search"] },
    { "id": "quick-research", "label": "Quick Research", "needs": ["web_search"] }
  ]
}
```

Each entry carries a mode `id` (the suffix the app composes onto a base model id,
§2.3), a human `label`, and a `needs` list of capabilities the mode requires. The
app shows a mode only when its `needs` ⊆ the advertised tools **and** the chosen
base model is in `tool_models` — the same gating the per-tool toggles already use.

`vision_models` and `tool_models` are subsets of `models` reporting which models
accept image input and which can drive tool/function calls (probed server-side
via Ollama `/api/show`; both optional, omitted/empty ⇒ the app treats that
capability as unknown and allows it optimistically). Because the server tools
are invoked by the model, a tool is usable only when `tools` advertises it **and**
the chosen model is in `tool_models` — the app gates the per-tool toggles on both.
For compatibility with older Phantasm app builds, the `web_search` flag is the
app-facing **read-only information tools** group: if any read-only information
tool is available, `web_search` may be true so the app can offer the broad tools
toggle. Individual booleans name the exact configured tools. Research modes are
advertised only when the actual Brave-backed `web_search` schema is usable.

### 2.2 Chat (single OpenAI-compatible endpoint)

`POST /v1/chat/completions` with `"stream": true`. Standard OpenAI request/
response shape and SSE token streaming. This is the **only** chat endpoint and
MUST work against raw Ollama unchanged. No separate tool endpoint, no custom
WebSocket protocol — *server* tools are invisible to the app, while *app-hosted*
tools ride standard OpenAI `tool_calls` (§2.3).

### 2.2b Message content & attachments (multimodal)

A message's `content` is **either** a plain string (the common case, byte-for-byte
what raw Ollama emits) **or** the standard OpenAI content-parts array:

```jsonc
{ "role": "user", "content": [
    { "type": "text", "text": "what is in this picture?" },
    { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,…" } }
] }
```

This keeps the orchestrator a drop-in OpenAI server. Conventions:

- **Images** ride as `image_url` parts whose `url` is a `data:<mime>;base64,…`
  data URI. The orchestrator strips the prefix and forwards the payload to
  Ollama native's per-message `images` field (vision models only).
- **Text files** are extracted to plain text *on the app side* and inlined as
  extra `text` parts (or folded into the string content), so they work against
  any text model with no server support. The server treats them as ordinary text.
- The app only emits the array form when a message carries attachments; plain
  turns stay a string. Servers MUST accept both shapes.

### 2.2a Model warm-up (optional, additive)

`POST /v1/warm` with `{ "model": "…" }` (model optional → server default).
Best-effort preload so the first turn skips cold-start; the app calls it on
launch and on model switch when auto-warm is enabled. For a native-Ollama
upstream the server issues a no-message "load" (model resident via a warm-only
`keep_alive`, zero tokens); for any other upstream it is a no-op. Returns
`{ "warmed": bool, "model": "…" }` and MUST NOT error the caller — a bare Ollama
(no orchestrator) simply lacks this route, and the app degrades to a native
`/api/chat` load instead. Plain OpenAI-compatible backends are not warmed (no
free preload).

### 2.3 Tools: server-side (invisible) and app-hosted (forwarded)

Most tool execution happens entirely on the **orchestrator ↔ Ollama** hop using
standard OpenAI function-calling and is invisible to the app:

1. App sends a normal request to the orchestrator.
2. Orchestrator calls Ollama as an OpenAI client, passing the configured `tools`.
3. Ollama returns `tool_calls`; the orchestrator executes them (Brave, ComfyUI),
   appends `tool`-role results, and re-calls — capped at N iterations.
4. Once Ollama returns a final assistant message, the orchestrator streams *that*
   back to the app as ordinary SSE chunks.

**App-hosted (client-executed) tools.** The app may also host its own tools —
ones it executes itself by rendering UI (the first is `ask_user_input`, a
multiple-choice prompt). It advertises them by sending **full** function schemas
(name + description + `parameters`) in the standard `tools` array. The
orchestrator merges these with its configured server tools and offers all to the
model, but it does **not** execute an app tool: when the model calls one, the
orchestrator streams that call back to the app as a standard `delta.tool_calls`
chunk terminated by `finish_reason: "tool_calls"`, then ends the turn. The app
fulfills the call, appends a `tool`-role result (with the matching
`tool_call_id`) to its history, and the model resumes on the next request. This
stays stateless (XR-2): the assistant `tool_calls` message and the `tool` result
both live in the app's history and are re-sent; every assistant `tool_calls`
message MUST be followed by a matching `tool` result (the app synthesizes a
"(dismissed)" result for an unanswered call). `arguments` is a JSON-encoded
string on the wire. Standard OpenAI clients that don't host the tool simply never
send its schema, so it's never offered to them.

**Classification + collisions.** A `tools` entry is app-hosted iff it carries a
`function.parameters` schema; a name-only entry is a server-tool selector
(below). On a name collision the **server** tool wins — the app's same-named
entry is dropped and the call is executed server-side.

**Per-request tool selection (standard OpenAI fields).** The app scopes which
server tools a turn may use via the **standard** OpenAI `tools` / `tool_choice`
request fields — no custom field. The `tools` array merely *names* the wanted
tools, either as a function entry
(`{"type":"function","function":{"name":"web_search"}}`) or the built-in
shorthand (`{"type":"web_search"}`); the server fills in the real schema and
intersects with what it has configured (a client can never enable a tool the
deployment lacks). Semantics: `tools` **absent** → the server offers every
configured tool (older clients keep working); **present** → only the named
tools; an **empty array** or `tool_choice: "none"` → no tools (plain chat).
Tools remain server-side and invisible otherwise; this only lets the client
scope which of the advertised (`/v1/capabilities`) tools apply to a given
conversation. Because selection rides standard fields, any OpenAI client can do
it and a bare backend ignores it harmlessly.

**Deep Research mode (model id, not a flag).** Deep Research is a **mode**
selected via the standard `model` field, never a request flag — there is no
`x_research`. The app sends a mode-suffixed model id, `"<base>:<mode>"` (e.g.
`"qwen2.5:14b:deep-research"`), and the server resolves the mode server-side
against a preset table. The parse rule is **split on the LAST `:`**: if the
suffix exactly matches a known mode id, the prefix is the base model and the
matched preset applies; otherwise the whole string is the base model and there is
no research mode. This handles colon-bearing Ollama ids correctly —
`"qwen2.5:14b"` → suffix `14b`, not a mode, so the whole string is the base;
`"qwen2.5:14b:deep-research"` → suffix `deep-research`, a mode, so base is
`"qwen2.5:14b"`. Modes are discoverable via `capabilities.modes` (§2.1); a bare
OpenAI client that never sends a suffix simply never researches. Each preset
declares its budget and the tools it offers (research offers `web_search` only,
resolved through the existing `tools` narrowing — §2.3 above). The result streams
back as ordinary assistant markdown (inline `[n]` citations + a numbered
`Sources:` list embedded in `content`), so a standard client renders it with no
special handling; progress rides the existing `x_status` field. Modes are
advertised only when `web_search` is usable, and the app gates each on its
`needs`.

**Thinking mode.** The app MAY include `reasoning_effort` on the request.
`"none"` asks the backend to suppress thinking/reasoning (the default app
behavior); a supported value such as `"medium"` allows backends that expose
reasoning to emit it. When reasoning is streamed, the server emits it as
`delta.reasoning_content` (the de-facto OpenAI-compat field name, so any standard
client understands it); the app also accepts the `reasoning`/`thinking` aliases
on input. Clients SHOULD keep it separate from assistant `content` and
hide it unless the user expands it. The app remembers the on/off preference per
backend profile and model.

Consequences:

- **Images** are embedded in the assistant message as markdown
  `![generated](data:image/png;base64,…)` or a URL.
- **Progress** rides an optional additive field on the SSE chunk,
  `"x_status": "generating image… 42%"`. Standard clients ignore unknown fields;
  the app reads `x_status`. Future custom fields should be `x_`-prefixed.
- Conversation is stateless server-side: the app sends full history each turn.
- Cancellation: the client aborts the SSE connection; the orchestrator detects
  the disconnect and halts generation and in-flight tool work.

**Tool privacy / persistence boundary.** Server-side tools MUST NOT persist
conversation content, tool inputs, tool outputs, fetched pages, generated
intermediate data, or user attachments to durable local storage. Any cache must
be in-memory and scoped to a single turn unless this spec is deliberately
changed. If a backend API requires file-backed handoff, the tool must use
request-scoped temp/scratch storage rather than durable input/output libraries
and must only read it back for the active turn. The orchestrator MUST NOT offer
local filesystem search/read/write tools or local-docs indexing; tools may only
read static operator-configured assets needed to run themselves (for example
ComfyUI workflow JSON). Future side-effecting tools (email/calendar/file/
database writes, shell/code execution, browser automation) require an explicit
contract update and user-confirmation UI.

## 3. Orchestration server requirements

**Functional:** capabilities endpoint (FR-O1), OpenAI-compatible chat with SSE
(FR-O2), server-side tool loop with iteration cap (FR-O3), Brave web search
(snippet-first; FR-O4), ComfyUI image gen with progress relay (FR-O5), model
listing (FR-O6), bearer auth → 401 (FR-O7), cancellation on disconnect (FR-O8),
optional read-only tools for web fetch, current time, calculator, unit
conversion, weather, places/geocoding, market data, GitHub reads, and OCR
(FR-O9). Local docs/filesystem tools and side-effecting tools are out of scope.

**Non-functional:** co-location over localhost/LAN (NFR-O1), async concurrency
with a configurable Ollama concurrency limit (NFR-O2), low plain-chat latency
(<50ms added; NFR-O3), env-var config (NFR-O4), Docker + compose (NFR-O5), tool
failures non-fatal (NFR-O6), structured per-turn logs with no content by default
(NFR-O7), and fast search (~1–2s to first token: snippet-first, no RAG, bounded
concurrent fetch, small injected context, warm model; NFR-O8).

## 4. iOS app requirements

**Functional:** backend config + validation (FR-A1), capability detection +
graceful degradation (FR-A2), streaming chat (FR-A3), markdown + code blocks
with copy (FR-A4), conversation management (FR-A5), model selection (FR-A6),
inline image display + save/share (FR-A7), `x_status` progress UI (FR-A8),
cancellation (FR-A9), connection handling distinguishing unreachable/auth/model
errors (FR-A10).

**Non-functional:** iOS 17+ (NFR-A1), token in Keychain (NFR-A2), local SwiftData
persistence (NFR-A3), smooth streaming off the main thread (NFR-A4), fast cold
start (NFR-A5), optional multiple backend profiles (NFR-A6).

## 5. Cross-cutting

- **XR-1 Graceful degradation** — every tool is optional; plain chat works
  against any OpenAI-compatible endpoint including raw Ollama.
- **XR-2 Stateless server, stateful client** — the app sends full history each
  turn.
- **XR-3 Versioning** — the capabilities manifest carries a version.
- **XR-4 No tool persistence** — server tools do not write local state or index
  local files; per-turn in-memory caches are allowed only as an optimization.

## 6. Build phases

1. Plain chat path (app + Ollama). 2. Orchestrator skeleton (capabilities, auth,
passthrough). 3. Tool loop + web search. 4. Image generation. 5. Polish
(conversation management, model picker, profiles, reconnect hardening).

## 7. Out of scope (deferred premium layer)

User accounts, subscription billing, cross-device cloud sync, managed
remote-access relay, and anything running on developer-hosted infrastructure.
MVP assumes the user reaches their own backend (home wifi, VPN/Tailscale, tunnel).

## 8. Resolved decisions

- Single OpenAI-compatible SSE endpoint; tools server-side; the only
  non-standard wire element is the `x_`-prefixed `x_status` (progress) field.
  Deep Research rides the standard `model` id (a `"<base>:<mode>"` suffix
  resolved server-side, §2.3) rather than a proprietary flag, so research stops
  being non-standard wire surface — the headline win. Tool selection rides
  standard `tools`/`tool_choice`; streamed reasoning rides
  `delta.reasoning_content`; `/v1/models` is served alongside
  `/v1/capabilities`.
- Upstream native Ollama via **`/api/chat`** when available (Ollama
  OpenAI-compat drops streamed tool_calls), with OpenAI-compatible `/v1`
  fallback for non-Ollama model hosts.
- Image return format: base64 data-URI markdown for MVP.
- Ship one default ComfyUI workflow, overridable via config.
