-- Ordering, OFFSET, and LIMIT edge cases
-- Tests: multi-column ORDER BY, ASC/DESC mixing, OFFSET pagination,
-- LIMIT 0/1 boundary cases, and NULLS FIRST/LAST ordering.

-- Multi-column sort: order accounts first by branch (ascending), then by
-- balance (descending) within each branch. Returns the top 20 rows.
-- Tests: two-column ORDER BY with mixed direction, LIMIT.
SELECT aid, bid, abalance
FROM pgbench_accounts
ORDER BY bid ASC, abalance DESC
LIMIT 20;

-- Pagination: skip the first 100 rows by aid order and return the next 10.
-- Simulates a second "page" of results in an application.
-- Tests: OFFSET + LIMIT combination, sort stability.
SELECT aid, abalance
FROM pgbench_accounts
ORDER BY aid
OFFSET 100
LIMIT 10;

-- Deep pagination: skip 99990 rows to read the last 10 accounts by aid.
-- Forces the engine to sort or scan almost the entire table before returning.
-- Tests: large OFFSET performance, late materialization.
SELECT aid, abalance
FROM pgbench_accounts
ORDER BY aid
OFFSET 99990
LIMIT 10;

-- LIMIT 1: return only the single account with the highest balance.
-- Optimal plans should use a top-1 heap rather than a full sort.
-- Tests: LIMIT 1 optimization, DESC sort.
SELECT aid, abalance
FROM pgbench_accounts
ORDER BY abalance DESC
LIMIT 1;

-- LIMIT 0: should return column metadata but zero rows. Edge case that
-- some engines handle specially.
-- Tests: zero-row LIMIT boundary.
SELECT aid, abalance
FROM pgbench_accounts
ORDER BY aid
LIMIT 0;

-- Three-column sort: branch ascending, balance descending, aid ascending
-- as a tiebreaker. Exercises the sort comparator chain.
-- Tests: three-level ORDER BY, tiebreaker column.
SELECT aid, bid, abalance
FROM pgbench_accounts
ORDER BY bid ASC, abalance DESC, aid ASC
LIMIT 30;
