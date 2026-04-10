-- Cross join and cartesian product queries
-- Tests: explicit CROSS JOIN, implicit cartesian product (comma syntax),
-- and controlled cartesian products with LIMIT to avoid blowup.

-- Explicit CROSS JOIN between branches and tellers. With scale factor 1
-- this produces 1 * 10 = 10 rows. Every branch is paired with every teller.
-- Tests: CROSS JOIN execution, cartesian product materialization.
SELECT b.bid, b.bbalance, t.tid, t.tbalance
FROM pgbench_branches b
CROSS JOIN pgbench_tellers t
ORDER BY b.bid, t.tid;

-- Implicit cartesian product using comma syntax in FROM. Equivalent to the
-- CROSS JOIN above but uses the older SQL-89 style.
-- Tests: implicit join parsing, equivalence with explicit CROSS JOIN.
SELECT b.bid, t.tid, b.bbalance + t.tbalance AS combined_balance
FROM pgbench_branches b, pgbench_tellers t
ORDER BY b.bid, t.tid;

-- Self cross-join on branches: produces all branch pairs. With 1 branch at
-- scale factor 1, this is trivial; at higher scale factors it tests
-- quadratic growth handling. Filtered to exclude self-pairs.
-- Tests: self cross-join, inequality filter on cartesian result.
SELECT b1.bid AS bid1, b2.bid AS bid2,
       b1.bbalance AS balance1, b2.bbalance AS balance2,
       b1.bbalance - b2.bbalance AS balance_diff
FROM pgbench_branches b1
CROSS JOIN pgbench_branches b2
WHERE b1.bid < b2.bid
ORDER BY b1.bid, b2.bid;

-- Controlled cartesian: cross-join a small account subset (5 rows) with all
-- tellers (10 rows), producing 50 rows. Shows per-account comparison with
-- every teller's balance.
-- Tests: CROSS JOIN with pre-filtered subquery to control output size.
SELECT a.aid, a.abalance, t.tid, t.tbalance,
       a.abalance - t.tbalance AS diff
FROM (SELECT aid, abalance FROM pgbench_accounts WHERE aid <= 5) a
CROSS JOIN pgbench_tellers t
ORDER BY a.aid, t.tid;
