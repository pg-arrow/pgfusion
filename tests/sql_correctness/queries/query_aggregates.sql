-- Aggregate queries on pgbench tables
-- Tests: full-table scans for COUNT(*), grouped aggregation with multiple
-- aggregate functions, and global (ungrouped) aggregates.

-- Row counts for each table. Validates that the reader sees all tuples
-- (100k accounts, 1 branch, 10 tellers, and N history rows at scale factor 1).
SELECT COUNT(*) FROM pgbench_accounts;
SELECT COUNT(*) FROM pgbench_branches;
SELECT COUNT(*) FROM pgbench_tellers;
SELECT COUNT(*) FROM pgbench_history;

-- Per-branch account statistics: count, total balance, and average balance.
-- Groups the entire accounts table by bid and sorts by branch id.
-- Tests: hash/sort aggregation with GROUP BY, multiple aggregate expressions.
SELECT bid, COUNT(*) AS num_accounts, SUM(abalance) AS total_balance, AVG(abalance) AS avg_balance
FROM pgbench_accounts
GROUP BY bid
ORDER BY bid;

-- Per-branch teller summary: total teller balance and teller count.
-- Smaller dataset than accounts, tests GROUP BY on a compact table.
SELECT bid, SUM(tbalance) AS total_teller_balance, COUNT(*) AS num_tellers
FROM pgbench_tellers
GROUP BY bid
ORDER BY bid;

-- Global min, max, and average across all account balances.
-- Single output row, full table scan. Tests: ungrouped aggregate over large table.
SELECT MIN(abalance), MAX(abalance), AVG(abalance)
FROM pgbench_accounts;
