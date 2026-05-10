# pgfusion

A SQL query engine that reads PostgreSQL data files directly. Built on [Apache DataFusion](https://datafusion.apache.org/) and [pg_arrow](../pg_arrow/).

[![asciicast](https://asciinema.org/a/sIhowFJ7Mf8b4Hzk.svg)](https://asciinema.org/a/sIhowFJ7Mf8b4Hzk)

## How it works

pgfusion points at a PostgreSQL data directory (`PGDATA`), discovers all tables via the system catalog, and registers them as DataFusion table providers. Queries are planned and executed by DataFusion; page reads and tuple decoding are handled by `pg_arrow`. Each table scan is partitioned across parallel ranges for concurrent reads.

## Use Cases

- **Backup analysis** — query PostgreSQL backups without restoring them
- **Offline analytics** — run OLAP queries on data directory copies without impacting production
- **Development** — analyze production data snapshots locally
- **Forensics** — inspect PostgreSQL data files at the page/tuple level

## Prerequisites

- **Rust** — [rustup.rs](https://rustup.rs)
- **just** — command runner

```bash
brew install just          # macOS
cargo install just         # other platforms
```

## Quick start

```bash
# Interactive REPL
just cli /path/to/pgdata

# Single query with timing
just query /path/to/pgdata "SELECT count(*) FROM my_table"

# Execute queries from a file
just query-file /path/to/pgdata queries.sql
```

## Docker

```bash
just docker-build
PGDATA_PATH=/path/to/pgdata just compose-cli
PGDATA_PATH=/path/to/pgdata just compose-query "SELECT count(*) FROM hits"
PGDATA_PATH=/path/to/pgdata just compose-server
just compose-down
```

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

## Benchmarks

### ClickBench (43 queries)

```bash
just clickbench-setup pg18    # download & load dataset (~75 GB uncompressed)
just clickbench pg18          # run all 43 queries vs PostgreSQL
just clickbench-report        # open latest heatmap in browser
```

##### Mac M2 Pro 10-core 32 GB

<img width="700" alt="ClickBench results" src="https://github.com/user-attachments/assets/79e2a570-6af1-430a-a2d0-7793094800a0" />

> **Note:** Some pgfusion results are incorrect (e.g. Q36, Q42). See `output/` in the checkpoint folder for per-query details.

### TPC-H (22 queries, SF1)

```bash
just tpch-setup pg18          # build dbgen and load dataset
just tpch pg18                # run all 22 queries vs PostgreSQL
just tpch-report              # open latest heatmap in browser
```

## Testing

```bash
just test                     # unit tests
just test-sql pg18            # SQL correctness tests
just test-consistency pg18    # consistency tests vs live PostgreSQL
```

## Common commands

```bash
just build        # debug build
just release      # release build
just bench        # Criterion benchmarks
just flamegraph /pgdata "SELECT count(*) FROM hits"
just --list       # all available recipes
```
