# syntax=docker/dockerfile:1

# Build context is pgfusion/ only — pg_arrow is fetched from GitHub via Cargo.
# Build with: docker build -f docker/Dockerfile -t pgfusion:latest .

# ── Stage 1: builder ──────────────────────────────────────────────────────────
FROM rust:1.95-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    git \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Trust GitHub's host key so cargo-git doesn't prompt
RUN mkdir -p /root/.ssh \
    && ssh-keyscan github.com >> /root/.ssh/known_hosts

WORKDIR /build

COPY . .

# SSH key is forwarded from the host agent — never stored in the image layer
RUN --mount=type=ssh \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --bin pgfusion_cli --bin pgfusion_server \
    && cp target/release/pgfusion_cli /usr/local/bin/pgfusion_cli \
    && cp target/release/pgfusion_server /usr/local/bin/pgfusion_server

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/pgfusion_cli    /usr/local/bin/pgfusion_cli
COPY --from=builder /usr/local/bin/pgfusion_server /usr/local/bin/pgfusion_server

RUN mkdir /pgdata

ENV RUST_LOG=info

ENTRYPOINT ["/usr/local/bin/pgfusion_cli"]
CMD ["-d", "/pgdata"]
