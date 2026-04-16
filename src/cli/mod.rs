use std::time::{Duration, Instant};

use clap::Parser;
use datafusion::common::DataFusionError;
use datafusion::execution::context::SessionContext;
use pg_arrow::file::{error::PgError, set_data_dir};
use rustyline::DefaultEditor;
use tokio_util::sync::CancellationToken;

use crate::session::SessionOptions;

#[derive(Parser)]
#[command(name = "pg_fusion_cli")]
#[command(about = "Query PostgreSQL data files directly using SQL via DataFusion")]
struct Cli {
    /// Path to the PostgreSQL data directory (PGDATA)
    #[arg(short = 'd', long)]
    data_dir: String,

    /// Database OID to read from (found under data_dir/base/<db_id>)
    #[arg(long, default_value_t = 16384)]
    db_id: usize,

    /// Execute a SQL command and exit
    #[arg(short = 'c', long = "command")]
    command: Option<String>,

    /// Execute SQL commands from a file and exit
    #[arg(short = 'f', long = "file")]
    file: Option<String>,

    /// Enable query timing
    #[arg(short = 't', long = "timing")]
    timing: bool,

    /// Memory limit for query execution (e.g. 512M, 2G). Default: unlimited.
    #[arg(long)]
    memory_limit: Option<String>,

    /// Target rows per RecordBatch (default: 8192)
    #[arg(long)]
    batch_size: Option<usize>,

    /// Number of partitions for parallel execution (default: CPU core count)
    #[arg(long)]
    target_partitions: Option<usize>,

    /// Disable coalescing of small batches between operators
    #[arg(long)]
    no_coalesce: bool,
}

/// Parse a human-readable memory size string (e.g. "512M", "2G", "1024K") into bytes.
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

fn format_elapsed(elapsed: Duration) -> String {
    let ms = elapsed.as_secs_f64() * 1000.0;
    if elapsed.as_secs() >= 1 {
        let total_secs = elapsed.as_secs();
        let hrs = total_secs / 3600;
        let mins = (total_secs % 3600) / 60;
        let secs = total_secs % 60;
        let millis = elapsed.subsec_millis();
        format!("{:.3}ms ({:02}:{:02}:{:02}.{:03})", ms, hrs, mins, secs, millis)
    } else {
        format!("{:.3}ms", ms)
    }
}

async fn execute_query(ctx: &SessionContext, sql: &str) -> Result<(), DataFusionError> {
    let cancel = CancellationToken::new();
    let cancel_clone = cancel.clone();
    let ctrlc_handle = tokio::spawn(async move {
        tokio::signal::ctrl_c().await.ok();
        cancel_clone.cancel();
    });

    let df = ctx.sql(sql).await?;
    let mut query_handle = tokio::task::spawn(async move { df.show().await });

    let result = tokio::select! {
        _ = cancel.cancelled() => {
            query_handle.abort();
            eprintln!("\nQuery cancelled.");
            Ok(())
        }
        join_result = &mut query_handle => {
            match join_result {
                Ok(inner) => inner,
                Err(join_err) if join_err.is_panic() => {
                    let panic_msg = match join_err.into_panic().downcast::<String>() {
                        Ok(msg) => *msg,
                        Err(payload) => match payload.downcast::<&str>() {
                            Ok(msg) => msg.to_string(),
                            Err(_) => "unknown panic".to_string(),
                        },
                    };
                    eprintln!("Query panicked: {panic_msg}");
                    Ok(())
                }
                Err(_) => {
                    eprintln!("Query task cancelled");
                    Ok(())
                }
            }
        }
    };

    ctrlc_handle.abort();
    result
}

/// Entry point for the CLI. Parses arguments and runs the appropriate mode
/// (single command, file execution, or interactive REPL).
pub async fn run() -> Result<(), PgError> {
    let cli = Cli::parse();

    set_data_dir(cli.data_dir);
    let db_id = cli.db_id;

    let opts = SessionOptions {
        memory_limit: cli.memory_limit.as_deref().map(parse_memory_size),
        batch_size: cli.batch_size,
        target_partitions: cli.target_partitions,
        coalesce_batches: if cli.no_coalesce { Some(false) } else { None },
    };

    let ctx = crate::create_session_with_options(db_id, &opts).expect("failed to create session");

    if let Some(command) = cli.command {
        let start = Instant::now();
        if let Err(e) = execute_query(&ctx, &command).await {
            eprintln!("Error: {e}");
            std::process::exit(1);
        }
        if cli.timing {
            let elapsed = start.elapsed();
            eprintln!("Time: {}", format_elapsed(elapsed));
        }
        return Ok(());
    }

    if let Some(file) = cli.file {
        let sql = std::fs::read_to_string(&file).unwrap_or_else(|e| {
            eprintln!("Failed to read {file}: {e}");
            std::process::exit(1);
        });
        for stmt in sql.split(';') {
            let stmt = stmt.trim();
            if stmt.is_empty() {
                continue;
            }
            let start = Instant::now();
            if let Err(e) = execute_query(&ctx, stmt).await {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
            if cli.timing {
                let elapsed = start.elapsed();
                eprintln!("Time: {}", format_elapsed(elapsed));
            }
        }
        return Ok(());
    }

    println!("pg_fusion_cli");
    println!("Type \\? for help.\n");

    let mut rl = DefaultEditor::new().unwrap();
    let mut timing = cli.timing;

    loop {
        let readline = rl.readline("pg_fusion> ");
        match readline {
            Ok(line) => {
                let mut trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }

                let _ = rl.add_history_entry(trimmed);

                if trimmed == "\\q" || trimmed == "quit" || trimmed == "exit" {
                    break;
                }

                if trimmed == "\\?" || trimmed == "\\help" {
                    println!("  \\dt        List tables");
                    println!("  \\timing    Toggle query timing");
                    println!("  \\?         Show this help");
                    println!("  \\q         Quit (also: quit, exit, Ctrl-D)");
                    continue;
                }

                if trimmed == "\\dt" {
                    trimmed = "SHOW TABLES;";
                }

                if trimmed == "\\timing" {
                    timing = !timing;
                    println!("Timing is {}.", if timing { "on" } else { "off" });
                    continue;
                }

                let start = Instant::now();

                if let Err(e) = execute_query(&ctx, trimmed).await {
                    eprintln!("Error: {e}");
                }

                if timing {
                    let elapsed = start.elapsed();
                    println!("Time: {}", format_elapsed(elapsed));
                }
            }
            Err(
                rustyline::error::ReadlineError::Interrupted | rustyline::error::ReadlineError::Eof,
            ) => {
                break;
            }
            Err(e) => {
                eprintln!("Readline error: {e}");
                break;
            }
        }
    }

    Ok(())
}
