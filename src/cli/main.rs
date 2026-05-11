mod completer;

use std::io::{self, Write};
use std::time::{Duration, Instant};

use arrow::util::pretty::pretty_format_batches;
use clap::Parser;
use completer::{collect_table_names, PgFusionCompleter, PgFusionHelper};
use datafusion::common::DataFusionError;
use datafusion::execution::context::SessionContext;
use futures::StreamExt;
use mimalloc::MiMalloc;
use pg_arrow::file::{error::PgError, set_data_dir};
use pgfusion_lib::session::SessionOptions;
use pgfusion_lib::snapshot::PgSnapshot;
use rustyline::hint::HistoryHinter;
use rustyline::Editor;
use tokio_postgres;
use tokio_util::sync::CancellationToken;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

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

    /// PostgreSQL connection string (e.g. "host=localhost dbname=tpch").
    /// Required when --checkpoint is set.
    #[arg(long)]
    pg_url: Option<String>,

    /// Run CHECKPOINT on the PostgreSQL server before executing queries.
    /// Requires --pg-url.
    #[arg(long)]
    checkpoint: bool,

    /// Acquire a REPEATABLE READ snapshot before each query for MVCC-consistent reads.
    /// Requires --pg-url.
    #[arg(long)]
    consistent: bool,

    /// Print per-phase timing breakdown (pg connect, snapshot, query, rollback).
    #[arg(long)]
    debug_timing: bool,
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

fn format_elapsed(elapsed: Duration) -> String {
    let ms = elapsed.as_secs_f64() * 1000.0;
    if elapsed.as_secs() >= 1 {
        let total_secs = elapsed.as_secs();
        let hrs = total_secs / 3600;
        let mins = (total_secs % 3600) / 60;
        let secs = total_secs % 60;
        let millis = elapsed.subsec_millis();
        format!(
            "{:.3}ms ({:02}:{:02}:{:02}.{:03})",
            ms, hrs, mins, secs, millis
        )
    } else {
        format!("{:.3}ms", ms)
    }
}

async fn run_pg_checkpoint(pg_url: &str) -> Result<(), PgError> {
    let (client, connection) = tokio_postgres::connect(pg_url, tokio_postgres::NoTls)
        .await
        .map_err(|e| PgError::DecodeError(format!("pg connect failed: {e}")))?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("pg connection error: {e}");
        }
    });
    client
        .execute("CHECKPOINT", &[])
        .await
        .map_err(|e| PgError::DecodeError(format!("CHECKPOINT failed: {e}")))?;
    Ok(())
}

async fn execute_query(ctx: &SessionContext, sql: &str) -> Result<(), DataFusionError> {
    let cancel = CancellationToken::new();
    let cancel_clone = cancel.clone();
    let ctrlc_handle = tokio::spawn(async move {
        tokio::signal::ctrl_c().await.ok();
        cancel_clone.cancel();
    });

    let df = ctx.sql(sql).await?;
    let mut stream = df.execute_stream().await?.boxed();

    let mut query_handle = tokio::task::spawn(async move {
        while let Some(batch) = stream.next().await {
            let batch = batch?;
            let formatted = pretty_format_batches(&[batch])
                .map_err(|e| DataFusionError::External(Box::new(e)))?;
            // Lock stdout only for the write, not across the await.
            writeln!(io::stdout().lock(), "{formatted}")
                .map_err(|e| DataFusionError::External(Box::new(e)))?;
        }
        Ok::<(), DataFusionError>(())
    });

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

async fn maybe_checkpoint(pg_url: Option<&str>) {
    if let Some(url) = pg_url {
        if let Err(e) = run_pg_checkpoint(url).await {
            eprintln!("Warning: checkpoint failed: {e}");
        }
    }
}

/// Open a REPEATABLE READ transaction on PostgreSQL, get the snapshot, inject it into
/// the session config, run `f`, then commit. The open transaction holds back VACUUM
/// from removing dead tuple versions that the snapshot needs to see (or exclude).
/// When `debug` is true, prints timing for each phase.
async fn with_pg_snapshot<F, Fut>(ctx: &SessionContext, pg_url: &str, debug: bool, f: F)
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let t_connect = Instant::now();
    let conn_result = tokio_postgres::connect(pg_url, tokio_postgres::NoTls).await;
    let (client, conn) = match conn_result {
        Ok(pair) => pair,
        Err(e) => {
            eprintln!("Warning: pg connect failed: {e}");
            f().await;
            return;
        }
    };
    if debug {
        eprintln!("[debug] pg connect:       {}", format_elapsed(t_connect.elapsed()));
    }
    tokio::spawn(async move {
        if let Err(e) = conn.await {
            eprintln!("pg connection error: {e}");
        }
    });

    let t_snap = Instant::now();
    let snap = async {
        client
            .execute("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ", &[])
            .await
            .map_err(|e| format!("BEGIN failed: {e}"))?;
        let row = client
            .query_one("SELECT txid_current_snapshot()::text", &[])
            .await
            .map_err(|e| format!("snapshot query failed: {e}"))?;
        let snap_str: &str = row.get(0);
        PgSnapshot::parse(snap_str).ok_or_else(|| format!("failed to parse snapshot: {snap_str}"))
    }
    .await;

    match snap {
        Ok(snap) => {
            if debug {
                eprintln!(
                    "[debug] snapshot acquire: {} (xmin={} xmax={} xip={})",
                    format_elapsed(t_snap.elapsed()),
                    snap.xmin,
                    snap.xmax,
                    snap.xip.len()
                );
            }
            ctx.state_ref()
                .write()
                .config_mut()
                .options_mut()
                .extensions
                .insert(snap);
            let t_query = Instant::now();
            f().await;
            if debug {
                eprintln!("[debug] query execution:  {}", format_elapsed(t_query.elapsed()));
            }
        }
        Err(e) => {
            eprintln!("Warning: snapshot acquisition failed: {e}");
            f().await;
        }
    }

    let t_rollback = Instant::now();
    let _ = client.execute("ROLLBACK", &[]).await;
    if debug {
        eprintln!("[debug] rollback:         {}", format_elapsed(t_rollback.elapsed()));
    }
}

