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
  "models": [
    {
      "id": "llama3.3:70b",
      "context_length": 8192,
      "capabilities": {
        "completion": true,
        "vision": true,
        "audio": false,
        "tools": false,
        "insert": false,
        "embedding": false
      }
    },
    {
      "id": "qwen2.5:14b",
      "context_length": 32768,
      "reasoning_efforts": ["none", "low", "medium", "high"],
      "capabilities": {
        "completion": true,
        "vision": false,
        "audio": false,
        "tools": true,
        "insert": true,
        "embedding": false
      }
    },
    {
      "id": "nomic-embed-text:latest",
      "capabilities": {
        "completion": false,
        "vision": false,
        "audio": false,
        "tools": false,
        "insert": false,
        "embedding": true
      }
    }
  ],
  "tool_selectors": [
    {
      "id": "web_search",
      "label": "Web access",
      "tools": [
        "web_search",
        "web_fetch",
        "weather",
        "maps_places",
        "market_data",
        "github"
      ]
    },
    {
      "id": "utilities",
      "label": "Utilities",
      "tools": ["calculator", "time", "unit_convert", "ocr"]
    },
    {
      "id": "image_generation",
      "label": "Media generation",
      "tools": ["image_generation", "image_edit", "audio_generation", "video_generation"]
    }
  ]
}
```

A bare Ollama won't serve this route; the app MUST treat 404/connection failure
as "plain chat only" and degrade gracefully. `tool_selectors` is advisory — it
only tells the app which app-facing tool buckets it may offer for a turn. The
app never executes server tools.

The orchestrator also serves the standard `GET /v1/models` (OpenAI list shape)
backed by the same probe, so any standard OpenAI client can discover models;
`/v1/capabilities` is the Phantasm-aware superset the app prefers. `/v1/models`
lists the real **base** model ids only — a standard OpenAI client sees a normal
model list — while research **modes** live in the capabilities superset as the
Phantasm-aware detail (see below).

An optional `modes` array advertises the research modes the deployment offers
(see §2.3). It is present **only** when those modes' required server tools are
usable:

```jsonc
{
  // …the fields above, plus:
  "modes": [
    { "id": "deep-research",  "label": "Deep Research",  "required_tools": ["web_search"] },
    { "id": "quick-research", "label": "Quick Research", "required_tools": ["web_search"] }
  ]
}
```

Each entry carries a mode `id` (the suffix the app composes onto a base model id,
§2.3), a human `label`, and a `required_tools` list of tool selector ids the mode
requires. The app shows a mode only when all required selectors are advertised
**and** the chosen base model has `tools: true`.

Each `models[]` entry reports one base model id. Its `capabilities` object is
omitted when the server cannot determine per-model support for the upstream; the
app treats omitted capabilities as unknown and allows them optimistically. When
present, capability field names mirror upstream Ollama names: `completion` gates
chat model selection, `vision` gates image attachments, `audio` reports audio
input support, `tools` gates all server and app-hosted tool affordances, `insert`
reports fill-in-the-middle support, and `embedding` identifies embedding-only
models. `context_length` is model
metadata, not a capability, so it lives beside `capabilities`.
`reasoning_efforts`, when present, reports model reasoning support and lists
the configured effort values the app may offer for that model. Native Ollama
does not advertise this field because `/api/show` does not provide a
trustworthy per-model list of accepted levels.

Each `tool_selectors[]` entry names one app-facing UI bucket. When a bucket is
enabled, the app sends the concrete server-side schema names listed in that
entry's `tools[]` as standard OpenAI `tools[].function.name` entries; e.g. the
`web_search` selector may send `web_search`, `weather`, and `github` together
when all three concrete tools are listed.

Buckets are grouped by what a user reasons about, not by implementation:
`web_search` holds the tools that reach **out to the internet** (search, fetch,
weather, maps, market data, GitHub) and is gated by the per-chat web-access
toggle; `utilities` holds **offline, on-box** tools (calculator, current time,
unit conversion, local OCR) that the app offers **unconditionally** — disabling
web access never disables them, and the app needs no separate toggle for them.
`image_generation` covers image generation, editing, audio generation, and video generation,
gated by the media-generation toggle. Each tool runs an operator-configured
workflow; models never author or submit ComfyUI graphs. Research
modes are advertised only when the actual Brave-backed `web_search` schema is
usable.

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

### 2.2c Resumable turns (optional, additive)

A streaming turn can outlive its connection so a long generation survives the app
backgrounding (iOS cannot hold a streaming connection while suspended). This is a
pure **transport** extension — request/response *bodies* stay byte-for-byte
standard OpenAI; a client that ignores it gets the legacy behavior. See
[`resilient-turns.md`](resilient-turns.md) for the design.

- **Turn identity — `Idempotency-Key` request header.** When a streaming request
  carries one, the orchestrator runs the turn detached from the connection and
  buffers its output, keyed by that value. Dropping the connection (backgrounding)
  no longer cancels the turn. A later request with the **same** key attaches to
  the running-or-finished turn and replays it rather than starting over. The app
  uses its pending-assistant message id, reused verbatim on the recovery resend.
  Absent ⇒ legacy behavior (turn bound to the connection, cancelled on
  disconnect). Raw Ollama lacks this; the app degrades gracefully.
- **Replay cursor — SSE `id:` + `Last-Event-ID`.** Each SSE event is stamped with
  `id: <n>` (a per-turn monotonic sequence). On reconnect a client MAY send
  `Last-Event-ID: <n>` to resume after that event; omitted ⇒ full replay from the
  start (what the app does — it rebuilds the message from the replayed stream).
- **Cancel — `POST /v1/chat/cancel` `{ "turn_id": "<key>" }`** (bearer-authed).
  Cancels a resumable turn by its `Idempotency-Key`, interrupting in-flight tool
  work (incl. a running ComfyUI generation). This is the new app's Stop, since a
  resumable turn no longer cancels on disconnect. Unknown id ⇒ no-op `204`.
  Legacy clients don't need it (they cancel by disconnecting).
- **Retention.** A finished turn's buffer is kept for `TURN_RESULT_TTL_S` so a
  late reconnect still gets the result; total buffered turns are bounded by
  `TURN_REGISTRY_MAX`, each turn by `TURN_BUFFER_MAX_BYTES`, and aggregate event
  data by `TURN_REGISTRY_MAX_BYTES`. A still-running turn with no connected
  client past `TURN_ABANDON_GRACE_S` is cancelled by a watchdog (the
  force-killed-app backstop). All are server config.

### 2.2d Pairing URI (optional, additive)

A backend connection is fully described by URL + token (§1), so pairing a
device is a transport problem: move those strings onto the phone without
typing. The shared convention is a URI that doubles as QR payload and deep
link — see [`qr-pairing.md`](qr-pairing.md) for the design:

```
phantasm://pair?v=1&url=<base URL>&token=<bearer>&name=<label>
```

`v` and `url` are required (`v` ≠ `1` ⇒ reject; unknown params ignored);
`token` and `name` are optional, so the format covers unauthenticated
backends like bare Ollama. It is producer-agnostic — the orchestrator, the
app itself (sharing an existing profile to a second device), or a shell
one-liner can mint one; no HTTP surface is added. The URI embeds the bearer
token and MUST be handled as the credential it is (never logged, per NFR-O7).

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
ones it executes itself. Two kinds exist today: `ask_user_input` (a
multiple-choice prompt the app renders, resolved by the user) and `current_time`
(the device answers from its own clock + timezone, resolved automatically with no
UI). It advertises them by sending **full** function schemas
(name + description + `parameters`) in the standard `tools` array. The
orchestrator merges these with its configured server tools and offers all to the
model, but it does **not** execute an app tool: when the model calls one, the
orchestrator streams that call back to the app as a standard `delta.tool_calls`
chunk terminated by `finish_reason: "tool_calls"`, then ends the turn. The app
fulfills the call, appends a `tool`-role result (with the matching
`tool_call_id`) to its history, and the model resumes on the next request — for a
device-resolved tool like `current_time` the app continues the turn itself
without waiting for the user. This
stays stateless (XR-2): the assistant `tool_calls` message and the `tool` result
both live in the app's history and are re-sent; every assistant `tool_calls`
message MUST be followed by a matching `tool` result (the app synthesizes a
"(dismissed)" result for an unanswered call). `arguments` is a JSON-encoded
string on the wire. Standard OpenAI clients that don't host the tool simply never
send its schema, so it's never offered to them.

**Classification + collisions.** A `tools` entry is app-hosted iff it carries a
`function.parameters` schema; a name-only entry selects a concrete server tool.
On a name collision the **server** tool wins — the app's same-named entry is
dropped and the call is executed server-side.

**Mixed batches (server + app calls in one response).** A model may emit
server-side and app-hosted tool calls in the *same* assistant response (e.g.
`maps_places` + `get_current_location`). Every call is honored: the orchestrator
executes the server calls immediately, then ends the turn forwarding **only** the
app calls (the server calls stay invisible to the app, per the rest of §2.3). To
avoid losing the server work across the turn boundary, the orchestrator keeps a
short-lived, server-side **continuation**: the resolved history (the assistant
`tool_calls` message plus the server `tool` results) is held, keyed by the
forwarded app `tool_call_id`. When the app re-sends with its `tool` result, the
orchestrator matches that id, resumes from the held history with the app's answer
appended, and continues — so the model never re-issues or loses the server calls.
This is the one bounded exception to XR-2's pure statelessness (see XR-2); it is
best-effort: a miss (server restart, TTL expiry) degrades gracefully to the model
re-issuing the dropped server calls. It needs no app cooperation and no wire
change — the keying rides the standard OpenAI `tool_call_id` the app already
echoes.

**Per-request tool selection (standard OpenAI fields).** The app scopes which
server tools a turn may use via the **standard** OpenAI `tools` / `tool_choice`
request fields — no custom field. The `tools` array merely *names* the wanted
tools, either as a function entry
(`{"type":"function","function":{"name":"web_search"}}`) or the built-in
shorthand (`{"type":"web_search"}`); the server fills in the real schema and
intersects with what it has configured (a client can never enable a tool the
deployment lacks). Semantics: `tools` **absent** → the server offers every
configured tool (older clients keep working); **present** → only the named
tools; a specific `tool_choice` function object → only that tool and, for
OpenAI-compatible upstreams, a forwarded forced tool choice during tool
resolution; an **empty array** or `tool_choice: "none"` → no tools (plain
chat). Tools remain server-side and invisible otherwise; this only lets the
client scope which of the advertised (`/v1/capabilities`) tools apply to a
given conversation. Because selection rides standard fields, any OpenAI client
can do it and a bare backend ignores it harmlessly.

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

- **Images** are embedded in the assistant message as ordinary markdown — no
  custom request field or client logic. Two interchangeable, fully-standard
  forms, chosen by *server config* alone:
  - **Inline** (default): `![generated](data:image/png;base64,…)` — exactly
    OpenAI's vision data-URI form.
  - **URL**: `![generated](https://host/v1/files/<id>/content?exp=…&sig=…)` —
    an absolute image URL, emitted when the deployment sets both
    `IMAGE_STORE_DIR` and `PUBLIC_BASE_URL`. Any markdown-rendering client loads
    it directly; the signing/expiry are invisible server-side details. This keeps
    re-sent history small (a short link, not multi-MB base64).
  - **Fetch**: `GET /v1/files/<id>/content?exp=&sig=` (OpenAI Files-style path)
    is authorized by the signed query string (HMAC over `id:exp`), so it is
    exempt from bearer auth — image loaders can't send an `Authorization` header.
  - **Lifecycle**: the app owns it. `DELETE /v1/files/<id>` (bearer-authed) drops
    a blob when its conversation is deleted; a server-side TTL (`IMAGE_STORE_TTL_S`)
    is the backstop for deletes that never arrive. New ids are unique per
    delivery, so deleting one conversation cannot break another; legacy shared
    content-hash blobs rely on TTL cleanup instead of explicit deletion.
  - The edit tool resolves a URL-delivered image back to bytes server-side, so
    editing a previously-generated image works in either form.
- **Progress** rides optional additive fields on the SSE chunk, e.g.
  `"x_status": "generating image…"` plus `"x_progress": 0.42` for
  determinate work such as ComfyUI image generation. Standard clients ignore
  unknown fields; the app reads these `x_` fields. Future custom fields should
  be `x_`-prefixed.
- Conversation is stateless server-side: the app sends full history each turn.
- Cancellation: for a plain turn the client aborts the SSE connection and the
  orchestrator halts generation and in-flight tool work. A **resumable** turn
  (§2.2c) instead survives disconnect — it is cancelled explicitly via
  `POST /v1/chat/cancel`, or by the abandoned-turn watchdog.

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
database writes, browser automation) require an explicit contract update and
user-confirmation UI.

