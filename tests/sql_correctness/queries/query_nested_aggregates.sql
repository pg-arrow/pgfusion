-- Nested and multi-pass aggregation queries
-- SQL forbids aggregate-of-aggregate directly (e.g. AVG(COUNT(*))), so these
-- use subqueries or CTEs to compute inner aggregates first, then aggregate
-- the results again. Tests multi-pass aggregation patterns.

-- Average number of accounts per branch. Inner query counts per branch,
-- outer query averages those counts.
-- Tests: subquery aggregation feeding outer AVG, two-pass pattern.
SELECT AVG(account_count) AS avg_accounts_per_branch,
       MIN(account_count) AS min_accounts,
       MAX(account_count) AS max_accounts
FROM (
    SELECT bid, COUNT(*) AS account_count
    FROM pgbench_accounts
    GROUP BY bid
) per_branch;

-- Standard deviation of per-teller transaction counts. Inner query counts
-- transactions per teller, outer computes statistical aggregates.
-- Tests: STDDEV aggregate, two-pass aggregation.
SELECT AVG(txn_count) AS mean_txns,
       MIN(txn_count) AS min_txns,
       MAX(txn_count) AS max_txns,
       STDDEV(txn_count) AS stddev_txns
FROM (
    SELECT tid, COUNT(*) AS txn_count
    FROM pgbench_history
    GROUP BY tid
) per_teller;

-- Three-level aggregation: (1) count transactions per (bid, tid) pair,
-- (2) average those counts per branch, (3) find the branch with the
-- highest average teller activity.
-- Tests: three-level nested aggregation via CTEs.
WITH per_teller AS (
    SELECT bid, tid, COUNT(*) AS txn_count
    FROM pgbench_history
    GROUP BY bid, tid
),
per_branch AS (
    SELECT bid,
           AVG(txn_count) AS avg_teller_txns,
           MAX(txn_count) AS max_teller_txns
    FROM per_teller
    GROUP BY bid
)
SELECT bid, avg_teller_txns, max_teller_txns
FROM per_branch
ORDER BY avg_teller_txns DESC;

-- Compare each branch's account count to the global average account count.
-- Uses a CTE for the per-branch counts and a scalar subquery for the global avg.
-- Tests: scalar subquery inside SELECT alongside CTE, mixed aggregation sources.
WITH branch_counts AS (
    SELECT bid, COUNT(*) AS cnt
    FROM pgbench_accounts
    GROUP BY bid
)
SELECT bid, cnt,
       cnt - (SELECT AVG(cnt) FROM branch_counts) AS deviation_from_avg
FROM branch_counts
ORDER BY deviation_from_avg DESC;

-- Aggregate of conditional aggregates: count branches that are "large"
-- (> 1000 accounts) vs "small". Inner query classifies, outer counts.
-- Tests: CASE inside aggregate, two-pass classification + count.
SELECT size_class, COUNT(*) AS num_branches, SUM(account_count) AS total_accounts
FROM (
    SELECT bid,
           COUNT(*) AS account_count,
           CASE WHEN COUNT(*) > 1000 THEN 'large' ELSE 'small' END AS size_class
    FROM pgbench_accounts
    GROUP BY bid
) classified
GROUP BY size_class
ORDER BY size_class;
