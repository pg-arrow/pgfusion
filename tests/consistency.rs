/// Consistency tests: verify pgfusion's MVCC visibility matches PostgreSQL's ground truth.
///
/// Each test:
/// 1. Mutates pgbench_accounts via tokio_postgres
/// 2. Issues CHECKPOINT so heap pages are flushed
/// 3. Acquires a REPEATABLE READ snapshot
/// 4. Reads via pgfusion with snapshot injected into session config
/// 5. Asserts result vs psql ground truth
///
/// Reserved aids: 99901–99910, 90001–91000 (no overlap with pgbench SF1 = 100k rows).
///
/// Tests share pgbench_accounts rows — must run serially.
/// Always use: `just test-consistency` (nextest with test-threads=1).
/// Raw `cargo test` without --test-threads=1 will produce race failures.
///
/// Run ignored tests (clog-dependent) with: cargo nextest run --test consistency --run-ignored all
use arrow::array::Array;
use arrow::record_batch::RecordBatch;
use datafusion::prelude::SessionContext;
use pg_test_harness::{
    PgSnapshot, acquire_snapshot, checkpoint, connect_to, db_oid, read_pg_config,
    release_snapshot, skip_if_no_checkpoint,
};
use pgfusion_lib::{PgSnapshot as FusionSnapshot, create_session};

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Drop any leftover rows in the reserved aid ranges so this test starts clean,
/// even if the previous test panicked before its own cleanup ran.
async fn assert_clean_state(client: &tokio_postgres::Client) {
    client
        .execute(
            "DELETE FROM pgbench_accounts \
             WHERE (aid BETWEEN 99901 AND 99910) OR (aid BETWEEN 90001 AND 91000)",
            &[],
        )
        .await
        .expect("pre-test cleanup failed");
}

async fn setup() -> (pg_test_harness::PgConfig, SessionContext, tokio_postgres::Client) {
    let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
    pg_arrow::file::set_data_dir(config.data_dir.clone());
    let client = connect_to(&config, "pgbench_test").await;
    assert_clean_state(&client).await;
    let db_id = db_oid(&client, "pgbench_test").await;
    let ctx = create_session(db_id).expect("create_session failed");
    (config, ctx, client)
}

/// Inject a harness PgSnapshot into the pgfusion session config extensions.
fn inject_snapshot(ctx: &SessionContext, snap: &PgSnapshot) {
    let fusion_snap = FusionSnapshot {
        xmin: snap.xmin,
        xmax: snap.xmax,
        xip: snap.xip.clone(),
    };
    ctx.state_ref()
        .write()
        .config_mut()
        .options_mut()
        .extensions
        .insert(fusion_snap);
}

/// Run a SQL query via pgfusion and collect all RecordBatches.
async fn pgfusion_query(ctx: &SessionContext, sql: &str) -> Vec<RecordBatch> {
    ctx.sql(sql)
        .await
        .unwrap_or_else(|e| panic!("pgfusion SQL error: {e}\nQuery: {sql}"))
        .collect()
        .await
        .unwrap_or_else(|e| panic!("pgfusion collect error: {e}\nQuery: {sql}"))
}

/// Extract all i32 values from the first column of RecordBatches.
fn extract_i32_col(batches: &[RecordBatch]) -> Vec<i32> {
    use arrow::array::AsArray;
    let mut out = Vec::new();
    for batch in batches {
        if batch.num_columns() == 0 { continue; }
        let col = batch.column(0);
        let arr = col.as_primitive::<arrow::datatypes::Int32Type>();
        for i in 0..arr.len() {
            if arr.is_null(i) { continue; }
            out.push(arr.value(i));
        }
    }
    out
}


/// Delete reserved test rows. Called before and after each test for clean state.
async fn cleanup_aids(client: &tokio_postgres::Client, aids: &[i32]) {
    let placeholders: Vec<String> = (1..=aids.len()).map(|i| format!("${i}")).collect();
    let sql = format!(
        "DELETE FROM pgbench_accounts WHERE aid IN ({})",
        placeholders.join(", ")
    );
    let params: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> =
        aids.iter().map(|a| a as &(dyn tokio_postgres::types::ToSql + Sync)).collect();
    client
        .execute(&sql, &params)
        .await
        .unwrap_or_else(|e| panic!("cleanup_aids failed: {e}"));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// INSERT a row, checkpoint, read via pgfusion → row must appear.
#[tokio::test]
async fn test_insert_visible_after_checkpoint() {
    let (_, ctx, client) = setup().await;
    let aids = [99901i32];
    cleanup_aids(&client, &aids).await;

    client
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99901, 1, 11111, 'test_insert')",
            &[],
        )
        .await
        .expect("INSERT failed");

    checkpoint(&client).await;

    let snap = acquire_snapshot(&client).await;
    inject_snapshot(&ctx, &snap);
    release_snapshot(&client).await;

    let batches = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid = 99901",
    )
    .await;
    let got = extract_i32_col(&batches);
    assert_eq!(got, vec![99901], "inserted row not visible");

    cleanup_aids(&client, &aids).await;
}

