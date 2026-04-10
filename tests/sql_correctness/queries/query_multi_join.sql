-- Multi-table join queries (3+ tables)
-- Tests: three-way and four-way joins, mixed join types (INNER + LEFT),
-- join ordering effects, and joins with aggregation.

-- Three-way inner join: accounts -> branches -> tellers, connecting through
-- the common bid column. Returns a combined view for the first 10 accounts.
-- The optimizer must decide join order (accounts-branches then tellers, or
-- accounts-tellers then branches).
-- Tests: three-table INNER JOIN, join order optimization.
SELECT a.aid, a.abalance,
       b.bid, b.bbalance,
       t.tid, t.tbalance
FROM pgbench_accounts a
JOIN pgbench_branches b ON a.bid = b.bid
JOIN pgbench_tellers t ON a.bid = t.bid
WHERE a.aid <= 10
ORDER BY a.aid, t.tid;

-- Four-way join: accounts + branches + tellers + history. Connects an account
-- to its branch, all tellers in that branch, and any history records for
-- that account. Uses INNER JOINs throughout, so only accounts with history
-- appear.
-- Tests: four-table join, multiple join predicates, high fan-out control.
SELECT a.aid, a.abalance,
       b.bbalance,
       t.tid, t.tbalance,
       h.delta, h.mtime
FROM pgbench_accounts a
JOIN pgbench_branches b ON a.bid = b.bid
JOIN pgbench_tellers t ON t.bid = b.bid
JOIN pgbench_history h ON h.aid = a.aid
WHERE a.aid <= 5
ORDER BY a.aid, t.tid, h.mtime;

-- Mixed join types: LEFT JOIN history onto accounts so accounts without
-- transactions still appear (with NULL history columns), then INNER JOIN
-- to branches. Demonstrates that join type matters for result completeness.
-- Tests: LEFT JOIN + INNER JOIN combination, NULL propagation from outer join.
SELECT a.aid, a.abalance,
       b.bbalance,
       h.delta,
       COALESCE(h.delta, 0) AS delta_or_zero
FROM pgbench_accounts a
JOIN pgbench_branches b ON a.bid = b.bid
LEFT JOIN pgbench_history h ON h.aid = a.aid
WHERE a.aid <= 20
ORDER BY a.aid;

-- Join with aggregation: for each branch, count accounts and sum their
-- balances (from accounts), count tellers (from tellers), and count
-- transactions (from history). Uses LEFT JOINs so branches with no history
-- still appear.
-- Tests: multi-table LEFT JOIN with GROUP BY, multiple COUNT DISTINCT patterns.
SELECT b.bid, b.bbalance,
       COUNT(DISTINCT a.aid) AS num_accounts,
       SUM(a.abalance) AS total_account_balance,
       COUNT(DISTINCT t.tid) AS num_tellers,
       COUNT(h.tid) AS num_transactions
FROM pgbench_branches b
LEFT JOIN pgbench_accounts a ON a.bid = b.bid
LEFT JOIN pgbench_tellers t ON t.bid = b.bid
LEFT JOIN pgbench_history h ON h.bid = b.bid
GROUP BY b.bid, b.bbalance
ORDER BY b.bid;

-- Semi-join pattern via EXISTS: find accounts that have at least one history
-- record AND whose branch has more than 5 tellers. Chains two EXISTS checks.
-- Tests: multiple correlated EXISTS, semi-join optimization.
SELECT a.aid, a.bid, a.abalance
FROM pgbench_accounts a
WHERE EXISTS (
    SELECT 1 FROM pgbench_history h WHERE h.aid = a.aid
)
AND EXISTS (
    SELECT 1 FROM pgbench_tellers t WHERE t.bid = a.bid
    HAVING COUNT(*) > 5
)
ORDER BY a.aid
LIMIT 20;
