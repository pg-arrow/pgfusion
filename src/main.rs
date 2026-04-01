use std::time::Instant;

use clap::Parser;
use datafusion::common::DataFusionError;
use datafusion::execution::context::SessionContext;
use pg_arrow::file::{error::PgError, set_data_dir};
use pg_fusion_lib::create_session;
use rustyline::DefaultEditor;
use tokio_util::sync::CancellationToken;

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

#[tokio::main]
async fn main() -> Result<(), PgError> {
    env_logger::init();

    let cli = Cli::parse();

    set_data_dir(cli.data_dir);
    let db_id = cli.db_id;

    let ctx = create_session(db_id).expect("failed to create session");

    println!("pg_fusion_cli");
    println!("Type \\? for help.\n");

    let mut rl = DefaultEditor::new().unwrap();
    let mut timing = false;

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
                    println!("Time: {:.3}ms", elapsed.as_secs_f64() * 1000.0);
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
