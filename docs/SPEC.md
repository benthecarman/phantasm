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
  "tools": { "web_search": true, "image_generation": true },
  "streaming": "sse"
}
```

A bare Ollama won't serve this route; the app MUST treat 404/connection failure
as "plain chat only" and degrade gracefully. The `tools` block is advisory — it
only tells the app whether to *show* affordances. The app never executes tools.

`vision_models` and `tool_models` are subsets of `models` reporting which models
accept image input and which can drive tool/function calls (probed server-side
via Ollama `/api/show`; both optional, omitted/empty ⇒ the app treats that
capability as unknown and allows it optimistically). Because the server tools
are invoked by the model, a tool is usable only when `tools` advertises it **and**
the chosen model is in `tool_models` — the app gates the per-tool toggles on both.

### 2.2 Chat (single OpenAI-compatible endpoint)

`POST /v1/chat/completions` with `"stream": true`. Standard OpenAI request/
response shape and SSE token streaming. This is the **only** chat endpoint and
MUST work against raw Ollama unchanged. No separate tool endpoint, no custom
WebSocket protocol — tools are invisible to the app.

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
launch and on model switch. For a native-Ollama upstream the server issues a
no-message "load" (model resident via `keep_alive`, zero tokens); for any other
upstream it is a no-op. Returns `{ "warmed": bool, "model": "…" }` and MUST NOT
error the caller — a bare Ollama (no orchestrator) simply lacks this route, and
the app degrades to a native `/api/chat` load instead. Plain OpenAI-compatible
backends are not warmed (no free preload).

### 2.3 Tools are server-side and invisible to the app

Tool execution happens entirely on the **orchestrator ↔ Ollama** hop using
standard OpenAI function-calling:

1. App sends a normal request to the orchestrator.
2. Orchestrator calls Ollama as an OpenAI client, passing the configured `tools`.
3. Ollama returns `tool_calls`; the orchestrator executes them (Brave, ComfyUI),
   appends `tool`-role results, and re-calls — capped at N iterations.
4. Once Ollama returns a final assistant message, the orchestrator streams *that*
   back to the app as ordinary SSE chunks.

**Per-request tool selection (additive).** The app MAY include an `x_tools`
field on the request — a JSON array of tool names it wants offered this turn
(e.g. `["web_search"]`). Following the `x_`-prefix convention, standard clients
and backends ignore it. Semantics: field **absent** → the server offers every
configured tool (older clients keep working); **present** → the server offers
only the named tools, always intersected with what is actually configured (a
client can never enable a tool the deployment lacks); an **empty array** → no
tools (plain chat). Tools remain server-side and invisible otherwise; this only
lets the client scope which of the advertised (`/v1/capabilities`) tools apply
to a given conversation.

**Deep Research mode (additive).** The app MAY include an `x_research: true`
field to run the turn in Deep Research mode. Following the `x_`-prefix
convention, standard clients and backends ignore it; **absent/false** is an
ordinary turn. When set, the orchestrator injects a research system prompt,
offers only `web_search` (forcing full-page fetching regardless of the
operator's `SEARCH_FETCH_PAGES` gate), and runs a larger tool-loop budget
(`MAX_RESEARCH_ITERS`) so the model can decompose the question, search across
several rounds, and synthesize a single cited answer. The result still streams
back as ordinary assistant markdown (inline `[n]` citations + a sources list),
so a standard client renders it with no special handling. Deep Research depends
on `web_search` being configured; the app gates its toggle on that capability.

Consequences:

- **Images** are embedded in the assistant message as markdown
  `![generated](data:image/png;base64,…)` or a URL.
- **Progress** rides an optional additive field on the SSE chunk,
  `"x_status": "generating image… 42%"`. Standard clients ignore unknown fields;
  the app reads `x_status`. Future custom fields should be `x_`-prefixed.
- Conversation is stateless server-side: the app sends full history each turn.
- Cancellation: the client aborts the SSE connection; the orchestrator detects
  the disconnect and halts generation and in-flight tool work.

## 3. Orchestration server requirements

**Functional:** capabilities endpoint (FR-O1), OpenAI-compatible chat with SSE
(FR-O2), server-side tool loop with iteration cap (FR-O3), Brave web search
(snippet-first; FR-O4), ComfyUI image gen with progress relay (FR-O5), model
listing (FR-O6), bearer auth → 401 (FR-O7), cancellation on disconnect (FR-O8).

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

## 6. Build phases

1. Plain chat path (app + Ollama). 2. Orchestrator skeleton (capabilities, auth,
passthrough). 3. Tool loop + web search. 4. Image generation. 5. Polish
(conversation management, model picker, profiles, reconnect hardening).

## 7. Out of scope (deferred premium layer)

User accounts, subscription billing, cross-device cloud sync, managed
remote-access relay, and anything running on developer-hosted infrastructure.
MVP assumes the user reaches their own backend (home wifi, VPN/Tailscale, tunnel).

## 8. Resolved decisions

- Single OpenAI-compatible SSE endpoint; tools server-side; only non-standard
  element is the `x_`-prefixed `x_status` field.
- Upstream native Ollama via **`/api/chat`** when available (Ollama
  OpenAI-compat drops streamed tool_calls), with OpenAI-compatible `/v1`
  fallback for non-Ollama model hosts.
- Image return format: base64 data-URI markdown for MVP.
- Ship one default ComfyUI workflow, overridable via config.