**Sandboxed code execution (`code_exec`).** The one execution tool this
contract deliberately admits. The model runs short self-authored snippets in a
hardened, single-use container (rootless by default): no host filesystem
access, one container per execution — recycled afterward, so no state or
artifacts survive between runs — and bounded CPU, memory, pids, runtime, and
captured output. The same `code_exec` schema name appears in **both** selector
buckets (§2.1): under `utilities` it is always offered like the other offline
tools, and its listing under `web_search` is what lets a run reach the
internet. The lane is chosen per turn from the web-access signal — the presence
of other web-bucket tools in the request's selection — never from the tool
name: web access off ⇒ the no-network lane (no egress at all); on ⇒ an
egress-filtered lane (internet reachable, internal/metadata endpoints blocked
by deployment firewalling). Execution stays server-side and invisible to the
app like any other server tool; the tool honors the persistence boundary above
(nothing it writes outlives the run).

## 3. Orchestration server requirements

**Functional:** capabilities endpoint (FR-O1), OpenAI-compatible chat with SSE
(FR-O2), server-side tool loop with iteration cap (FR-O3), Brave web search
(snippet-first; FR-O4), ComfyUI image gen with progress relay (FR-O5), model
listing (FR-O6), bearer auth → 401 (FR-O7), cancellation — on disconnect for a
plain turn, or via `POST /v1/chat/cancel` for a resumable turn that survives
disconnect (FR-O8, §2.2c), optional self-contained tools for web fetch, current
time, calculator, unit conversion, weather, places/geocoding, market data,
GitHub reads, OCR, and sandboxed code execution (`code_exec`, §2.3) (FR-O9),
a `pair` subcommand printing the §2.2d pairing URI as a terminal QR — one
line after install, URL from the argument or `PAIR_URL`/`PUBLIC_BASE_URL`,
never emitted from the running service (FR-O10,
[`qr-pairing.md`](qr-pairing.md)). Local docs/filesystem tools and
other side-effecting tools are out of scope.

