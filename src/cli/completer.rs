use datafusion::execution::context::SessionContext;
use rustyline::completion::{Completer, Pair};
use rustyline::hint::HistoryHinter;
use rustyline::Context;
use rustyline_derive::{Completer, Helper, Highlighter, Hinter, Validator};

pub(super) const BACKSLASH_COMMANDS: &[&str] = &[
    "\\d", "\\dt", "\\timing", "\\i", "\\c", "\\x", "\\l", "\\?", "\\q",
];

const SQL_KEYWORDS: &[&str] = &[
    "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "JOIN",
    "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "ON", "AS", "INSERT", "UPDATE", "DELETE",
    "CREATE", "DROP", "ALTER", "TABLE", "WITH", "UNION", "ALL", "DISTINCT", "COUNT", "SUM",
    "AVG", "MIN", "MAX", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "BETWEEN", "CASE",
    "WHEN", "THEN", "ELSE", "END", "DESCRIBE", "SHOW", "EXPLAIN",
];

// Keywords after which the next token is likely a table name.
const TABLE_CONTEXT_KEYWORDS: &[&str] = &[
    "FROM", "JOIN", "INTO", "TABLE", "UPDATE", "DESCRIBE",
];

pub(super) struct PgFusionCompleter {
    pub table_names: Vec<String>,
}

impl Completer for PgFusionCompleter {
    type Candidate = Pair;

    fn complete(
        &self,
        line: &str,
        pos: usize,
        _ctx: &Context,
    ) -> rustyline::Result<(usize, Vec<Pair>)> {
        let slice = &line[..pos];
        let word_start = slice
            .rfind(|c: char| c.is_whitespace())
            .map(|i| i + 1)
            .unwrap_or(0);
        let word = &slice[word_start..];
        let upper = slice.trim_start().to_uppercase();
        let is_backslash_cmd = slice.trim_start().starts_with('\\') && !slice.contains(' ');

        let candidates: Vec<&str> = if is_backslash_cmd {
            BACKSLASH_COMMANDS.to_vec()
        } else if needs_table_completion(&upper) {
            self.table_names.iter().map(String::as_str).collect()
        } else {
            SQL_KEYWORDS
                .iter()
                .copied()
                .chain(self.table_names.iter().map(String::as_str))
                .collect()
        };

        let word_lower = word.to_lowercase();
        let matches: Vec<Pair> = candidates
            .iter()
            .filter(|c| c.to_lowercase().starts_with(&word_lower))
            .map(|c| Pair {
                display: c.to_string(),
                replacement: c.to_string(),
            })
            .collect();

        Ok((word_start, matches))
    }
}

fn needs_table_completion(upper_line: &str) -> bool {
    let tokens: Vec<&str> = upper_line.split_whitespace().collect();
    if tokens.len() < 2 {
        return false;
    }
    let prev = tokens[tokens.len() - 2];
    TABLE_CONTEXT_KEYWORDS.contains(&prev)
}

#[derive(Helper, Completer, Hinter, Highlighter, Validator)]
pub(super) struct PgFusionHelper {
    #[rustyline(Completer)]
    pub completer: PgFusionCompleter,
    #[rustyline(Hinter)]
    pub hinter: HistoryHinter,
}

pub(super) async fn collect_table_names(ctx: &SessionContext) -> Vec<String> {
    use arrow::array::{Array, StringArray};

    let Ok(df) = ctx.sql("SHOW TABLES").await else {
        return vec![];
    };
    let Ok(batches) = df.collect().await else {
        return vec![];
    };
    let mut names = Vec::new();
    for batch in &batches {
        // SHOW TABLES returns: catalog, schema, name — "name" is column index 2
        if batch.num_columns() >= 3 {
            if let Some(col) = batch.column(2).as_any().downcast_ref::<StringArray>() {
                for i in 0..col.len() {
                    if !col.is_null(i) {
                        names.push(col.value(i).to_string());
                    }
                }
            }
        }
    }
    names
}
