-- Join queries across pgbench tables
-- Tests: inner join execution, multi-table reads, join predicate evaluation,
-- and combined filter + join.

-- Join accounts to branches on bid, returning the first 10 accounts with their
-- branch balance. Tests a large-to-small table join (accounts is much bigger
-- than branches) with an additional row-count filter on aid.
SELECT a.aid, a.abalance, b.bbalance
FROM pgbench_accounts a
JOIN pgbench_branches b ON a.bid = b.bid
WHERE a.aid <= 10;

-- Join every teller to its branch. Both tables are small (10 tellers per branch
-- at scale factor 1), so this is a small-to-small equi-join that returns all rows.
-- Tests: full join materialization with no filter.
SELECT t.tid, t.tbalance, b.bbalance
FROM pgbench_tellers t
JOIN pgbench_branches b ON t.bid = b.bid;

-- Join accounts to tellers on bid (a many-to-many relationship since multiple
-- accounts and multiple tellers share the same bid). Filtered to the first 100
-- accounts. Tests: fan-out join behavior where each account matches several tellers.
SELECT a.aid, a.abalance, t.tbalance
FROM pgbench_accounts a
JOIN pgbench_tellers t ON a.bid = t.bid
WHERE a.aid <= 100;