**Non-functional:** co-location over localhost/LAN (NFR-O1), async concurrency
with a configurable upstream generation limit (NFR-O2), low plain-chat latency
(<50ms added; NFR-O3), env-var config (NFR-O4), Docker + compose (NFR-O5), tool
failures non-fatal (NFR-O6), structured per-turn logs with no content by default
(NFR-O7), and fast search (~1–2s to first token: snippet-first, no RAG, bounded
concurrent fetch, small injected context, warm model where supported; NFR-O8).

## 4. iOS app requirements

**Functional:** backend config + validation (FR-A1), capability detection +
graceful degradation (FR-A2), streaming chat (FR-A3), markdown + code blocks
with copy (FR-A4), conversation management (FR-A5), model selection (FR-A6),
inline image display + save/share (FR-A7), `x_status` progress UI (FR-A8),
cancellation — Stop calls `POST /v1/chat/cancel` for a resumable turn (FR-A9,
§2.2c), resumable turns so a generation survives backgrounding: the app keys each
turn with `Idempotency-Key` and reconnects to replay it on foreground (FR-A11),
connection handling distinguishing unreachable/auth/model errors (FR-A10),
QR pairing — scan or deep-link a §2.2d pairing URI into a backend profile
behind an explicit confirmation showing the target host, and render a pairing
QR for an existing profile to pair a second device (FR-A12,
[`qr-pairing.md`](qr-pairing.md)).

