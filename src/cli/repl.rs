use std::io::{self, Write};
use std::time::{Duration, Instant};

use datafusion::execution::context::SessionContext;
use rustyline::hint::HistoryHinter;
use rustyline::Editor;

use super::completer::{collect_table_names, PgFusionCompleter, PgFusionHelper};
use super::exec::{execute_file, run_command};

pub(super) enum InputAction {
    Quit,
    Query(String),
    Done,
}

pub(super) fn format_elapsed(elapsed: Duration) -> String {
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

pub(super) fn resolve_input(
    trimmed: &str,
    out: &mut impl Write,
    timing: &mut bool,
    data_dir: &str,
    db_name: &str,
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
            match pg_arrow::table::list_databases() {
                Ok(dbs) => {
                    writeln!(out, "  {:>10}  {}", "oid", "name").ok();
                    for d in dbs {
                        writeln!(out, "  {:>10}  {}", d.oid, d.datname).ok();
                    }
                }
                Err(e) => {
                    writeln!(out, "pg_database lookup failed: {e}").ok();
                }
            }
            return InputAction::Done;
        }

        "\\c" => {
            writeln!(out, "data_dir: {data_dir}").ok();
            writeln!(out, "database: {db_name} (oid={db_id})").ok();
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
    writeln!(
        out,
        "  \\debug         Toggle debug timing (pg connect / snapshot / query / rollback)"
    )?;
    writeln!(out, "  \\i <file>      Execute SQL from file")?;
    writeln!(out, "  \\count         Toggle count-only output (suppress rows, show row count)")?;
    writeln!(out, "  \\c             Show current connection info")?;
    writeln!(out, "  \\x             Toggle expanded display (not yet supported)")?;
    writeln!(out, "  \\l             List databases (reads pg_database)")?;
    writeln!(out, "  \\c <db>        Switch to another database (also: USE <db>;)")?;
    writeln!(out, "  \\?             Show this help")?;
    writeln!(out, "  \\q             Quit (also: quit, exit, Ctrl-D)")
}

pub(super) struct ReplState {
    pub timing: bool,
    pub debug: bool,
    pub data_dir: String,
    pub db_name: String,
    pub db_id: usize,
    pub session_opts: pgfusion_lib::session::SessionOptions,
    pub checkpoint_url: Option<String>,
    pub snapshot_url: Option<String>,
    pub count_only: bool,
}

pub(super) async fn run_repl(ctx: SessionContext, mut state: ReplState) {
    let mut stdout = io::stdout();
    writeln!(stdout, "pg_fusion_cli").ok();
    writeln!(stdout, "Connected to database \"{}\".", state.db_name).ok();
    writeln!(stdout, "Type \\? for help.\n").ok();

    let mut ctx = ctx;
    let table_names = collect_table_names(&ctx).await;
    let helper = PgFusionHelper {
        completer: PgFusionCompleter { table_names },
        hinter: HistoryHinter::new(),
    };

    let mut rl: Editor<PgFusionHelper, _> = Editor::new().unwrap();
    rl.set_helper(Some(helper));

    let mut timing = state.timing;
    let mut debug = state.debug;
    let mut count_only = state.count_only;
    let checkpoint_url = state.checkpoint_url.as_deref();
    let snapshot_url = state.snapshot_url.as_deref();

    loop {
        let prompt = format!("{}=> ", state.db_name);
        let readline = rl.readline(&prompt);
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

                if trimmed == "\\count" {
                    count_only = !count_only;
                    writeln!(stdout, "Count-only output is {}.", if count_only { "on" } else { "off" }).ok();
                    continue;
                }

                // \i needs async + ctx, handle before resolve_input
                if let Some(path) = trimmed.strip_prefix("\\i").map(str::trim) {
                    if path.is_empty() {
                        eprintln!("Usage: \\i <file>");
                    } else {
                        let start = Instant::now();
                        if let Err(e) = execute_file(
                            &ctx,
                            path,
                            false,
                            debug,
                            checkpoint_url,
                            snapshot_url,
                            count_only,
                        )
                        .await
                        {
                            eprintln!("Error: {e}");
                        }
                        if timing {
                            eprintln!("Time: {}", format_elapsed(start.elapsed()));
                        }
                    }
                    continue;
                }

                // USE <db>;  or  \c <db>  — rebuild session against the named database.
                if let Some(target) = parse_use_database(trimmed) {
                    match switch_database(&target, &state.session_opts) {
                        Ok((new_ctx, new_oid)) => {
                            ctx = new_ctx;
                            state.db_name = target.clone();
                            state.db_id = new_oid;
                            let names = collect_table_names(&ctx).await;
                            rl.helper_mut().unwrap().completer.table_names = names;
                            writeln!(
                                stdout,
                                "You are now connected to database \"{}\" (oid={}).",
                                target, new_oid
                            )
                            .ok();
                        }
                        Err(e) => eprintln!("Error: {e}"),
                    }
                    continue;
                }

                match resolve_input(
                    trimmed,
                    &mut stdout,
                    &mut timing,
                    &state.data_dir,
                    &state.db_name,
                    state.db_id,
                ) {
                    InputAction::Quit => break,
                    InputAction::Done => continue,
                    InputAction::Query(sql) => {
                        run_command(
                            &ctx,
                            &sql,
                            timing,
                            debug,
                            checkpoint_url,
                            snapshot_url,
                            count_only,
                        )
                        .await
                    }
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
}

/// Parse `USE <name>;` or `\c <name>` — return Some(name) if it matches.
fn parse_use_database(input: &str) -> Option<String> {
    let s = input.trim().trim_end_matches(';').trim();
    if let Some(rest) = s.strip_prefix("\\c").or_else(|| s.strip_prefix("\\connect")) {
        let name = rest.trim();
        if !name.is_empty() && !name.contains(char::is_whitespace) {
            return Some(name.trim_matches('"').to_string());
        }
    }
    // case-insensitive USE
    let lower = s.to_ascii_lowercase();
    if let Some(rest) = lower.strip_prefix("use ") {
        let name = rest.trim();
        if !name.is_empty() {
            return Some(name.trim_matches('"').to_string());
        }
    }
    None
}

/// Resolve a database name to its OID and build a fresh `SessionContext`.
fn switch_database(
    name: &str,
    opts: &pgfusion_lib::session::SessionOptions,
) -> Result<(SessionContext, usize), String> {
    let oid = pg_arrow::table::get_database_oid(name)
        .map_err(|e| format!("pg_database lookup failed: {e}"))?
        .ok_or_else(|| format!("database not found: {name}"))? as usize;
    let ctx = pgfusion_lib::create_session_with_options(oid, opts)
        .map_err(|e| format!("create session: {e}"))?;
    Ok((ctx, oid))
}
