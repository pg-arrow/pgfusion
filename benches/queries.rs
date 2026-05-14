mod common;

use common::*;
use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};

fn bench_full_scan(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let ctx = bctx.default_session();
    let mut group = c.benchmark_group("full_scan");
    group.sample_size(10);
    group.bench_function("count_star_accounts", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT COUNT(*) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
        });
    });
    group.bench_function("count_star_history", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT COUNT(*) FROM pgbench_history").await.unwrap().collect().await.unwrap();
        });
    });
    group.finish();
}

fn bench_aggregation(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let ctx = bctx.default_session();
    let mut group = c.benchmark_group("aggregation");
    group.sample_size(10);
    group.bench_function("avg_abalance", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT AVG(abalance) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
        });
    });
    group.bench_function("min_max_abalance", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT MIN(abalance), MAX(abalance) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
        });
    });
    group.bench_function("count_distinct_bid", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT COUNT(DISTINCT bid) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
        });
    });
    group.finish();
}

fn bench_group_by(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let ctx = bctx.default_session();
    let mut group = c.benchmark_group("group_by");
    group.sample_size(10);
    group.bench_function("bid_count", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT bid, COUNT(*) FROM pgbench_accounts GROUP BY bid ORDER BY bid")
                .await.unwrap().collect().await.unwrap();
        });
    });
    group.bench_function("bid_sum_abalance", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT bid, SUM(abalance) FROM pgbench_accounts GROUP BY bid ORDER BY SUM(abalance) DESC")
                .await.unwrap().collect().await.unwrap();
        });
    });
    group.bench_function("teller_top10", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT tid, COUNT(*) FROM pgbench_history GROUP BY tid ORDER BY COUNT(*) DESC LIMIT 10")
                .await.unwrap().collect().await.unwrap();
        });
    });
    group.finish();
}

fn bench_projection(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let ctx = bctx.default_session();
    let projections: &[(&str, &str)] = &[
        ("1_col", "SELECT COUNT(aid) FROM pgbench_accounts"),
        ("2_col", "SELECT COUNT(aid), AVG(abalance) FROM pgbench_accounts"),
        ("all_col", "SELECT SUM(abalance), MIN(abalance), MAX(abalance), COUNT(*) FROM pgbench_accounts"),
    ];
    let mut group = c.benchmark_group("projection");
    group.sample_size(10);
    for (name, sql) in projections {
        group.bench_with_input(BenchmarkId::new("width", name), sql, |b, sql| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql(sql).await.unwrap().collect().await.unwrap();
            });
        });
    }
    group.finish();
}

fn bench_point_lookup(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let ctx = bctx.default_session();
    let mut group = c.benchmark_group("point_lookup");
    group.sample_size(10);
    group.bench_function("aid_eq", |b| {
        b.to_async(&bctx.rt).iter(|| async {
            ctx.sql("SELECT * FROM pgbench_accounts WHERE aid = 1")
                .await.unwrap().collect().await.unwrap();
        });
    });
    group.finish();
}

criterion_group!(
    benches,
    bench_full_scan,
    bench_aggregation,
    bench_group_by,
    bench_projection,
    bench_point_lookup,
);
criterion_main!(benches);
