# pgfusion justfile
# Usage: just <recipe>   (run from pgfusion/)
# Requires: https://github.com/casey/just

pg_version := env_var_or_default("PG_VERSION", "pg18")

# ── Default ───────────────────────────────────────────────────────────────────

default:
    @just --list

# ── Build ─────────────────────────────────────────────────────────────────────

# Debug build
build:
    cargo build

# Release build (both binaries)
release:
    cargo build --release --bin pgfusion_cli --bin pgfusion_server

# ── Lint & Format ─────────────────────────────────────────────────────────────

fmt:
    cargo fmt

fmt-check:
    cargo fmt --check

clippy:
    cargo clippy -- -D warnings

# ── Tests ─────────────────────────────────────────────────────────────────────

# Unit tests
test:
    cargo test

# SQL correctness tests against PostgreSQL
test-sql pg=pg_version:
    cd tests/sql_correctness && bash run.sh {{pg}}

# Consistency tests (pgfusion vs PostgreSQL after heap mutations)
test-consistency pg=pg_version:
    cd tests/consistency && bash run.sh {{pg}}

# All integration tests
test-all pg=pg_version: (test-sql pg) (test-consistency pg)

# ── Benchmarks ────────────────────────────────────────────────────────────────

# Criterion query benchmarks (optional filter regex)
bench filter="":
    cargo bench --bench query_bench -- {{filter}}

# ── ClickBench ────────────────────────────────────────────────────────────────

# Download and load the ClickBench hits dataset into PostgreSQL
# Set CLICKBENCH_MAX_ROWS=1000000 for a smaller dataset
clickbench-setup pg=pg_version:
    cd benches/clickbench && bash setup.sh {{pg}}

# Run the 43-query comparison (pgfusion vs PostgreSQL)
clickbench pg=pg_version runs="3":
    cd benches/clickbench && bash run.sh {{pg}} {{runs}}

# Open the ClickBench heatmap report in a browser
clickbench-report:
    open benches/clickbench/heatmap.html

# ── CLI ───────────────────────────────────────────────────────────────────────

# Interactive REPL
# Usage: just cli /path/to/pgdata 16384
cli data_dir db_id="16384":
    cargo run --release --bin pgfusion_cli -- -d {{data_dir}} --db-id {{db_id}}

# Run a single SQL query with timing
# Usage: just query /path/to/pgdata "SELECT count(*) FROM hits"
query data_dir sql db_id="16384":
    cargo run --release --bin pgfusion_cli -- \
        -d {{data_dir}} --db-id {{db_id}} -c {{sql}} -t

# Run SQL from a file with timing
# Usage: just query-file /path/to/pgdata queries.sql
query-file data_dir file db_id="16384":
    cargo run --release --bin pgfusion_cli -- \
        -d {{data_dir}} --db-id {{db_id}} -f {{file}} -t

# Start the server (stub — panics until implemented)
server:
    cargo run --release --bin pgfusion_server

# ── Docker ────────────────────────────────────────────────────────────────────

# Build the Docker image (SSH key forwarded from host agent for private pg_arrow repo)
docker-build:
    docker build --ssh default -f docker/Dockerfile -t pgfusion:latest .

# Build via docker compose
compose-build:
    PGDATA_PATH=${PGDATA_PATH:?Set PGDATA_PATH to your PostgreSQL data directory} \
        docker compose -f docker/docker-compose.yml build

# Run pgfusion-cli interactively inside Docker
compose-cli:
    PGDATA_PATH=${PGDATA_PATH:?Set PGDATA_PATH to your PostgreSQL data directory} \
        docker compose -f docker/docker-compose.yml run --rm pgfusion-cli

# Run a single SQL query via the Docker CLI service
# Usage: just compose-query "SELECT count(*) FROM hits"
compose-query sql:
    PGDATA_PATH=${PGDATA_PATH:?Set PGDATA_PATH to your PostgreSQL data directory} \
        docker compose -f docker/docker-compose.yml \
        run --rm pgfusion-cli -c '{{sql}}' -t

# Start pgfusion-server via docker compose
compose-server:
    PGDATA_PATH=${PGDATA_PATH:?Set PGDATA_PATH to your PostgreSQL data directory} \
        docker compose -f docker/docker-compose.yml up pgfusion-server

# Stop and remove compose containers
compose-down:
    docker compose -f docker/docker-compose.yml down

# ── Flamegraph & Profiling ────────────────────────────────────────────────────

# Flamegraph for the CLI against a PGDATA directory (requires cargo-flamegraph)
# Usage: just flamegraph /path/to/pgdata "SELECT count(*) FROM hits"
flamegraph data_dir sql db_id="16384":
    cargo flamegraph --bin pgfusion_cli -o flamegraph.svg \
        -- -d {{data_dir}} --db-id {{db_id}} -c {{sql}} -t
    open flamegraph.svg

# Flamegraph for criterion query benchmarks
# Usage: just flamegraph-bench   or   just flamegraph-bench "Q1"
flamegraph-bench filter="":
    cargo flamegraph --bench query_bench -o flamegraph.svg -- {{filter}}
    open flamegraph.svg

# Samply CPU profile for the CLI (macOS/Linux — opens in browser)
# Usage: just samply /path/to/pgdata "SELECT count(*) FROM hits"
samply data_dir sql db_id="16384":
    samply record cargo run --release --bin pgfusion_cli \
        -- -d {{data_dir}} --db-id {{db_id}} -c {{sql}} -t

# Samply CPU profile for criterion benchmarks
samply-bench filter="":
    samply record cargo bench --bench query_bench -- {{filter}}

# Open the last generated flamegraph
flamegraph-open:
    open flamegraph.svg

# ── Docs ──────────────────────────────────────────────────────────────────────

doc:
    cargo doc --open --no-deps
