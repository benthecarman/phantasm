# Running multiple upstream model hosts

One orchestrator can front several model backends at once — for example,
Ollama for a rotating cast of small models plus a vLLM instance pinned to one
big model. The app is unaffected: it still sees a single OpenAI-compatible
server whose model list is the union of everything the upstreams serve, and
each chat is routed to the right backend by the model id it asks for.

If you only run one backend, you can stop reading — the flat `UPSTREAM_*` vars
work exactly as they always have.

## Quick start

The flat `UPSTREAM_*` vars define your **default** upstream. To add more,
declare their names in `UPSTREAMS` and configure each one with
`UPSTREAM_<NAME>_*` vars (name uppercased, `-` becomes `_`):

```sh
# default upstream — unchanged from a single-upstream setup
UPSTREAM_BASE_URL=http://localhost:11434     # Ollama, auto-detected
UPSTREAM_DEFAULT_MODEL=llama3.1

# a second upstream named "vllm"
UPSTREAMS=vllm
UPSTREAM_VLLM_KIND=vllm
UPSTREAM_VLLM_BASE_URL=http://localhost:8000
UPSTREAM_VLLM_MODELS=qwen3-32b
UPSTREAM_VLLM_MAX_CONCURRENCY=2
```

Restart the orchestrator and you're done: the app's model picker shows
`llama3.1` (and anything else Ollama serves) alongside `qwen3-32b`, and
selecting `qwen3-32b` sends those turns to vLLM.

Add as many as you like — `UPSTREAMS=blah,custom,vllm` with
`UPSTREAM_BLAH_*`, `UPSTREAM_CUSTOM_*`, `UPSTREAM_VLLM_*` blocks.

## Per-upstream settings

Only `_BASE_URL` is required — a name declared in `UPSTREAMS` without it fails
startup loudly rather than silently dropping the backend.

| Var | Default | Meaning |
|-----|---------|---------|
| `UPSTREAM_<NAME>_BASE_URL` | *(required)* | Where the backend listens. |
| `UPSTREAM_<NAME>_KIND` | `auto` | `auto`, `ollama`, `vllm`, `llama_cpp`, `openai_compatible`. `auto` probes native Ollama first, then OpenAI `/v1`. Set it explicitly for non-Ollama hosts so a slow startup can't be mis-detected. |
| `UPSTREAM_<NAME>_MODELS` | *(probed)* | CSV pin of the models this upstream serves. Unset => probed from the backend (`/api/tags` or `/v1/models`). |
| `UPSTREAM_<NAME>_API_KEY` | *(none)* | Bearer token for OpenAI-compatible backends. |
| `UPSTREAM_<NAME>_MAX_CONCURRENCY` | global `UPSTREAM_MAX_CONCURRENCY` | Cap on simultaneous generations on this backend. |
| `UPSTREAM_<NAME>_THINKING_HINT` | `true` | Send the Qwen-style `enable_thinking` hint (OpenAI-compatible backends only). Set `false` for strict `/v1` servers. |
| `UPSTREAM_<NAME>_REASONING_EFFORTS` | *(none)* | CSV of reasoning effort values to advertise for this OpenAI-compatible upstream's models, e.g. `none,low,medium,high`. Rejected when the upstream kind is explicitly native Ollama. |

Two things change meaning slightly in multi-upstream mode:

- **`UPSTREAM_MODELS`** (the flat var) pins only the *default* upstream's
  list — use `UPSTREAM_<NAME>_MODELS` for the extras.
- **`UPSTREAM_MAX_CONCURRENCY`** is the *per-upstream default*, not a global
  total. Each upstream has its own limit, so a busy vLLM queue never blocks
  Ollama turns (they're different GPUs — that's the point).

## How routing works

- A request's model id is matched against each upstream's model list
  (pinned or probed) in order: **default upstream first, then `UPSTREAMS`
  order**. First match wins.
- A model no upstream claims falls back to the default upstream — so a typo'd
  model id produces a normal upstream error, and a single-upstream setup
  behaves exactly as before.
- If two upstreams serve the same model id, the earlier one always gets it.
  Pin lists (`_MODELS`) if you need to disambiguate.
- Probed model lists refresh on the same ~60s cycle as the app's capability
  refresh, so a freshly `ollama pull`ed model starts routing without a
  restart. If an upstream is temporarily unreachable, its last-known list is
  kept rather than dropping its models.
- Research modes (`…:deep-research`) route by the base model, as you'd expect.

## Verifying it works

- **Startup logs** print one line per backend —
  `upstream configured name=vllm kind=OpenAICompatible models=1 …` — and each
  turn logs which upstream served it (`turn started … upstream=vllm`).
- **`GET /v1/models`** (or the app's model picker) should show the union of
  all upstreams' models.
- If a model is missing or routes to the wrong place, check the startup log's
  per-upstream model counts first: `models=0` on an extra upstream means its
  probe failed (backend down, wrong `_BASE_URL`, or wrong `_KIND`) and nothing
  will route to it — pin `_MODELS` or fix the probe.

Implementation notes, if you're changing this code: routing lives in
`orchestrator/src/upstreams.rs`, config parsing in
`orchestrator/src/config.rs` (`UpstreamSpec`), and per-upstream detection +
the capabilities union in `orchestrator/src/lib.rs`.
