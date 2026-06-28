# Resilient turns — surviving client disconnect (background) mid-generation

Design plan for fixing: *backgrounding the app during a server-side image
generation abandons the work; you have to keep the app foregrounded to see it
finish.*

Status: **proposal** (not yet implemented). Owner: TBD.

## 1. Problem recap

A turn's work is bound to the live SSE connection:

1. App backgrounds → iOS grants ~30s, then cancels the local streaming task
   (`ios/.../ChatViewModel.swift:122-127`), which aborts the `URLSession.bytes`
   request (`SSEStream.swift:248`) → TCP drops.
2. Server's SSE drop-guard fires the turn's `CancellationToken`
   (`orchestrator/src/routes/chat.rs:209`); the turn loop bails
   (`turn.rs:202-210`) and in-flight tools are abandoned (`turn.rs:357-362`).
3. ComfyUI is never told to stop (`tools/comfy.rs:120-140` has no cancel
   branch), so the GPU job runs on, orphaned, and its result is never fetched.
4. On foreground the app's recovery (`ChatViewModel.swift:579-628`) **re-sends
   the request**, which spawns a *brand-new* turn from scratch — it queues behind
   the orphaned ComfyUI job and effectively never converges.

Root constraint: **iOS cannot hold a streaming HTTP connection open in the
background** (background `URLSession` only does discrete upload/download tasks,
not SSE). So the fix must live on the server: decouple the turn's lifetime from
the connection, buffer its output, and let the client **reconnect to fetch** the
in-progress or finished turn.

## 2. Design overview

Introduce a **resumable turn**: the spawned turn task keeps running regardless of
whether any client is attached. Its `TurnEvent`s are appended to an in-memory
**event log** held in a new `TurnRegistry`, keyed by a client-supplied stable
**`Idempotency-Key` request header**. An SSE responder *attaches* to that log —
replaying buffered events from a cursor, then tailing live events until `Done`.
Disconnecting just detaches the responder; it does **not** cancel the turn.

The whole resume mechanism rides on **standard HTTP/SSE transport, not the chat
schema** — the request and response *bodies* stay byte-for-byte standard OpenAI
(see §3). A vanilla OpenAI client that ignores these headers gets today's
behavior.

```
POST /v1/chat/completions   header: Idempotency-Key: T
                            (resume also sends: Last-Event-ID: N)
        │
        ▼
  TurnRegistry.get_or_create(T)
        ├── miss  → spawn turn task → writes events into ActiveTurn(T).log
        └── hit   → attach to existing ActiveTurn(T).log  (no new turn)
        │
        ▼
  SSE responder: replay log[(N+1)..], then tail until Done
        │           (N from Last-Event-ID; full replay from 0 if absent)
        ▼
   (client backgrounds → connection drops → responder detached)
        │
   turn task keeps running, keeps appending to log
        │
   (client foregrounds → resends, same Idempotency-Key → HIT)
        │
   new responder replays the log tail (incl. the image) → done
```

The turn is cancelled only by an **explicit** signal (stop button → cancel
endpoint) or a **safety TTL** — never by a dropped connection.

This composes with, and is orthogonal to, the existing `ContinuationCache`
(intra-turn app+server tool-call pausing, `state.rs:53-113`). That stays as-is.

## 3. The turn key + replay cursor: standard headers, not a body field

