# pgfusion

A SQL query engine that reads PostgreSQL data files directly, bypassing the PostgreSQL server entirely. Built on [Apache DataFusion](https://datafusion.apache.org/) and powered by [pg_arrow](../pg_arrow/) for low-level page parsing and Arrow conversion.

[![asciicast](https://asciinema.org/a/sIhowFJ7Mf8b4Hzk.svg)](https://asciinema.org/a/sIhowFJ7Mf8b4Hzk)

## Prerequisites

- **Rust** — [rustup.rs](https://rustup.rs)
- **just** — command runner for all recipes

```bash
# macOS
brew install just

# Linux / Windows (via cargo)
cargo install just

# All platforms (pre-built binary)
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin
```

For flamegraph and profiling recipes:

```bash
cargo install cargo-flamegraph  # flamegraph-* recipes
cargo install samply            # samply-* recipes
```

## How it works

pgfusion points at a PostgreSQL data directory (`PGDATA`), discovers all tables via the system catalog, and registers them as DataFusion table providers. Queries are planned and executed by DataFusion, while the actual page reads and tuple decoding are handled by `pg_arrow`. Each table scan is partitioned across 10 parallel ranges for concurrent reads.

## Quick start

```bash
# Interactive REPL
just cli /path/to/pgdata

# Single query with timing
just query /path/to/pgdata "SELECT count(*) FROM my_table"

# Execute queries from a file
just query-file /path/to/pgdata queries.sql
```

### REPL commands

| Command | Description |
|---|---|
| `\dt` | List tables |
| `\timing` | Toggle query timing |
| `\?` | Show help |
| `\q` | Quit |

## Common commands

```bash
just build                    # Debug build
just release                  # Release build (cli + server)
just test                     # Unit tests
just test-sql pg18            # SQL correctness tests
just test-consistency pg18    # Consistency tests (vs live PostgreSQL)
just bench                    # Criterion query benchmarks
just clickbench-setup pg18    # Download and load ClickBench dataset
just clickbench pg18          # Run 43-query comparison vs PostgreSQL
just clickbench-report        # Open heatmap in browser
just flamegraph /pgdata "SELECT count(*) FROM hits"  # CPU flamegraph
just doc                      # Open rustdoc
just --list                   # Show all available recipes
```

## Docker

```bash
# Build image
just docker-build

# Interactive CLI inside Docker
PGDATA_PATH=/path/to/pgdata just compose-cli

# Run a single query via Docker
PGDATA_PATH=/path/to/pgdata just compose-query "SELECT count(*) FROM hits"

# Start the server service
PGDATA_PATH=/path/to/pgdata just compose-server

# Tear down
just compose-down
```

Resource limits default to 2 CPUs / 2 GB RAM. Override with:

```bash
PGFUSION_CPU_LIMIT=4.0 PGFUSION_MEM_LIMIT=8G PGDATA_PATH=/path/to/pgdata just compose-cli
```

Docker files live in `docker/` (`Dockerfile`, `docker-compose.yml`, `.dockerignore`). The build context is the repo root so that `pg_arrow` (a sibling crate) is accessible during the build.

## Library usage

```rust
use pgfusion_lib::create_session;

#[tokio::main]
async fn main() {
    let ctx = create_session(16384).expect("failed to create session");
    let df = ctx.sql("SELECT count(*) FROM pgbench_accounts").await.unwrap();
    df.show().await.unwrap();
}
```

## Architecture

```
src/
├── lib.rs            # Module exports: create_session, CustomDataSource
├── datasource.rs     # DataFusion TableProvider, ExecutionPlan, RecordBatchStream
├── session.rs        # Session bootstrapping: catalog discovery, table registration
├── cli/              # pgfusion_cli binary (clap + rustyline REPL)
└── server/           # pgfusion_server binary (planned)
```

**Key types:**

- `CustomDataSource` — `TableProvider` backed by PostgreSQL heap files
- `PgTableExec` — `ExecutionPlan` that partitions reads across parallel ranges
- `PgRecordBatchStream` — Bridges `futures::Stream` to DataFusion's `RecordBatchStream`
- `create_session(db_id)` — Creates a `SessionContext` with all tables registered

## Testing

```bash
just test                     # Unit tests
just test-sql pg18            # SQL correctness tests (requires PostgreSQL data dir)
just test-consistency pg18    # Consistency tests (reads against live heap mutations)
just test-all pg18            # All integration tests
```

## Benchmarks

```bash
just bench                    # Criterion micro-benchmark
just clickbench-setup pg18    # Download & load ClickBench dataset (~75 GB uncompressed)
just clickbench pg18          # Run all 43 queries, compare pgfusion vs PostgreSQL
just clickbench-report        # Open heatmap.html in browser
just flamegraph-bench         # CPU flamegraph for query benchmarks
just samply-bench             # samply profile for query benchmarks
```

## Dependencies

| Crate | Purpose |
|---|---|
| `pg_arrow` | PostgreSQL file reading and Arrow conversion |
| `datafusion` 53.0 | Query planning and execution |
| `arrow` 58.0 | Columnar data format |
| `clap` 4 | CLI argument parsing |
| `rustyline` 18.0 | Interactive REPL |
| `mimalloc` | High-performance memory allocator |
| `tokio` | Async runtime |
