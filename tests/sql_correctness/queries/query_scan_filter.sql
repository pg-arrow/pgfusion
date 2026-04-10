-- Full table scans and range filter queries
-- Tests: sequential scan, column projection, comparison predicates,
-- ORDER BY, LIMIT, and BETWEEN range expressions.

-- Return all columns from branches. Small table (1 row per scale factor),
-- exercises full-row projection with SELECT *.
SELECT * FROM pgbench_branches;

-- Return all columns from tellers. Slightly larger (10 rows per scale factor),
-- same full-row projection test.
SELECT * FROM pgbench_tellers;

-- Find all accounts with a positive balance. After pgbench init most balances
-- are zero, so this tests a selective filter that returns few rows from a large scan.
SELECT aid, abalance FROM pgbench_accounts WHERE abalance > 0;

-- Find all accounts with a negative balance. Same selectivity characteristics
-- as the positive filter but tests the less-than comparison path.
SELECT aid, abalance FROM pgbench_accounts WHERE abalance < 0;

-- Accounts in branch 1, ordered by aid, capped at 20 rows. Tests: equality
-- filter on a non-primary column (bid), ORDER BY on the primary key, and
-- LIMIT to truncate output early.
SELECT aid, bid, abalance FROM pgbench_accounts WHERE bid = 1 ORDER BY aid LIMIT 20;

-- Accounts in the aid range [1000, 2000], ordered by aid. Tests: BETWEEN
-- range predicate (compiled to aid >= 1000 AND aid <= 2000), sorted output.
SELECT aid, abalance FROM pgbench_accounts WHERE aid BETWEEN 1000 AND 2000 ORDER BY aid;
