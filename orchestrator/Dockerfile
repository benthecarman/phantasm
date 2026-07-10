# ---- build stage ----
FROM rust:1.92-slim AS builder
WORKDIR /app

# Cache dependencies separately from source for faster rebuilds.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --locked --release --bin phantasm-orchestrator
RUN rm -rf src

COPY src ./src
COPY workflows ./workflows
# Touch main so cargo rebuilds with the real source.
RUN touch src/main.rs && cargo build --locked --release --bin phantasm-orchestrator

# ---- runtime stage ----
FROM debian:bookworm-slim AS runtime
WORKDIR /app

# rustls is used (no OpenSSL); only need CA certs for outbound TLS (Brave).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/phantasm-orchestrator /usr/local/bin/
COPY --from=builder /app/workflows /app/workflows

# Run without root and give durable metrics/image data a mountable home.
RUN groupadd --gid 10001 phantasm \
    && useradd --uid 10001 --gid phantasm --home /var/lib/phantasm \
        --no-create-home --shell /usr/sbin/nologin phantasm \
    && install -d -o phantasm -g phantasm /var/lib/phantasm

EXPOSE 8080
ENV PHANTASM_BIND=0.0.0.0:8080
ENV PHANTASM_METRICS_DB=/var/lib/phantasm/phantasm-metrics.sqlite
VOLUME ["/var/lib/phantasm"]
WORKDIR /var/lib/phantasm
USER phantasm
ENTRYPOINT ["phantasm-orchestrator"]