**Non-functional:** iOS 18+ (NFR-A1), token in Keychain (NFR-A2), local GRDB/SQLite
persistence (NFR-A3), smooth streaming off the main thread (NFR-A4), fast cold
start (NFR-A5), optional multiple backend profiles (NFR-A6).

## 5. Cross-cutting

- **XR-1 Graceful degradation** — every tool is optional; plain chat works
  against any OpenAI-compatible endpoint including raw Ollama.
- **XR-2 Stateless server, stateful client** — the app sends full history each
  turn. Two bounded exceptions, both in-memory, TTL'd, capped, and lossy-safe (a
  miss just re-runs), so the server stays effectively stateless across
  conversations: (a) a turn paused on an app-hosted tool call while server calls
  co-occurred holds its resolved history server-side until the app's follow-up
  (see §2.3 "Mixed batches"); (b) a resumable turn (§2.2c) buffers its output for
  reconnect — a miss just re-runs the turn.
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
MVP assumes the user reaches their own backend using a server URL that is
already reachable from their device.

## 8. Resolved decisions

- Single OpenAI-compatible SSE endpoint; tools server-side; the only
  non-standard *body* element is the `x_`-prefixed `x_status` (progress) field.
  Deep Research rides the standard `model` id (a `"<base>:<mode>"` suffix
  resolved server-side, §2.3) rather than a proprietary flag, so research stops
  being non-standard wire surface — the headline win. Tool selection rides
  standard `tools`/`tool_choice`; streamed reasoning rides
  `delta.reasoning_content`; `/v1/models` is served alongside
  `/v1/capabilities`. Resumable turns (§2.2c) add only *transport* surface —
  the `Idempotency-Key`/`Last-Event-ID` headers, SSE `id:`, and a
  `POST /v1/chat/cancel` endpoint — leaving request/response bodies standard.
