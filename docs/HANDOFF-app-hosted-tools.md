# Handoff: App-hosted tools + `ask_user` multiple-choice

**Status:** Orchestrator (Rust) implemented **and verified green**. iOS (Swift)
implemented with tests written but **never compiled** — this work was done on a
Linux box with no Swift/Xcode toolchain. Your first job on the Mac is to make the
iOS half build and pass tests, then verify end-to-end.

This doc is self-contained: it explains the feature, the architecture decision
behind it, every change made, what's verified, and exactly how to finish.

---

## 1. What this feature is

We added the ability for the model to present the user with **tappable
multiple-choice options** ("quick replies"), like modern AI apps. The model calls
a tool named `ask_user` with a question + options; the app renders buttons; the
user taps one (or several, or free-types); the model continues with that answer.

There is **no OpenAI-standard primitive** for multiple-choice, so it's
implemented as the OpenAI-idiomatic **client-executed tool call** (the same shape
Anthropic's AskUserQuestion / Slack Block Kit / Messenger quick-replies use).

## 2. The architecture decision (important context)

Phantasm originally had **all tools server-side and invisible to the app** (SPEC
§2.2/§2.3): the orchestrator ran web-search/image-gen against Ollama in a loop
and the app only saw a plain SSE token stream.

During planning the user pivoted deliberately (and said **backward compatibility
is NOT a concern** — both halves are self-hosted and change together):

> "We are just going to start adding tools to the app. We can get rid of that
> contract." → chose: **the app sends its own tool schemas.**

So the final design is a **generic merge + route** layer, not an `ask_user`
special case:

- The app sends **full OpenAI function schemas** for tools it hosts, in the
  standard `tools` request array.
- The orchestrator **merges** app tools with its configured server tools, offers
  all to the model, **executes server tools itself**, and **forwards app-tool
  calls back to the app** (standard `delta.tool_calls` + `finish_reason:
  "tool_calls"`).
- The app fulfills the call (renders UI), returns a `tool`-role result in
  history, and the model resumes next turn.

`ask_user` is simply the **first** app-hosted tool. The orchestrator has **zero
`ask_user`-specific code** — that's the payoff. Adding a future app tool = a new
schema entry + a handler in the app, no server change.

**Classification rule:** a `tools` entry with `function.parameters` = app-hosted
tool (forward its calls); a name-only entry = server-tool selector (existing
behavior). **On a name collision the server tool wins** (the app's same-named
entry is dropped, executed server-side).

Stateless is preserved (XR-2): the assistant `tool_calls` message and the `tool`
result both live in the app's local history and are re-sent each turn.

The full approved plan is at `/home/ben/.claude/plans/fizzy-moseying-island.md`
(may not exist on your machine; this doc supersedes it).

## 3. The wire contract (the shapes)

**Forwarded call — streaming SSE from orchestrator to app:**

```jsonc
// chunk 1: the tool call (arguments is a JSON-encoded STRING, not an object)
{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_…",
  "type":"function","function":{"name":"ask_user",
  "arguments":"{\"question\":\"…\",\"options\":[\"a\",\"b\"],\"allow_multiple\":false}"}}]},
  "finish_reason":null}]}
// chunk 2: the finish
{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
// then: data: [DONE]
```

**App reply on the next request — re-sent in full history:**

```jsonc
{"role":"assistant","content":"","tool_calls":[ …same call… ]}
{"role":"tool","tool_call_id":"call_…","name":"ask_user","content":"<the answer>"}
```

**`ask_user` arguments schema** (the app owns this; sent in the request `tools`):
`{ question: string, options: string[], allow_multiple?: bool }`.

**Pairing rule:** every assistant `tool_calls` message MUST be followed by a
matching `tool` result. If the user never answered (e.g. they typed an unrelated
message, or the app restarted and the prompt was dismissed), the app synthesizes
a `"(dismissed)"` tool result so history stays OpenAI-valid.

---

## 4. Orchestrator changes (Rust) — VERIFIED ✅

Verified on Linux: `cargo test` (121 pass), `cargo clippy --all-targets`,
`cargo fmt --all --check`, `cargo build --features gzip` all clean.

| File | Change |
|------|--------|
| `orchestrator/src/openai/types.rs` | `ToolSpecFunction` now also deserializes `description` + `parameters`. New `ChatRequest::app_tools() -> Vec<Value>` rebuilds OpenAI envelopes for schema-bearing entries (`[]` when `tool_choice:"none"`). Added `RawArguments::to_json_string()`. Added serialize-only `DeltaToolCall`/`DeltaFunctionCall` + `Delta.tool_calls` field + `Delta::tool_calls(...)` ctor. |
| `orchestrator/src/orchestrator/mod.rs` | New `TurnEvent::ToolCalls(Vec<ToolCall>)`. |
| `orchestrator/src/orchestrator/turn.rs` | `run_turn` takes a new `app_tools: Vec<Value>` param. Merges app tools after `select_schemas` with **server-wins** collision handling (`schema_name` helper builds the `app_names` set). In the streaming tool-resolution loop, if the model calls any app tool it sends `TurnEvent::ToolCalls(app_calls)` + `Done{reason:"tool_calls"}` and returns. Co-occurring server calls are executed first and held in a short-lived server-side continuation keyed by the forwarded app `tool_call_id`. |
| `orchestrator/src/openai/sse.rs` | `ChunkFactory::tool_calls(&[ToolCall])` emits the delta chunk; `ensure_call_id` mints an id when absent. |
| `orchestrator/src/routes/chat.rs` | Computes `req.app_tools()`, passes into `run_turn`. `stream_response` maps `TurnEvent::ToolCalls` → `factory.tool_calls`. `collect_response` (non-streaming) emits `tool_calls` with `content:null` + `finish_reason:"tool_calls"` via `wire_tool_calls`. |
| `docs/SPEC.md` | §2.2/§2.3 rewritten: app-hosted vs server tools, forwarding, collision rule, pairing rule. |

`ChatMessage` already had `tool_calls`/`tool_call_id`/`name` and round-trips
through Ollama's native API both ways, so no message-type changes were needed.

**Tests added** (in `turn.rs`, `types.rs`, `sse.rs`): app-tool extraction,
collision (server wins → executed not forwarded), forwarding (emits ToolCalls +
Done, never executes app-hosted tools), mixed app+server call, SSE shape
(arguments is a string), `to_json_string`, `ensure_call_id`.

---

## 5. iOS changes (Swift) — IMPLEMENTED, NOT COMPILED ⚠️

All written carefully against the existing code, but **no Swift compiler was
available** — expect to fix compile nits. New files must be picked up by
`xcodegen generate` (Views are globbed; PhantasmKit is SPM).

### New files
- `ios/Packages/PhantasmKit/Sources/PhantasmKit/Tools/AskUserParser.swift` —
  pure parser: `MultipleChoice { toolCallId, question, options, allowMultiple }`
  + `parse(WireToolCall)` / `firstChoice(in:)`. Tolerant (nil on bad JSON / wrong
  name / <2 options).
- `ios/Views/Chat/ChoicePromptView.swift` — the prompt UI (single-select =
  tap-to-send full-width buttons; multi-select = toggles + Send). Rendered above
  the composer.
- `ios/Packages/PhantasmKit/Tests/PhantasmKitTests/AskUserParserTests.swift`.

### Edited files
| File | Change |
|------|--------|
| `…/PhantasmKit/Models/WireTypes.swift` | `JSONValue` (inline schema), `WireToolCall` (Codable), `ToolSpec` full-schema init, `ChatRequest(appTools:)` merge (app tools offered even when server tools are off), `WireMessage` `toolCalls`/`toolCallId`/`name` + `init(assistantToolCalls:)` / `init(toolResult:name:content:)`, `Delta.toolCalls`, `ToolName.askUser`, `AppTools` registry with the `ask_user` schema. |
| `…/PhantasmKit/Networking/SSEStream.swift` | `ChatStreamEvent.toolCalls([WireToolCall])`; accumulate `delta.toolCalls` by index (fragment-merge) and emit before `.done` on the terminating frame. `mergeToolCall` helper. |
| `…/PhantasmKit/Persistence/Models.swift` | `Message` gains `toolCalls`/`toolCallId`/`name`. `wireHistory()` rewritten to emit assistant tool_call + `tool` result messages, preserve ordering, and synthesize a `(dismissed)` result for an unanswered call. |
| `…/PhantasmKit/Persistence/AppDatabase.swift` | Migration `v6_client_tools` adds the 3 columns; new `completeToolCallMessage(id:toolCalls:)`. |
| `…/PhantasmKit/Persistence/ChatStore.swift` | Protocol gains `completeToolCallMessage`. |
| `ios/ViewModels/ChatViewModel.swift` | `pendingChoice` state; capture forwarded calls on `.toolCalls`; commit the tool_call row in `finish()`; `answerPendingChoice(_:)` persists the `tool` result and starts the next turn; `send()` routes free-typed text to `answerPendingChoice` while pending; restart recovery re-derives `pendingChoice`; advertises `AppTools.all` only against an orchestrator with a tool-capable model. |
| `ios/Views/Chat/ChatView.swift` | Renders `ChoicePromptView` above the composer when `vm.pendingChoice != nil` (`.id(choice.toolCallId)`). |

**Tests added/extended:** `AskUserParserTests`; SSE whole + fragmented tool-call
decode; `ModelTests` wireHistory round-trip, dismissed synthesis,
`completeToolCallMessage`, app-tool schema encoding (`tools` array carries the
full `ask_user` parameters; app tools offered when server tools disabled).

---

## 6. What to do on the Mac

```sh
cd ios
xcodegen generate                                        # picks up new files
swift test --package-path Packages/PhantasmKit           # PhantasmKit logic tests
xcodebuild -project Phantasm.xcodeproj -scheme Phantasm \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Fix any compile errors (see §7 for the spots I'm least sure about), then re-run.
Also re-confirm the orchestrator if you touch it:
```sh
cd orchestrator && cargo test && cargo clippy --all-targets && cargo fmt --all --check
```

### End-to-end verification
1. Run the orchestrator against Ollama with a tool-capable model:
   `PHANTASM_AUTH_TOKEN=dev cargo run` (no special env needed — the **app**
   supplies the `ask_user` schema).
2. In the app, prompt something that invites a choice, e.g. *"Help me pick a
   database — ask me what I need first."*
3. Confirm:
   - buttons render above the composer;
   - single-tap sends immediately and the model continues;
   - a multi-select question shows toggles + Send and joins picks with `", "`;
   - free-typing in the composer answers and continues (no orphaned tool call);
   - the prompt hides once answered;
   - force-quit + relaunch mid-prompt restores the prompt;
   - a `git`-clean run with web-search OFF still offers `ask_user`.

---

## 7. Things to watch when compiling iOS (my best guesses at risk)

- **`WireMessage` optional fields:** I rely on Swift auto-initializing optional
  stored properties to `nil`, and on synthesized `Codable` using `encodeIfPresent`
  for optionals (so plain messages stay byte-for-byte standard, no
  `tool_calls`/`null` keys). If a plain-chat encoding test regresses, check this.
- **`JSONValue` snake_case:** the schema is encoded through `Wire.encoder()`
  (`convertToSnakeCase`). All schema keys are already lowercase/underscored
  (`allow_multiple`), so they pass through unchanged — don't rename them to
  camelCase or they'll be mangled.
- **GRDB + new columns:** `Message`'s new columns match property names exactly;
  migration `v6_client_tools` adds them. The FTS5 `message_ft` sync only touches
  `content`, so the new columns don't affect it.
- **`ChoicePromptView` selection state:** `.id(choice.toolCallId)` resets the
  multi-select `@State` per distinct prompt.
- **xcodegen:** the `.xcodeproj` is generated/git-ignored — you MUST run
  `xcodegen generate` after pulling, or the new `ChoicePromptView.swift` won't be
  in the target.

---

## 8. Behavioral notes / decisions to confirm with the user

- **App tools are independent of the per-chat server-tool toggles.** `ask_user`
  is offered whenever you're on an orchestrator with a tool-capable model, even
  if web-search/image-gen are toggled off. This matches "the app hosts it." Flag
  if the user wants a separate toggle.
- **Mixed calls:** if the model calls a server tool AND an app tool in one
  message, only the app tool is forwarded; the server call is dropped and the
  model re-issues it next turn.
- **Raw-Ollama / plain-OpenAI backends:** app tools are only sent to a full
  orchestrator (`capabilities != nil`), since a raw backend has nothing to
  forward through.
- **Tap = send immediately; multi-select supported; free-typing always allowed;
  answered prompts hide** — these were the user's explicit choices.
