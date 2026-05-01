# pgfusion justfile
# Usage: just <recipe>   (run from pgfusion/)
# Requires: https://github.com/casey/just

pg_version := env_var_or_default("PG_VERSION", "pg18")

# ── Default ───────────────────────────────────────────────────────────────────

[group('default')]
help:
    @just --list --unsorted

# ── Build ─────────────────────────────────────────────────────────────────────

# Debug build
[group('build')]
build:
    cargo build

# Release build (both binaries)
[group('build')]
release:
    cargo build --release --bin pgfusion_cli --bin pgfusion_server

# Install sccache and configure it automatically in .cargo/config.toml
# Default cache: ~/Library/Caches/Mozilla.sccache (macOS) or ~/.cache/sccache (Linux), 10GB
# Override: SCCACHE_CACHE_SIZE=20G  or  SCCACHE_DIR=/custom/path
[group('build')]
sccache-setup:
    @if ! command -v sccache >/dev/null 2>&1; then \
        echo "Installing sccache..."; \
        cargo install sccache; \
    else \
        echo "sccache already installed: $(sccache --version)"; \
    fi
    @mkdir -p .cargo
    @if ! grep -q 'rustc-wrapper.*sccache' .cargo/config.toml 2>/dev/null; then \
        if grep -q '^\[build\]' .cargo/config.toml 2>/dev/null; then \
            awk '/^\[build\]/{print; print "rustc-wrapper = \"sccache\""; next} 1' \
                .cargo/config.toml > .cargo/config.toml.tmp && mv .cargo/config.toml.tmp .cargo/config.toml; \
        else \
            { [ -s .cargo/config.toml ] && printf '\n'; printf '[build]\nrustc-wrapper = "sccache"\n'; } >> .cargo/config.toml; \
        fi; \
        echo "sccache configured in .cargo/config.toml"; \
    else \
        echo "sccache already configured in .cargo/config.toml"; \
    fi

# Show sccache statistics (run after a build to verify cache hits)
[group('build')]
sccache-stats:
    sccache --show-stats

# ── Lint & Format ─────────────────────────────────────────────────────────────

[group('lint')]
fmt:
    cargo fmt

[group('lint')]
fmt-check:
    cargo fmt --check

[group('lint')]
clippy:
    cargo clippy -- -D warnings

# ── Tests ─────────────────────────────────────────────────────────────────────

# Unit tests
[group('test')]
test:
    cargo test

# SQL correctness tests against PostgreSQL
[group('test')]
test-sql pg=pg_version:
    cd tests/sql_correctness && bash run.sh {{pg}}

# Consistency tests (pgfusion vs PostgreSQL after heap mutations)
[group('test')]
test-consistency pg=pg_version:
    cd tests/consistency && bash run.sh {{pg}}

# All integration tests
[group('test')]
test-all pg=pg_version: (test-sql pg) (test-consistency pg)

# ── Benchmarks ────────────────────────────────────────────────────────────────

# Criterion query benchmarks (optional filter regex)
[group('bench')]
bench filter="":
    cargo bench --bench query_bench -- {{filter}}

# ── CLI ───────────────────────────────────────────────────────────────────────

# Interactive REPL
# Usage: just cli /path/to/pgdata 16384
[group('cli')]
cli data_dir db_id="16384":
    cargo run --release --bin pgfusion_cli -- -d {{data_dir}} --db-id {{db_id}}

# Run a single SQL query with timing
# Usage: just query /path/to/pgdata "SELECT count(*) FROM hits"
[group('cli')]
query data_dir sql db_id="16384":
    cargo run --release --bin pgfusion_cli -- \
        -d {{data_dir}} --db-id {{db_id}} -c {{sql}} -t

# Run SQL from a file with timing
# Usage: just query-file /path/to/pgdata queries.sql
[group('cli')]
query-file data_dir file db_id="16384":
    cargo run --release --bin pgfusion_cli -- \
        -d {{data_dir}} --db-id {{db_id}} -f {{file}} -t

# Start the server (stub — panics until implemented)
[group('cli')]
server:
    cargo run --release --bin pgfusion_server

# ── ClickBench ────────────────────────────────────────────────────────────────

# Download and load the ClickBench hits dataset into PostgreSQL
# Set CLICKBENCH_MAX_ROWS=1000000 for a smaller dataset
[group('clickbench')]
clickbench-setup pg=pg_version:
    cd benches/clickbench && bash setup.sh {{pg}}

# Run the 43-query comparison (pgfusion vs PostgreSQL)
# Results always saved to checkpoints/current/
# Usage: just clickbench pg18 1 custom-label Q13 
[group('clickbench')]
clickbench pg=pg_version runs="3" query="":
    cd benches/clickbench && bash run.sh {{pg}} {{runs}} \
        $([ -n "{{query}}" ] && echo "--query={{query}}" || true)

# Run and checkpoint results under checkpoints/<short-hash>[-label]/
# Usage: just clickbench-checkpoint pg18 3 my-label
[group('clickbench')]
clickbench-checkpoint pg=pg_version runs="3" label="" query="":
    cd benches/clickbench && bash run.sh {{pg}} {{runs}} --checkpoint \
        $([ -n "{{label}}" ] && echo "--label={{label}}" || true) \
        $([ -n "{{query}}" ] && echo "--query={{query}}" || true)


# Checkpoint current results without re-running (optionally with a label)
# Usage: just clickbench-save   or   just clickbench-save before-optimization
[group('clickbench')]
clickbench-save label="":
    cd benches/clickbench && bash run.sh --checkpoint-only \
        $([ -n "{{label}}" ] && echo "--label={{label}}" || true)

