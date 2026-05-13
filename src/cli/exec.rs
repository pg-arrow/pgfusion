use std::io::{self, Write};
use std::time::Instant;

use arrow::util::pretty::pretty_format_batches;
use datafusion::common::DataFusionError;
use datafusion::execution::context::SessionContext;
use futures::StreamExt;
use pg_arrow::file::error::PgError;
use pgfusion_lib::snapshot::PgSnapshot;
use tokio_util::sync::CancellationToken;

use super::repl::format_elapsed;

pub(super) async fn run_pg_checkpoint(pg_url: &str) -> Result<(), PgError> {
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

pub(super) async fn execute_query(ctx: &SessionContext, sql: &str) -> Result<(), DataFusionError> {
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

pub(super) async fn maybe_checkpoint(pg_url: Option<&str>) {
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
pub(super) async fn with_pg_snapshot<F, Fut>(
    ctx: &SessionContext,
    pg_url: &str,
    debug: bool,
    f: F,
) where
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

pub(super) async fn execute_file(
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

pub(super) async fn run_command(
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