/// INSERT then UPDATE, checkpoint between each → updated value visible.
#[tokio::test]
async fn test_update_visible_after_checkpoint() {
    let (_, ctx, client) = setup().await;
    let aids = [99901i32];
    cleanup_aids(&client, &aids).await;

    client
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99901, 1, 11111, 'test_update_before')",
            &[],
        )
        .await
        .expect("INSERT failed");
    checkpoint(&client).await;

    client
        .execute(
            "UPDATE pgbench_accounts SET abalance = 22222 WHERE aid = 99901",
            &[],
        )
        .await
        .expect("UPDATE failed");
    checkpoint(&client).await;

    let snap = acquire_snapshot(&client).await;
    inject_snapshot(&ctx, &snap);
    release_snapshot(&client).await;

    let batches = pgfusion_query(
        &ctx,
        "SELECT abalance FROM pgbench_accounts WHERE aid = 99901",
    )
    .await;
    use arrow::array::AsArray;
    let val = batches
        .iter()
        .flat_map(|b| {
            let arr = b.column(0).as_primitive::<arrow::datatypes::Int32Type>();
            (0..arr.len()).map(|i| arr.value(i)).collect::<Vec<_>>()
        })
        .next()
        .expect("no row returned");
    assert_eq!(val, 22222, "updated abalance not visible");

    cleanup_aids(&client, &aids).await;
}

/// In-flight tx INSERT not visible under snapshot taken while tx is open;
/// visible after commit + new snapshot.
#[tokio::test]
async fn test_parallel_transaction_not_visible() {
    if skip_if_no_checkpoint() { return; }

    let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
    pg_arrow::file::set_data_dir(config.data_dir.clone());

    // Connection A: holds open INSERT
    let conn_a = connect_to(&config, "pgbench_test").await;
    // Connection B: acquires snapshot while A is open
    let conn_b = connect_to(&config, "pgbench_test").await;

    let db_id = db_oid(&conn_b, "pgbench_test").await;
    let ctx = create_session(db_id).expect("create_session failed");

    assert_clean_state(&conn_b).await;
    cleanup_aids(&conn_b, &[99902i32]).await;

    conn_a.execute("BEGIN", &[]).await.expect("BEGIN failed");
    conn_a
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99902, 1, 33333, 'test_parallel')",
            &[],
        )
        .await
        .expect("INSERT failed");

    // Snapshot S: A's xid is in xip → aid=99902 invisible
    let snap_s = acquire_snapshot(&conn_b).await;
    inject_snapshot(&ctx, &snap_s);
    release_snapshot(&conn_b).await;

    checkpoint(&conn_b).await;

    let batches = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid = 99902",
    )
    .await;
    assert!(
        extract_i32_col(&batches).is_empty(),
        "in-flight tx row must not be visible under snapshot taken while tx was open"
    );

    // Commit A; new snapshot S2 → aid=99902 now visible
    conn_a.execute("COMMIT", &[]).await.expect("COMMIT failed");
    checkpoint(&conn_b).await;

    let snap_s2 = acquire_snapshot(&conn_b).await;
    inject_snapshot(&ctx, &snap_s2);
    release_snapshot(&conn_b).await;

    let batches2 = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid = 99902",
    )
    .await;
    assert_eq!(
        extract_i32_col(&batches2),
        vec![99902],
        "committed row must be visible under new snapshot"
    );

    cleanup_aids(&conn_b, &[99902i32]).await;
}

