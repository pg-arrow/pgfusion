# Deployment

## CLI (local / scripted)

```bash
cargo build --release --bin pgfusion_cli

# Interactive REPL
pgfusion_cli -d /path/to/pgdata --db-id 16384

# Single query
pgfusion_cli -d /path/to/pgdata -c "SELECT count(*) FROM orders"

# From file
pgfusion_cli -d /path/to/pgdata -f queries.sql
```

## Server (Arrow Flight SQL)

```bash
cargo build --release --bin pgfusion_server

pgfusion_server -d /path/to/pgdata --db-id 16384
```

Remote clients connect via Arrow Flight SQL. PostgreSQL wire protocol is not supported.

## Docker

```bash
just docker-build
PGDATA_PATH=/path/to/pgdata just compose-cli
PGDATA_PATH=/path/to/pgdata just compose-query "SELECT count(*) FROM hits"
just compose-down
```

## Configuration

All options can be set via a TOML config file. Pass it with `--config`:

```bash
pgfusion_cli -d /path/to/pgdata --config pgfusion_config.toml
```

CLI flags override config file values. See [`pgfusion_config.toml`](../pgfusion_config.toml) for all available options.

| Section | Key | Description |
|---|---|---|
| `[query]` | `batch_size` | Rows per Arrow RecordBatch (default: 8192) |
| `[query]` | `target_partitions` | Parallel execution tasks (default: CPU count) |
| `[query]` | `memory_limit` | Max query memory, e.g. `"512M"` or `"2G"` |
| `[query]` | `temp_directory` | Spill directory when memory limit is exceeded |
| `[datasource]` | `partition_count` | Page-range partitions per heap scan (default: 10) |
| `[connection]` | `pg_url` | PostgreSQL connection string |
| `[connection]` | `checkpoint` | Run `CHECKPOINT` before each query |
| `[connection]` | `consistent` | Acquire REPEATABLE READ snapshot per query |
| `[output]` | `timing` | Print query elapsed time |
| `[output]` | `debug_timing` | Print per-phase timing breakdown |

## Deployment Modes

### Offline analytics

Point pgfusion at a local `PGDATA` snapshot or backup. No running PostgreSQL server required, provided the data directory was checkpointed and vacuumed before the server was stopped.

```bash
pgfusion_cli -d /path/to/pgdata-snapshot --db-id 16384
```

### Analytics sidecar on the primary

Run `pgfusion_server` on the same host as the primary PostgreSQL server. Set `memory_limit` to avoid starving the primary. Use `--checkpoint` and `--consistent` for MVCC-correct reads.

```bash
pgfusion_server -d /var/lib/postgresql/data --db-id 16384 \
  --pg-url "host=/var/run/postgresql port=5432 dbname=mydb user=myuser" \
  --checkpoint --consistent
```

> **Note:** Until WAL streaming is implemented, `--checkpoint` issues a `CHECKPOINT` before each query, which adds disk I/O load on the primary.

### Analytical read replica

On a streaming replica node, run `pgfusion_server` as a sidecar alongside the standby PostgreSQL server. PostgreSQL handles replication and failover; pgfusion reads directly from the replica's `PGDATA`.

```bash
pgfusion_server -d /var/lib/postgresql/data --db-id 16384 \
  --pg-url "host=/var/run/postgresql port=5432 dbname=mydb user=myuser" \
  --consistent
```