- Upstream native Ollama via **`/api/chat`** when available, with explicit or
  auto-detected OpenAI-compatible `/v1` support for non-Ollama model hosts such
  as vLLM and llama.cpp. Streaming chat turns require the selected upstream to
  support streamed tool calls. `UPSTREAM_KIND` may force `native_ollama` or
  `openai_compatible`/`vllm`/`llama_cpp`; unset/`auto` probes native Ollama
  first, then `/v1/models`.
- Image return format: inline base64 data-URI markdown by default; absolute
  server-hosted image URLs when the deployment configures a store + public base
  (server-side choice, no client opt-in; see §2.2b).
- Generated audio is returned as an absolute signed Files-style URL, never an
  inline data URI; byte-range fetches support native streaming playback. Audio
  workflows are operator-configured and must expose one temporary audio output.
- Generated video uses the same signed, byte-range-capable artifact delivery.
  Video workflows are operator-configured and expose one selected file output;
  models provide only bounded semantic inputs, never graph JSON.
- Ship one default ComfyUI workflow, overridable via config.
- Pairing rides a `phantasm://pair` URI (§2.2d) carrying the static token
  directly — no token issuance, no `/v1/pair` endpoint, no new HTTP surface.
  A one-time-code exchange was considered and deferred: it would require the
  server to mint and store credentials, breaking the env-only/stateless model
  for marginal gain at single-user scale (see `qr-pairing.md`).
