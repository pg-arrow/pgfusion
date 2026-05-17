mod completer;
mod exec;
mod repl;

use anyhow::{Context, Result};
use clap::Parser;
use pg_arrow::file::set_data_dir;
use pgfusion_lib::config::PgFusionConfig;
use pgfusion_lib::session::SessionOptions;

use exec::{execute_file, run_command};
use repl::{ReplState, run_repl};

#[cfg(feature = "jemalloc")]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

#[cfg(not(feature = "jemalloc"))]
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

#[derive(Parser)]
#[command(name = "pg_fusion_cli")]
#[command(about = "Query PostgreSQL data files directly using SQL via DataFusion")]
struct Cli {
    /// Path to the PostgreSQL data directory (PGDATA)
    #[arg(short = 'D', long)]
    data_dir: String,

    /// Database name to connect to (resolved against pg_database; default: postgres)
    #[arg(short = 'd', long, default_value = "postgres")]
    db: String,

    /// Execute a SQL command and exit
    #[arg(short = 'c', long = "command")]
    command: Option<String>,

    /// Execute SQL commands from a file and exit
    #[arg(short = 'f', long = "file")]
    file: Option<String>,

    /// Enable query timing (overrides config file output.timing)
    #[arg(short = 't', long = "timing")]
    timing: bool,

    /// PostgreSQL connection string (e.g. "host=localhost dbname=tpch").
    /// Overrides config file connection.pg_url.
    #[arg(long)]
    pg_url: Option<String>,

    /// Run CHECKPOINT on the PostgreSQL server before executing queries.
    /// Requires --pg-url or config file connection.pg_url.
    #[arg(long)]
    checkpoint: bool,

    /// Acquire a REPEATABLE READ snapshot before each query for MVCC-consistent reads.
    /// Requires --pg-url or config file connection.pg_url.
    #[arg(long)]
    consistent: bool,

    /// Path to a TOML config file. See pgfusion_config.toml for all options.
    #[arg(long, value_name = "FILE")]
    config: Option<String>,
}

fn parse_memory_size(s: &str) -> usize {
    let s = s.trim();
    let (num, multiplier) = if let Some(n) = s.strip_suffix('G').or_else(|| s.strip_suffix('g')) {
        (n, 1024 * 1024 * 1024)
    } else if let Some(n) = s.strip_suffix('M').or_else(|| s.strip_suffix('m')) {
        (n, 1024 * 1024)
    } else if let Some(n) = s.strip_suffix('K').or_else(|| s.strip_suffix('k')) {
        (n, 1024)
    } else {
        (s, 1)
    };
    num.trim()
        .parse::<usize>()
        .unwrap_or_else(|_| panic!("invalid memory size: {s}"))
        * multiplier
}

/// Fully-resolved runtime settings after merging the config file with CLI flags.
/// CLI flags take precedence over config file values.
struct RuntimeConfig {
    session: SessionOptions,
    pg_url: Option<String>,
    checkpoint: bool,
    consistent: bool,
    timing: bool,
    debug_timing: bool,
}

impl RuntimeConfig {
    fn build(cli: &Cli, file_cfg: &PgFusionConfig) -> Self {
        let q = file_cfg.query.as_ref();
        let ds = file_cfg.datasource.as_ref();
        let conn = file_cfg.connection.as_ref();
        let out = file_cfg.output.as_ref();

        Self {
            session: SessionOptions {
                memory_limit: q.and_then(|q| q.memory_limit.as_deref().map(parse_memory_size)),
                batch_size: q.and_then(|q| q.batch_size),
                target_partitions: q.and_then(|q| q.target_partitions),
                coalesce_batches: q.and_then(|q| q.coalesce_batches),
                partition_count: ds.and_then(|d| d.partition_count),
                planning_concurrency: q.and_then(|q| q.planning_concurrency),
                temp_directory: q.and_then(|q| q.temp_directory.clone()),
            },
            pg_url: cli.pg_url.clone().or_else(|| conn?.pg_url.clone()),
            checkpoint: cli.checkpoint || conn.and_then(|c| c.checkpoint).unwrap_or(false),
            consistent: cli.consistent || conn.and_then(|c| c.consistent).unwrap_or(false),
            timing: cli.timing || out.and_then(|o| o.timing).unwrap_or(false),
            debug_timing: out.and_then(|o| o.debug_timing).unwrap_or(false),
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    let cli = Cli::parse();

    set_data_dir(cli.data_dir.clone());

    let db_id = pg_arrow::table::get_database_oid(&cli.db)
        .with_context(|| format!("failed to read pg_database under {}", cli.data_dir))?
        .ok_or_else(|| anyhow::anyhow!("database not found: {}", cli.db))? as usize;

    let file_cfg = cli
        .config
        .as_deref()
        .map(|p| PgFusionConfig::load(std::path::Path::new(p)))
        .transpose()
        .with_context(|| "failed to load config file")?
        .unwrap_or_default();

    let cfg = RuntimeConfig::build(&cli, &file_cfg);

    let ctx = pgfusion_lib::create_session_with_options(db_id, &cfg.session)
        .with_context(|| format!("failed to create session for db={} (oid={db_id})", cli.db))?;

    if (cfg.checkpoint || cfg.consistent) && cfg.pg_url.is_none() {
        eprintln!("Warning: --checkpoint and --consistent require --pg-url");
    }
    let checkpoint_url: Option<&str> = if cfg.checkpoint { cfg.pg_url.as_deref() } else { None };
    let snapshot_url: Option<&str> = if cfg.consistent { cfg.pg_url.as_deref() } else { None };

    if let Some(command) = cli.command {
        run_command(&ctx, &command, cfg.timing, cfg.debug_timing, checkpoint_url, snapshot_url)
            .await;
        return Ok(());
    }

    if let Some(ref file) = cli.file {
        return execute_file(&ctx, file, cfg.timing, cfg.debug_timing, checkpoint_url, snapshot_url)
            .await
            .with_context(|| format!("failed to execute file: {}", file));
    }

    run_repl(
        ctx,
        ReplState {
            timing: cfg.timing,
            debug: cfg.debug_timing,
            data_dir: cli.data_dir,
            db_name: cli.db,
            db_id,
            session_opts: cfg.session,
            checkpoint_url: checkpoint_url.map(str::to_owned),
            snapshot_url: snapshot_url.map(str::to_owned),
        },
    )
    .await;

    Ok(())
}
