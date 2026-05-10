# pgfusion Examples

## Structure

```
examples/
├── lib/rust/          # Direct library usage (no server needed)
│   └── count_query.rs
└── client/            # Client examples for pgfusion_server (Arrow Flight SQL)
    ├── python/        # Python — ADBC, ConnectorX
    ├── typescript/    # TypeScript/Bun — Arrow Flight SQL
    ├── rust/          # Rust — arrow-flight client
    └── sql/           # DuckDB SQL
```

## lib — Direct Library Usage

No server needed. Reads PostgreSQL heap files directly via `pgfusion_lib`.

```bash
cargo run --example count_query
```

## client — pgfusion_server Clients

Requires pgfusion_server running:

```bash
pgfusion_server -d /path/to/pgdata --db-id 16384 --port 32010
```

| Language | Dir | Run |
|----------|-----|-----|
| Python (ADBC) | `python/adbc.py` | `uv run adbc.py` |
| Python (ConnectorX) | `python/cx_client.py` | `uv run cx_client.py` |
| Python (Ibis) | `python/ibis_client.py` | `uv run ibis_client.py` |
| TypeScript | `typescript/flight_sql_client.ts` | `bun install && bun run flight_sql_client.ts` |
| Rust | `rust/flight_sql.rs` | `cargo run --example flight_sql_client` |
| DuckDB | `sql/duckdb.sql` | `duckdb < duckdb.sql` |

See `client/python/README.md` for Python setup details.
