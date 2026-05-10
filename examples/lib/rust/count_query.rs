use pg_test_harness::db_oid_blocking;
use pgfusion_lib::create_session;

#[tokio::main]
async fn main() {
    let db_id = db_oid_blocking("postgres");
    let ctx = create_session(db_id).expect("failed to create session");

    let df = ctx.sql("SELECT * FROM pgbench_accounts").await.unwrap();

    let count = df.count().await.unwrap();
    println!("Total rows is {:?}", count);
}
