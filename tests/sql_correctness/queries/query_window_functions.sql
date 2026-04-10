-- Window function queries over pgbench tables
-- Tests: PARTITION BY, ORDER BY within window frames, multiple window
-- functions in one query, offset functions (LAG/LEAD), and statistical
-- ranking functions (NTILE, PERCENT_RANK).

-- Rank accounts within each branch by descending balance, and compute
-- per-branch running totals and averages. Filtered to the first 5 branches
-- to keep output manageable. Each row gets its positional rank, the branch's
-- total balance, and the branch's average balance as window-computed columns.
-- Tests: ROW_NUMBER, SUM OVER, AVG OVER with PARTITION BY.
SELECT aid, bid, abalance,
       ROW_NUMBER() OVER (PARTITION BY bid ORDER BY abalance DESC) AS rank_in_branch,
       SUM(abalance) OVER (PARTITION BY bid) AS branch_total,
       AVG(abalance) OVER (PARTITION BY bid) AS branch_avg
FROM pgbench_accounts
WHERE bid <= 5
ORDER BY bid, rank_in_branch
LIMIT 50;

-- For the first 100 accounts (by aid), show each account's balance alongside
-- the previous and next account's balance, plus the difference from the
-- previous row. Useful for spotting balance discontinuities.
-- Tests: LAG and LEAD offset window functions, arithmetic on window results.
SELECT aid, abalance,
       LAG(abalance, 1) OVER (ORDER BY aid) AS prev_balance,
       LEAD(abalance, 1) OVER (ORDER BY aid) AS next_balance,
       abalance - LAG(abalance, 1) OVER (ORDER BY aid) AS balance_diff
FROM pgbench_accounts
WHERE aid <= 100
ORDER BY aid;

-- Running cumulative delta and transaction count per branch over time.
-- Orders history rows by mtime within each branch and computes a running
-- sum of delta and running count. Shows how branch balances evolve.
-- Tests: SUM OVER and COUNT OVER with PARTITION BY + ORDER BY (cumulative frame).
SELECT bid,
       SUM(delta) OVER (PARTITION BY bid ORDER BY mtime) AS running_delta,
       COUNT(*) OVER (PARTITION BY bid ORDER BY mtime) AS running_count
FROM pgbench_history
ORDER BY bid, mtime
LIMIT 50;

-- Assign each history row to a quartile bucket (1-4) based on delta value,
-- and compute its percent rank within the full dataset. Shows the distribution
-- of transaction deltas.
-- Tests: NTILE (equal-width bucketing) and PERCENT_RANK (relative position).
SELECT tid, delta,
       NTILE(4) OVER (ORDER BY delta) AS quartile,
       PERCENT_RANK() OVER (ORDER BY delta) AS pct_rank
FROM pgbench_history
LIMIT 100;
