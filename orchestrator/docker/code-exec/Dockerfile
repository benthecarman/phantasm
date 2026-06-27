# Universal sandbox image for the orchestrator's `code_exec` tool.
#
# It bundles the interpreted-language runtimes plus a single dispatcher
# (`run-code`) that reads source on stdin and runs it. The orchestrator keeps a
# pool of these idle (the ENTRYPOINT just sleeps) and `exec`s `run-code <lang>`
# into one per execution, then destroys it.
#
# Hardening (resource caps, read-only rootfs, dropped caps, no-new-privileges,
# non-root user, network policy) is applied by the orchestrator via `run` flags —
# NOT baked here — so it stays configurable per deployment. This image only needs
# the runtimes and the dispatcher.
#
# Build (tag must match CODE_EXEC_IMAGE):
#   podman build -t phantasm/code-exec:latest docker/code-exec
#   # or: docker build -t phantasm/code-exec:latest docker/code-exec
FROM debian:stable-slim

# Interpreted runtimes for v1. Add languages here (and to CODE_EXEC_LANGUAGES +
# the run-code dispatcher) to support more. ca-certificates lets code make TLS
# requests over the (egress-filtered) network.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        nodejs \
        ruby \
        bash \
        coreutils \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY run-code /usr/local/bin/run-code
RUN chmod +x /usr/local/bin/run-code

# The orchestrator also passes `--user`; bake a non-root default as defense in depth.
USER 65534:65534

# Pooled containers idle here; the orchestrator `exec`s run-code into them.
ENTRYPOINT ["sleep", "infinity"]
