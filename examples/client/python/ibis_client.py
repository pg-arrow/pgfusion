# /// script
# dependencies = [
#   "ibis-framework[flightsql]",
#   "pyarrow",
#   "polars",
# ]
# ///
"""
Example: Ibis DataFrame API over pgfusion_server via Arrow Flight SQL.

Ibis compiles DataFrame operations to SQL and executes against pgfusion_server.
Same code runs on DuckDB, BigQuery, Snowflake — swap backend, keep logic.

Run:
    pgfusion_server -D /path/to/pgdata -d mydb --port 32010
    uv run ibis_client.py
"""

import ibis
import ibis.selectors as s

# Connect to pgfusion_server Flight SQL endpoint
con = ibis.flight_sql.connect(host="localhost", port=32010)

# List available tables
print(con.list_tables())

# Get a table reference — lazy, no data fetched yet
orders = con.table("orders")
users = con.table("users")

# Composable, type-safe query — compiles to SQL sent to pgfusion
result = (
    orders.filter(orders.amount > 100)
    .group_by("region")
    .aggregate(
        total_revenue=orders.revenue.sum(),
        order_count=orders.id.count(),
        avg_amount=orders.amount.mean(),
    )
    .order_by(ibis.desc("total_revenue"))
)

# Execute — pgfusion runs the SQL, returns Arrow, Ibis wraps as DataFrame
df = result.execute()  # returns pandas DataFrame by default
print(df.head())

# Or return as Polars
df_polars = result.to_polars()
print(df_polars.head())

# Window functions
orders_with_rank = orders.mutate(
    rank=orders.revenue.rank().over(ibis.window(group_by="region", order_by=ibis.desc("revenue")))
)
print(orders_with_rank.limit(10).execute())

# Join — Ibis compiles to a single SQL JOIN sent to pgfusion
enriched = orders.join(users, orders.user_id == users.id).select(
    orders.region,
    orders.revenue,
    users.name,
    users.email,
)
print(enriched.limit(5).execute())

# Selectors — apply aggregations across columns matching a predicate
summary = orders.group_by("region").aggregate(
    s.numeric().sum()  # sum all numeric columns
)
print(summary.execute())
