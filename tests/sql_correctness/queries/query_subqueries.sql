-- Subquery and analytic-style queries
-- Tests: scalar subqueries in WHERE, derived tables (inline views) in FROM,
-- and correlated scalar subqueries in the SELECT list.

-- Find the top 20 accounts whose balance exceeds the global average.
-- The WHERE clause contains a scalar subquery that computes AVG(abalance)
-- over the entire accounts table, then the outer query filters and sorts.
-- Tests: scalar subquery evaluation, comparison against subquery result.
SELECT a.aid, a.abalance
FROM pgbench_accounts a
WHERE a.abalance > (SELECT AVG(abalance) FROM pgbench_accounts)
ORDER BY a.abalance DESC
LIMIT 20;

-- Count accounts per branch using a derived table (subquery in FROM).
-- The inner query groups and counts, the outer query just re-orders.
-- Tests: derived table materialization, GROUP BY inside a subquery.
SELECT bid, num_accounts
FROM (
    SELECT bid, COUNT(*) AS num_accounts
    FROM pgbench_accounts
    GROUP BY bid
) sub
ORDER BY num_accounts DESC;

-- For each branch, compute the number of accounts and tellers using
-- correlated scalar subqueries in the SELECT list. Each subquery runs
-- once per branch row, counting matching rows in the referenced table.
-- Tests: correlated subquery execution, per-row subquery evaluation.
SELECT b.bid, b.bbalance,
       (SELECT COUNT(*) FROM pgbench_accounts a WHERE a.bid = b.bid) AS account_count,
       (SELECT COUNT(*) FROM pgbench_tellers t WHERE t.bid = b.bid) AS teller_count
FROM pgbench_branches b
ORDER BY b.bid;
