set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

_wait-url url timeout_seconds:
  #!/usr/bin/env bash
  set -euo pipefail
  deadline=$((SECONDS + {{timeout_seconds}}))
  until curl -fsS "{{url}}" >/dev/null; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for {{url}}" >&2
      exit 1
    fi
    sleep 2
  done

_real-upstream-test kind base model filter="real_upstream_":
  #!/usr/bin/env bash
  set -euo pipefail
  cd orchestrator
  PHANTASM_AUTH_TOKEN="${PHANTASM_AUTH_TOKEN:-dev}" \
  UPSTREAM_KIND="{{kind}}" \
  UPSTREAM_BASE_URL="{{base}}" \
  UPSTREAM_DEFAULT_MODEL="{{model}}" \
  cargo test --test real_upstreams "{{filter}}" -- --ignored --nocapture

ollama-test:
  #!/usr/bin/env bash
  set -euo pipefail
  command -v ollama >/dev/null || { echo "ollama CLI not found" >&2; exit 1; }
  command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
  base="${OLLAMA_TEST_BASE:-http://127.0.0.1:11434}"
  model="${OLLAMA_TEST_MODEL:-qwen3:1.7b}"
  started_pid=""
  if ! curl -fsS "$base/api/tags" >/dev/null; then
    ollama serve &
    started_pid=$!
    trap 'if [[ -n "$started_pid" ]]; then kill "$started_pid" 2>/dev/null || true; fi' EXIT
  fi
  just _wait-url "$base/api/tags" 120
  ollama pull "$model"
  REAL_UPSTREAM_TEST_THINKING=1 REAL_UPSTREAM_TEST_TOOLS=1 just _real-upstream-test ollama "$base" "$model"

llama-cpp-test:
  #!/usr/bin/env bash
  set -euo pipefail
  command -v llama-server >/dev/null || { echo "llama-server not found" >&2; exit 1; }
  command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
  command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
  base="${LLAMA_CPP_TEST_BASE:-http://127.0.0.1:8080}"
  port="${LLAMA_CPP_TEST_PORT:-8080}"
  model_path="${LLAMA_CPP_TEST_MODEL:-/usr/share/ollama/.ollama/models/blobs/sha256-3d0b790534fe4b79525fc3692950408dca41171676ed7e21db57af5c65ef6ab6}"
  if [[ ! -f "$model_path" ]]; then
    echo "llama.cpp model file not found: $model_path" >&2
    echo "Set LLAMA_CPP_TEST_MODEL=/path/to/model.gguf to override." >&2
    exit 1
  fi
  echo "Using llama.cpp model: $model_path"
  started_pid=""
  if ! curl -fsS "$base/v1/models" >/dev/null; then
    llama-server \
      -m "$model_path" \
      --host 127.0.0.1 \
      --port "$port" \
      --jinja \
      -ngl 999 \
      ${LLAMA_CPP_TEST_ARGS:-} &
    started_pid=$!
    trap 'if [[ -n "$started_pid" ]]; then kill "$started_pid" 2>/dev/null || true; fi' EXIT
  fi
  just _wait-url "$base/v1/models" 300
  model_id=$(curl -fsS "$base/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
  REAL_UPSTREAM_TEST_THINKING=1 REAL_UPSTREAM_TEST_TOOLS=1 just _real-upstream-test llama_cpp "$base" "$model_id"

vllm-test:
  #!/usr/bin/env bash
  set -euo pipefail
  command -v vllm >/dev/null || { echo "vllm not found" >&2; exit 1; }
  command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
  base="${VLLM_TEST_BASE:-http://127.0.0.1:8000}"
  port="${VLLM_TEST_PORT:-8000}"
  model="${VLLM_TEST_MODEL:-Qwen/Qwen3-1.7B}"
  started_pid=""

  cleanup() {
    if [[ -n "$started_pid" ]]; then
      kill "$started_pid" 2>/dev/null || true
      wait "$started_pid" 2>/dev/null || true
      started_pid=""
    fi
  }
  trap cleanup EXIT

  wait_ready() {
    local deadline=$((SECONDS + 900))
    until curl -fsS "$base/v1/models" >/dev/null; do
      if ! kill -0 "$started_pid" 2>/dev/null; then
        echo "vLLM exited before becoming ready" >&2
        wait "$started_pid" || true
        exit 1
      fi
      if (( SECONDS >= deadline )); then
        echo "Timed out waiting for $base/v1/models" >&2
        exit 1
      fi
      sleep 2
    done
  }

  start_vllm() {
    local usage_flag="$1"
    echo "Starting vLLM with $usage_flag"
    VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}" \
    vllm serve "$model" \
      --host 127.0.0.1 \
      --port "$port" \
      --max-model-len "${VLLM_MAX_MODEL_LEN:-4096}" \
      --enforce-eager \
      --gpu-memory-utilization "${VLLM_GPU_MEMORY_UTILIZATION:-0.60}" \
      --enable-auto-tool-choice \
      --tool-call-parser "${VLLM_TOOL_CALL_PARSER:-qwen3_xml}" \
      ${VLLM_TEST_ARGS:-} \
      "$usage_flag" &
    started_pid=$!
    wait_ready
  }

  stop_vllm() {
    cleanup
    local deadline=$((SECONDS + 60))
    while curl -fsS "$base/v1/models" >/dev/null 2>&1; do
      if (( SECONDS >= deadline )); then
        echo "Timed out waiting for vLLM to release $base" >&2
        exit 1
      fi
      sleep 1
    done
  }

  if curl -fsS "$base/v1/models" >/dev/null 2>&1; then
    echo "vllm-test needs an unused endpoint so it can restart vLLM in both usage modes: $base" >&2
    echo "Stop the existing server or choose free VLLM_TEST_BASE/VLLM_TEST_PORT values." >&2
    exit 1
  fi

  start_vllm --no-enable-force-include-usage
  REAL_VLLM_EXPECT_CONTINUOUS_USAGE=0 \
    REAL_UPSTREAM_TEST_THINKING=1 \
    REAL_UPSTREAM_TEST_TOOLS=1 \
    just _real-upstream-test vllm "$base" "$model"
  stop_vllm

  start_vllm --enable-force-include-usage
  REAL_VLLM_EXPECT_CONTINUOUS_USAGE=1 \
    just _real-upstream-test vllm "$base" "$model" real_upstream_vllm_server_usage_mode

comfy-test env_file="/etc/phantasm/orchestrator.env":
  #!/usr/bin/env bash
  set -euo pipefail
  command -v curl >/dev/null || { echo "curl not found" >&2; exit 1; }
  env_file="{{env_file}}"
  if [[ ! -f "$env_file" ]]; then
    echo "ComfyUI env file not found: $env_file" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
  base="${COMFYUI_BASE_URL:-http://127.0.0.1:8188}"
  curl -fsS --max-time 10 "$base/system_stats" >/dev/null
  cd orchestrator
  cargo test --test real_comfy -- --ignored --nocapture
