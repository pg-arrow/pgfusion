# /// script
# dependencies = [
#   "connectorx",
#   "pyarrow",
#   "polars",
# ]
# ///
"""
Example: ConnectorX querying pgfusion_server via Arrow Flight SQL.

ConnectorX returns Arrow/Polars directly with parallel partitioned fetches.

Run:
    pgfusion_server -d /path/to/pgdata --db-id 16384 --port 32010
    uv run cx_client.py
"""

import connectorx as cx
import pyarrow as pa
import polars as pl

FLIGHT_SQL_URI = "flightsql://localhost:32010"

table: pa.Table = cx.read_sql(
    FLIGHT_SQL_URI,
    "SELECT region, sum(revenue) AS total FROM orders GROUP BY region",
    return_type="arrow",
    protocol="flight",
)
print(f"Arrow Table: {table.num_rows} rows, schema: {table.schema}")

df: pl.DataFrame = cx.read_sql(
    FLIGHT_SQL_URI,
    "SELECT user_id, created_at, amount FROM transactions WHERE amount > 100",
    return_type="polars",
    protocol="flight",
)
print(df.head())

# Parallel partitioned fetch
table = cx.read_sql(
    FLIGHT_SQL_URI,
    "SELECT * FROM events WHERE ts BETWEEN '2025-01-01' AND '2025-12-31'",
    return_type="arrow",
    protocol="flight",
    partition_on="user_id",
    partition_num=8,
)
print(f"Partitioned fetch: {table.num_rows} rows")