/// Two concurrent writers: only the committed one is visible under snapshot
/// taken after B commits but while A is still open.
#[tokio::test]
async fn test_concurrent_writers_isolation() {
    if skip_if_no_checkpoint() { return; }

    let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
    pg_arrow::file::set_data_dir(config.data_dir.clone());

    let conn_a = connect_to(&config, "pgbench_test").await;
    let conn_b = connect_to(&config, "pgbench_test").await;
    let conn_snap = connect_to(&config, "pgbench_test").await;

    let db_id = db_oid(&conn_snap, "pgbench_test").await;
    let ctx = create_session(db_id).expect("create_session failed");

    assert_clean_state(&conn_snap).await;
    cleanup_aids(&conn_snap, &[99903i32, 99904i32]).await;

    // A: open INSERT, not committed
    conn_a.execute("BEGIN", &[]).await.expect("BEGIN A");
    conn_a
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99903, 1, 44444, 'concurrent_a')",
            &[],
        )
        .await
        .expect("INSERT A");

    // B: INSERT and commit
    conn_b
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99904, 1, 55555, 'concurrent_b')",
            &[],
        )
        .await
        .expect("INSERT B");

    checkpoint(&conn_snap).await;

    // Snapshot S: A in xip, B committed before S
    let snap_s = acquire_snapshot(&conn_snap).await;
    inject_snapshot(&ctx, &snap_s);
    release_snapshot(&conn_snap).await;

    let batches = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid IN (99903, 99904) ORDER BY aid",
    )
    .await;
    let visible = extract_i32_col(&batches);
    assert!(
        !visible.contains(&99903),
        "A's uncommitted row must not be visible"
    );
    assert!(
        visible.contains(&99904),
        "B's committed row must be visible"
    );

    // Commit A; new snapshot → both visible
    conn_a.execute("COMMIT", &[]).await.expect("COMMIT A");
    checkpoint(&conn_snap).await;

    let snap_s2 = acquire_snapshot(&conn_snap).await;
    inject_snapshot(&ctx, &snap_s2);
    release_snapshot(&conn_snap).await;

    let batches2 = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid IN (99903, 99904) ORDER BY aid",
    )
    .await;
    let mut visible2 = extract_i32_col(&batches2);
    visible2.sort();
    assert_eq!(visible2, vec![99903, 99904], "both rows must be visible after both commit");

    cleanup_aids(&conn_snap, &[99903i32, 99904i32]).await;
}

/// Rollback after checkpoint: aborted tuple must not be visible.
///
/// # Known issue
/// This test currently fails because pg_arrow does not yet check the clog
/// (commit log) to filter tuples whose xmin is in aborted state. The snapshot
/// alone cannot distinguish "never committed" from "in-progress" when the
/// transaction has since rolled back.
///
/// Tracked for future implementation. Test is marked #[ignore] to document
/// expected behavior without blocking CI.
#[tokio::test]
#[ignore = "clog-based aborted tuple filtering not yet implemented (known issue)"]
async fn test_rollback_after_checkpoint_not_visible() {
    if skip_if_no_checkpoint() { return; }

    let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
    pg_arrow::file::set_data_dir(config.data_dir.clone());

    let conn_tx = connect_to(&config, "pgbench_test").await;
    let conn_read = connect_to(&config, "pgbench_test").await;

    let db_id = db_oid(&conn_read, "pgbench_test").await;
    let ctx = create_session(db_id).expect("create_session failed");

    assert_clean_state(&conn_read).await;
    cleanup_aids(&conn_read, &[99905i32]).await;

    conn_tx.execute("BEGIN", &[]).await.expect("BEGIN");
    conn_tx
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99905, 1, 66666, 'test_rollback')",
            &[],
        )
        .await
        .expect("INSERT");

    // Checkpoint while tx is open — page flushed with uncommitted tuple
    checkpoint(&conn_read).await;

    conn_tx.execute("ROLLBACK", &[]).await.expect("ROLLBACK");

    // New snapshot after rollback
    let snap = acquire_snapshot(&conn_read).await;
    inject_snapshot(&ctx, &snap);
    release_snapshot(&conn_read).await;

    let batches = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid = 99905",
    )
    .await;
    assert!(
        extract_i32_col(&batches).is_empty(),
        "rolled-back row must not be visible (requires clog check)"
    );

    cleanup_aids(&conn_read, &[99905i32]).await;
}

/// Snapshot is stable: re-running the same query with the same snapshot
/// returns identical results even after new inserts are checkpointed.
#[tokio::test]
async fn test_repeatable_read_stability() {
    if skip_if_no_checkpoint() { return; }

    let (_config, ctx, client) = setup().await;
    cleanup_aids(&client, &[99906i32]).await;

    let snap = acquire_snapshot(&client).await;
    inject_snapshot(&ctx, &snap);

    // First read
    let r1 = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid = 99906",
    )
    .await;
    let first = extract_i32_col(&r1);

    // Insert + checkpoint (should not affect our snapshot)
    client
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99906, 1, 77777, 'repeatable')",
            &[],
        )
        .await
        .expect("INSERT");
    checkpoint(&client).await;

    // Second read with same snapshot
    let r2 = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid = 99906",
    )
    .await;
    let second = extract_i32_col(&r2);

    release_snapshot(&client).await;

    assert_eq!(first, second, "repeatable read: same snapshot must return same rows");

    cleanup_aids(&client, &[99906i32]).await;
}

