-- Conditional logic and NULL handling queries
-- Tests: CASE with aggregates, NULLIF, COALESCE chains, conditional
-- counting (COUNT with CASE/FILTER), and boolean expression evaluation.

-- Conditional counting: count accounts in each branch split by balance sign.
-- Uses CASE inside SUM to pivot the counts into separate columns (cross-tab
-- style). A single GROUP BY pass produces three derived columns.
-- Tests: CASE inside aggregate function, conditional counting pattern.
SELECT bid,
       COUNT(*) AS total,
       SUM(CASE WHEN abalance > 0 THEN 1 ELSE 0 END) AS positive_count,
       SUM(CASE WHEN abalance = 0 THEN 1 ELSE 0 END) AS zero_count,
       SUM(CASE WHEN abalance < 0 THEN 1 ELSE 0 END) AS negative_count
FROM pgbench_accounts
GROUP BY bid
ORDER BY bid;

-- Compute a "health score" per branch: the ratio of positive-balance accounts
-- to total accounts, expressed as a percentage. Uses NULLIF to avoid
-- division by zero if a branch has no accounts.
-- Tests: NULLIF in denominator, CAST for float division, CASE + SUM combo.
SELECT bid,
       COUNT(*) AS total,
       CAST(SUM(CASE WHEN abalance > 0 THEN 1 ELSE 0 END) AS DOUBLE)
           / NULLIF(COUNT(*), 0) * 100.0 AS pct_positive
FROM pgbench_accounts
GROUP BY bid
ORDER BY pct_positive DESC;

-- Multi-level CASE: assign a letter grade to each account based on balance.
-- Tests: multi-branch CASE expression, string literals in CASE output.
SELECT aid, abalance,
       CASE
           WHEN abalance > 10000  THEN 'A'
           WHEN abalance > 1000   THEN 'B'
           WHEN abalance > 0      THEN 'C'
           WHEN abalance = 0      THEN 'D'
           WHEN abalance > -1000  THEN 'E'
           ELSE                        'F'
       END AS grade
FROM pgbench_accounts
WHERE aid <= 50
ORDER BY aid;

-- COALESCE with multiple fallbacks: try balance, then teller balance from a
-- LEFT JOIN (NULL if no matching teller for the account's branch), then a
-- default of 0. Exercises COALESCE with 3 arguments.
-- Tests: COALESCE chain, LEFT JOIN producing NULLs, fallback evaluation.
SELECT a.aid, a.abalance,
       t.tbalance,
       COALESCE(NULLIF(a.abalance, 0), t.tbalance, 0) AS effective_balance
FROM pgbench_accounts a
LEFT JOIN pgbench_tellers t ON a.bid = t.bid AND t.tid = a.bid * 10 + 1
WHERE a.aid <= 20
ORDER BY a.aid;

-- Boolean-style filtering with arithmetic: select accounts where the balance
-- is an even number and positive, combining modulo arithmetic with AND.
-- Tests: modulo operator (%), compound boolean predicates.
SELECT aid, abalance
FROM pgbench_accounts
WHERE abalance > 0 AND abalance % 2 = 0
ORDER BY abalance DESC
LIMIT 20;
