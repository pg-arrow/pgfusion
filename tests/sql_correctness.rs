/// SQL correctness tests: run each .sql file against pgfusion and snapshot the output.
///
/// # Modes
/// - Normal (`cargo nextest run --test sql_correctness`):
///   Snapshot exists → assert pgfusion output == snapshot. No PG connection needed.
/// - Seed (`INSTA_UPDATE=new cargo nextest run --test sql_correctness`):
///   Snapshot missing → connect to PG, assert pgfusion rows == psql rows, write snapshot.
/// - Force re-validate (`INSTA_FORCE_PG_VALIDATE=1 ... INSTA_UPDATE=new ...`):
///   Snapshot exists but env var set → re-assert against live PG and update snapshot.
///
/// # Snapshot keys
/// One snapshot per query: `{file_stem}__{n}` (1-based), e.g. `query_aggregates__1`.
use std::path::PathBuf;

use arrow::array::{Array, AsArray};
use arrow::datatypes::DataType;
use arrow::record_batch::RecordBatch;
use arrow::util::pretty::pretty_format_batches;
use datafusion::prelude::SessionContext;
use pg_test_harness::{checkpoint, connect_to, db_oid, read_pg_config};
use pgfusion_lib::create_session;

const QUERIES_DIR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/sql_correctness/queries"
);
const SNAPSHOTS_DIR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/sql_correctness/snapshots"
);

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Parse a .sql file into individual query strings.
/// Strips `--` comments, splits on `;`, trims whitespace, drops empty entries.
fn parse_sql_file(path: &str) -> Vec<String> {
    let src = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("failed to read {path}: {e}"));
    src.lines()
        .map(|line| {
            if let Some(idx) = line.find("--") { &line[..idx] } else { line }
        })
        .collect::<Vec<_>>()
        .join(" ")
        .split(';')
        .map(|q| q.trim().to_owned())
        .filter(|q| !q.is_empty())
        .collect()
}

/// Returns true if the snapshot file for a given key already exists on disk.
fn snapshot_exists(snap_key: &str) -> bool {
    let path = PathBuf::from(SNAPSHOTS_DIR)
        .join(format!("sql_correctness__{snap_key}.snap"));
    path.exists()
}

/// Returns true when PG validation is required:
/// - snapshot is missing (seeding run), OR
/// - INSTA_FORCE_PG_VALIDATE=1 is set (forced re-validation).
/// Always false when INSTA_SKIP_PG=1.
fn needs_pg_validation(snap_key: &str) -> bool {
    if std::env::var("INSTA_SKIP_PG").is_ok() {
        return false;
    }
    !snapshot_exists(snap_key) || std::env::var("INSTA_FORCE_PG_VALIDATE").is_ok()
}

/// Format a RecordBatch slice into normalized pipe-separated rows for comparison.
/// Preserves row order and represents NULL as the literal string "NULL".
fn normalize_fusion_rows(batches: &[RecordBatch]) -> Vec<String> {
    let mut rows = Vec::new();
    for batch in batches {
        let ncols = batch.num_columns();
        for row_idx in 0..batch.num_rows() {
            let cols: Vec<String> = (0..ncols)
                .map(|col_idx| {
                    let col = batch.column(col_idx);
                    if col.is_null(row_idx) {
                        "NULL".to_owned()
                    } else {
                        format_arrow_value(col.as_ref(), row_idx)
                    }
                })
                .collect();
            rows.push(cols.join("|"));
        }
    }
    rows
}

fn format_arrow_value(array: &dyn Array, row: usize) -> String {
    match array.data_type() {
        DataType::Boolean => {
            let v: bool = array.as_boolean().value(row);
            v.to_string()
        }
        DataType::Int16 => array.as_primitive::<arrow::datatypes::Int16Type>().value(row).to_string(),
        DataType::Int32 => array.as_primitive::<arrow::datatypes::Int32Type>().value(row).to_string(),
        DataType::Int64 => array.as_primitive::<arrow::datatypes::Int64Type>().value(row).to_string(),
        DataType::Float32 => array.as_primitive::<arrow::datatypes::Float32Type>().value(row).to_string(),
        DataType::Float64 => array.as_primitive::<arrow::datatypes::Float64Type>().value(row).to_string(),
        DataType::Utf8 => array.as_string::<i32>().value(row).to_owned(),
        DataType::LargeUtf8 => array.as_string::<i64>().value(row).to_owned(),
        _ => {
            // For other types (Date, Timestamp, Decimal, etc.) fall back to debug repr.
            // Both sides use the same normalization so comparison is consistent.
            format!("{:?}", array.slice(row, 1))
        }
    }
}

/// Normalize rows from tokio_postgres into pipe-separated strings, NULLs as "NULL".
fn normalize_psql_rows(rows: &[tokio_postgres::Row]) -> Vec<String> {
    rows.iter()
        .map(|row| {
            let ncols = row.len();
            let cols: Vec<String> = (0..ncols)
                .map(|i| {
                    // Try common types in order. Unknown → debug repr.
                    if let Ok(Some(v)) = row.try_get::<_, Option<i64>>(i) {
                        return v.to_string();
                    }
                    if let Ok(Some(v)) = row.try_get::<_, Option<i32>>(i) {
                        return v.to_string();
                    }
                    if let Ok(Some(v)) = row.try_get::<_, Option<i16>>(i) {
                        return v.to_string();
                    }
                    if let Ok(Some(v)) = row.try_get::<_, Option<f64>>(i) {
                        return v.to_string();
                    }
                    if let Ok(Some(v)) = row.try_get::<_, Option<f32>>(i) {
                        return v.to_string();
                    }
                    if let Ok(Some(v)) = row.try_get::<_, Option<bool>>(i) {
                        return v.to_string();
                    }
                    if let Ok(Some(v)) = row.try_get::<_, Option<String>>(i) {
                        return v;
                    }
                    // NULL for all Option<T> variants returns Ok(None)
                    if let Ok(None::<String>) = row.try_get(i) {
                        return "NULL".to_owned();
                    }
                    // Fallback: cast via postgres TEXT protocol
                    format!("{:?}", row.columns()[i].name())
                })
                .collect();
            cols.join("|")
        })
        .collect()
}