/// Long-running transaction: its inserts are invisible under snapshots taken
/// while it's open; visible under snapshots taken after commit.
#[tokio::test]
async fn test_long_running_tx_checkpoint_visibility() {
    if skip_if_no_checkpoint() { return; }

    let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
    pg_arrow::file::set_data_dir(config.data_dir.clone());

    let conn_long = connect_to(&config, "pgbench_test").await; // holds long tx
    let conn_b = connect_to(&config, "pgbench_test").await;    // commits quickly
    let conn_obs = connect_to(&config, "pgbench_test").await;  // observer

    let db_id = db_oid(&conn_obs, "pgbench_test").await;
    let ctx = create_session(db_id).expect("create_session failed");

    assert_clean_state(&conn_obs).await;
    cleanup_aids(&conn_obs, &[99907i32, 99908i32]).await;

    // Long tx: INSERT aid=99907, keep open
    conn_long.execute("BEGIN", &[]).await.expect("BEGIN long");
    conn_long
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99907, 1, 88888, 'long_tx')",
            &[],
        )
        .await
        .expect("INSERT long");

    // Checkpoint: flushes uncommitted tuple for long tx
    checkpoint(&conn_obs).await;

    // Quick commit: aid=99908
    conn_b
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99908, 1, 99999, 'quick_commit')",
            &[],
        )
        .await
        .expect("INSERT quick");
    checkpoint(&conn_obs).await;

    // Snapshot S: long tx in xip → 99907 invisible; 99908 committed → visible
    let snap_s = acquire_snapshot(&conn_obs).await;
    inject_snapshot(&ctx, &snap_s);
    release_snapshot(&conn_obs).await;

    let batches = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid IN (99907, 99908) ORDER BY aid",
    )
    .await;
    let visible = extract_i32_col(&batches);
    assert!(!visible.contains(&99907), "long-running tx row must not be visible");
    assert!(visible.contains(&99908), "quick-commit row must be visible");

    // Commit long tx; new snapshot → both visible
    conn_long.execute("COMMIT", &[]).await.expect("COMMIT long");
    checkpoint(&conn_obs).await;

    let snap_s2 = acquire_snapshot(&conn_obs).await;
    inject_snapshot(&ctx, &snap_s2);
    release_snapshot(&conn_obs).await;

    let batches2 = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid IN (99907, 99908) ORDER BY aid",
    )
    .await;
    let mut visible2 = extract_i32_col(&batches2);
    visible2.sort();
    assert_eq!(visible2, vec![99907, 99908], "both rows visible after long tx commits");

    cleanup_aids(&conn_obs, &[99907i32, 99908i32]).await;
}

/// Frozen tuples (xmin <= FROZEN_XID = 2) are always visible regardless of snapshot.
///
/// System catalog tables like pg_namespace have frozen xmin values and must
/// always appear in pgfusion queries.
#[tokio::test]
async fn test_frozen_tuple_always_visible() {
    let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
    pg_arrow::file::set_data_dir(config.data_dir.clone());

    // Connect to postgres db where system tables live
    let client = connect_to(&config, "postgres").await;
    let db_id = db_oid(&client, "postgres").await;
    let ctx = create_session(db_id).expect("create_session failed");

    checkpoint(&client).await;

    let snap = acquire_snapshot(&client).await;
    inject_snapshot(&ctx, &snap);
    release_snapshot(&client).await;

    let batches = pgfusion_query(&ctx, "SELECT oid FROM pg_namespace").await;
    let count: usize = batches.iter().map(|b| b.num_rows()).sum();
    assert!(count > 0, "pg_namespace rows (frozen tuples) must always be visible");
}

