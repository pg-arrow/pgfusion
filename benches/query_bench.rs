use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};
use datafusion::prelude::SessionContext;
use pg_arrow::file::PAGE_BUFFER_SIZE;
use pg_arrow::file::reader::{ChunkReader, Oid, TableFileReader};
use pg_arrow::heap::page::HeapPageData;
use pg_arrow::table::PgTableReader;
use pgfusion_lib::{SessionOptions, create_session, create_session_with_options};
use tokio::runtime::Runtime;

/// Database OIDs. Adjust if your local setup differs.
const PGBENCH_DB_ID: Oid = 16384;
const CLICKBENCH_DB_ID: Oid = 16727;

fn session(db_id: Oid, opts: &SessionOptions) -> SessionContext {
    create_session_with_options(db_id, opts).expect("failed to create session")
}

fn clickbench_session() -> SessionContext {
    create_session(CLICKBENCH_DB_ID).expect("failed to create clickbench session")
}

fn pgbench_session() -> SessionContext {
    create_session(PGBENCH_DB_ID).expect("failed to create pgbench session")
}

/// Raw pg_arrow: read all pages -> Arrow RecordBatches, no DataFusion.
fn raw_read_all_batches(db_id: Oid, table_name: &str) -> usize {
    let mut reader = PgTableReader::new(db_id).unwrap();
    reader.set_table(table_name).unwrap();

    let schema = reader.schema().unwrap().clone();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, _) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();

    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);
    let page_reader = file_reader.get_page_reader().unwrap();
    let stream = page_reader.into_batch_stream(&schema, None);

    let mut total_rows = 0usize;
    for batch_result in stream {
        let batch = batch_result.unwrap();
        total_rows += batch.num_rows();
    }
    total_rows
}

// ── Configuration presets ───────────────────────────────────────────────────

fn opts_default() -> SessionOptions {
    SessionOptions::default()
}

fn opts_mem_2g() -> SessionOptions {
    SessionOptions {
        memory_limit: Some(2 * 1024 * 1024 * 1024),
        ..Default::default()
    }
}

fn opts_mem_512m() -> SessionOptions {
    SessionOptions {
        memory_limit: Some(512 * 1024 * 1024),
        ..Default::default()
    }
}

fn opts_batch_1024() -> SessionOptions {
    SessionOptions {
        batch_size: Some(1024),
        ..Default::default()
    }
}

fn opts_batch_16384() -> SessionOptions {
    SessionOptions {
        batch_size: Some(16384),
        ..Default::default()
    }
}

fn opts_no_coalesce() -> SessionOptions {
    SessionOptions {
        coalesce_batches: Some(false),
        ..Default::default()
    }
}

fn opts_partitions_4() -> SessionOptions {
    SessionOptions {
        target_partitions: Some(4),
        ..Default::default()
    }
}

fn opts_partitions_20() -> SessionOptions {
    SessionOptions {
        target_partitions: Some(20),
        ..Default::default()
    }
}

fn opts_tuned() -> SessionOptions {
    SessionOptions {
        memory_limit: Some(8 * 1024 * 1024 * 1024),
        batch_size: Some(16384),
        coalesce_batches: Some(false),
        target_partitions: Some(20),
    }
}

// ── Config: memory limit ────────────────────────────────────────────────────

