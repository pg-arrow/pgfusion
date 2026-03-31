use std::{error::Error, sync::Arc};

use datafusion::{execution::context::SessionContext, prelude::SessionConfig};
use futures::StreamExt;
use pg_arrow::{
    file::error::PgError,
    table::PgTableReader,
    types::{PgAttribute, PgCatalogRelation, PgClass},
};
use pg_fusion_lib::CustomDataSource;
use tokio::sync::Mutex;

#[tokio::main]
async fn main() -> Result<(), PgError> {
    let mut config = SessionConfig::new();
    config.options_mut().catalog.information_schema = true;
    let ctx = SessionContext::new_with_config(config);

    let db_id = 16384;
    let table_reader = PgTableReader::new(db_id).unwrap();
    for table_details in table_reader.get_all_tables().unwrap() {
        let custom_table_provider = CustomDataSource {
            db_id: db_id,
            schema: Arc::new(table_details.1.to_arrow_schema()),
            pg_schema: table_details.1,
            table_metadata: table_details.0.clone(),
        };

        ctx.register_table(table_details.0.relname, Arc::new(custom_table_provider))
            .unwrap();
    }

    // let df = ctx
    //     .sql("SELECT * FROM information_schema.tables WHERE table_type = 'BASE TABLE'")
    //     .await
    //     .unwrap();
    // let df = ctx
    //     .sql(
    //         "SHOW COLUMNS FROM pgbench_accounts;", //         "SELECT
    //                                                //     table_schema,
    //                                                //     table_name,
    //                                                //     column_name,
    //                                                //     data_type,
    //                                                //     is_nullable
    //                                                // FROM information_schema.columns where table_name = 'pgbench_accounts'
    //                                                // ",
    //     )
    //     .await
    //     .unwrap();

    // let df = ctx
    //     .sql("SELECT orders.order_number, orders.total, customers.first_name FROM orders INNER JOIN customers ON orders.customer_id = customers.id")
    //     .await
    //     .unwrap();
    let df = ctx
        .sql("select bid from pgbench_accounts UNION ALL select id from customers;")
        .await
        .unwrap();
    // let mut stream = df.execute_stream().await.unwrap();
    // while let Some(Ok(batch)) = stream.next().await {
    //     let df = ctx.read_batch(batch).unwrap();
    //     // df.show().await.unwrap();
    // }
    // df.show_limit(1).await.unwrap();
    // println!("Got {} rows", df.count().await.unwrap());
    df.explain(false, false).unwrap().show().await.unwrap();
    Ok(())
}
