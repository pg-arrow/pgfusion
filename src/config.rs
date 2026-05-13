use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("failed to read config file '{path}': {source}")]
    Io {
        path: String,
        source: std::io::Error,
    },
    #[error("failed to parse config file '{path}': {source}")]
    Parse {
        path: String,
        source: toml::de::Error,
    },
}

/// Top-level pgfusion configuration loaded from a TOML file.
///
/// All fields are optional. CLI flags always override values set here.
#[derive(Debug, Default, Deserialize, Serialize)]
pub struct PgFusionConfig {
    pub query: Option<QueryConfig>,
    pub datasource: Option<DatasourceConfig>,
    pub connection: Option<ConnectionConfig>,
    pub output: Option<OutputConfig>,
}

/// DataFusion execution tuning — maps to `datafusion.execution.*` and `datafusion.runtime.*`.
#[derive(Debug, Default, Deserialize, Serialize)]
pub struct QueryConfig {
    /// Rows per Arrow RecordBatch (datafusion default: 8192).
    pub batch_size: Option<usize>,
    /// Parallel execution tasks. 0 or unset = CPU core count.
    pub target_partitions: Option<usize>,
    /// Merge small batches between operators (datafusion default: true).
    pub coalesce_batches: Option<bool>,
    /// Max memory for query execution, e.g. "512M" or "2G". Unset = unlimited.
    pub memory_limit: Option<String>,
    /// Directory for spill files when memory limit is exceeded.
    pub temp_directory: Option<String>,
    /// Parallel query planning threads. 0 or unset = CPU core count.
    pub planning_concurrency: Option<usize>,
}

/// pg_arrow heap file scan configuration.
#[derive(Debug, Default, Deserialize, Serialize)]
pub struct DatasourceConfig {
    /// Page-range partitions per heap file scan (default: 10).
    /// Each partition reads a contiguous range of pages in parallel.
    /// Higher values increase IO parallelism; diminishing returns above CPU count.
    pub partition_count: Option<usize>,
}

/// PostgreSQL live-connection features.
#[derive(Debug, Default, Deserialize, Serialize)]
pub struct ConnectionConfig {
    /// PostgreSQL connection string, e.g. "host=localhost dbname=mydb".
    pub pg_url: Option<String>,
    /// Run CHECKPOINT before each query (requires pg_url).
    pub checkpoint: Option<bool>,
    /// Acquire REPEATABLE READ snapshot for MVCC-consistent reads (requires pg_url).
    pub consistent: Option<bool>,
}

/// Output and display preferences.
#[derive(Debug, Default, Deserialize, Serialize)]
pub struct OutputConfig {
    /// Print query elapsed time after each statement.
    pub timing: Option<bool>,
    /// Print per-phase timing: pg connect / snapshot / query / rollback.
    pub debug_timing: Option<bool>,
    /// String displayed for NULL values in query output (default: "NULL").
    pub null_value: Option<String>,
}

impl PgFusionConfig {
    pub fn load(path: &Path) -> Result<Self, ConfigError> {
        let content = std::fs::read_to_string(path).map_err(|source| ConfigError::Io {
            path: path.display().to_string(),
            source,
        })?;
        toml::from_str(&content).map_err(|source| ConfigError::Parse {
            path: path.display().to_string(),
            source,
        })
    }
}
