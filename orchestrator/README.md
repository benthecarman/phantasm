# Phantasm Orchestrator

An OpenAI-compatible orchestration proxy for self-hosted AI. It sits between a
thin chat client (the Phantasm iOS app, or any OpenAI client) and your own
[Ollama](https://ollama.com) + [ComfyUI](https://github.com/comfyanonymous/ComfyUI),
adding **read-only tools**, **web search**, and **image generation** via a
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
                             └── ComfyUI       (image_generation / image_edit)
```

- **Plain turns** are a near-passthrough: one upstream streaming chat call,
  transcoded chunk-for-chunk to OpenAI SSE.
- **Tool turns** run the standard function-calling loop *upstream* (orchestrator
  ↔ Ollama). The client only sees the final streamed answer, plus optional
  progress on the additive `x_status` SSE field.
- Generated **images** are embedded in the answer as markdown
  `![generated](data:image/png;base64,…)`.
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
| `GET`  | `/v1/capabilities`      | Advertise models + which tools are live  |
| `POST` | `/v1/chat/completions`  | OpenAI-compatible chat (SSE or JSON)      |

All routes require `Authorization: Bearer <PHANTASM_AUTH_TOKEN>`.

## Run

### Docker (recommended)

```sh
cp .env.example .env          # set PHANTASM_AUTH_TOKEN (required)
docker compose up             # builds + starts on :8080
```

If Ollama/ComfyUI run on the host, the compose file points the container at
`host.docker.internal` by default.

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
Thorough (full-page-fetch) search: set `SEARCH_FETCH_PAGES=true`; the model then
opts into `depth="thorough"` per query, leaving simple lookups snippet-fast.

### systemd (bare metal)

For a non-Docker host, [`deploy/phantasm-orchestrator.service`](deploy/phantasm-orchestrator.service)
is a hardened `Type=notify` unit (sandboxed, runs as a dedicated `phantasm`
user, drains in-flight turns on stop). Build, then follow the install header in
the file:

```sh
cargo build --release
sudo useradd --system --no-create-home --shell /usr/sbin/nologin phantasm
sudo install -m 0755 target/release/phantasm-orchestrator /usr/local/bin/
sudo install -d -m 0755 /etc/phantasm
sudo cp .env.example /etc/phantasm/orchestrator.env   # then edit PHANTASM_AUTH_TOKEN
sudo chown root:phantasm /etc/phantasm/orchestrator.env && sudo chmod 0640 /etc/phantasm/orchestrator.env
sudo cp deploy/phantasm-orchestrator.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now phantasm-orchestrator
journalctl -u phantasm-orchestrator -f
```

The orchestrator emits `READY=1` once it's listening, so `systemctl start`
blocks until the endpoint is actually up. `.env.example` is already in the
`KEY=value` format systemd's `EnvironmentFile` expects.

## Configuration

Everything is environment-driven — see [`.env.example`](.env.example) for the
full annotated list.

## Tests

```sh
cargo test                    # 20 unit + 6 integration, no real backends needed
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
