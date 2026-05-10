-- Example: DuckDB querying pgfusion_server via Arrow Flight SQL.
--
-- DuckDB speaks Flight SQL natively via the arrow extension.
-- Zero ETL: DuckDB sends SQL, gets Arrow IPC back, joins with local data.
--
-- Run:
--   pgfusion_server -d /path/to/pgdata --db-id 16384 --port 32010
--   duckdb

-- Attach pgfusion as a Flight SQL data source
ATTACH 'grpc://localhost:32010' AS pg (TYPE flight_sql);

-- Query pg tables directly — result is Arrow, stays columnar through DuckDB
SELECT region, sum(revenue)
FROM pg.orders
GROUP BY region
ORDER BY sum(revenue) DESC;

-- Join pg data with a local Parquet file — DuckDB handles the merge
SELECT o.region, p.population, sum(o.revenue) / p.population AS revenue_per_capita
FROM pg.orders o
JOIN read_parquet('population.parquet') p ON o.region = p.region
GROUP BY o.region, p.population;

-- DuckDB pushes predicates to pgfusion via Flight SQL
-- pgfusion evaluates WHERE in DataFusion before sending batches
SELECT * FROM pg.users WHERE created_at > '2025-01-01';
