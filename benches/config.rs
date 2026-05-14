mod common;

use common::*;
use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};
use pgfusion_lib::SessionOptions;

fn bench_config_memory(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let configs: &[(&str, SessionOptions)] = &[
        ("unlimited", opts_default()),
        ("2G", opts_mem_2g()),
        ("512M", opts_mem_512m()),
    ];
    let mut group = c.benchmark_group("config_memory");
    group.sample_size(10);
    for (name, opts) in configs {
        let ctx = bctx.session(opts);
        group.bench_with_input(BenchmarkId::new("count_star", name), &ctx, |b, ctx| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql("SELECT COUNT(*) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
            });
        });
        let ctx = bctx.session(opts);
        group.bench_with_input(BenchmarkId::new("group_by_bid", name), &ctx, |b, ctx| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql("SELECT bid, COUNT(*) FROM pgbench_accounts GROUP BY bid ORDER BY COUNT(*) DESC")
                    .await.unwrap().collect().await.unwrap();
            });
        });
    }
    group.finish();
}

fn bench_config_batch_size(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let configs: &[(&str, SessionOptions)] = &[
        ("1024", opts_batch_1024()),
        ("8192_default", opts_default()),
        ("16384", opts_batch_16384()),
    ];
    let mut group = c.benchmark_group("config_batch_size");
    group.sample_size(10);
    for (name, opts) in configs {
        let ctx = bctx.session(opts);
        group.bench_with_input(BenchmarkId::new("count_star", name), &ctx, |b, ctx| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql("SELECT COUNT(*) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
            });
        });
        let ctx = bctx.session(opts);
        group.bench_with_input(BenchmarkId::new("avg_abalance", name), &ctx, |b, ctx| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql("SELECT AVG(abalance) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
            });
        });
    }
    group.finish();
}

fn bench_config_coalesce(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let configs: &[(&str, SessionOptions)] = &[
        ("coalesce_on", opts_default()),
        ("coalesce_off", opts_no_coalesce()),
    ];
    let mut group = c.benchmark_group("config_coalesce");
    group.sample_size(10);
    for (name, opts) in configs {
        let ctx = bctx.session(opts);
        group.bench_with_input(BenchmarkId::new("count_star", name), &ctx, |b, ctx| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql("SELECT COUNT(*) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
            });
        });
        let ctx = bctx.session(opts);
        group.bench_with_input(BenchmarkId::new("avg_abalance", name), &ctx, |b, ctx| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql("SELECT AVG(abalance) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
            });
        });
    }
    group.finish();
}

fn bench_config_partitions(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let configs: &[(&str, SessionOptions)] = &[
        ("4", opts_partitions_4()),
        ("10_default", opts_default()),
        ("20", opts_partitions_20()),
    ];
    let mut group = c.benchmark_group("config_partitions");
    group.sample_size(10);
    for (name, opts) in configs {
        let ctx = bctx.session(opts);
        group.bench_with_input(BenchmarkId::new("count_star", name), &ctx, |b, ctx| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql("SELECT COUNT(*) FROM pgbench_accounts").await.unwrap().collect().await.unwrap();
            });
        });
        let ctx = bctx.session(opts);
        group.bench_with_input(BenchmarkId::new("group_by_bid", name), &ctx, |b, ctx| {
            b.to_async(&bctx.rt).iter(|| async {
                ctx.sql("SELECT bid, SUM(abalance) FROM pgbench_accounts GROUP BY bid ORDER BY bid")
                    .await.unwrap().collect().await.unwrap();
            });
        });
    }
    group.finish();
}

fn bench_config_tuned(c: &mut Criterion) {
    let bctx = BenchContext::new();
    let configs: &[(&str, SessionOptions)] = &[("default", opts_default()), ("tuned", opts_tuned())];
    let queries: &[(&str, &str)] = &[
        ("count_star", "SELECT COUNT(*) FROM pgbench_accounts"),
        ("avg_abalance", "SELECT AVG(abalance) FROM pgbench_accounts"),
        ("count_distinct_bid", "SELECT COUNT(DISTINCT bid) FROM pgbench_accounts"),
        ("group_by_bid", "SELECT bid, COUNT(*), SUM(abalance) FROM pgbench_accounts GROUP BY bid ORDER BY bid"),
        ("join_accounts_branches", "SELECT a.bid, COUNT(*), AVG(a.abalance) FROM pgbench_accounts a JOIN pgbench_branches b ON a.bid = b.bid GROUP BY a.bid"),
    ];
    let mut group = c.benchmark_group("config_default_vs_tuned");
    group.sample_size(10);
    for (qname, sql) in queries {
        for (cname, opts) in configs {
            let ctx = bctx.session(opts);
            group.bench_with_input(BenchmarkId::new(*qname, cname), &ctx, |b, ctx| {
                let sql = *sql;
                b.to_async(&bctx.rt).iter(|| async {
                    ctx.sql(sql).await.unwrap().collect().await.unwrap();
                });
            });
        }
    }
    group.finish();
}

criterion_group!(
    benches,
    bench_config_memory,
    bench_config_batch_size,
    bench_config_coalesce,
    bench_config_partitions,
    bench_config_tuned,
);
criterion_main!(benches);
