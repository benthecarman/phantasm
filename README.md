# Phantasm

A fast, self-hostable AI chat app for iOS that talks to a backend **you**
control. The app is a thin OpenAI-compatible client; an optional orchestration
server adds web search and image generation on top of plain inference. Both run
on your own hardware.

## Components

| Directory                      | What it is                                                                 |
|--------------------------------|----------------------------------------------------------------------------|
| [`orchestrator/`](orchestrator) | Rust/Axum server. Co-locates with Ollama + ComfyUI, runs the server-side tool loop, exposes one OpenAI-compatible endpoint. |
| [`ios/`](ios)                   | SwiftUI chat client. Configurable endpoint + token; speaks OpenAI SSE so it works against the orchestrator *or* a bare Ollama. |
| [`docs/SPEC.md`](docs/SPEC.md)  | The interface contract and requirements (v0.1 MVP).                        |

## Design principles

1. **The app never knows how the backend is hosted** — it takes a URL and a token.
2. **Baseline is OpenAI-compatible.** Tools are an extension, feature-detected
   at runtime via `/v1/capabilities`.
3. **The orchestrator owns all complexity** — ComfyUI handshakes, search, and the
   tool loop live server-side, co-located with the heavy services.
4. **One app binary, many backend configs.**

## Quick start

1. **Backend:** see [`orchestrator/README.md`](orchestrator/README.md) —
   `cp .env.example .env && docker compose up`.
2. **App:** open [`ios/`](ios) (`cd ios && xcodegen generate && open Phantasm.xcodeproj`),
   point Settings at your orchestrator URL + token.

You can also point the app straight at a bare Ollama instance — it degrades to
plain chat with no tool affordances.

## Status

MVP build. The orchestrator is feature-complete (chat passthrough, tool loop,
Brave web search, ComfyUI image gen, cancellation) with unit + integration
tests. The iOS app covers the plain-chat foundation plus capability detection,
markdown/image rendering, and `x_status` progress.

Out of scope for MVP (deferred premium layer): user accounts, billing, cloud
sync, and managed remote-access relay. You reach your own backend yourself
(home wifi, VPN/Tailscale, or your own tunnel).
