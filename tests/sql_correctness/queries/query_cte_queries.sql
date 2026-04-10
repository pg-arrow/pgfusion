-- Common Table Expression (CTE) queries
-- Tests: WITH clause materialization, CTE joined to base tables,
-- chained CTEs, CTE with HAVING, and CTE with window functions.

-- Compute full aggregate statistics per branch in a CTE, then join back
-- to pgbench_branches to display branch-level metadata alongside the
-- computed stats. Ordered by total balance descending to highlight the
-- wealthiest branches.
-- Tests: single CTE with GROUP BY + multiple aggregates, CTE-to-table JOIN.
WITH branch_stats AS (
    SELECT bid,
           COUNT(*) AS num_accounts,
           SUM(abalance) AS total_balance,
           AVG(abalance) AS avg_balance,
           MIN(abalance) AS min_balance,
           MAX(abalance) AS max_balance
    FROM pgbench_accounts
    GROUP BY bid
)
SELECT b.bid, b.bbalance, s.num_accounts, s.total_balance, s.avg_balance
FROM pgbench_branches b
JOIN branch_stats s ON b.bid = s.bid
ORDER BY s.total_balance DESC;

-- Two chained CTEs: first identifies "hot" accounts (those with more than
-- one history entry) using HAVING, then enriches them with account details.
-- The outer query aggregates per branch to see which branches have the most
-- frequently transacted accounts.
-- Tests: chained CTEs, HAVING filter, CTE-to-CTE dependency, final GROUP BY.
WITH hot_accounts AS (
    SELECT aid, COUNT(*) AS txn_count, SUM(delta) AS net_delta
    FROM pgbench_history
    GROUP BY aid
    HAVING COUNT(*) > 1
),
account_info AS (
    SELECT a.aid, a.bid, a.abalance, h.txn_count, h.net_delta
    FROM pgbench_accounts a
    JOIN hot_accounts h ON a.aid = h.aid
)
SELECT ai.bid, COUNT(*) AS hot_count, AVG(ai.txn_count) AS avg_txns
FROM account_info ai
GROUP BY ai.bid
ORDER BY hot_count DESC;

-- CTE using a window function (RANK) to rank tellers within each branch
-- by balance, then filters to only the top-ranked teller per branch and
-- joins to branches for context.
-- Tests: window function inside CTE, CTE with WHERE filter, CTE-to-table JOIN.
WITH ranked_tellers AS (
    SELECT t.tid, t.bid, t.tbalance,
           RANK() OVER (PARTITION BY t.bid ORDER BY t.tbalance DESC) AS rnk
    FROM pgbench_tellers t
)
SELECT r.tid, r.bid, r.tbalance, r.rnk, b.bbalance
FROM ranked_tellers r
JOIN pgbench_branches b ON r.bid = b.bid
WHERE r.rnk = 1
ORDER BY r.bid;