async fn execute_file(
    ctx: &SessionContext,
    path: &str,
    timing: bool,
    debug: bool,
    checkpoint_url: Option<&str>,
    snapshot_url: Option<&str>,
) -> Result<(), PgError> {
    let sql = std::fs::read_to_string(path).map_err(|e| PgError::DecodeError(e.to_string()))?;
    for stmt in sql.split(';') {
        let stmt = stmt.trim();
        if stmt.is_empty() {
            continue;
        }
        maybe_checkpoint(checkpoint_url).await;
        let start = Instant::now();
        if let Some(url) = snapshot_url {
            with_pg_snapshot(ctx, url, debug, || async {
                if let Err(e) = execute_query(ctx, stmt).await {
                    eprintln!("Error: {e}");
                }
            })
            .await;
        } else if let Err(e) = execute_query(ctx, stmt).await {
            eprintln!("Error: {e}");
        }
        if timing {
            eprintln!("Time: {}", format_elapsed(start.elapsed()));
        }
    }
    Ok(())
}

async fn run_command(
    ctx: &SessionContext,
    sql: &str,
    timing: bool,
    debug: bool,
    checkpoint_url: Option<&str>,
    snapshot_url: Option<&str>,
) {
    maybe_checkpoint(checkpoint_url).await;
    let start = Instant::now();
    if let Some(url) = snapshot_url {
        with_pg_snapshot(ctx, url, debug, || async {
            if let Err(e) = execute_query(ctx, sql).await {
                eprintln!("Error: {e}");
            }
        })
        .await;
    } else if let Err(e) = execute_query(ctx, sql).await {
        eprintln!("Error: {e}");
    }
    if timing {
        eprintln!("Time: {}", format_elapsed(start.elapsed()));
    }
}

enum InputAction {
    Quit,
    /// Run a SQL string.
    Query(String),
    /// Already handled inline (meta-command with no SQL).
    Done,
}

fn resolve_input(
    trimmed: &str,
    out: &mut impl Write,
    timing: &mut bool,
    data_dir: &str,
    db_id: usize,
) -> InputAction {
    match trimmed {
        "\\q" | "quit" | "exit" => return InputAction::Quit,

        "\\?" | "\\help" => {
            print_help(out).ok();
            return InputAction::Done;
        }

        "\\timing" => {
            *timing = !*timing;
            writeln!(out, "Timing is {}.", if *timing { "on" } else { "off" }).ok();
            return InputAction::Done;
        }

        "\\x" => {
            writeln!(out, "Expanded display not yet supported.").ok();
            return InputAction::Done;
        }

        "\\l" => {
            writeln!(out, "Multiple databases not supported. Connected to db_id {db_id}.").ok();
            return InputAction::Done;
        }

        "\\c" => {
            writeln!(out, "data_dir: {data_dir}").ok();
            writeln!(out, "db_id:    {db_id}").ok();
            return InputAction::Done;
        }

        "\\d" | "\\dt" => return InputAction::Query("SHOW TABLES;".to_string()),

        _ => {}
    }

    if let Some(table) = trimmed.strip_prefix("\\d ") {
        let table = table.trim();
        return InputAction::Query(format!("DESCRIBE {table};"));
    }

    // \i handled separately (needs async + ctx); signal caller with a sentinel
    InputAction::Query(trimmed.to_string())
}

