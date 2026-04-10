-- pgbench built-in: simple-update select portion
-- Mirrors the SELECT phase of pgbench's default "simple-update" transaction profile.
-- In the full pgbench transaction, this SELECT fetches the current balance before
-- applying an UPDATE+INSERT. Here we run only the read portion.
--
-- Each query performs a primary-key point lookup on pgbench_accounts.
-- Tests: index seek (or full-scan + filter), single-row projection, integer equality.

-- Fetch balance for account 1 (lowest aid, always exists after pgbench -i).
SELECT abalance FROM pgbench_accounts WHERE aid = 1;

-- Fetch balance for account 100 (low aid range).
SELECT abalance FROM pgbench_accounts WHERE aid = 100;

-- Fetch balance for account 50000 (mid-range aid, exercises deeper page reads).
SELECT abalance FROM pgbench_accounts WHERE aid = 50000;
