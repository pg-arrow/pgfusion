-- Compute-bound queries
-- These queries stress the CPU: heavy arithmetic per row, complex expression
-- evaluation, many aggregate functions, deep CASE nesting, mathematical
-- functions, and string construction in tight loops. I/O is minimal relative
-- to the computation performed.

-- Per-row arithmetic storm: compute multiple derived columns involving
-- multiplication, division, modulo, and absolute value for every account.
-- With 100k rows, this generates ~500k expression evaluations.
-- Stress: expression evaluation throughput, per-row function call overhead.
SELECT aid, bid, abalance,
       abalance * abalance AS balance_squared,
       ABS(abalance) AS abs_balance,
       abalance % 7 AS mod7,
       abalance % 13 AS mod13,
       CAST(abalance AS DOUBLE) / NULLIF(aid, 0) AS balance_per_aid,
       ABS(abalance) * 1000 + aid AS composite_score
FROM pgbench_accounts;

-- Mathematical functions applied to every row. SQRT, LN, and POWER are
-- floating-point operations that are CPU-intensive per call.
-- Stress: FP math pipeline, per-row transcendental function evaluation.
SELECT aid, abalance,
       SQRT(CAST(ABS(abalance) + 1 AS DOUBLE)) AS sqrt_bal,
       LN(CAST(ABS(abalance) + 1 AS DOUBLE)) AS ln_bal,
       POWER(CAST(ABS(abalance) AS DOUBLE), 0.5) AS power_half,
       EXP(CAST(abalance AS DOUBLE) / 100000.0) AS exp_scaled
FROM pgbench_accounts
WHERE abalance != 0
ORDER BY aid;

-- Deeply nested CASE: 10-branch CASE statement evaluated for every row.
-- Each branch involves a comparison, and the engine cannot short-circuit
-- easily when values span the full range.
-- Stress: branch prediction misses, deep conditional evaluation.
SELECT aid, abalance,
       CASE
           WHEN abalance > 50000  THEN 'tier_10'
           WHEN abalance > 20000  THEN 'tier_9'
           WHEN abalance > 10000  THEN 'tier_8'
           WHEN abalance > 5000   THEN 'tier_7'
           WHEN abalance > 1000   THEN 'tier_6'
           WHEN abalance > 0      THEN 'tier_5'
           WHEN abalance = 0      THEN 'tier_4'
           WHEN abalance > -1000  THEN 'tier_3'
           WHEN abalance > -5000  THEN 'tier_2'
           WHEN abalance > -10000 THEN 'tier_1'
           ELSE                        'tier_0'
       END AS tier
FROM pgbench_accounts;

-- Many aggregates in one pass: compute 10 different aggregate functions over
-- the full accounts table. The engine must maintain 10 accumulators and
-- update all of them for every input row.
-- Stress: per-row accumulator update overhead, many concurrent aggregates.
SELECT bid,
       COUNT(*) AS cnt,
       SUM(abalance) AS sum_bal,
       AVG(abalance) AS avg_bal,
       MIN(abalance) AS min_bal,
       MAX(abalance) AS max_bal,
       STDDEV(CAST(abalance AS DOUBLE)) AS stddev_bal,
       SUM(CASE WHEN abalance > 0 THEN 1 ELSE 0 END) AS pos_count,
       SUM(CASE WHEN abalance < 0 THEN 1 ELSE 0 END) AS neg_count,
       SUM(CASE WHEN abalance = 0 THEN 1 ELSE 0 END) AS zero_count,
       SUM(ABS(abalance)) AS total_abs_balance
FROM pgbench_accounts
GROUP BY bid
ORDER BY bid;

-- String construction per row: build a formatted string for every account
-- by concatenating multiple CAST expressions. String allocation and
-- concatenation is CPU and allocator intensive.
-- Stress: per-row string allocation, CAST + concatenation throughput.
SELECT aid,
       'bid=' || CAST(bid AS VARCHAR)
       || ' aid=' || CAST(aid AS VARCHAR)
       || ' bal=' || CAST(abalance AS VARCHAR) AS label
FROM pgbench_accounts;

-- Compound boolean evaluation: every row is tested against a chain of OR'd
-- conditions, each involving different columns and operators. Forces full
-- predicate evaluation without short-circuit (unless the optimizer rewrites).
-- Stress: complex predicate evaluation, no early termination.
SELECT aid, bid, abalance
FROM pgbench_accounts
WHERE (abalance > 100 AND bid % 2 = 0)
   OR (abalance < -100 AND bid % 2 = 1)
   OR (abalance = 0 AND aid % 1000 = 0)
   OR (ABS(abalance) BETWEEN 50 AND 150)
ORDER BY aid;

-- Hash-heavy aggregation with expression keys: GROUP BY on a computed
-- expression forces the engine to hash the expression result for every row.
-- Tests the hashing throughput on derived values.
-- Stress: hash computation on CASE expression per row.
SELECT
    CASE
        WHEN abalance % 10 = 0 THEN 'mod10_0'
        WHEN abalance % 10 < 5 THEN 'mod10_low'
        ELSE                        'mod10_high'
    END AS bucket,
    COUNT(*) AS cnt,
    AVG(abalance) AS avg_bal
FROM pgbench_accounts
GROUP BY
    CASE
        WHEN abalance % 10 = 0 THEN 'mod10_0'
        WHEN abalance % 10 < 5 THEN 'mod10_low'
        ELSE                        'mod10_high'
    END
ORDER BY bucket;
