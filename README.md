# pgfusion

A SQL query engine that reads PostgreSQL data files directly, bypassing the PostgreSQL server entirely. Built on [Apache DataFusion](https://datafusion.apache.org/) and powered by [pg_arrow](../pg_arrow/) for low-level page parsing and Arrow conversion.

## How it works

pgfusion points at a PostgreSQL data directory (`PGDATA`), discovers all tables via the system catalog, and registers them as DataFusion table providers. Queries are planned and executed by DataFusion, while the actual page reads and tuple decoding are handled by `pg_arrow`. Each table scan is partitioned across 10 parallel ranges for concurrent reads.

## Quick start

```bash
# Build
cargo build --release

# Interactive REPL
cargo run --bin pgfusion_cli --release -- -d /path/to/pgdata --db-id 16384

# Single query
cargo run --bin pgfusion_cli --release -- -d /path/to/pgdata -c "SELECT count(*) FROM my_table"

# Execute queries from a file with timing
cargo run --bin pgfusion_cli --release -- -d /path/to/pgdata -f queries.sql -t
```

### REPL commands

| Command    | Description          |
|------------|----------------------|
| `\dt`      | List tables          |
| `\timing`  | Toggle query timing  |
| `\?`       | Show help            |
| `\q`       | Quit                 |

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

- `CustomDataSource` -- `TableProvider` backed by PostgreSQL heap files
- `PgTableExec` -- `ExecutionPlan` that partitions reads across parallel ranges
- `PgRecordBatchStream` -- Bridges `futures::Stream` to DataFusion's `RecordBatchStream`
- `create_session(db_id)` -- Creates a `SessionContext` with all tables registered

## Testing

```bash
# Unit tests
cargo test

# SQL correctness tests (requires a PostgreSQL data directory)
cd tests/sql_correctness && bash run.sh

# Consistency tests (reads against live heap mutations)
cd tests/consistency && bash run.sh
```

## Benchmarks

```bash
# Criterion micro-benchmark
cargo bench

# ClickBench analytical query suite
cd benches/clickbench && bash run.sh
```

## Dependencies

| Crate | Purpose |
|-------|---------|
| `pg_arrow` | PostgreSQL file reading and Arrow conversion |
| `datafusion` 53.0 | Query planning and execution |
| `arrow` 58.0 | Columnar data format |
| `clap` 4 | CLI argument parsing |
| `rustyline` 18.0 | Interactive REPL |
| `mimalloc` | High-performance memory allocator |
| `tokio` | Async runtime |
