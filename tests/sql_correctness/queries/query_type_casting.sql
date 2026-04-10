-- Type casting and arithmetic precision queries
-- Tests: explicit CAST between types, integer vs float division, arithmetic
-- overflow awareness, and mixed-type expressions.

-- Integer division vs float division: dividing two integers truncates in SQL;
-- casting one operand to DOUBLE produces a fractional result.
-- Tests: integer division truncation, CAST to DOUBLE for precise division.
SELECT bid,
       SUM(abalance) / COUNT(*) AS int_avg,
       CAST(SUM(abalance) AS DOUBLE) / COUNT(*) AS float_avg
FROM pgbench_accounts
GROUP BY bid
ORDER BY bid;

-- Cast aid (integer) to various types and verify round-trip behavior.
-- Tests: CAST to VARCHAR, CAST to BIGINT, CAST to DOUBLE.
SELECT aid,
       CAST(aid AS VARCHAR) AS aid_str,
       CAST(aid AS BIGINT) AS aid_bigint,
       CAST(aid AS DOUBLE) AS aid_double
FROM pgbench_accounts
WHERE aid <= 5
ORDER BY aid;

-- Arithmetic with mixed types: multiply integer balance by a float constant.
-- The result should be DOUBLE (type promotion). Also test integer modulo.
-- Tests: implicit type promotion, float literal arithmetic, modulo operator.
SELECT aid, abalance,
       abalance * 1.05 AS balance_with_interest,
       abalance * 0.10 AS ten_pct,
       abalance % 100 AS last_two_digits
FROM pgbench_accounts
WHERE aid <= 10
ORDER BY aid;

-- Large value arithmetic: multiply balance by a big constant to test whether
-- the engine handles large intermediate values without overflow. At scale
-- factor 1, balances are small, but the pattern matters.
-- Tests: large multiplier, potential integer overflow paths.
SELECT aid, abalance,
       CAST(abalance AS BIGINT) * 1000000 AS scaled_up,
       CAST(abalance AS DOUBLE) / 3.0 AS third
FROM pgbench_accounts
WHERE abalance != 0
ORDER BY ABS(abalance) DESC
LIMIT 20;

-- Boolean expression results: compute boolean-like columns using CASE, since
-- SQL doesn't always have a native boolean output in SELECT. Also shows
-- that comparison operators produce usable results in expressions.
-- Tests: comparison in CASE, IS NULL check, mixed boolean conditions.
SELECT a.aid, a.abalance,
       CASE WHEN a.abalance > 0 THEN 'true' ELSE 'false' END AS is_positive,
       CASE WHEN a.abalance = 0 THEN 'true' ELSE 'false' END AS is_zero,
       CASE WHEN h.aid IS NOT NULL THEN 'true' ELSE 'false' END AS has_history
FROM pgbench_accounts a
LEFT JOIN (SELECT DISTINCT aid FROM pgbench_history) h ON a.aid = h.aid
WHERE a.aid <= 20
ORDER BY a.aid;
