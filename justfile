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

# Install sccache and wire it into .cargo/config.toml (SCCACHE_CACHE_SIZE / SCCACHE_DIR to override)
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

# Unit + lib tests
[group('test')]
test:
    cargo nextest run --lib

# SQL correctness: fast (snapshot diff only — no PG connection needed)
[group('test')]
test-sql:
    INSTA_SKIP_PG=1 cargo nextest run -P sql --test sql_correctness

# SQL correctness: seed snapshots (requires live PG + pgbench data)
[group('test')]
test-sql-seed:
    INSTA_UPDATE=unseen INSTA_OUTPUT=summary cargo test --test sql_correctness -- --nocapture || true
    cargo insta accept

# SQL correctness: force re-validate all snapshots against live PostgreSQL
[group('test')]
test-sql-validate:
    INSTA_UPDATE=new INSTA_OUTPUT=summary INSTA_FORCE_PG_VALIDATE=1 cargo test --test sql_correctness -- --nocapture
    cargo insta accept

# Consistency tests: MVCC visibility, parallel tx, rollback-after-checkpoint
[group('test')]
test-consistency:
    cargo nextest run -P consistency --test consistency --no-capture

# Consistency tests + #[ignore] tests (clog/rollback)
[group('test')]
test-consistency-full:
    cargo nextest run -P consistency --test consistency --run-ignored all --no-capture

# Consistency tests without checkpoint (WAL streaming / live-read path)
[group('test')]
test-consistency-no-checkpoint:
    PG_TEST_NO_CHECKPOINT=1 cargo nextest run -P consistency --test consistency --no-capture

# All integration tests (fast sql snapshot check + consistency)
[group('test')]
test-all: test-sql test-consistency

# Code coverage — integration tests (requires cargo-llvm-cov)
# RUSTFLAGS=-C instrument-coverage ensures pg_arrow (path dep) is also instrumented
[group('test')]
coverage:
    RUSTFLAGS="-C instrument-coverage" cargo llvm-cov nextest \
        -P consistency --test consistency --no-report
    cargo llvm-cov report \
        --ignore-filename-regex 'tests/|src/server/|\.cargo|rustup' \
        --html --output-dir coverage/

# Code coverage — unit/lib tests only (fast, no PG needed)
[group('test')]
coverage-unit:
    RUSTFLAGS="-C instrument-coverage" cargo llvm-cov nextest --lib \
        --no-report
    cargo llvm-cov report \
        --ignore-filename-regex 'tests/|src/server/|\.cargo|rustup' \
        --html --output-dir coverage/

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

# ── PostgreSQL CLI & Setup ────────────────────────────────────────────────────

harness_setup := env_var_or_default("PG_HARNESS_DIR", "") + "/scripts/setup-postgres.sh"

# Open a psql session for a given PostgreSQL version
# Usage: just psql pg18   or   just psql pg18 test
[group('postgres')]
psql pg=pg_version db="postgres":
    @bin=$(awk -v s="postgres.{{pg}}" '$0~"\\["s"\\]"{f=1} f&&$1=="bin_dir"{gsub(/.*= *"|"$/,""); print $0; exit}' pg-test-config.toml); \
     DYLD_LIBRARY_PATH="$bin/../lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$bin/psql" {{db}}

[private]
check-harness:
    @[ -n "${PG_HARNESS_DIR:-}" ] || { echo "error: PG_HARNESS_DIR is not set\nSet it to your pg-test-harness clone: export PG_HARNESS_DIR=/path/to/pg-test-harness"; exit 1; }

# Full setup: build from source, init cluster, load test data
[group('postgres')]
pg-setup pg=pg_version: check-harness
    TARGET_DIR="$(pwd)" TESTDATA_DIR="$(pwd)/testdata" bash {{harness_setup}} -b {{pg}} -B -i -t

# Full setup with simple schema
[group('postgres')]
pg-setup-simple pg=pg_version: check-harness
    TARGET_DIR="$(pwd)" TESTDATA_DIR="$(pwd)/testdata" bash {{harness_setup}} -b {{pg}} -B -i -t -s

# Build PostgreSQL source only
[group('postgres')]
pg-build pg=pg_version: check-harness
    TARGET_DIR="$(pwd)" TESTDATA_DIR="$(pwd)/testdata" bash {{harness_setup}} -b {{pg}} -B

# Init cluster only (source must already be built)
[group('postgres')]
pg-init pg=pg_version: check-harness
    TARGET_DIR="$(pwd)" TESTDATA_DIR="$(pwd)/testdata" bash {{harness_setup}} -b {{pg}} -i

# Load test data into an already-initialised cluster
[group('postgres')]
pg-testdata pg=pg_version: check-harness
    TARGET_DIR="$(pwd)" TESTDATA_DIR="$(pwd)/testdata" bash {{harness_setup}} -b {{pg}} -t

# Create pgbench_test db with pgbench data (SF=1 by default; override with PGBENCH_SCALE=N or PGBENCH_DBNAME=name)
[group('postgres')]
pg-setup-pgbench pg=pg_version: check-harness
    TARGET_DIR="$(pwd)" TESTDATA_DIR="$(pwd)/testdata" bash {{harness_setup}} -b {{pg}} -p

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

# Samply CPU profile for the CLI at 40000 Hz (macOS/Linux — opens in browser)
# Usage: just samply /path/to/pgdata "SELECT count(*) FROM hits"
[group('profiling')]
samply data_dir sql db_id="16384":
    cargo build --profile profiling --bin pgfusion_cli
    samply record -r 40000 ./target/profiling/pgfusion_cli \
        -d {{data_dir}} --db-id {{db_id}} -c {{sql}} -t

# Samply CPU profile for criterion benchmarks at 40000 Hz
[group('profiling')]
samply-bench filter="":
    samply record -r 40000 cargo bench --bench query_bench -- {{filter}}

# Open the last generated flamegraph
[group('profiling')]
flamegraph-open:
    open flamegraph.svg

# ── Docs ──────────────────────────────────────────────────────────────────────

[group('docs')]
doc:
    cargo doc --open --no-deps
