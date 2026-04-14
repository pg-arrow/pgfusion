use crate::datasource::CustomDataSource;
use datafusion::prelude::{SessionConfig, SessionContext};
use pg_arrow::file::reader::Oid;
use pg_arrow::table::PgTableReader;
use std::sync::Arc;

/// Create a `SessionContext` with all tables from the given database registered.
pub fn create_session(
    db_id: Oid,
) -> std::result::Result<SessionContext, pg_arrow::file::error::PgError> {
    let mut config = SessionConfig::new();
    config.options_mut().catalog.information_schema = true;
    let ctx = SessionContext::new_with_config(config);

    let table_reader = PgTableReader::new(db_id)?;
    for table_details in table_reader.get_all_tables()? {
        let provider = CustomDataSource {
            db_id,
            schema: Arc::new(table_details.1.to_arrow_schema()),
            pg_schema: table_details.1,
            table_metadata: table_details.0.clone(),
        };

        ctx.register_table(&table_details.0.relname, Arc::new(provider))
            .unwrap();
    }

    Ok(ctx)
}
