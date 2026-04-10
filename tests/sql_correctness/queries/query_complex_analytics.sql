-- Complex analytic and multi-level aggregation queries
-- Tests: CASE expressions, LEFT JOIN with derived tables, multi-CTE pipelines,
-- top-N-per-group via window functions, self-joins, NOT EXISTS anti-joins,
-- and correlated subqueries with computed thresholds.

-- Bucket every account balance into one of five categories using CASE, then
-- count accounts and find min/max within each bucket. The CASE expression
-- must appear identically in SELECT and GROUP BY since there is no alias
-- reference in standard SQL GROUP BY.
-- Tests: CASE expression evaluation, GROUP BY on a computed expression.
SELECT
    CASE
        WHEN abalance < -1000 THEN 'very_negative'
        WHEN abalance < 0     THEN 'negative'
        WHEN abalance = 0     THEN 'zero'
        WHEN abalance < 1000  THEN 'positive'
        ELSE                       'very_positive'
    END AS balance_bucket,
    COUNT(*) AS num_accounts,
    MIN(abalance) AS min_bal,
    MAX(abalance) AS max_bal
FROM pgbench_accounts
GROUP BY
    CASE
        WHEN abalance < -1000 THEN 'very_negative'
        WHEN abalance < 0     THEN 'negative'
        WHEN abalance = 0     THEN 'zero'
        WHEN abalance < 1000  THEN 'positive'
        ELSE                       'very_positive'
    END
ORDER BY min_bal;

-- Branch health check: compare each branch's stored bbalance against the
-- actual sum of its account balances. A non-zero discrepancy indicates the
-- branch balance is out of sync with its accounts (expected after pgbench
-- transactions). Uses LEFT JOIN so branches with no accounts still appear.
-- Tests: LEFT JOIN to derived table, COALESCE for NULL handling, ABS in ORDER BY.
SELECT b.bid,
       b.bbalance AS reported_balance,
       COALESCE(a.actual_balance, 0) AS actual_balance,
       b.bbalance - COALESCE(a.actual_balance, 0) AS discrepancy
FROM pgbench_branches b
LEFT JOIN (
    SELECT bid, SUM(abalance) AS actual_balance
    FROM pgbench_accounts
    GROUP BY bid
) a ON b.bid = a.bid
ORDER BY ABS(b.bbalance - COALESCE(a.actual_balance, 0)) DESC;

-- Two-level CTE pipeline: first CTE aggregates history by (tid, bid) to get
-- per-teller transaction stats; second CTE rolls those up to per-branch totals.
-- The final SELECT joins both to compute each teller's percentage share of
-- their branch's total transactions.
-- Tests: chained CTEs, CAST to DOUBLE for division, percentage computation.
WITH teller_stats AS (
    SELECT h.tid, h.bid,
           COUNT(*) AS txn_count,
           SUM(delta) AS total_delta,
           AVG(delta) AS avg_delta
    FROM pgbench_history h
    GROUP BY h.tid, h.bid
),
branch_totals AS (
    SELECT bid,
           SUM(txn_count) AS branch_txns,
           SUM(total_delta) AS branch_delta
    FROM teller_stats
    GROUP BY bid
)
SELECT ts.tid, ts.bid, ts.txn_count, ts.total_delta,
       bt.branch_txns,
       CAST(ts.txn_count AS DOUBLE) / bt.branch_txns * 100.0 AS pct_of_branch_txns
FROM teller_stats ts
JOIN branch_totals bt ON ts.bid = bt.bid
ORDER BY ts.bid, ts.txn_count DESC;

-- Top-3 accounts per branch by absolute balance magnitude. Uses ROW_NUMBER
-- with PARTITION BY bid to rank accounts within each branch, then filters
-- to keep only the top 3. Classic "top-N per group" pattern.
-- Tests: ROW_NUMBER window function, ABS in ORDER BY, post-window filter.
WITH ranked AS (
    SELECT aid, bid, abalance,
           ROW_NUMBER() OVER (PARTITION BY bid ORDER BY ABS(abalance) DESC) AS rn
    FROM pgbench_accounts
)
SELECT aid, bid, abalance
FROM ranked
WHERE rn <= 3
ORDER BY bid, rn;

-- Self-join on pgbench_accounts: find pairs of distinct accounts in the same
-- branch that have the exact same non-zero balance. The a1.aid < a2.aid
-- condition avoids duplicate pairs and self-matches.
-- Tests: self-join, multi-column join predicate, inequality to break symmetry.
SELECT a1.aid AS aid1, a2.aid AS aid2, a1.bid, a1.abalance
FROM pgbench_accounts a1
JOIN pgbench_accounts a2
    ON a1.bid = a2.bid AND a1.abalance = a2.abalance AND a1.aid < a2.aid
WHERE a1.abalance != 0
ORDER BY a1.bid, a1.abalance
LIMIT 50;

-- Anti-join via NOT EXISTS: find branches that have zero transaction history.
-- For each branch row, the subquery checks for any matching history row;
-- branches with no match are returned.
-- Tests: NOT EXISTS anti-join pattern, correlated subquery short-circuit.
SELECT b.bid, b.bbalance
FROM pgbench_branches b
WHERE NOT EXISTS (
    SELECT 1 FROM pgbench_history h WHERE h.bid = b.bid
);

-- Find accounts whose absolute balance exceeds twice their branch's average
-- absolute balance (outlier detection). A derived table computes per-branch
-- averages, then the outer query joins and filters. Branches with zero
-- average are excluded to avoid division-by-zero edge cases.
-- Tests: derived table join, ABS on both sides of comparison, compound WHERE.
SELECT a.aid, a.bid, a.abalance, branch_avg
FROM pgbench_accounts a
JOIN (
    SELECT bid, AVG(abalance) AS branch_avg
    FROM pgbench_accounts
    GROUP BY bid
) ba ON a.bid = ba.bid
WHERE ABS(a.abalance) > ABS(ba.branch_avg) * 2 AND ba.branch_avg != 0
ORDER BY ABS(a.abalance) DESC
LIMIT 30;
