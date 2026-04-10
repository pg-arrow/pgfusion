-- History table analysis queries
-- The pgbench_history table records one row per completed transaction (INSERT-only,
-- no primary key). These queries aggregate the transaction log to find patterns.
-- Tests: GROUP BY, ORDER BY DESC, LIMIT (top-N), and multi-aggregate expressions.

-- Total number of history records. Baseline count to verify all transaction
-- log rows are visible.
SELECT COUNT(*) FROM pgbench_history;

-- Top 10 tellers by transaction count, with the sum of deltas applied.
-- Identifies which tellers processed the most transactions.
-- Tests: GROUP BY + ORDER BY DESC + LIMIT for a top-N pattern.
SELECT tid, COUNT(*) AS txn_count, SUM(delta) AS total_delta
FROM pgbench_history
GROUP BY tid
ORDER BY txn_count DESC
LIMIT 10;

-- Per-branch transaction summary: count, total delta, and average delta.
-- Shows the transaction volume and net balance change per branch.
-- Tests: GROUP BY with three aggregate functions, sorted output.
SELECT bid, COUNT(*) AS txn_count, SUM(delta) AS total_delta, AVG(delta) AS avg_delta
FROM pgbench_history
GROUP BY bid
ORDER BY bid;

-- Top 20 most frequently transacted accounts. Finds accounts that appear
-- most often in the history log, useful for hot-spot detection.
-- Tests: GROUP BY on a high-cardinality column (aid), ORDER BY DESC + LIMIT.
SELECT aid, COUNT(*) AS txn_count
FROM pgbench_history
GROUP BY aid
ORDER BY txn_count DESC
LIMIT 20;