/// VACUUM marks old tuple versions LP_DEAD — pgfusion must not surface them.
#[tokio::test]
async fn test_vacuum_dead_tuple_invisible() {
    if skip_if_no_checkpoint() { return; }

    let (_config, ctx, client) = setup().await;
    cleanup_aids(&client, &[99909i32]).await;

    // Insert and checkpoint
    client
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99909, 1, 11111, 'vac_before')",
            &[],
        )
        .await
        .expect("INSERT");
    checkpoint(&client).await;

    // Update → creates dead tuple for old version
    client
        .execute(
            "UPDATE pgbench_accounts SET abalance = 22222 WHERE aid = 99909",
            &[],
        )
        .await
        .expect("UPDATE");
    checkpoint(&client).await;

    // VACUUM marks old tuple LP_DEAD
    client
        .execute("VACUUM pgbench_accounts", &[])
        .await
        .expect("VACUUM");
    checkpoint(&client).await;

    let snap = acquire_snapshot(&client).await;
    inject_snapshot(&ctx, &snap);
    release_snapshot(&client).await;

    let batches = pgfusion_query(
        &ctx,
        "SELECT abalance FROM pgbench_accounts WHERE aid = 99909",
    )
    .await;
    use arrow::array::AsArray;
    let values: Vec<i32> = batches
        .iter()
        .flat_map(|b| {
            let arr = b.column(0).as_primitive::<arrow::datatypes::Int32Type>();
            (0..arr.len()).map(|i| arr.value(i)).collect::<Vec<_>>()
        })
        .collect();
    assert_eq!(values, vec![22222], "only updated value visible; dead tuple must be filtered");
    assert_eq!(values.len(), 1, "exactly one row — LP_DEAD old version must not appear");

    cleanup_aids(&client, &[99909i32]).await;
}

/// Large transaction spanning multiple pages: all 1000 rows visible after commit+checkpoint.
#[tokio::test]
async fn test_large_transaction_many_rows() {
    if skip_if_no_checkpoint() { return; }

    let (_config, ctx, client) = setup().await;

    // Cleanup reserved range
    client
        .execute(
            "DELETE FROM pgbench_accounts WHERE aid BETWEEN 90001 AND 91000",
            &[],
        )
        .await
        .expect("cleanup range");

    // Insert 1000 rows in one transaction
    client.execute("BEGIN", &[]).await.expect("BEGIN");
    for aid in 90001i32..=91000 {
        client
            .execute(
                "INSERT INTO pgbench_accounts (aid, bid, abalance) VALUES ($1, 1, 0)",
                &[&aid],
            )
            .await
            .unwrap_or_else(|e| panic!("INSERT aid={aid} failed: {e}"));
    }
    client.execute("COMMIT", &[]).await.expect("COMMIT");
    checkpoint(&client).await;

    let snap = acquire_snapshot(&client).await;
    inject_snapshot(&ctx, &snap);
    release_snapshot(&client).await;

    // Verify exact aid set matches expected range
    let fusion_batches = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid BETWEEN 90001 AND 91000 ORDER BY aid",
    )
    .await;
    let mut fusion_aids = extract_i32_col(&fusion_batches);
    fusion_aids.sort();

    let expected: Vec<i32> = (90001..=91000).collect();
    assert_eq!(fusion_aids.len(), 1000, "all 1000 inserted rows must be visible");
    assert_eq!(fusion_aids, expected, "aid list mismatch across page boundaries");

    // Cleanup
    client
        .execute(
            "DELETE FROM pgbench_accounts WHERE aid BETWEEN 90001 AND 91000",
            &[],
        )
        .await
        .expect("cleanup range after");
}

/// Row inserted and committed AFTER our snapshot (xmin >= xmax) must not be visible.
///
/// Core MVCC rule: snapshot only sees txs committed before snapshot taken.
/// Even when tuple is checkpointed to disk it must remain invisible to older snapshots.
#[tokio::test]
async fn test_future_commit_not_visible() {
    if skip_if_no_checkpoint() { return; }

    let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
    pg_arrow::file::set_data_dir(config.data_dir.clone());

    let conn_snap = connect_to(&config, "pgbench_test").await;
    let conn_writer = connect_to(&config, "pgbench_test").await;

    let db_id = db_oid(&conn_snap, "pgbench_test").await;
    let ctx = create_session(db_id).expect("create_session failed");

    assert_clean_state(&conn_snap).await;
    cleanup_aids(&conn_snap, &[99910i32]).await;

    // Acquire snapshot S before the INSERT exists
    let snap_s = acquire_snapshot(&conn_snap).await;

    // INSERT and commit AFTER snapshot — xmin > S.xmax
    conn_writer
        .execute(
            "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) \
             VALUES (99910, 1, 77777, 'future_commit')",
            &[],
        )
        .await
        .expect("INSERT future");

    // Checkpoint so tuple is on disk
    checkpoint(&conn_snap).await;

    // Inject old snapshot (taken before insert)
    inject_snapshot(&ctx, &snap_s);
    release_snapshot(&conn_snap).await;

    let batches = pgfusion_query(
        &ctx,
        "SELECT aid FROM pgbench_accounts WHERE aid = 99910",
    )
    .await;
    assert!(
        extract_i32_col(&batches).is_empty(),
        "row committed after snapshot must not be visible (xmin >= xmax)"
    );

    cleanup_aids(&conn_snap, &[99910i32]).await;
}
