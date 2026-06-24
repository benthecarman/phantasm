# CLAUDE.md

Guidance for working in this repo. Phantasm is a self-hostable AI chat product:
a thin OpenAI-compatible **iOS app** plus an optional **orchestration server**
that adds web search + image generation via a server-side tool loop that is
invisible to the app.

See [`docs/SPEC.md`](docs/SPEC.md) for the full requirements + interface
contract. The contract (§2) is the boundary that lets the two halves evolve
independently — change it deliberately, on both sides.

## Layout

| Path             | What                                                           |
|------------------|---------------------------------------------------------------|
| `orchestrator/`  | Rust/Axum server. Co-locates with Ollama + ComfyUI.           |
| `ios/`           | SwiftUI client. `xcodegen` project + `PhantasmKit` SPM package.|
| `docs/SPEC.md`   | Requirements + interface contract (v0.1 MVP).                 |

## Build & test

**Orchestrator** (`cd orchestrator`):
```sh
cargo test                      # 14 unit + 4 integration (mock Ollama, no real backends)
cargo clippy --all-targets      # keep clean — CI-equivalent gate
cargo fmt                       # before committing
cargo build --features page_fetch   # the one optional feature must also build
PHANTASM_AUTH_TOKEN=dev cargo run    # local run (needs Ollama at OLLAMA_BASE_URL)
```

**iOS** (`cd ios`):
```sh
swift test --package-path Packages/PhantasmKit          # 15 host-testable logic tests
xcodegen generate                                        # regenerate after editing project.yml or adding files
xcodebuild -project Phantasm.xcodeproj -scheme Phantasm \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```
After adding/removing source files you **must** re-run `xcodegen generate` (the
`.xcodeproj` is generated and git-ignored). Sources are globbed from `App/`,
`Views/`, `ViewModels/`.

## Architecture — things that aren't obvious from the code

- **Upstream Ollama uses the native `/api/chat` (NDJSON), not the OpenAI-compat
  endpoint.** The OpenAI-compat one silently drops `tool_calls` when streaming.
  The orchestrator still presents OpenAI *downstream* to the app.
- **Two-phase turn** (`orchestrator/src/orchestrator/turn.rs`): tool resolution
  runs non-streaming `chat_once` in a loop (capped at `MAX_TOOL_ITERS`); once the
  model stops calling tools, the final answer is re-issued as a streaming call.
  Plain turns (no tools) skip straight to streaming — the low-overhead path.
- **Tools are invisible to the app.** It's a plain OpenAI SSE client. Progress
  rides the additive `x_status` SSE field; generated images are embedded as
  base64-data-URI markdown in the assistant message. Any new custom SSE field
  must be `x_`-prefixed so standard clients ignore it.
- **Stateless server, stateful client** (XR-2): the app sends full history each
  turn; the orchestrator holds no session state.
- **Tool failures are non-fatal** (NFR-O6): each tool folds its own error into
  the `tool`-role message it returns, so the model continues. Don't propagate
  tool errors up as fatal.
- **Cancellation**: a `CancellationToken` per turn, fired by an SSE drop-guard
  when the client disconnects; every Ollama/tool await is `select!`ed on it.
- **iOS persistence is buffer-then-commit**: tokens accumulate in the view model
  during a turn; one complete `Message` is written on completion (no per-token
  SwiftData writes — that would jank scrolling).

## Conventions

- The orchestrator is generic over a `ChatBackend` trait + `ToolExecutor` trait
  so the turn loop is unit-tested with scripted in-memory impls (no network).
  Add backend/tool behavior behind these, not inline in routes.
- Config is **only** via env vars (`orchestrator/.env.example` is the source of
  truth). No hardcoded endpoints.
- `PhantasmKit` is pure logic (no SwiftUI/UIKit) so it tests on the host via
  `swift test`. Keep view code in the app target. The package is built in Swift 5
  language mode; the app target too (SwiftUI ergonomics) — code is async/Sendable
  clean regardless.
- Never log message content by default (NFR-O7); it's gated behind
  `LOG_MESSAGE_CONTENT`.

## Out of scope (deferred premium layer)

Accounts, billing, cloud sync, and managed remote-access relay are intentionally
not here (SPEC §7). The user reaches their own backend themselves.