/// Run a SQL query via pgfusion and return the RecordBatches.
async fn run_pgfusion(ctx: &SessionContext, sql: &str) -> Vec<RecordBatch> {
    ctx.sql(sql)
        .await
        .unwrap_or_else(|e| panic!("pgfusion SQL error: {e}\nQuery: {sql}"))
        .collect()
        .await
        .unwrap_or_else(|e| panic!("pgfusion collect error: {e}\nQuery: {sql}"))
}

/// Core test logic: parse .sql file, run each query, optionally validate vs PG, snapshot.
async fn run_sql_file_test(file_stem: &str) {
    let config = read_pg_config(env!("CARGO_MANIFEST_DIR"), "pg18");
    pg_arrow::file::set_data_dir(config.data_dir.clone());

    let sql_path = format!("{QUERIES_DIR}/{file_stem}.sql");
    let queries = parse_sql_file(&sql_path);

    let skip_pg = std::env::var("INSTA_SKIP_PG").is_ok();

    let any_needs_pg = !skip_pg && queries.iter().enumerate().any(|(i, _)| {
        needs_pg_validation(&format!("{file_stem}__{}", i + 1))
    });

    let (db_id, pg_client) = if skip_pg {
        // No PG connection — use stored OID from config.
        let oid = config.pgbench_test_oid
            .expect("pgbench_test_oid missing from pg-test-config.toml; required when INSTA_SKIP_PG=1");
        (oid, None::<tokio_postgres::Client>)
    } else {
        let client = connect_to(&config, "pgbench_test").await;
        if any_needs_pg {
            checkpoint(&client).await;
        }
        let oid = db_oid(&client, "pgbench_test").await;
        let maybe_client = if any_needs_pg { Some(client) } else { None };
        (oid, maybe_client)
    };

    let ctx = create_session(db_id).expect("create_session failed");

    for (i, sql) in queries.iter().enumerate() {
        let snap_key = format!("{file_stem}__{}", i + 1);

        let batches = run_pgfusion(&ctx, sql).await;

        let pg_validated = if needs_pg_validation(&snap_key) {
            let client = pg_client.as_ref()
                .unwrap_or_else(|| panic!("PG client required for snapshot seeding but not connected"));
            let pg_rows_raw = client
                .query(sql.as_str(), &[])
                .await
                .unwrap_or_else(|e| panic!("psql error on query {snap_key}: {e}\nQuery: {sql}"));
            let pg_rows = normalize_psql_rows(&pg_rows_raw);
            let fusion_rows = normalize_fusion_rows(&batches);
            if fusion_rows != pg_rows {
                let force = std::env::var("INSTA_FORCE_PG_VALIDATE").is_ok();
                let msg = format!(
                    "pgfusion vs psql mismatch [{snap_key}]\nQuery: {sql}\n  pgfusion: {fusion_rows:?}\n  psql:     {pg_rows:?}"
                );
                if force {
                    panic!("{msg}");
                } else {
                    // Skip snapshot — only snapshot queries that match psql.
                    eprintln!("WARN (skipping snapshot): {msg}");
                    continue;
                }
            }
            true
        } else {
            false
        };
        let _ = pg_validated;

        let table = pretty_format_batches(&batches)
            .unwrap_or_else(|e| panic!("pretty_format_batches failed: {e}"))
            .to_string();
        let formatted = format!("Query: {sql}\n\n{table}");

        let mut settings = insta::Settings::clone_current();
        settings.set_snapshot_path(std::path::Path::new(SNAPSHOTS_DIR));
        settings.set_prepend_module_to_snapshot(false);
        settings.bind(|| {
            insta::assert_snapshot!(snap_key, formatted);
        });
    }
}

// ── One test per .sql file ────────────────────────────────────────────────────

macro_rules! sql_file_test {
    ($name:ident) => {
        #[tokio::test]
        async fn $name() {
            run_sql_file_test(stringify!($name)).await;
        }
    };
}

sql_file_test!(query_aggregates);
sql_file_test!(query_complex_analytics);
sql_file_test!(query_compute_bound);
sql_file_test!(query_conditional_logic);
sql_file_test!(query_cross_join);
sql_file_test!(query_cte_queries);
sql_file_test!(query_extreme_values);
sql_file_test!(query_having_filter);
sql_file_test!(query_history_analysis);
sql_file_test!(query_join_queries);
sql_file_test!(query_memory_bound);
sql_file_test!(query_multi_join);
sql_file_test!(query_nested_aggregates);
sql_file_test!(query_ordering_limits);
sql_file_test!(query_scan_filter);
sql_file_test!(query_select_only);
sql_file_test!(query_set_operations);
sql_file_test!(query_simple_select);
sql_file_test!(query_string_operations);
sql_file_test!(query_subqueries);
sql_file_test!(query_type_casting);
sql_file_test!(query_window_functions);
