# Phantasm Orchestrator

An OpenAI-compatible orchestration proxy for self-hosted AI. It sits between a
thin chat client (the Phantasm iOS app, or any OpenAI client) and your own
[Ollama](https://ollama.com) + [ComfyUI](https://github.com/comfyanonymous/ComfyUI),
adding **read-only tools**, **web search**, and **image/audio/video generation** via a
server-side tool loop that is *invisible to the client*.

The client only ever speaks plain OpenAI SSE, so it can point at this
orchestrator, a bare Ollama instance, or OpenAI itself — unchanged.

## How it works

```
iOS app ──OpenAI SSE──▶ orchestrator ──native /api/chat──▶ Ollama
                             │      └─or OpenAI-compatible /v1
                             │
                             ├── Brave Search / web fetch / APIs
                             ├── local utility tools (time, calculator, units)
                             ├── tesseract OCR (temp-file handoff only)
                             └── ComfyUI       (image / edit / audio / video)
```

- **Plain turns** are a near-passthrough: one upstream streaming chat call,
  transcoded chunk-for-chunk to OpenAI SSE.
- **Tool turns** run the standard function-calling loop *upstream* (orchestrator
  ↔ Ollama). The client only sees the final streamed answer, plus optional
  progress on the additive `x_status` SSE field.
- Generated **images** are embedded as data-URI markdown by default, or as
  signed `/v1/files/{id}/content` links when URL delivery is configured.
- **Tool privacy boundary:** tools do not persist conversation content, fetched
  pages, tool outputs, attachments, or intermediate data to durable local
  storage. The only cache is in-memory and scoped to one turn. When a backend
  needs file-backed handoff (for example ComfyUI image editing), Phantasm uses
  temp/scratch paths rather than durable input/output libraries. The
  orchestrator does not provide local filesystem search/read/write or local-docs
  indexing tools.

> **Upstream detection.** At startup the orchestrator probes `OLLAMA_BASE_URL`.
> If `/api/tags` is present, it uses native Ollama `/api/chat`; otherwise, if
> `/v1/models` is present, it uses an OpenAI-compatible upstream. Set
> `UPSTREAM_API_KEY` when that upstream needs bearer auth.

## Endpoints

| Method | Path                    | Purpose                                  |
|--------|-------------------------|------------------------------------------|
| `GET`  | `/healthz`              | Auth-exempt process liveness check       |
| `GET`  | `/v1/capabilities`      | Advertise models + which tools are live  |
| `POST` | `/v1/chat/completions`  | OpenAI-compatible chat (SSE or JSON)      |

All `/v1/*` routes require `Authorization: Bearer <PHANTASM_AUTH_TOKEN>`
except signed image fetches at `/v1/files/{id}/content`.

## Run

### Docker (recommended)

```sh
cp .env.example .env          # set PHANTASM_AUTH_TOKEN (required)
docker compose up             # builds + starts on :8080
```

If Ollama/ComfyUI run on the host, the compose file points the container at
`host.docker.internal` by default. The container runs as uid/gid 10001 and the
compose file persists `/var/lib/phantasm` in the `phantasm-data` volume. Put
`IMAGE_STORE_DIR=/var/lib/phantasm/images` there when enabling URL image
delivery.

### Cargo (local dev)

```sh
PHANTASM_AUTH_TOKEN=dev-secret OLLAMA_BASE_URL=http://localhost:11434 \
  cargo run
```

Enable tools with the env toggles in `.env.example`. The read-only first-party
tools are `TOOL_WEB_FETCH`, `TOOL_CURRENT_TIME`, `TOOL_CALCULATOR`,
`TOOL_UNIT_CONVERT`, `TOOL_WEATHER`, `TOOL_MAPS_PLACES`, `TOOL_MARKET_DATA`,
`TOOL_GITHUB`, and `TOOL_OCR`; key-backed tools also need their API key. Brave
search still uses `TOOL_WEB_SEARCH` + `BRAVE_API_KEY`; image tools use
`TOOL_IMAGE_GEN` / `TOOL_IMAGE_EDIT` plus their ComfyUI workflow config.
`TOOL_AUDIO_GEN` adds fixed-workflow audio generation. It uses the configured
prompt/output and optional negative/lyrics/duration/seed node bindings, and
requires `IMAGE_STORE_DIR` plus `PUBLIC_BASE_URL` for compact signed artifact
delivery. The model never authors
or submits ComfyUI graphs. Any model and API-format workflow can be used by
setting `COMFYUI_AUDIO_WORKFLOW` and its input/output node mappings.
`TOOL_VIDEO_GEN` follows the same fixed-workflow contract with prompt/output
bindings and optional negative/size/frame-rate/frame-count/seed mappings. The
selected output may come from any ComfyUI node that reports one retrievable file
artifact; VideoHelperSuite's Video Combine node is forced to temporary output.
Thorough (full-page-fetch) search: set `SEARCH_FETCH_PAGES=true`; the model then
opts into `depth="thorough"` per query, leaving simple lookups snippet-fast.

### systemd (bare metal)

For a non-Docker host, [`deploy/phantasm-orchestrator.service`](deploy/phantasm-orchestrator.service)
is a `Type=notify` unit that also supports rootless Podman for `code_exec` and
drains in-flight turns on stop. Its `YOURUSER`/`YOURUID` placeholders are
intentionally invalid; build the binary, then follow the complete install header
in the unit to choose a real login user, configure lingering, and install it:

```sh
cargo build --release
sudo install -m 0755 target/release/phantasm-orchestrator /usr/local/bin/
# Continue with steps 0–5 at the top of deploy/phantasm-orchestrator.service.
```

The orchestrator emits `READY=1` once it's listening, so `systemctl start`
blocks until the endpoint is actually up. `.env.example` is already in the
`KEY=value` format systemd's `EnvironmentFile` expects.

## Configuration

Everything is environment-driven — see [`.env.example`](.env.example) for the
full annotated list.

## Tests

```sh
cargo test                    # unit + integration, no real backends needed
cargo clippy --all-targets    # lints
```

Unit tests cover the tool loop (scripted backend), SSE chunk shapes, and tool
formatting. Integration tests run the real router in front of a mock Ollama and
assert the end-to-end SSE stream, the non-streaming completion, and auth.

## Verifying against real backends (on your LAN)

The automated tests use mocks. To confirm against the real thing:

1. **Start it.** `docker compose up` with a valid `.env`.
2. **Capabilities.**
   ```sh
   curl -s localhost:8080/v1/capabilities -H "Authorization: Bearer $TOKEN" | jq
   ```
   Expect your models listed and `tools.web_search` / `tools.image_generation`
   reflecting what you enabled and what's reachable.
3. **Plain chat.**
   ```sh
   curl -N localhost:8080/v1/chat/completions -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     -d '{"model":"llama3.1","stream":true,"messages":[{"role":"user","content":"hi"}]}'
   ```
   Expect `data:` chunks with content deltas, then `data: [DONE]`.
4. **Search turn** (with `TOOL_WEB_SEARCH=true` + key): ask something current.
   Expect an `x_status:"searching the web…"` chunk, then a fast answer (~1–2s to
   first token).
5. **Image turn** (with `TOOL_IMAGE_GEN=true` + workflow): ask for an image.
   Expect `x_status:"generating image…"` plus `x_progress` updates, then a `data:` image URI
   embedded in the final markdown answer.
6. **Cancellation.** Kill the curl mid-stream; the orchestrator logs the turn
   finishing and stops upstream work.
7. **Auth.** A request without the bearer token returns `401`.
