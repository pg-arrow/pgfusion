# Python Client Examples

Query pgfusion_server via Arrow Flight SQL using Python.

## Setup with uv

```bash
# Install uv (if not already)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Create venv and install deps
uv venv
uv pip install adbc-driver-flightsql pyarrow polars connectorx

# Run an example
uv run adbc.py
uv run cx_client.py
```

## Or with inline script dependencies (uv 0.4+)

Each example has a `# /// script` block at the top — run directly with no venv:

```bash
uv run adbc.py
uv run cx_client.py
```

uv resolves and installs deps into an isolated cache automatically.

## Prerequisites

Start pgfusion_server before running any example:

```bash
pgfusion_server -D /path/to/pgdata -d mydb --port 32010
```

## Examples

| File | Client | Notes |
|------|--------|-------|
| `adbc.py` | ADBC + pyarrow/polars | Native Arrow Flight SQL, zero copy |
| `cx_client.py` | ConnectorX | Parallel partitioned fetch, Arrow/Polars output |
| `ibis_client.py` | Ibis + Flight SQL | DataFrame API, composable queries, multi-backend |
