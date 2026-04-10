use criterion::{Criterion, criterion_group, criterion_main};
use pgfusion_lib::create_session;
use tokio::runtime::Runtime;

fn bench_count_star_pgbench_accounts(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let db_id = 16384;

    let ctx = create_session(db_id).expect("failed to create session");

    c.bench_function("SELECT count(*) FROM pgbench_accounts", |b| {
        b.to_async(&rt).iter(|| async {
            let df = ctx
                .sql("SELECT count(*) FROM pgbench_accounts")
                .await
                .unwrap();
            df.collect().await.unwrap();
        });
    });
}

criterion_group!(benches, bench_count_star_pgbench_accounts);
criterion_main!(benches);