fn print_help(out: &mut impl Write) -> io::Result<()> {
    writeln!(out, "  \\d             List tables")?;
    writeln!(out, "  \\d <table>     Describe table columns")?;
    writeln!(out, "  \\dt            List tables")?;
    writeln!(out, "  \\timing        Toggle query timing")?;
    writeln!(out, "  \\debug         Toggle debug timing (pg connect / snapshot / query / rollback)")?;
    writeln!(out, "  \\i <file>      Execute SQL from file")?;
    writeln!(out, "  \\c             Show current connection info")?;
    writeln!(out, "  \\x             Toggle expanded display (not yet supported)")?;
    writeln!(out, "  \\l             List databases (not applicable)")?;
    writeln!(out, "  \\?             Show this help")?;
    writeln!(out, "  \\q             Quit (also: quit, exit, Ctrl-D)")
}

#[tokio::main]
async fn main() -> Result<(), PgError> {
    env_logger::init();

    let cli = Cli::parse();

    set_data_dir(cli.data_dir.clone());
    let db_id = cli.db_id;

    let opts = SessionOptions {
        memory_limit: cli.memory_limit.as_deref().map(parse_memory_size),
        batch_size: cli.batch_size,
        target_partitions: cli.target_partitions,
        coalesce_batches: if cli.no_coalesce { Some(false) } else { None },
    };

    let ctx = pgfusion_lib::create_session_with_options(db_id, &opts)
        .expect("failed to create session");

    if (cli.checkpoint || cli.consistent) && cli.pg_url.is_none() {
        eprintln!("Warning: --checkpoint and --consistent require --pg-url");
    }
    let checkpoint_url: Option<&str> = if cli.checkpoint {
        cli.pg_url.as_deref()
    } else {
        None
    };
    let snapshot_url: Option<&str> = if cli.consistent {
        cli.pg_url.as_deref()
    } else {
        None
    };

    let debug = cli.debug_timing;

    if let Some(command) = cli.command {
        run_command(&ctx, &command, cli.timing, debug, checkpoint_url, snapshot_url).await;
        return Ok(());
    }

    if let Some(ref file) = cli.file {
        return execute_file(&ctx, file, cli.timing, debug, checkpoint_url, snapshot_url).await;
    }

    let mut stdout = io::stdout();
    writeln!(stdout, "pg_fusion_cli").ok();
    writeln!(stdout, "Type \\? for help.\n").ok();

    let table_names = collect_table_names(&ctx).await;
    let helper = PgFusionHelper {
        completer: PgFusionCompleter { table_names },
        hinter: HistoryHinter::new(),
    };

    let mut rl: Editor<PgFusionHelper, _> = Editor::new().unwrap();
    rl.set_helper(Some(helper));
    let mut timing = cli.timing;
    let mut debug = debug;

    loop {
        let readline = rl.readline("pg_fusion> ");
        match readline {
            Ok(line) => {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }

                let _ = rl.add_history_entry(trimmed);

                if trimmed == "\\debug" {
                    debug = !debug;
                    writeln!(stdout, "Debug timing is {}.", if debug { "on" } else { "off" }).ok();
                    continue;
                }

                // \i needs async + ctx, handle before resolve_input
                if let Some(path) = trimmed.strip_prefix("\\i").map(str::trim) {
                    if path.is_empty() {
                        eprintln!("Usage: \\i <file>");
                    } else {
                        let start = Instant::now();
                        if let Err(e) = execute_file(&ctx, path, false, debug, checkpoint_url, snapshot_url).await {
                            eprintln!("Error: {e}");
                        }
                        if timing {
                            eprintln!("Time: {}", format_elapsed(start.elapsed()));
                        }
                    }
                    continue;
                }

                match resolve_input(trimmed, &mut stdout, &mut timing, &cli.data_dir, db_id) {
                    InputAction::Quit => break,
                    InputAction::Done => continue,
                    InputAction::Query(sql) => run_command(&ctx, &sql, timing, debug, checkpoint_url, snapshot_url).await,
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
