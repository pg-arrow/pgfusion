# pgfusion

SQL query engine that reads PostgreSQL data files directly, without a running server. Built on [Apache DataFusion](https://datafusion.apache.org/) and [pg_arrow](../pg_arrow/).

[![asciicast](https://asciinema.org/a/sIhowFJ7Mf8b4Hzk.svg)](https://asciinema.org/a/sIhowFJ7Mf8b4Hzk)

Reads `PGDATA` directly, discovers tables from the system catalog, and runs SQL via DataFusion. Page reads and tuple decoding are handled by `pg_arrow`. Scans are partitioned across page ranges for parallel execution.

## Quick start

Requires [Rust](https://rustup.rs) and [just](https://github.com/casey/just).

```bash
just cli /path/to/pgdata                                  # interactive REPL
just query /path/to/pgdata "SELECT count(*) FROM orders"  # single query
just query-file /path/to/pgdata queries.sql               # from file
```

## Consistency

By default pgfusion reads raw heap files with no MVCC filtering — dead tuples may appear and unflushed writes may be missing.

**Against a live database** — use `--checkpoint` (flushes dirty pages) and `--consistent` (REPEATABLE READ snapshot for xmin visibility):

```bash
# Unix socket (default PostgreSQL setup)
pgfusion_cli -d /path/to/pgdata --db-id 16384 \
  --pg-url "host=/tmp port=5432 dbname=mydb user=myuser" \
  --checkpoint --consistent \
  -c "SELECT count(*) FROM orders"

# TCP
pgfusion_cli -d /path/to/pgdata --db-id 16384 \
  --pg-url "host=localhost port=5432 dbname=mydb user=myuser password=secret" \
  --checkpoint --consistent \
  -c "SELECT count(*) FROM orders"
```

**Offline** — run `CHECKPOINT` and `VACUUM` before stopping PostgreSQL, or just do a clean shutdown. pgfusion will see consistent data without `--consistent`.

| Flag | Description |
|---|---|
| `--pg-url <url>` | PostgreSQL connection string — required for the flags below |
| `--checkpoint` | Run `CHECKPOINT` before each query to flush dirty pages |
| `--consistent` | Acquire a REPEATABLE READ snapshot per query for MVCC visibility |
| `--debug-timing` | Print timing for each phase: connect, snapshot, query, rollback |

`\debug` toggles debug timing in the REPL.

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

Both runners share `benches/bench_lib.sh` for query execution, timing, and checkpoint management.

## Testing

```bash
just test                     # unit tests
just test-sql pg18            # SQL correctness tests
just test-consistency pg18    # consistency vs live PostgreSQL (uses --consistent)
```

## Docker

```bash
just docker-build
PGDATA_PATH=/path/to/pgdata just compose-cli
PGDATA_PATH=/path/to/pgdata just compose-query "SELECT count(*) FROM hits"
just compose-down
```

## Commands

```bash
just build        # debug build
just release      # release build
just bench        # Criterion benchmarks
just --list       # all recipes
```
