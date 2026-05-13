use crate::datasource::CustomDataSource;
use datafusion::execution::memory_pool::GreedyMemoryPool;
use datafusion::execution::runtime_env::RuntimeEnvBuilder;
use datafusion::prelude::{SessionConfig, SessionContext};
use pg_arrow::file::reader::Oid;
use pg_arrow::table::PgTableReader;
use std::sync::Arc;

/// Tuning knobs for the DataFusion session.
#[derive(Debug, Clone, Default)]
pub struct SessionOptions {
    /// Maximum memory for query execution (bytes). `None` = unlimited.
    pub memory_limit: Option<usize>,
    /// Target rows per RecordBatch (default: 8192).
    pub batch_size: Option<usize>,
    /// Number of DataFusion parallel execution tasks. `None` = CPU core count.
    pub target_partitions: Option<usize>,
    /// Merge small batches between operators (default: true).
    pub coalesce_batches: Option<bool>,
    /// Heap file page-range partitions per table scan (default: 10).
    pub partition_count: Option<usize>,
    /// Parallel query planning threads. `None` = CPU core count.
    pub planning_concurrency: Option<usize>,
    /// Directory for spill files when memory limit is exceeded.
    pub temp_directory: Option<String>,
}

/// Create a `SessionContext` with all tables from the given database registered.
pub fn create_session(
    db_id: Oid,
) -> std::result::Result<SessionContext, pg_arrow::file::error::PgError> {
    create_session_with_options(db_id, &SessionOptions::default())
}

/// Create a `SessionContext` with explicit tuning options.
pub fn create_session_with_options(
    db_id: Oid,
    opts: &SessionOptions,
) -> std::result::Result<SessionContext, pg_arrow::file::error::PgError> {
    let mut config = SessionConfig::new();
    config.options_mut().catalog.information_schema = true;

    if let Some(batch_size) = opts.batch_size {
        config.options_mut().execution.batch_size = batch_size;
    }
    if let Some(partitions) = opts.target_partitions {
        config.options_mut().execution.target_partitions = partitions;
    }
    if let Some(coalesce) = opts.coalesce_batches {
        config.options_mut().execution.coalesce_batches = coalesce;
    }
    if let Some(concurrency) = opts.planning_concurrency {
        config.options_mut().execution.planning_concurrency = concurrency;
    }

    let partition_count = opts.partition_count.unwrap_or(10);

    let ctx = if opts.memory_limit.is_some() || opts.temp_directory.is_some() {
        let mut rt_builder = RuntimeEnvBuilder::new();
        if let Some(limit) = opts.memory_limit {
            rt_builder = rt_builder.with_memory_pool(Arc::new(GreedyMemoryPool::new(limit)));
        }
        if let Some(ref dir) = opts.temp_directory {
            rt_builder = rt_builder.with_temp_file_path(dir);
        }
        let runtime = rt_builder.build_arc().expect("failed to build runtime env");
        SessionContext::new_with_config_rt(config, runtime)
    } else {
        SessionContext::new_with_config(config)
    };

    let table_reader = PgTableReader::new(db_id)?;
    for table_details in table_reader.get_all_tables()? {
        let provider = CustomDataSource {
            db_id,
            schema: Arc::new(table_details.1.to_arrow_schema()),
            pg_schema: table_details.1,
            table_metadata: table_details.0.clone(),
            partition_count,
        };

        ctx.register_table(&table_details.0.relname, Arc::new(provider))
            .unwrap();
    }

    Ok(ctx)
}