fn bench_config_memory(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();

    let configs: &[(&str, SessionOptions)] = &[
        ("unlimited", opts_default()),
        ("2G", opts_mem_2g()),
        ("512M", opts_mem_512m()),
    ];

    let mut group = c.benchmark_group("config_memory");
    group.sample_size(10);

    for (name, opts) in configs {
        let ctx = session(CLICKBENCH_DB_ID, opts);
        group.bench_with_input(BenchmarkId::new("count_star_hits", name), &ctx, |b, ctx| {
            b.to_async(&rt).iter(|| async {
                let df = ctx.sql("SELECT COUNT(*) FROM hits").await.unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    for (name, opts) in configs {
        let ctx = session(CLICKBENCH_DB_ID, opts);
        group.bench_with_input(BenchmarkId::new("group_by_userid", name), &ctx, |b, ctx| {
            b.to_async(&rt).iter(|| async {
                let df = ctx
                    .sql(
                        "SELECT UserID, COUNT(*) FROM hits \
                             GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10",
                    )
                    .await
                    .unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    group.finish();
}

// ── Config: batch size ──────────────────────────────────────────────────────

fn bench_config_batch_size(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();

    let configs: &[(&str, SessionOptions)] = &[
        ("1024", opts_batch_1024()),
        ("8192_default", opts_default()),
        ("16384", opts_batch_16384()),
    ];

    let mut group = c.benchmark_group("config_batch_size");
    group.sample_size(10);

    for (name, opts) in configs {
        let ctx = session(CLICKBENCH_DB_ID, opts);
        group.bench_with_input(BenchmarkId::new("count_star_hits", name), &ctx, |b, ctx| {
            b.to_async(&rt).iter(|| async {
                let df = ctx.sql("SELECT COUNT(*) FROM hits").await.unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    for (name, opts) in configs {
        let ctx = session(CLICKBENCH_DB_ID, opts);
        group.bench_with_input(BenchmarkId::new("avg_userid", name), &ctx, |b, ctx| {
            b.to_async(&rt).iter(|| async {
                let df = ctx.sql("SELECT AVG(UserID) FROM hits").await.unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    group.finish();
}

// ── Config: coalesce batches ────────────────────────────────────────────────

fn bench_config_coalesce(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();

    let configs: &[(&str, SessionOptions)] = &[
        ("coalesce_on", opts_default()),
        ("coalesce_off", opts_no_coalesce()),
    ];

    let mut group = c.benchmark_group("config_coalesce");
    group.sample_size(10);

    for (name, opts) in configs {
        let ctx = session(CLICKBENCH_DB_ID, opts);
        group.bench_with_input(BenchmarkId::new("count_star_hits", name), &ctx, |b, ctx| {
            b.to_async(&rt).iter(|| async {
                let df = ctx.sql("SELECT COUNT(*) FROM hits").await.unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    for (name, opts) in configs {
        let ctx = session(CLICKBENCH_DB_ID, opts);
        group.bench_with_input(BenchmarkId::new("avg_userid", name), &ctx, |b, ctx| {
            b.to_async(&rt).iter(|| async {
                let df = ctx.sql("SELECT AVG(UserID) FROM hits").await.unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    group.finish();
}

// ── Config: target partitions ───────────────────────────────────────────────

fn bench_config_partitions(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();

    let configs: &[(&str, SessionOptions)] = &[
        ("4", opts_partitions_4()),
        ("10_default", opts_default()),
        ("20", opts_partitions_20()),
    ];

    let mut group = c.benchmark_group("config_partitions");
    group.sample_size(10);

    for (name, opts) in configs {
        let ctx = session(CLICKBENCH_DB_ID, opts);
        group.bench_with_input(BenchmarkId::new("count_star_hits", name), &ctx, |b, ctx| {
            b.to_async(&rt).iter(|| async {
                let df = ctx.sql("SELECT COUNT(*) FROM hits").await.unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    for (name, opts) in configs {
        let ctx = session(CLICKBENCH_DB_ID, opts);
        group.bench_with_input(BenchmarkId::new("group_by_url", name), &ctx, |b, ctx| {
            b.to_async(&rt).iter(|| async {
                let df = ctx
                    .sql(
                        "SELECT URL, COUNT(*) AS c FROM hits \
                             GROUP BY URL ORDER BY c DESC LIMIT 10",
                    )
                    .await
                    .unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    group.finish();
}

// ── Config: default vs tuned ────────────────────────────────────────────────

fn bench_config_tuned(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();

    let configs: &[(&str, SessionOptions)] =
        &[("default", opts_default()), ("tuned", opts_tuned())];

    let queries: &[(&str, &str)] = &[
        ("count_star", "SELECT COUNT(*) FROM hits"),
        ("avg_userid", "SELECT AVG(UserID) FROM hits"),
        (
            "count_distinct_userid",
            "SELECT COUNT(DISTINCT UserID) FROM hits",
        ),
        (
            "group_by_userid",
            "SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10",
        ),
        (
            "group_by_url",
            "SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10",
        ),
    ];

    let mut group = c.benchmark_group("config_default_vs_tuned");
    group.sample_size(10);

    for (qname, sql) in queries {
        for (cname, opts) in configs {
            let ctx = session(CLICKBENCH_DB_ID, opts);
            group.bench_with_input(BenchmarkId::new(*qname, cname), &ctx, |b, ctx| {
                let sql = *sql;
                b.to_async(&rt).iter(|| async {
                    let df = ctx.sql(sql).await.unwrap();
                    df.collect().await.unwrap();
                });
            });
        }
    }

    group.finish();
}

// ── Raw vs DataFusion ───────────────────────────────────────────────────────

fn bench_raw_vs_datafusion(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let cb_ctx = clickbench_session();

    let mut group = c.benchmark_group("raw_vs_datafusion_hits");
    group.sample_size(10);

    group.bench_function("raw_pg_arrow", |b| {
        b.iter(|| {
            raw_read_all_batches(CLICKBENCH_DB_ID, "hits");
        });
    });

    group.bench_function("datafusion_count_star", |b| {
        b.to_async(&rt).iter(|| async {
            let df = cb_ctx.sql("SELECT COUNT(*) FROM hits").await.unwrap();
            df.collect().await.unwrap();
        });
    });

    group.bench_function("datafusion_select_star", |b| {
        b.to_async(&rt).iter(|| async {
            let df = cb_ctx.sql("SELECT * FROM hits").await.unwrap();
            let batches = df.collect().await.unwrap();
            let _rows: usize = batches.iter().map(|b| b.num_rows()).sum();
        });
    });

    group.finish();
}

fn bench_raw_vs_datafusion_pgbench(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let pb_ctx = pgbench_session();

    let mut group = c.benchmark_group("raw_vs_datafusion_pgbench");
    group.sample_size(10);

    group.bench_function("raw_pg_arrow", |b| {
        b.iter(|| {
            raw_read_all_batches(PGBENCH_DB_ID, "pgbench_accounts");
        });
    });

    group.bench_function("datafusion_count_star", |b| {
        b.to_async(&rt).iter(|| async {
            let df = pb_ctx
                .sql("SELECT COUNT(*) FROM pgbench_accounts")
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });

    group.finish();
}

// ── Full scan ───────────────────────────────────────────────────────────────

fn bench_full_scan(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let cb_ctx = clickbench_session();
    let pb_ctx = pgbench_session();

    let mut group = c.benchmark_group("full_scan");
    group.sample_size(10);

    group.bench_function("count_star_hits", |b| {
        b.to_async(&rt).iter(|| async {
            let df = cb_ctx.sql("SELECT COUNT(*) FROM hits").await.unwrap();
            df.collect().await.unwrap();
        });
    });

    group.bench_function("count_star_pgbench_accounts", |b| {
        b.to_async(&rt).iter(|| async {
            let df = pb_ctx
                .sql("SELECT COUNT(*) FROM pgbench_accounts")
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });

    group.finish();
}

// ── Aggregation ─────────────────────────────────────────────────────────────

fn bench_aggregation(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let ctx = clickbench_session();

    let mut group = c.benchmark_group("aggregation");
    group.sample_size(10);

    group.bench_function("avg_userid", |b| {
        b.to_async(&rt).iter(|| async {
            let df = ctx.sql("SELECT AVG(UserID) FROM hits").await.unwrap();
            df.collect().await.unwrap();
        });
    });

    group.bench_function("min_max_eventdate", |b| {
        b.to_async(&rt).iter(|| async {
            let df = ctx
                .sql("SELECT MIN(EventDate), MAX(EventDate) FROM hits")
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });

    group.bench_function("count_distinct_userid", |b| {
        b.to_async(&rt).iter(|| async {
            let df = ctx
                .sql("SELECT COUNT(DISTINCT UserID) FROM hits")
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });

    group.finish();
}

// ── GROUP BY ────────────────────────────────────────────────────────────────

fn bench_group_by(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let ctx = clickbench_session();

    let mut group = c.benchmark_group("group_by");
    group.sample_size(10);

    group.bench_function("regionid_top10", |b| {
        b.to_async(&rt).iter(|| async {
            let df = ctx
                .sql(
                    "SELECT RegionID, COUNT(DISTINCT UserID) AS u \
                     FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10",
                )
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });

    group.bench_function("userid_top10", |b| {
        b.to_async(&rt).iter(|| async {
            let df = ctx
                .sql(
                    "SELECT UserID, COUNT(*) FROM hits \
                     GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10",
                )
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });

    group.bench_function("url_top10", |b| {
        b.to_async(&rt).iter(|| async {
            let df = ctx
                .sql(
                    "SELECT URL, COUNT(*) AS c FROM hits \
                     GROUP BY URL ORDER BY c DESC LIMIT 10",
                )
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });

    group.finish();
}

// ── Projection width ────────────────────────────────────────────────────────

fn bench_projection(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let ctx = clickbench_session();

    let mut group = c.benchmark_group("projection");
    group.sample_size(10);

    let projections: &[(&str, &str)] = &[
        ("1_col", "SELECT COUNT(UserID) FROM hits"),
        (
            "3_col",
            "SELECT COUNT(UserID), AVG(ResolutionWidth), MIN(CounterID) FROM hits",
        ),
        (
            "wide",
            "SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), \
             SUM(ResolutionWidth + 2), SUM(ResolutionWidth + 3), \
             SUM(ResolutionWidth + 4), SUM(ResolutionWidth + 5), \
             SUM(ResolutionWidth + 6), SUM(ResolutionWidth + 7), \
             SUM(ResolutionWidth + 8), SUM(ResolutionWidth + 9) FROM hits",
        ),
    ];

    for (name, sql) in projections {
        group.bench_with_input(BenchmarkId::new("width", name), sql, |b, sql| {
            b.to_async(&rt).iter(|| async {
                let df = ctx.sql(sql).await.unwrap();
                df.collect().await.unwrap();
            });
        });
    }

    group.finish();
}

// ── Point lookup ────────────────────────────────────────────────────────────

fn bench_point_lookup(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let ctx = clickbench_session();

    let mut group = c.benchmark_group("point_lookup");
    group.sample_size(10);

    group.bench_function("userid_eq", |b| {
        b.to_async(&rt).iter(|| async {
            let df = ctx
                .sql("SELECT UserID FROM hits WHERE UserID = 435090932899640449")
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });

    group.finish();
}

// ── Pipeline breakdown: I/O → Parse → Arrow → DataFusion ──────────────────

/// Read all pages as raw bytes via pread (no parsing, no Arrow conversion).
fn raw_read_pages_io_only(db_id: Oid, table_name: &str) -> usize {
    let reader = PgTableReader::new(db_id).unwrap();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, _) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();

    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);

    let total_pages = pg_class.relpages.max(0) as usize;
    let chunk_size = 256; // same as DEFAULT_PAGES_PER_BATCH
    let mut pages_read_total = 0usize;
    let mut start = 0;

    while start < total_pages {
        let want = chunk_size.min(total_pages - start);
        let (_bytes, pages_read) = file_reader.read_pages_bulk(start, want).unwrap();
        pages_read_total += pages_read;
        start += pages_read;
        if pages_read < want {
            break;
        }
    }
    pages_read_total
}

/// Read pages and parse headers/line pointers (HeapPageData), but skip Arrow conversion.
fn raw_read_pages_parsed(db_id: Oid, table_name: &str) -> usize {
    let reader = PgTableReader::new(db_id).unwrap();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, _) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();

    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);

    let total_pages = pg_class.relpages.max(0) as usize;
    let chunk_size = 256;
    let mut total_tuples = 0usize;
    let mut start = 0;

    while start < total_pages {
        let want = chunk_size.min(total_pages - start);
        let (bulk_bytes, pages_read) = file_reader.read_pages_bulk(start, want).unwrap();
        for i in 0..pages_read {
            let offset = i * PAGE_BUFFER_SIZE;
            let page_bytes = bulk_bytes.slice(offset..offset + PAGE_BUFFER_SIZE);
            let page = HeapPageData::parse_bytes(page_bytes).unwrap();
            total_tuples += page.lp_num;
        }
        start += pages_read;
        if pages_read < want {
            break;
        }
    }
    total_tuples
}

/// Read pages, parse, and convert to Arrow RecordBatches (no DataFusion).
fn raw_read_pages_arrow(db_id: Oid, table_name: &str) -> usize {
    let reader = PgTableReader::new(db_id).unwrap();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, schema) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();

    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);

    let total_pages = pg_class.relpages.max(0) as usize;
    let chunk_size = 128;
    let mut total_rows = 0usize;
    let mut start = 0;

    while start < total_pages {
        let want = chunk_size.min(total_pages - start);
        let (bulk_bytes, pages_read) = file_reader.read_pages_bulk(start, want).unwrap();
        for i in 0..pages_read {
            let offset = i * PAGE_BUFFER_SIZE;
            let page_bytes = bulk_bytes.slice(offset..offset + PAGE_BUFFER_SIZE);
            let page = HeapPageData::parse_bytes(page_bytes).unwrap();
            let batch = page.to_record_batch(schema, None).unwrap();
            total_rows += batch.num_rows();
        }
        start += pages_read;
        if pages_read < want {
            break;
        }
    }
    total_rows
}

/// Read pages, parse, and convert only projected columns to Arrow.
fn raw_read_pages_arrow_projected(db_id: Oid, table_name: &str, projection: &[usize]) -> usize {
    let reader = PgTableReader::new(db_id).unwrap();
    let table = reader.get_all_tables().unwrap();
    let (pg_class, schema) = table.iter().find(|(c, _)| c.relname == table_name).unwrap();

    let file_reader = TableFileReader::new(db_id, pg_class.relfilenode as usize);

    let total_pages = pg_class.relpages.max(0) as usize;
    let chunk_size = 128;
    let mut total_rows = 0usize;
    let mut start = 0;

    while start < total_pages {
        let want = chunk_size.min(total_pages - start);
        let (bulk_bytes, pages_read) = file_reader.read_pages_bulk(start, want).unwrap();
        for i in 0..pages_read {
            let offset = i * PAGE_BUFFER_SIZE;
            let page_bytes = bulk_bytes.slice(offset..offset + PAGE_BUFFER_SIZE);
            let page = HeapPageData::parse_bytes(page_bytes).unwrap();
            let batch = page.to_record_batch(schema, Some(projection)).unwrap();
            total_rows += batch.num_rows();
        }
        start += pages_read;
        if pages_read < want {
            break;
        }
    }
    total_rows
}

fn bench_pipeline_breakdown(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let cb_ctx = clickbench_session();

    let mut group = c.benchmark_group("pipeline_breakdown");
    group.sample_size(10);

    // Stage 1: I/O only (pread, no parsing)
    group.bench_function("1_io_only", |b| {
        b.iter(|| {
            raw_read_pages_io_only(CLICKBENCH_DB_ID, "hits");
        });
    });

    // Stage 2: I/O + page header parse (no Arrow conversion)
    group.bench_function("2_io_plus_parse", |b| {
        b.iter(|| {
            raw_read_pages_parsed(CLICKBENCH_DB_ID, "hits");
        });
    });

    // Stage 3a: I/O + parse + Arrow conversion (1 column: UserID)
    group.bench_function("3a_arrow_1col", |b| {
        b.iter(|| {
            raw_read_pages_arrow_projected(CLICKBENCH_DB_ID, "hits", &[0]);
        });
    });

    // Stage 3b: I/O + parse + Arrow conversion (all 105 columns)
    group.bench_function("3b_arrow_all_cols", |b| {
        b.iter(|| {
            raw_read_pages_arrow(CLICKBENCH_DB_ID, "hits");
        });
    });

    // Stage 4: DataFusion COUNT(*) (currently decodes all columns due to bug)
    group.bench_function("4_datafusion_count_star", |b| {
        b.to_async(&rt).iter(|| async {
            let df = cb_ctx.sql("SELECT COUNT(watchid) FROM hits").await.unwrap();
            df.collect().await.unwrap();
        });
    });

    // Stage 5: DataFusion SELECT * (full pipeline)
    group.bench_function("5_datafusion_select_star", |b| {
        b.to_async(&rt).iter(|| async {
            let df = cb_ctx.sql("SELECT * FROM hits").await.unwrap();
            let batches = df.collect().await.unwrap();
            let _rows: usize = batches.iter().map(|b| b.num_rows()).sum();
        });
    });

    group.finish();
}

criterion_group!(
    benches,
    bench_pipeline_breakdown,
    bench_config_memory,
    bench_config_batch_size,
    bench_config_coalesce,
    bench_config_partitions,
    bench_config_tuned,
    bench_raw_vs_datafusion,
    bench_raw_vs_datafusion_pgbench,
    bench_full_scan,
    bench_aggregation,
    bench_group_by,
    bench_projection,
    bench_point_lookup,
);
criterion_main!(benches);
