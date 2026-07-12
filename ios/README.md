# Phantasm iOS

A fast, thin AI chat client (SwiftUI, iOS 18+). It speaks OpenAI-compatible
streaming for the [Phantasm orchestrator](../orchestrator) and generic backends,
and uses Ollama's native `/api/chat` stream when it detects a bare Ollama
instance. It can also detect a Maple/OpenSecret enclave and wrap the same
OpenAI-compatible traffic in that service's encrypted session protocol. Tools
(web search, image generation) run server-side and are invisible
to the app — it just renders the streamed answer, displays images embedded as
markdown, and reads the optional `x_status` field for progress.

## Architecture

- **`Packages/PhantasmKit/`** — pure, host-testable logic: the SSE parser +
  streaming `ChatClient`, native Ollama chat adapter, capability detection,
  Maple encrypted HTTP adapter, `AppError` taxonomy, Keychain token storage,
  GRDB models, profile store,
  and the base64-image markdown extractor.
- **App target** (`App/`, `Views/`, `ViewModels/`) — SwiftUI with `@Observable`
  MVVM. Uses MarkdownUI for rendering, GRDB/GRDBQuery for SQLite persistence,
  and ollama-swift for bare-Ollama transport.

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
app probes `/v1/capabilities`; if absent it checks `/api/tags` for native
Ollama, then falls back to generic OpenAI-compatible `/v1/models`. If those
ordinary probes fail, it tries Maple's key exchange and repeats model discovery
through the encrypted transport. No Maple-specific profile setting is needed.

## Tests

```sh
swift test --package-path Packages/PhantasmKit
```

More than 280 host and app tests cover streaming, capability degradation, error
mapping, markdown/image handling, tools, and GRDB persistence on an in-memory
store.

## Key behaviors

- **Streaming** over `URLSession.bytes` → typed `ChatStreamEvent`s. Stop button
  cancels the consuming `Task`, which aborts the SSE connection (FR-A9).
- **Maple encryption** below the OpenAI client: X25519 establishes a session;
  ChaCha20-Poly1305 encrypts JSON bodies and decrypts JSON/SSE envelopes. The
  decrypted SSE is handed to the same parser used by every compatible backend.
- **Buffer-then-commit** persistence: tokens accumulate in memory during a turn;
  one complete assistant message is written on completion (no per-token disk
  writes, NFR-A4).
- **Graceful degradation**: no manifest → native Ollama or plain chat, tool
  affordances hidden (XR-1). A status pill shows "Full", "Ollama native", or
  "Plain chat".
- **Token** stored in the Keychain, keyed by profile id (NFR-A2); profile
  metadata (URL, name, model) in `UserDefaults`.
- **Markdown** via MarkdownUI with a custom image provider that resolves base64
  data-URIs (extracted to `phantasm-img://` placeholders) and a code-block style
  with a copy button. Trusted signed video artifacts from advanced ComfyUI
  workflows render with native playback controls.

## Notes

- Built in Swift 5 language mode for SwiftUI ergonomics; the networking code is
  written `async`/`await` + `Sendable`-clean.
- Maple's attestation document is currently parsed only to obtain its X25519
  key and bind the nonce. Certificate, signature, and PCR verification are not
  implemented yet, so encryption must not be described as authenticated
  attestation until that follow-up lands.
- The app deployment target is iOS 18. Multiple-backend profiles are supported.
