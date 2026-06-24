# Phantasm iOS

A fast, thin AI chat client (SwiftUI, iOS 17+). It speaks OpenAI-compatible
streaming, so it works against the [Phantasm orchestrator](../orchestrator) *or*
a bare Ollama instance. Tools (web search, image generation) run server-side and
are invisible to the app — it just renders the streamed answer, displays images
embedded as markdown, and reads the optional `x_status` field for progress.

## Architecture

- **`Packages/PhantasmKit/`** — pure, host-testable logic: the SSE parser +
  streaming `ChatClient`, capability detection, `AppError` taxonomy, Keychain
  token storage, SwiftData models, profile store, and the base64-image markdown
  extractor.
- **App target** (`App/`, `Views/`, `ViewModels/`) — SwiftUI with `@Observable`
  MVVM. Depends on `PhantasmKit` and [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui)
  (the only third-party dependency).

The project is generated from [`project.yml`](project.yml) with
[`xcodegen`](https://github.com/yonaskolb/XcodeGen) so the repo stays free of a
churning `.pbxproj`.

## Build & run

```sh
cd ios
xcodegen generate
xcodebuild -project Phantasm.xcodeproj -scheme Phantasm \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# or open and run from Xcode:
open Phantasm.xcodeproj
```

On first launch, open **Settings** (gear icon) → **Add Backend**, enter your
orchestrator (or Ollama) URL + bearer token, and tap **Test Connection**. The
app probes `/v1/capabilities`; if absent it falls back to a chat ping and runs
in plain-chat mode.

## Tests

```sh
swift test --package-path Packages/PhantasmKit
```

15 unit tests cover the SSE line classifier + event stream (fixture-driven, no
network), capability decoding + degradation, the error taxonomy, the base64
image extractor, and SwiftData persistence (cascade delete, buffer-then-commit)
on an in-memory store.

## Key behaviors

- **Streaming** over `URLSession.bytes` → typed `ChatStreamEvent`s. Stop button
  cancels the consuming `Task`, which aborts the SSE connection (FR-A9).
- **Buffer-then-commit** persistence: tokens accumulate in memory during a turn;
  one complete assistant message is written on completion (no per-token disk
  writes, NFR-A4).
- **Graceful degradation**: no manifest → plain chat, tool affordances hidden
  (XR-1). A status pill shows "Full" vs "Plain chat".
- **Token** stored in the Keychain, keyed by profile id (NFR-A2); profile
  metadata (URL, name, model) in `UserDefaults`.
- **Markdown** via MarkdownUI with a custom image provider that resolves base64
  data-URIs (extracted to `phantasm-img://` placeholders) and a code-block style
  with a copy button.

## Notes

- Built in Swift 5 language mode for SwiftUI ergonomics; the networking code is
  written `async`/`await` + `Sendable`-clean.
- Only the iOS 26.2 simulator runtime may be installed locally; the deployment
  target is 17.0 and runs there. Multiple-backend profiles are supported.
