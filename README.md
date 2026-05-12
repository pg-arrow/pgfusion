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
pgfusion_cli -d /path/to/pgdata --db-id 16384 \
  --pg-url "host=/tmp port=5432 dbname=mydb user=myuser" \
  --checkpoint --consistent \
  -c "SELECT count(*) FROM orders"
```

| Flag | Description |
|---|---|
| `--pg-url <url>` | PostgreSQL connection string |
| `--checkpoint` | Run `CHECKPOINT` before each query to flush dirty pages |
| `--consistent` | Acquire a REPEATABLE READ snapshot per query for MVCC visibility |
| `--debug-timing` | Print timing for each phase |

**Offline** — run `CHECKPOINT` and `VACUUM` before stopping PostgreSQL, or do a clean shutdown.

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

## Testing

### Setup (once)

Install test tooling:

```bash
cargo install cargo-nextest    # parallel test runner (required)
cargo install cargo-insta      # snapshot review tool
cargo install cargo-llvm-cov   # coverage (optional)
```

Clone [`pg-test-harness`](https://github.com/pg-arrow/pg-test-harness) and set `PG_HARNESS_DIR`:

```bash
git clone https://github.com/pg-arrow/pg-test-harness /path/to/pg-test-harness
export PG_HARNESS_DIR=/path/to/pg-test-harness   # add to ~/.zshrc or ~/.bashrc

just pg-setup-pgbench pg18   # build PG18, init cluster, load pgbench SF=1 (~100k rows)
just test-sql-seed           # seed SQL correctness snapshots against live PG (run once)
```

### Running tests

```bash
just test                    # unit tests (no PG needed)
just test-sql                # SQL correctness: snapshot diff only (no PG needed)
just test-sql-seed           # re-seed snapshots against live PG
just test-sql-validate       # force re-validate all snapshots against live PG
just test-consistency        # MVCC visibility tests (requires live PG)
just test-consistency-full   # + #[ignore] tests (clog/rollback)
just test-all                # test-sql + test-consistency
```

### Environment variables

| Variable | Description |
|---|---|
| `PG_HARNESS_DIR` | Path to pg-test-harness clone (required for `pg-setup-*` recipes) |
| `INSTA_SKIP_PG` | Set to skip PG connection in sql correctness tests (snapshot diff only) |
| `INSTA_FORCE_PG_VALIDATE=1` | Force re-validate all snapshots against live PG |
| `PG_TEST_NO_CHECKPOINT=1` | Skip CHECKPOINT in consistency tests (WAL streaming path) |
| `PG_VERSION` | Default PostgreSQL version (`pg18`) |

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
