-- pgbench built-in: select-only (-S flag)
-- Simulates pgbench's pure read-only workload. The real pgbench picks a random aid
-- per iteration; here we use fixed aids spanning several orders of magnitude to
-- exercise different regions of the accounts table.
--
-- Tests: repeated point lookups, single-column projection, integer equality filter.
-- Useful for benchmarking per-query overhead and filter pushdown.

-- Lookup at the very start of the table.
SELECT abalance FROM pgbench_accounts WHERE aid = 1;

-- Lookup in the first page neighborhood.
SELECT abalance FROM pgbench_accounts WHERE aid = 10;

-- Lookup around the 100th row.
SELECT abalance FROM pgbench_accounts WHERE aid = 100;

-- Lookup in the middle of a scale-factor=10 dataset (10k accounts).
SELECT abalance FROM pgbench_accounts WHERE aid = 1000;

-- Lookup near the end of a scale-factor=10 dataset.
SELECT abalance FROM pgbench_accounts WHERE aid = 10000;
