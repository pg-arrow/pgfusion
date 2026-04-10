-- Memory-bound queries
-- These queries stress the memory subsystem: large hash tables, big sorts,
-- high-cardinality GROUP BYs, wide intermediate results, and operations
-- that require materializing large datasets in memory before producing output.

-- Full-table sort on a non-indexed column. The entire accounts table must be
-- read into memory (or spilled to disk) and sorted by abalance. With 100k
-- rows at scale factor 1, this is a moderate memory allocation.
-- Stress: in-memory sort buffer for the full table.
SELECT aid, abalance
FROM pgbench_accounts
ORDER BY abalance DESC;

-- High-cardinality GROUP BY: group by aid (unique per row in accounts).
-- Creates as many groups as there are rows, maximizing hash table size.
-- The aggregate is trivial (COUNT = 1 for each), but the hash map is huge.
-- Stress: hash aggregation with N groups = N rows.
SELECT aid, COUNT(*) AS cnt
FROM pgbench_accounts
GROUP BY aid
ORDER BY aid;

-- Large hash join: join the full accounts table to itself on abalance.
-- Many accounts share abalance=0 (after pgbench init), creating a large
-- cartesian product within that group. Limited to 1000 rows to prevent
-- unbounded output, but the join build side is still the full table.
-- Stress: hash join build phase with full-table probe, fan-out on common values.
SELECT a1.aid AS aid1, a2.aid AS aid2, a1.abalance
FROM pgbench_accounts a1
JOIN pgbench_accounts a2 ON a1.abalance = a2.abalance
WHERE a1.aid < a2.aid
ORDER BY a1.abalance, a1.aid
LIMIT 1000;

-- Wide projection: select all columns from a multi-table join, materializing
-- a wide intermediate result. Each row carries columns from all four tables.
-- Stress: per-row memory footprint from wide tuples, materialization cost.
SELECT a.aid, a.bid, a.abalance, a.filler,
       b.bid AS b_bid, b.bbalance, b.filler AS b_filler,
       t.tid, t.bid AS t_bid, t.tbalance, t.filler AS t_filler
FROM pgbench_accounts a
JOIN pgbench_branches b ON a.bid = b.bid
JOIN pgbench_tellers t ON a.bid = t.bid
ORDER BY a.aid, t.tid
LIMIT 500;

-- Multiple window functions over the full table. Each window function may
-- require its own sorted partition copy in memory. Having several forces
-- the engine to maintain multiple window state buffers simultaneously.
-- Stress: concurrent window state buffers, full-table partitioning.
SELECT aid, bid, abalance,
       SUM(abalance) OVER (PARTITION BY bid ORDER BY aid) AS running_sum,
       AVG(abalance) OVER (PARTITION BY bid ORDER BY aid) AS running_avg,
       ROW_NUMBER() OVER (PARTITION BY bid ORDER BY abalance DESC) AS rank_desc,
       ROW_NUMBER() OVER (ORDER BY aid) AS global_row_num
FROM pgbench_accounts;

-- UNION ALL of multiple full-table scans: concatenates three copies of the
-- accounts table. Triples the memory footprint if the engine materializes
-- before sorting.
-- Stress: large intermediate materialization from union, sort on 300k rows.
SELECT aid, bid, abalance, 'accounts' AS source FROM pgbench_accounts
UNION ALL
SELECT aid, bid, abalance, 'copy2' AS source FROM pgbench_accounts
UNION ALL
SELECT aid, bid, abalance, 'copy3' AS source FROM pgbench_accounts
ORDER BY abalance DESC
LIMIT 100;

-- DISTINCT on a large result set: forces the engine to build a hash set
-- (or sort + dedup) over all unique (bid, abalance) pairs.
-- Stress: deduplication hash set over full table scan.
SELECT DISTINCT bid, abalance
FROM pgbench_accounts
ORDER BY bid, abalance;
