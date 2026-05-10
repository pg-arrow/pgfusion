# pgfusion

DataFusion-based SQL query engine for reading PostgreSQL data files directly. Provides a library (`pgfusion_lib`), an interactive CLI (`pgfusion_cli`), and a query server (`pgfusion_server`, planned).

## Module Organization

```
src/
├── lib.rs            # declares modules, re-exports public API
├── datasource.rs     # CustomDataSource, PgTableExec, PgRecordBatchStream (DataFusion providers)
├── session.rs        # create_session() -- bootstraps catalogs, registers all tables
├── cli/
│   ├── main.rs       # pgfusion_cli binary entry point
│   └── mod.rs        # CLI logic: Cli struct (clap), REPL (rustyline), query execution
└── server/
    └── main.rs       # pgfusion_server binary entry point (self-contained, not in lib)
```

## Public API

- `pgfusion_lib::create_session` -- used by examples, benchmarks, and the CLI
- `pgfusion_lib::CustomDataSource` -- for advanced use cases needing direct table provider access

## Key Conventions

- `pgfusion` never parses PostgreSQL binary formats directly — delegate to `pg_arrow`
- Error handling: propagate `PgError` and `DataFusionError`; use `anyhow` only in binaries and tests
- `mimalloc` is the global allocator in binaries (not the library)
