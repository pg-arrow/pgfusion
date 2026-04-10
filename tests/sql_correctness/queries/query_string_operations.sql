-- String operations and NULL handling on the filler column
-- pgbench_accounts has a `filler` CHAR(84) column padded with spaces.
-- pgbench_history has a `filler` CHAR(22) column.
-- These queries exercise string functions, LIKE patterns, CAST, and NULL logic.

-- Check how many accounts have a non-null filler value. After pgbench init,
-- filler is space-padded but not NULL; verifies the reader handles CHAR(84).
-- Tests: IS NOT NULL predicate, COUNT with filter.
SELECT COUNT(*) AS non_null_fillers
FROM pgbench_accounts
WHERE filler IS NOT NULL;

-- Cast integer aid to a string and concatenate with a label. Exercises
-- integer-to-string CAST and the || concatenation operator.
-- Tests: CAST(int AS VARCHAR), string concatenation.
SELECT aid, 'account_' || CAST(aid AS VARCHAR) AS account_label, abalance
FROM pgbench_accounts
WHERE aid <= 10
ORDER BY aid;

-- COALESCE chain: if abalance is zero (common after pgbench init), substitute
-- a marker value. Demonstrates multi-argument COALESCE and NULLIF.
-- NULLIF(abalance, 0) returns NULL when balance is 0, then COALESCE replaces
-- that NULL with -999.
-- Tests: NULLIF, COALESCE, conditional value replacement.
SELECT aid,
       abalance,
       NULLIF(abalance, 0) AS balance_or_null,
       COALESCE(NULLIF(abalance, 0), -999) AS balance_or_marker
FROM pgbench_accounts
WHERE aid <= 20
ORDER BY aid;

-- Length of the filler column. CHAR(84) should always be 84 bytes when
-- not NULL. Validates fixed-width string handling.
-- Tests: LENGTH function on CHAR type.
SELECT aid, LENGTH(filler) AS filler_len
FROM pgbench_accounts
WHERE aid <= 5;

-- UPPER/LOWER on a constructed string. Builds a mixed-case label then
-- transforms it both ways.
-- Tests: UPPER, LOWER, nested string expressions.
SELECT aid,
       UPPER('branch_' || CAST(bid AS VARCHAR)) AS upper_label,
       LOWER('ACCOUNT_' || CAST(aid AS VARCHAR)) AS lower_label
FROM pgbench_accounts
WHERE aid <= 10
ORDER BY aid;

-- TRIM the space-padded filler column and check its trimmed length.
-- CHAR(84) pads with spaces; TRIM should remove them.
-- Tests: TRIM function, CHAR padding behavior.
SELECT aid,
       LENGTH(filler) AS raw_len,
       LENGTH(TRIM(filler)) AS trimmed_len
FROM pgbench_accounts
WHERE aid <= 5;