# Open the ClickBench heatmap report in a browser (latest run)
[group('clickbench')]
clickbench-report:
    open benches/clickbench/checkpoints/current/heatmap.html

# Open a checkpointed heatmap by slug (e.g. just clickbench-report-checkpoint f85939b-initial-results)
[group('clickbench')]
clickbench-report-checkpoint slug:
    open benches/clickbench/checkpoints/{{slug}}/heatmap.html

# ── TPC-H ─────────────────────────────────────────────────────────────────────

# Download, build dbgen, and load TPC-H SF1 dataset into PostgreSQL
[group('tpch')]
tpch-setup pg=pg_version:
    cd benches/tpch && bash setup.sh {{pg}}

# Run the 22-query comparison (pgfusion vs PostgreSQL)
# Results always saved to checkpoints/current/
[group('tpch')]
tpch pg=pg_version runs="3":
    cd benches/tpch && bash run.sh {{pg}} {{runs}}

# Run and checkpoint results under checkpoints/<short-hash>[-label]/
# Usage: just tpch-checkpoint pg18 3 my-label
[group('tpch')]
tpch-checkpoint pg=pg_version runs="3" label="":
    cd benches/tpch && bash run.sh {{pg}} {{runs}} --checkpoint \
        $([ -n "{{label}}" ] && echo "--label={{label}}" || true)

# Checkpoint current results without re-running (optionally with a label)
# Usage: just tpch-save   or   just tpch-save before-optimization
[group('tpch')]
tpch-save label="":
    cd benches/tpch && bash run.sh --checkpoint-only \
        $([ -n "{{label}}" ] && echo "--label={{label}}" || true)

# Open the TPC-H heatmap report in a browser (latest run)
[group('tpch')]
tpch-report:
    open benches/tpch/heatmap.html

# Open a checkpointed TPC-H heatmap by slug (e.g. just tpch-report-checkpoint f85939b-initial)
[group('tpch')]
tpch-report-checkpoint slug:
    open benches/tpch/checkpoints/{{slug}}/heatmap.html

# ── PostgreSQL CLI ────────────────────────────────────────────────────────────

# Open a psql session for a given PostgreSQL version
# Usage: just psql pg18   or   just psql pg18 test
[group('postgres')]
psql pg=pg_version db="postgres":
    @bin=$(awk -v s="postgres.{{pg}}" '$0~"\\["s"\\]"{f=1} f&&$1=="bin_dir"{gsub(/.*= *"|"$/,""); print $0; exit}' ../pg_arrow/pg-test-config.toml); \
     DYLD_LIBRARY_PATH="$bin/../lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$bin/psql" {{db}}

# ── Docker ────────────────────────────────────────────────────────────────────

# Build the Docker image (SSH key forwarded from host agent for private pg_arrow repo)
[group('docker')]
docker-build:
    docker build --ssh default -f docker/Dockerfile -t pgfusion:latest .

# Build via docker compose
[group('docker')]
compose-build:
    PGDATA_PATH=${PGDATA_PATH:?Set PGDATA_PATH to your PostgreSQL data directory} \
        docker compose -f docker/docker-compose.yml build

# Run pgfusion-cli interactively inside Docker
[group('docker')]
compose-cli:
    PGDATA_PATH=${PGDATA_PATH:?Set PGDATA_PATH to your PostgreSQL data directory} \
        docker compose -f docker/docker-compose.yml run --rm pgfusion-cli

# Run a single SQL query via the Docker CLI service
# Usage: just compose-query "SELECT count(*) FROM hits"
[group('docker')]
compose-query sql:
    PGDATA_PATH=${PGDATA_PATH:?Set PGDATA_PATH to your PostgreSQL data directory} \
        docker compose -f docker/docker-compose.yml \
        run --rm pgfusion-cli -c '{{sql}}' -t

# Start pgfusion-server via docker compose
[group('docker')]
compose-server:
    PGDATA_PATH=${PGDATA_PATH:?Set PGDATA_PATH to your PostgreSQL data directory} \
        docker compose -f docker/docker-compose.yml up pgfusion-server

# Stop and remove compose containers
[group('docker')]
compose-down:
    docker compose -f docker/docker-compose.yml down

# ── Flamegraph & Profiling ────────────────────────────────────────────────────

# Flamegraph for the CLI against a PGDATA directory (requires cargo-flamegraph)
# Usage: just flamegraph /path/to/pgdata "SELECT count(*) FROM hits"
[group('profiling')]
flamegraph data_dir sql db_id="16384":
    cargo flamegraph --bin pgfusion_cli -o flamegraph.svg \
        -- -d {{data_dir}} --db-id {{db_id}} -c {{sql}} -t
    open flamegraph.svg

# Flamegraph for criterion query benchmarks
# Usage: just flamegraph-bench   or   just flamegraph-bench "Q1"
[group('profiling')]
flamegraph-bench filter="":
    cargo flamegraph --bench query_bench -o flamegraph.svg -- {{filter}}
    open flamegraph.svg

# Samply CPU profile for the CLI (macOS/Linux — opens in browser)
# Usage: just samply /path/to/pgdata "SELECT count(*) FROM hits"
[group('profiling')]
samply data_dir sql db_id="16384":
    samply record cargo run --release --bin pgfusion_cli \
        -- -d {{data_dir}} --db-id {{db_id}} -c {{sql}} -t

# Samply CPU profile for criterion benchmarks
[group('profiling')]
samply-bench filter="":
    samply record cargo bench --bench query_bench -- {{filter}}

# Open the last generated flamegraph
[group('profiling')]
flamegraph-open:
    open flamegraph.svg

# ── Docs ──────────────────────────────────────────────────────────────────────

[group('docs')]
doc:
    cargo doc --open --no-deps
