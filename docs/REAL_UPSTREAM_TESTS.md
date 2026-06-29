# Real Upstream Smoke Tests

These tests are for local development, not CI. The root `justfile` can start a
real model host locally, then run the orchestrator in-process against it.

Each backend command runs the full real-upstream suite:

- `/v1/models` through the orchestrator
- `/v1/capabilities` through the orchestrator
- non-streaming `/v1/chat/completions`
- streaming `/v1/chat/completions` with a `[DONE]` sentinel
- streamed thinking via `delta.reasoning_content`, and suppression with
  `reasoning_effort: "none"`
- real model tool calling through the server-side current-time tool

For OpenAI-compatible hosts, the orchestrator forwards `reasoning_effort` and
also sends the Qwen-style `chat_template_kwargs.enable_thinking` hint so
llama.cpp/vLLM templates can disable thinking per request.

The tool-calling smoke test requires actual server-side time-tool execution. It
asks for the current server Unix timestamp so the model cannot satisfy the turn
from static model knowledge, and it sends standard `tool_choice: "required"`
with only the `time` tool offered so vLLM cannot silently choose a text-only
answer.

Ollama also checks clean `upstream_error` mapping for a bogus model id. llama.cpp
and vLLM can legally ignore the requested model id and serve the loaded model,
so that assertion self-skips for those backends unless
`REAL_UPSTREAM_EXPECT_BAD_MODEL_ERROR=1` is set.

## Just Commands

Run from the repo root:

```sh
just ollama-test
just llama-cpp-test
just vllm-test
```

Each command reuses an already-running backend if its port responds. Otherwise
it starts the backend, waits for readiness, runs the ignored smoke test, and
stops only the process it started.

## Ollama

Default:

```sh
just ollama-test
```

Overrides:

```sh
OLLAMA_TEST_MODEL=qwen3:1.7b just ollama-test
OLLAMA_TEST_BASE=http://127.0.0.1:11434 just ollama-test
```

The recipe runs `ollama pull` for the selected model.

## llama.cpp

Default, using the local Ollama `qwen3:1.7b` model blob:

```sh
just llama-cpp-test
```

Overrides:

```sh
LLAMA_CPP_TEST_MODEL=/path/to/model.gguf just llama-cpp-test

LLAMA_CPP_TEST_BASE=http://127.0.0.1:8081 \
LLAMA_CPP_TEST_PORT=8081 \
LLAMA_CPP_TEST_MODEL=/path/to/model.gguf \
just llama-cpp-test

LLAMA_CPP_TEST_ARGS="--ctx-size 4096" \
LLAMA_CPP_TEST_MODEL=/path/to/model.gguf \
just llama-cpp-test
```

The default model path is:

```sh
/usr/share/ollama/.ollama/models/blobs/sha256-3d0b790534fe4b79525fc3692950408dca41171676ed7e21db57af5c65ef6ab6
```

The recipe starts `llama-server` with `--jinja -ngl 999`, then reads the model
id from `/v1/models`.

## vLLM

Default:

```sh
just vllm-test
```

Overrides:

```sh
VLLM_TEST_MODEL=Qwen/Qwen3-1.7B just vllm-test

VLLM_GPU_MEMORY_UTILIZATION=0.75 just vllm-test

VLLM_MAX_MODEL_LEN=8192 just vllm-test

VLLM_TOOL_CALL_PARSER=qwen3_xml just vllm-test

VLLM_TEST_ARGS="--generation-config vllm" just vllm-test
```

The recipe starts:

```sh
VLLM_USE_FLASHINFER_SAMPLER=0 vllm serve Qwen/Qwen3-1.7B
```

with `--max-model-len 4096`, `--enforce-eager`, `--gpu-memory-utilization
0.60`, `--enable-auto-tool-choice`, and `--tool-call-parser qwen3_xml` unless
overridden. These defaults keep startup reliable on local 16GB GPUs and make the
tool-calling smoke test meaningful.

## Raw Cargo Command

If you start the backend yourself, run from `orchestrator/`:

```sh
PHANTASM_AUTH_TOKEN=dev \
UPSTREAM_KIND=ollama \
UPSTREAM_BASE_URL=http://localhost:11434 \
UPSTREAM_DEFAULT_MODEL=qwen3:1.7b \
cargo test --test real_upstreams -- --ignored --nocapture
```

To run only one real test manually:

```sh
REAL_UPSTREAM_TEST_THINKING=1 cargo test --test real_upstreams real_upstream_thinking_streams_reasoning -- --ignored --nocapture
REAL_UPSTREAM_TEST_TOOLS=1 cargo test --test real_upstreams real_upstream_model_can_call_time_tool -- --ignored --nocapture
```

## Notes

- The test timeout is intentionally generous because local model first-token
  latency can vary a lot.
- Prefer small models for this smoke test. It verifies the adapter path, not
  model quality.
- Keep the normal mock-backed integration tests as CI gates; these real-upstream
  tests are for local confidence before changing backend protocol code.
