mod common;

use common::*;
use criterion::{Criterion, criterion_group, criterion_main};

fn bench_pipeline_breakdown(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let ctx = bctx.default_session();
    let mut group = c.benchmark_group("pipeline_breakdown");
    group.sample_size(10);
    group.bench_function("1_io_only", |b| {
        b.iter(|| { raw_read_pages_io_only(bctx.db_id, "pgbench_accounts"); });
    });
    group.bench_function("2_io_plus_parse", |b| {
        b.iter(|| { raw_read_pages_parsed(bctx.db_id, "pgbench_accounts"); });
    });
    group.bench_function("3a_arrow_1col", |b| {
        b.iter(|| { raw_read_pages_arrow_projected(bctx.db_id, "pgbench_accounts", &[0]); });
    });
    group.bench_function("3b_arrow_all_cols", |b| {
        b.iter(|| { raw_read_pages_arrow(bctx.db_id, "pgbench_accounts"); });
    });
    group.bench_function("4_datafusion_count_star", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT COUNT(aid) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
        });
    });
    group.bench_function("5_datafusion_select_star", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            let batches = ctx.sql("SELECT * FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
            let _rows: usize = batches.iter().map(|b| b.num_rows()).sum();
        });
    });
    group.finish();
}

fn bench_raw_vs_datafusion(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let ctx = bctx.default_session();
    let mut group = c.benchmark_group("raw_vs_datafusion");
    group.sample_size(10);
    group.bench_function("raw_pg_arrow", |b| {
        b.iter(|| { raw_read_all_batches(bctx.db_id, "pgbench_accounts"); });
    });
    group.bench_function("datafusion_count_star", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT COUNT(*) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
        });
    });
    group.bench_function("datafusion_select_star", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            let batches = ctx.sql("SELECT * FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
            let _rows: usize = batches.iter().map(|b| b.num_rows()).sum();
        });
    });
    group.finish();
}

criterion_group!(benches, bench_pipeline_breakdown, bench_raw_vs_datafusion);
criterion_main!(benches);