Chat Completions has no native resume/turn-id (the `chatcmpl-…` response `id` is
server-minted and only arrives with the first chunk, so it can't key a reconnect
for a turn the client hasn't successfully started). The OpenAI **Responses API**
*does* have this natively (`background`+`store`+`starting_after`), but adopting it
means migrating the endpoint and doesn't fit the Ollama-native upstream — out of
scope. So we keep Chat Completions and carry resume on **transport headers**,
leaving the JSON body untouched:

- **Turn identity — `Idempotency-Key: <uuid>` (request header).** OpenAI supports
  this header for safe retries; its semantics ("a repeat with the same key maps
  to the same operation") are exactly resume-to-completion. The server keys the
  `ActiveTurn` by it. Absent ⇒ today's behavior (fresh turn, cancel-on-disconnect
  — the legacy path, §6).
- **Replay cursor — SSE `id:` field + `Last-Event-ID` header.** The *web-standard*
  resumable-SSE protocol: the server stamps each SSE event with `id: <seq>` (a
  per-turn monotonic sequence); on reconnect the client sends
  `Last-Event-ID: <n>` and the server replays from `n+1`. Omitted ⇒ full replay
  from 0. This gives mid-stream resume for free and needs no bespoke cursor.

The client-controlled stable id is the iOS **pending assistant message UUID**: it
already persists with the incomplete assistant row and is reused verbatim on
recovery (`ChatViewModel.swift:615`, `pendingAssistantMessageID = pending.id`).
Use it as the `Idempotency-Key`.

- **No body/SSE-schema changes.** Request and response bodies stay byte-for-byte
  standard OpenAI; resume lives entirely in headers. A standard client that
  ignores `Idempotency-Key`/`Last-Event-ID`/`id:` degrades to current behavior.
- A turn id maps 1:1 to a single incomplete assistant message. The app-tool-call
  continuation produces a *new* assistant message afterward, hence a *new*
  `Idempotency-Key` — so resume and the continuation cache never collide.

> **Caveat:** `URLSession.bytes` (the iOS client) doesn't auto-manage
> `Last-Event-ID` the way a browser `EventSource` does — but the app already sets
> request headers by hand, so it just sets these two manually. Still the standard
> headers, just not browser-automatic.

## 4. Server: `TurnRegistry` + `ActiveTurn`

New module `orchestrator/src/state.rs` (alongside `ContinuationCache`) or a
dedicated `orchestrator/src/turn_registry.rs`. Event-log + `Notify` (not a
broadcast channel — avoids bounded-lag drops and supports replay-from-index
cleanly).

```rust
#[derive(Clone, Default)]
pub struct TurnRegistry(Arc<Mutex<HashMap<String, Arc<ActiveTurn>>>>);

pub struct ActiveTurn {
    log: Mutex<TurnLog>,        // std::sync::Mutex — pushes are short, no await held
    notify: Notify,             // notify_waiters() after each append
    cancel: CancellationToken,  // fired by the explicit cancel endpoint or the TTL watchdog (§6)
    attached: AtomicUsize,      // live responder count; drives the abandoned-turn backstop
    detached_at: Mutex<Option<Instant>>, // when attached last hit 0; backstop clock
    created_at: Instant,
    terminal_at: Mutex<Option<Instant>>, // set on Done/Error; drives result-TTL eviction
}

struct TurnLog {
    events: Vec<TurnEvent>,     // the full turn, in order
    done: bool,                 // true once a terminal Done/Error is appended
}
```

**Producer (turn task).** Replace the single `mpsc::Sender<TurnEvent>` the turn
writes to with a sink that appends to `ActiveTurn.log` and calls
`notify.notify_waiters()`. Minimal-diff option: keep `run_turn`'s `tx:
mpsc::Sender` signature and run a small pump task that drains `rx` into the log —
so `turn.rs` is untouched. Preferred for a first cut.

**Consumer (SSE responder).** A stream that holds `Arc<ActiveTurn>` and a cursor
`i`, seeded from the `Last-Event-ID` header (`i = n+1`, or `0` if absent). The
event's log index *is* its SSE `id:` — a per-turn monotonic sequence — so the
client's `Last-Event-ID` round-trips directly into the cursor:

```text
i = last_event_id.map(|n| n + 1).unwrap_or(0)
loop {
    snapshot = log.events[i..].clone(); done = log.done;   // under the lock
    for ev in snapshot { yield map_event(ev).id(i.to_string()); i += 1 }
    if done { yield done_event(); return }
    notify.notified().await        // wakes on next append
}
```

`axum::response::sse::Event::id(..)` stamps the SSE `id:` line. Race-free: the
producer appends-then-notifies under the same discipline; a `Notify` permit set
between the snapshot and the `notified()` await is retained, so no wakeup is lost.
(Subscribe-before-snapshot is automatic with `Notify`.)

A `Last-Event-ID` past the current log length (client ahead of server — shouldn't
happen, but be defensive) clamps to the log end and tails from there.

**Memory.** The log buffers the whole turn, including the final
base64-data-URI image in inline-delivery mode (multi-MB). This is the same
tradeoff `ContinuationCache` already accepts. In **URL-delivery** mode
(`IMAGE_STORE_DIR` + public base, `turn.rs:192`) the image is a `/v1/images/<id>`
ref, not bytes — much cheaper. Recommend documenting URL-delivery as the
preferred config for this feature. Bound with `TURN_REGISTRY_MAX` (evict oldest
*terminal* entry first), mirroring `CONTINUATION_MAX`.

**TTL.** Two timers:
- `RESULT_TTL` (`TURN_RESULT_TTL_S`, default 24h): after `terminal_at`, keep the
  finished log so a late reconnect can still fetch it, then evict. The long
  default lets a reconnect recover a generation even long after the app closed;
  memory is bounded by `TURN_REGISTRY_MAX`, not the TTL.
- `ABANDONED_TTL` / safety cap (`TURN_ABANDON_GRACE_S`, default 300s; `0`
  disables): a background watchdog cancels + drops any still-running turn whose
  `attached` count has been 0 since `detached_at` for longer than the grace, so
  an app that was *killed* (never reconnects, never hits the cancel endpoint)
  doesn't leave work running. Terminal turns are exempt (they're buffered results
  awaiting a possible reconnect). Natural per-tool timeouts (`comfy_timeout_s`,
  `max_tool_iters`, upstream request timeouts) already bound runtime; this is a
  backstop behind the explicit cancel (§6), not the primary stop path.

## 5. Server: chat route changes (`routes/chat.rs`)

`chat_completions` (`chat.rs:27-150`) needs the request **headers**. Add an
`axum::http::HeaderMap` (or typed `TypedHeader`) extractor to the handler and read
`Idempotency-Key` and `Last-Event-ID` from it — the JSON `ChatRequest` is
unchanged.

1. Read `Idempotency-Key` and `Last-Event-ID` from the headers.
2. If `Idempotency-Key` present, **atomic get-or-create** under the registry lock:
   - **Hit:** an `ActiveTurn` exists → do **not** spawn; build the SSE/collect
     response as an *attach* to its log, seeking to `Last-Event-ID`. Skip all the
     turn-spawn/continuation-splice work.
   - **Miss:** insert a fresh `ActiveTurn`, spawn the turn task wired to its log
     (via the pump), then attach. The get-or-create must hold the lock across
     check+insert to avoid a double-spawn race on a fast reconnect/retry storm.
3. If `Idempotency-Key` is absent → today's path unchanged (fresh turn; and we may
   keep drop-guard cancel for that legacy path only — see §6).

**`stream_response` (`chat.rs:200-252`):** the SSE body becomes the attach loop
from §4 (stamping `id:` on each event, seeded from `Last-Event-ID`). **Crucially
remove `let guard = cancel.drop_guard();`** (line 209) for resumable turns —
dropping the responder must *not* cancel. Detach instead: decrement the
attached-responder count (drives the abandoned-TTL watchdog).

**`collect_response` (`chat.rs:254+`):** non-streaming requests drain the log to
completion the same way. Lower priority (the iOS app streams), but routing it
through the registry keeps one code path.

## 6. Cancellation model

Cancellation depends on whether the turn is resumable (i.e. whether it was
started with an `Idempotency-Key`):

- **Legacy / standard clients (no `Idempotency-Key`).** Unchanged: *disconnect ⇒
  cancel* via the drop-guard (`chat.rs:209`). This is the OpenAI-standard cancel
  (Chat Completions has no cancel endpoint — aborting the request is the cancel),
  so a vanilla client keeps working exactly as today.
- **Resumable turns (with `Idempotency-Key`).** *disconnect ⇒ detach, keep
  running* (so backgrounding survives). Cancel comes from either:
  - the **explicit cancel endpoint** below (the new app's Stop), or
  - the **abandoned-turn backstop** (§4 TTL): a running turn with no attached
    responder past a grace window → fire `cancel`, so an app that was *killed*
    (never reconnects, never calls cancel) doesn't leave work running.

**Stop button.** `ChatViewModel.stop()` (`ChatViewModel.swift:852`) currently
just cancels the local task (drops the connection). For a resumable turn that no
longer stops the server, so the new app additionally calls
**`POST /v1/chat/cancel { "turn_id": "..." }`** (shape per §11): looks up the
`ActiveTurn` by `Idempotency-Key`, fires its `cancel`, evicts. This frees the GPU
*immediately* on Stop (no waiting for the backstop), which is the win over relying
on the watchdog alone — and it composes with the ComfyUI interrupt below.
Legacy clients don't need it: their disconnect already cancels.
- **ComfyUI interrupt (folds in the option-B hygiene fix).** Give
  `comfy::run_workflow` (`tools/comfy.rs:84-145`) a cancel branch in its
  `select!`: on `cancel.cancelled()`, POST ComfyUI `/interrupt` (and delete the
  queued `prompt_id` if not yet started) before returning, so an explicitly
  cancelled job frees the GPU instead of orphaning it. Thread the
  `CancellationToken` down `image_gen::run` → `generate` → `run_workflow`
  (currently it stops at `image_gen.rs:65-68`).

## 7. iOS changes

1. **Send the headers.** Set `Idempotency-Key` on the chat request, from
   `pendingAssistantMessageID`. The request goes through `ChatClient.stream`
   (`SSEStream.swift:218-228`), which builds the `URLRequest` — add the header
   there (and a `ChatRequest`-level field carrying the id is *not* needed; the
   JSON body stays standard). Set the same key on both the initial send and the
   recovery resend so they share identity (the recovery path already reuses the
   message id, `ChatViewModel.swift:615`).
2. **Rebuild from the replay.** Simplest first cut: on (re)connect omit
   `Last-Event-ID` so the server replays the whole turn; the client starts each
   connection with empty streaming buffers and lets the replay rebuild — i.e. in
   `recoverPendingTurn` drop the `streamingText = pending.message.content` preseed
   (`:611`) and start empty, so replayed tokens aren't double-counted. (The
   initial send already starts empty.) Optional optimization: persist the last
   seen SSE `id:` and send it as `Last-Event-ID` to resume mid-stream and skip
   re-streaming the prefix — not required for correctness.
3. **Background expiry is now benign.** Keep the background-task path
   (`:115-127`); when it cancels the local task the server keeps going, and the
   existing foreground recovery (`recoverPendingTurnIfNeeded`) now reconnects to
   a *running or finished* turn instead of restarting it. No new lifecycle code
   needed — the behavior falls out of resume.
4. **Stop button** (`:852`) also calls the new cancel endpoint.

## 8. Contract / SPEC §2 changes

Update `docs/SPEC.md` §2 deliberately (both halves). Note that resume is a
*transport* extension — the request/response bodies are unchanged:
- Request headers: `Idempotency-Key` (turn identity) and `Last-Event-ID` (replay
  cursor); both standard, ignorable by standard clients.
- Response: each SSE event carries a standard `id:` line (per-turn sequence).
- New endpoint `POST /v1/chat/cancel` (shape per §11); its `turn_id` is the
  turn's `Idempotency-Key`. Optional for clients — legacy clients cancel by
  disconnecting (§6).
- Document resume semantics: a repeat with the same `Idempotency-Key` ⇒ attach +
  replay (from `Last-Event-ID`, or from the start); the server retains a turn's
  output for `RESULT_TTL` after completion.

## 9. Edge cases

- **Concurrent requests, same id:** atomic get-or-create → second attaches to the
  first; both replay the same log.
- **Reconnect after completion:** log is terminal → responder replays all events
  (from `Last-Event-ID`) incl. the image and `Done`, then ends. This is the core
  "finished while backgrounded" win.
- **Reconnect after error/cancel:** replays the `Error`/cancel; app handles as
  today.
- **`Last-Event-ID` past log end:** clamp to end and tail (§4).
- **App killed (not backgrounded):** no reconnect → abandoned-TTL watchdog
  cancels; result-TTL evicts.
- **Turn ends in app tool calls:** `ToolCalls`+`Done` are buffered/replayable
  like any terminal; the continuation then starts a new turn (new
  `Idempotency-Key`). Compatible with `ContinuationCache`.
- **Legacy client (no `Idempotency-Key`):** unchanged behavior; safe to keep
  drop-guard cancel on that path only.

## 10. Testing

- `TurnRegistry` unit tests: get-or-create atomicity; replay-from-zero;
  replay-from-`Last-Event-ID` cursor (incl. past-end clamp); tail-after-replay;
  terminal replay; TTL/eviction; `MAX` bound.
- Route test: SSE events carry monotonic `id:` lines; a reconnect with
  `Last-Event-ID: n` resumes from `n+1`.
- Turn-loop tests already use scripted in-memory `ChatBackend`/`ToolExecutor`
  (CLAUDE.md conventions) — add: detach mid-stream, the turn still completes and
  buffers; reattach replays the full output.
- Cancel endpoint: `POST /v1/chat/cancel` with a live `turn_id` fires the turn's
  cancel and evicts; an attached responder sees the turn end; an unknown id is a
  no-op (not an error). Legacy turn (no `Idempotency-Key`): disconnect still
  cancels.
- ComfyUI interrupt: scripted tool that observes cancel → asserts interrupt
  issued.
- iOS `PhantasmKit`: `ChatClient.stream` sets `Idempotency-Key`; recovery starts
  empty and rebuilds from a replayed stream without duplication.

## 11. Open decisions

1. **Cancel endpoint shape** — `POST /v1/chat/cancel {turn_id}` (proposed) vs.
   `DELETE /v1/chat/turns/{turn_id}` vs. piggybacking a flag on the chat
   endpoint. Affects SPEC §2.
2. ✅ **Abandoned-running-turn policy** — added the no-attached-responder
   watchdog; `TURN_ABANDON_GRACE_S` default 300s (`0` disables).
3. ✅ **`RESULT_TTL` / `TURN_REGISTRY_MAX` values** — `TURN_RESULT_TTL_S` default
   24h, `TURN_REGISTRY_MAX` default 128; both env-configurable.
4. **Inline vs URL image delivery** — recommend requiring/encouraging
   URL-delivery for this feature to keep the log cheap; or accept the inline
   memory cost.

## 12. Phasing

1. ✅ **Done (server).** `TurnRegistry` + `ActiveTurn` (`turn_registry.rs`) +
   pump; chat route reads `Idempotency-Key`/`Last-Event-ID`, routes resumable
   streaming turns through the registry (`spawn_turn`/`spawn_pump`/
   `attach_response` in `routes/chat.rs`), no drop-guard on that path;
   `TURN_RESULT_TTL_S`/`TURN_REGISTRY_MAX` config + TTL/size eviction. Tested:
   registry unit tests + integration `resumable_turn_replays_on_reconnect_*`.
   Not yet user-visible — dormant until the iOS app sends the header (phase 2).
2. ✅ **Done.** Server: `POST /v1/chat/cancel` (`routes/chat.rs::cancel`,
   registered in `routes/mod.rs`) + ComfyUI interrupt-on-drop
   (`tools/comfy.rs::InterruptOnDrop` → `/interrupt` + `/queue` delete). iOS:
   `ChatClient` sends `Idempotency-Key` (= pending-assistant id) and gains
   `cancel(...)`; `streamReply` passes the turn id; `recoverPendingTurn` starts
   empty so the replay rebuilds; `stop()` calls the cancel endpoint. Tested:
   integration `cancel_drops_turn_so_reconnect_reruns` / `cancel_requires_auth`;
   app builds + installs.
3. ✅ **Done.** Abandoned-turn watchdog: `ActiveTurn` tracks attached responders
   (RAII `AttachGuard` in `attach_response`); `TurnRegistry::sweep_abandoned` +
   `spawn_watchdog` (started in `build_state`) cancel + drop still-running turns
   with no listener past `TURN_ABANDON_GRACE_S` (default 300s, `0` disables).
   Tested: `sweep_cancels_detached_running_turns_only`,
   `detach_rearms_the_abandoned_clock`.
4. SPEC §2 + docs. (Remaining: fold the contract changes into `docs/SPEC.md`.)
