# pgfusion Agent Guidelines

Detailed context for AI agents working on the pgfusion crate. See also `CLAUDE.md` for top-level pointers.

## Module Organization

```
src/
├── lib.rs            # Module hub: declares modules, re-exports public API
├── datasource.rs     # CustomDataSource, PgTableExec, PgRecordBatchStream (DataFusion providers)
├── session.rs        # create_session() -- bootstraps catalogs, registers all tables
├── cli/
│   ├── main.rs       # pgfusion_cli binary entry point (global allocator + env_logger + cli::run())
│   └── mod.rs        # CLI logic: Cli struct (clap), REPL (rustyline), query execution
└── server/
    ├── main.rs       # pgfusion_server binary entry point
    └── mod.rs        # Server logic (planned)
```

## Key Types

- `CustomDataSource` -- `TableProvider` implementation backed by PostgreSQL heap files
- `PgTableExec` -- `ExecutionPlan` that partitions table reads across 10 parallel ranges
- `PgRecordBatchStream` -- Bridges `futures::Stream` to DataFusion's `RecordBatchStream`
- `create_session(db_id)` -- Primary public API: returns a `SessionContext` with all tables registered

## Public API

The library exports two items at the crate root via re-exports:
- `pgfusion_lib::create_session` -- used by examples, benchmarks, and the CLI
- `pgfusion_lib::CustomDataSource` -- for advanced use cases needing direct table provider access
- `pgfusion_lib::cli::run()` -- CLI entry point (used by `cli/main.rs`)
- `pgfusion_lib::server::run()` -- Server entry point (used by `server/main.rs`, not yet implemented)

## Dependencies

- `pg_arrow` (sibling crate) -- PostgreSQL file reading and Arrow conversion
- `datafusion` 53.0 -- Query planning and execution
- `arrow` 58.0 -- Columnar data format
- `clap` 4 -- CLI argument parsing
- `rustyline` 18.0 -- Interactive readline for REPL
- `mimalloc` 0.1 -- High-performance memory allocator (binary only)
- `tokio` -- Async runtime with multi-thread and signal support

## Testing

- `cargo test` -- Unit tests (in `datasource.rs`)
- `tests/sql_correctness/` -- 22 SQL test files run via `run.sh` against a live PostgreSQL data directory
- `tests/consistency/` -- Tests that pgfusion reads live heap mutations
- `benches/query_bench.rs` -- Criterion benchmark (`SELECT count(*)`)
- `benches/clickbench/` -- ClickBench analytical query suite

## CLI Usage

```bash
# Interactive REPL
pgfusion_cli -d /path/to/pgdata --db-id 16384

# Single query
pgfusion_cli -d /path/to/pgdata -c "SELECT count(*) FROM my_table"

# File execution with timing
pgfusion_cli -d /path/to/pgdata -f queries.sql -t
```

REPL commands: `\dt` (list tables), `\timing` (toggle), `\?` (help), `\q` (quit)

## Gitignore

The `.gitignore` covers profiling artifacts (`flamegraph.svg`, `perf.data`), `pg-test-config.toml`, benchmark data, and test results. If a file listed in `.gitignore` is still showing up in `git status`, it was likely committed before the rule was added — run `git rm --cached <file>` to untrack it without deleting it from disk.
