# pgfusion

> **Status:** Work in progress. APIs, on-disk assumptions, and CLI flags may change. Not yet production-ready.
>
> **Current implementation:** reads PostgreSQL heap files **directly from disk** (no shared buffer pool yet) and decodes them into Apache Arrow via `pg_arrow`. A buffer-pool / page-cache layer is on the roadmap.

SQL query engine that reads PostgreSQL data files directly. Built on [Apache DataFusion](https://datafusion.apache.org/) and [pg_arrow](https://github.com/pg-arrow/pg_arrow).

[![asciicast](https://asciinema.org/a/sIhowFJ7Mf8b4Hzk.svg)](https://asciinema.org/a/sIhowFJ7Mf8b4Hzk)

Reads `PGDATA` directly, discovers tables from the system catalog, and executes SQL via DataFusion. Page reads and tuple decoding are handled by `pg_arrow`. Scans are partitioned across page ranges for parallel execution.

Consistent reads require either a running PostgreSQL server (live MVCC snapshots) or a cleanly checkpointed and vacuumed data directory (offline). See [Consistency](#consistency).

---

## Use Cases

**Offline analytics on backups** — point pgfusion at a local `PGDATA` snapshot or backup and run SQL immediately, no restore needed. Querying S3-backed data directories (with per-table granularity) is coming soon.

**Analytics sidecar on the primary** — run `pgfusion_server` alongside the primary PostgreSQL server, reading the same `PGDATA`. Offloads analytical queries without touching the primary's connection pool. Remote clients connect via Arrow Flight SQL; local use via `pgfusion_cli`. Use `--checkpoint` and `--consistent` for MVCC-correct reads. Memory must be budgeted carefully to avoid contention with the primary.

**Analytical read replica** — on a streaming replica node, run `pgfusion_server` as a sidecar next to the standby PostgreSQL server. PostgreSQL handles replication and failover as normal; pgfusion serves analytical queries directly off the replica's `PGDATA`. Remote clients connect via Arrow Flight SQL; local access via `pgfusion_cli`. On failover, the promoted node continues serving both PostgreSQL and pgfusion traffic without any additional setup.

---

## Things to Note

- **No PostgreSQL wire protocol** — remote access uses Arrow Flight SQL (`pgfusion_server`, **WIP — not production-ready**); local access uses the CLI (`pgfusion_cli`). psql and libpq clients will not work.
- **Checkpoint per query** — `--consistent` issues a `CHECKPOINT` before each query to flush dirty pages. Until WAL streaming is implemented, this can cause disk I/O contention on a live primary. Use with care on write-heavy workloads.
- **Memory sharing** — when running as a sidecar, pgfusion shares host memory with PostgreSQL. Set `query.memory_limit` in the config to cap pgfusion's footprint.
- **No WAL streaming yet** — reads reflect the state at the last checkpoint, not real-time. WAL streaming is on the roadmap.
- **Platform support** — tested on macOS and Linux. Windows is not currently supported.
- **PostgreSQL version** — only tested against PostgreSQL 18. Older versions may work, but multi-version testing is WIP.

---

## Quick Start

Requires [Rust](https://rustup.rs) 1.85+ (edition 2024). [`just`](https://github.com/casey/just) is recommended but optional.

### Install

Install both binaries (`pgfusion_cli` and `pgfusion_server` — server is **WIP**) straight from git:

```bash
cargo install --git https://github.com/pg-arrow/pgfusion

# Or just the CLI
cargo install --git https://github.com/pg-arrow/pgfusion --bin pgfusion_cli
```

`cargo install` drops the binaries in `~/.cargo/bin/` — make sure that's on your `PATH`. Not yet published to crates.io.

### Run the CLI

Flags follow PostgreSQL convention: `-D` is the data directory (PGDATA), `-d` is the database name (resolved against `pg_database`; defaults to `postgres`).

```bash
# Interactive REPL on a PGDATA directory (defaults to db "postgres")
pgfusion_cli -D /path/to/pgdata

# Select a specific database by name
pgfusion_cli -D /path/to/pgdata -d mydb

# One-shot query
pgfusion_cli -D /path/to/pgdata -d mydb -c "SELECT count(*) FROM orders"

# Execute a file of SQL
pgfusion_cli -D /path/to/pgdata -d mydb -f queries.sql

# Time queries
pgfusion_cli -D /path/to/pgdata -d mydb -t -c "SELECT count(*) FROM orders"
```

Inside the REPL, switch databases with `USE <name>;` or `\c <name>`, and list them with `\l`.

### Via `just` (inside a checkout)

```bash
just cli /path/to/pgdata                                  # interactive REPL
just query /path/to/pgdata "SELECT count(*) FROM orders"  # single query
just query-file /path/to/pgdata queries.sql               # from file
```

## Consistency

By default pgfusion reads raw heap files with no MVCC filtering — dead tuples may appear and unflushed writes may be missing.

**Against a live database** — use `--checkpoint` (flushes dirty pages) and `--consistent` (REPEATABLE READ snapshot for xmin visibility):

```bash
pgfusion_cli -D /path/to/pgdata -d mydb \
  --pg-url "host=/tmp port=5432 dbname=mydb user=myuser" \
  --checkpoint --consistent \
  -c "SELECT count(*) FROM orders"
```

| Flag | Description |
|---|---|
| `--pg-url <url>` | PostgreSQL connection string |
| `--checkpoint` | Run `CHECKPOINT` before each query to flush dirty pages |
| `--consistent` | Acquire a REPEATABLE READ snapshot per query for MVCC visibility |
| `--debug-timing` | Print per-phase timing (connect / snapshot / query / rollback) |

**Offline** — run `CHECKPOINT` and `VACUUM` before stopping PostgreSQL, or do a clean shutdown.

## Library Usage

```rust
use pgfusion_lib::create_session;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let ctx = create_session(16384)?;
    let df = ctx.sql("SELECT count(*) FROM pgbench_accounts").await?;
    df.show().await?;
    Ok(())
}
```

---

## Benchmarks

See [docs/BENCHMARKING.md](docs/BENCHMARKING.md) for full setup, scale factors, allocator comparison, and CPU profiling.

### ClickBench (43 queries)

> Requires: `export PGFUSION_BENCHMARK_DIR=/path/to/pgfusion-benchmark`

```bash
just clickbench-setup pg18    # download & load dataset (~75 GB uncompressed)
just clickbench pg18          # run all 43 queries vs PostgreSQL
just clickbench-report        # open latest heatmap in browser
```

##### Mac M2 Pro 10-core 32 GB

<img width="700" alt="ClickBench results" src="https://github.com/user-attachments/assets/79e2a570-6af1-430a-a2d0-7793094800a0" />

> **Note:** Some pgfusion results are incorrect (e.g. Q36, Q42). See `output/` in the checkpoint folder for per-query details.

### TPC-H (22 queries, SF10)

> Requires: `export PGFUSION_BENCHMARK_DIR=/path/to/pgfusion-benchmark`

```bash
just tpch-setup pg18          # build dbgen and load dataset
just tpch pg18                # run all 22 queries vs PostgreSQL
just tpch-report              # open latest heatmap in browser
```

---

## Roadmap

### Near-term

- [ ] **Filter pushdown** — push DataFusion predicates into the heap scan to skip pages early
- [ ] **PostgreSQL datatype parity** — fix `date`/`string` conversions (tracked via ClickBench Q36, Q42), add `interval` support
- [ ] **TOAST / PGLZ decompression** — decompress inline PGLZ-compressed values during tuple decode
- [ ] **`\x` expanded display** — column-per-row output mode in the REPL

### Medium-term

- [ ] **WAL streaming** — read WAL segments for point-in-time queries without per-query `CHECKPOINT`
- [ ] **Flight SQL server** — expose pgfusion over Arrow Flight SQL (`pgfusion_server`)
- [ ] **Buffer pool** — page cache to avoid re-reading hot pages across queries
- [ ] **Index scans** — use PostgreSQL B-tree, Hash, GiST, GIN, and BRIN index files to accelerate point, range, and full-text lookups
- [ ] **pgvector** — read `vector` columns and support approximate nearest-neighbor queries via IVFFlat/HNSW index files
- [ ] **ParadeDB** — read BM25 index files for full-text search
- [ ] **Citus** — discover and query sharded tables across distributed data directories
- [ ] **Per-query allocation** — arena-per-query to avoid repeated alloc/dealloc on hot paths
- [ ] **Tracing** — OpenTelemetry spans for query planning, scan, and decode phases

### Long-term

- [ ] **Disaggregated storage** — read heap files from object storage (S3, GCS) without a local copy
- [ ] **io_uring** — async I/O backend for Linux for lower-latency page reads
- [ ] **Auth/authz** — PostgreSQL-compatible authentication and row-level access control

---

## Deployment

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for CLI, server, Docker, and configuration options.

## Testing

See [docs/TESTING.md](docs/TESTING.md) for setup, test recipes, and environment variables.

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md). Bug reports and feature requests via GitHub Issues are welcome — PRs will open soon.

## Commands

```bash
just build        # debug build
just release      # release build
just bench        # Criterion benchmarks
just --list       # all recipes
```
