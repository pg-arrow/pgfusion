# /// script
# dependencies = [
#   "adbc-driver-flightsql",
#   "pyarrow",
#   "polars",
# ]
# ///
"""
Example: Python ADBC client connecting to pgfusion_server via Arrow Flight SQL.

ADBC (Arrow Database Connectivity) is the Arrow-native equivalent of JDBC/ODBC.
Results arrive as Arrow RecordBatches — no conversion to Python rows.

Run:
    pgfusion_server -d /path/to/pgdata --db-id 16384 --port 32010
    uv run adbc.py
"""

import adbc_driver_flightsql.dbapi as flight_sql
import pyarrow as pa
import polars as pl

conn = flight_sql.connect("grpc://localhost:32010")
cursor = conn.cursor()

cursor.execute("SELECT region, sum(revenue) FROM orders GROUP BY region")
table: pa.Table = cursor.fetch_arrow_table()
print(f"Got {table.num_rows} rows as Arrow Table")
print(table.schema)

# Stream batch by batch for large results
cursor.execute("SELECT * FROM large_events WHERE ts > '2025-01-01'")
reader = cursor.fetch_record_batch()
for batch in reader:
    print(f"batch: {batch.num_rows} rows")

df = pl.from_arrow(table)
print(df.head())

conn.close()
