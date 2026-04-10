-- HAVING clause queries
-- Tests: HAVING vs WHERE distinction (WHERE filters rows before aggregation,
-- HAVING filters groups after aggregation), HAVING with multiple predicates,
-- and HAVING on computed aggregate expressions.

-- Branches where the account count exceeds 50. The WHERE clause is absent,
-- so all rows are aggregated, then HAVING filters the groups.
-- Tests: basic HAVING with COUNT.
SELECT bid, COUNT(*) AS num_accounts
FROM pgbench_accounts
GROUP BY bid
HAVING COUNT(*) > 50
ORDER BY num_accounts DESC;

-- Branches where the average account balance is negative. Identifies branches
-- that are net-negative overall.
-- Tests: HAVING on AVG, negative comparison.
SELECT bid, AVG(abalance) AS avg_balance, COUNT(*) AS num_accounts
FROM pgbench_accounts
GROUP BY bid
HAVING AVG(abalance) < 0
ORDER BY avg_balance;

-- Combined WHERE + HAVING: first filter to non-zero balances (WHERE), then
-- group by branch and keep only groups with more than 5 such accounts (HAVING).
-- Tests: WHERE pre-filter combined with HAVING post-filter.
SELECT bid, COUNT(*) AS nonzero_count, SUM(abalance) AS total_nonzero
FROM pgbench_accounts
WHERE abalance != 0
GROUP BY bid
HAVING COUNT(*) > 5
ORDER BY nonzero_count DESC;

-- HAVING with a compound predicate: branches that have both high transaction
-- count AND significant total delta in the history table.
-- Tests: HAVING with AND combining two aggregate conditions.
SELECT bid,
       COUNT(*) AS txn_count,
       SUM(delta) AS total_delta,
       AVG(delta) AS avg_delta
FROM pgbench_history
GROUP BY bid
HAVING COUNT(*) > 10 AND ABS(SUM(delta)) > 100
ORDER BY txn_count DESC;

-- HAVING comparing two different aggregates against each other: find branches
-- where the maximum balance exceeds 10x the average balance (outlier branches).
-- Tests: HAVING with inter-aggregate comparison.
SELECT bid,
       MAX(abalance) AS max_bal,
       AVG(abalance) AS avg_bal
FROM pgbench_accounts
GROUP BY bid
HAVING MAX(abalance) > AVG(abalance) * 10
ORDER BY bid;
