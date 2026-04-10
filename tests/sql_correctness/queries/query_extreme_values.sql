-- Extreme value and boundary queries
-- Tests: MIN/MAX combinations, first/last row patterns, boundary detection,
-- and queries that stress edge cases in data distribution.

-- Global extremes: the single richest and poorest accounts.
-- Tests: ORDER BY + LIMIT 1 for min/max row retrieval (alternative to aggregate).
SELECT aid, abalance FROM pgbench_accounts ORDER BY abalance DESC LIMIT 1;
SELECT aid, abalance FROM pgbench_accounts ORDER BY abalance ASC LIMIT 1;

-- First and last account by primary key. Verifies the full aid range is
-- readable and the sort order is correct at the boundaries.
-- Tests: boundary row access, ascending vs descending.
SELECT aid, bid, abalance FROM pgbench_accounts ORDER BY aid ASC LIMIT 1;
SELECT aid, bid, abalance FROM pgbench_accounts ORDER BY aid DESC LIMIT 1;

-- Per-branch extremes: find the min and max balance in each branch alongside
-- the range (max - min). Useful for detecting branches with high variance.
-- Tests: GROUP BY with MIN, MAX, and computed column.
SELECT bid,
       MIN(abalance) AS min_balance,
       MAX(abalance) AS max_balance,
       MAX(abalance) - MIN(abalance) AS balance_range
FROM pgbench_accounts
GROUP BY bid
ORDER BY balance_range DESC;

-- Find the account(s) with the exact minimum balance (there may be ties).
-- Uses a scalar subquery to compute the MIN, then filters for matching rows.
-- Tests: scalar subquery in WHERE, equality on aggregate result.
SELECT aid, bid, abalance
FROM pgbench_accounts
WHERE abalance = (SELECT MIN(abalance) FROM pgbench_accounts)
ORDER BY aid;

-- Accounts at the boundaries of each branch: first and last aid per branch.
-- Uses window functions to tag the first and last row without self-joining.
-- Tests: FIRST_VALUE / LAST_VALUE window functions with frame specification.
SELECT DISTINCT bid,
       FIRST_VALUE(aid) OVER (PARTITION BY bid ORDER BY aid ASC
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_aid,
       LAST_VALUE(aid) OVER (PARTITION BY bid ORDER BY aid ASC
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_aid,
       FIRST_VALUE(abalance) OVER (PARTITION BY bid ORDER BY aid ASC
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_balance,
       LAST_VALUE(abalance) OVER (PARTITION BY bid ORDER BY aid ASC
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_balance
FROM pgbench_accounts
ORDER BY bid;

-- Count accounts at the exact global average balance (unlikely to be exact,
-- so also count within +/- 1 of average). Exercises rounding edge cases.
-- Tests: scalar subquery, BETWEEN with computed bounds, ABS comparison.
SELECT
    (SELECT COUNT(*) FROM pgbench_accounts
     WHERE abalance = (SELECT CAST(AVG(abalance) AS INT) FROM pgbench_accounts)
    ) AS exact_avg_count,
    (SELECT COUNT(*) FROM pgbench_accounts
     WHERE ABS(abalance - (SELECT AVG(abalance) FROM pgbench_accounts)) <= 1
    ) AS near_avg_count;
