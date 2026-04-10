-- Set operations and DISTINCT queries
-- Tests: UNION (deduplicated merge), INTERSECT (common rows), EXCEPT
-- (difference), UNION ALL (concatenation without dedup), and DISTINCT.

-- UNION of branch IDs from accounts and tellers. Deduplicates the combined
-- result so each bid appears once. Verifies that both tables reference the
-- same set of branch IDs.
-- Tests: UNION deduplication across two scans, ORDER BY on union output.
SELECT bid FROM pgbench_accounts
UNION
SELECT bid FROM pgbench_tellers
ORDER BY bid;

-- INTERSECT of branch IDs: returns only bids that appear in both accounts
-- and tellers. Should be identical to the UNION result if the schema is
-- consistent (every branch has both accounts and tellers).
-- Tests: INTERSECT set operation, hash-based or sort-based intersection.
SELECT bid FROM pgbench_accounts
INTERSECT
SELECT bid FROM pgbench_tellers;

-- EXCEPT: finds branches that exist in pgbench_branches but have no
-- corresponding rows in pgbench_history. Identifies branches with zero
-- transaction activity.
-- Tests: EXCEPT set difference, DISTINCT inside one operand.
SELECT bid FROM pgbench_branches
EXCEPT
SELECT DISTINCT bid FROM pgbench_history;

-- DISTINCT on a two-column combination: unique (bid, abalance) pairs
-- where the balance is non-zero. Useful for seeing the spread of non-default
-- balances across branches.
-- Tests: multi-column DISTINCT, inequality filter, ORDER BY + LIMIT.
SELECT DISTINCT bid, abalance
FROM pgbench_accounts
WHERE abalance != 0
ORDER BY bid, abalance
LIMIT 50;

-- UNION ALL: concatenates branch IDs from accounts and tellers without
-- removing duplicates. Result size equals the sum of both table sizes.
-- Tests: UNION ALL (no dedup overhead), ORDER BY + LIMIT on concatenated result.
SELECT bid FROM pgbench_accounts
UNION ALL
SELECT bid FROM pgbench_tellers
ORDER BY bid
LIMIT 50;
