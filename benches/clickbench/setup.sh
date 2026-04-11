#!/usr/bin/env bash
set -euo pipefail

# ClickBench setup for pg_fusion benchmarking
# Downloads the ClickBench hits dataset, loads it into PostgreSQL,
# then shuts down the server so pg_fusion can read the data files directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PG_ARROW_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)/pg_arrow"
CONFIG_FILE="$PG_ARROW_ROOT/pg-test-config.toml"

# Default PostgreSQL version
PG_VERSION="${1:-pg18}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Read paths from pg-test-config.toml ──────────────────────────────────────

if [ ! -f "$CONFIG_FILE" ]; then
    log_err "Config file not found: $CONFIG_FILE"
    log_err "Run setup-postgres.sh first:  ./pg_arrow/scripts/setup-postgres.sh -b $PG_VERSION -B -i -t"
    exit 1
fi

# Simple TOML field reader (works for flat key = "value" within a section)
read_toml() {
    local section="$1" key="$2"
    awk -v section="$section" -v key="$key" '
        $0 ~ "\\[" section "\\]" { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && $1 == key { gsub(/.*= *"?|"$/, ""); print; exit }
    ' "$CONFIG_FILE"
}

BIN_DIR="$(read_toml "postgres.$PG_VERSION" "bin_dir")"
DATA_DIR="$(read_toml "postgres.$PG_VERSION" "data_dir")"

if [ -z "$BIN_DIR" ] || [ -z "$DATA_DIR" ]; then
    log_err "Could not read bin_dir/data_dir for [postgres.$PG_VERSION] from $CONFIG_FILE"
    exit 1
fi

PSQL="$BIN_DIR/psql"
PG_CTL="$BIN_DIR/pg_ctl"
PGBENCH="$BIN_DIR/pgbench"
LIB_DIR="$(cd "$BIN_DIR/../lib" && pwd)"
export DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
DB_NAME="clickbench"
HITS_TSV="$SCRIPT_DIR/hits.tsv"
HITS_URL="https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz"

# Max rows to load (0 = full dataset). 10M rows ≈ 10-12GB on disk.
MAX_ROWS="${CLICKBENCH_MAX_ROWS:-0}"

# ── Download dataset ─────────────────────────────────────────────────────────

if [ ! -f "$HITS_TSV" ]; then
    if [ "$MAX_ROWS" -gt 0 ] 2>/dev/null; then
        log_info "Downloading first ${MAX_ROWS} rows of ClickBench hits dataset..."
    else
        log_info "Downloading full ClickBench hits dataset (~8GB compressed, ~75GB uncompressed)..."
    fi
    log_info "URL: $HITS_URL"
    log_info "This will take a while on first run."

    if [ "$MAX_ROWS" -gt 0 ] 2>/dev/null; then
        # Stream, decompress, and truncate to MAX_ROWS
        if command -v curl &>/dev/null; then
            curl -sL "$HITS_URL" | gunzip | head -n "$MAX_ROWS" > "$HITS_TSV"
        elif command -v wget &>/dev/null; then
            wget --no-verbose -O - "$HITS_URL" | gunzip | head -n "$MAX_ROWS" > "$HITS_TSV"
        else
            log_err "Neither wget nor curl found. Install one and retry."
            exit 1
        fi
    else
        if command -v curl &>/dev/null; then
            curl -sL "$HITS_URL" | gunzip > "$HITS_TSV"
        elif command -v wget &>/dev/null; then
            wget --no-verbose -O - "$HITS_URL" | gunzip > "$HITS_TSV"
        else
            log_err "Neither wget nor curl found. Install one and retry."
            exit 1
        fi
    fi
    log_ok "Download complete: $HITS_TSV ($(du -h "$HITS_TSV" | cut -f1))"
else
    log_ok "Dataset already exists: $HITS_TSV ($(du -h "$HITS_TSV" | cut -f1))"
fi

# ── Start PostgreSQL ─────────────────────────────────────────────────────────

SERVER_WAS_RUNNING=false
if "$PG_CTL" -D "$DATA_DIR" status &>/dev/null; then
    SERVER_WAS_RUNNING=true
    log_info "PostgreSQL is already running"
else
    log_info "Starting PostgreSQL..."
    "$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/logfile" start
    sleep 2
    log_ok "PostgreSQL started"
fi

# ── Create database and load data ────────────────────────────────────────────

if "$PSQL" -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    log_info "Database '$DB_NAME' already exists"
    ROW_COUNT=$("$PSQL" -t -A -c "SELECT COUNT(*) FROM hits;" "$DB_NAME" 2>/dev/null || echo "0")
    if [ "$ROW_COUNT" -gt 0 ] 2>/dev/null; then
        log_ok "Table 'hits' has $ROW_COUNT rows — skipping load"
    else
        log_info "Table empty or missing, loading data..."
        "$PSQL" "$DB_NAME" < "$SCRIPT_DIR/create.sql"
        log_info "Loading data with \\copy (this takes 10-30 minutes)..."
        "$PSQL" "$DB_NAME" -c "\\copy hits FROM '$HITS_TSV';"
        ROW_COUNT=$("$PSQL" -t -A -c "SELECT COUNT(*) FROM hits;" "$DB_NAME")
        log_ok "Loaded $ROW_COUNT rows into hits table"
    fi
else
    log_info "Creating database '$DB_NAME'..."
    "$BIN_DIR/createdb" "$DB_NAME"
    "$PSQL" "$DB_NAME" < "$SCRIPT_DIR/create.sql"
    log_info "Loading data with \\copy (this takes 10-30 minutes)..."
    "$PSQL" "$DB_NAME" -c "\\copy hits FROM '$HITS_TSV';"
    ROW_COUNT=$("$PSQL" -t -A -c "SELECT COUNT(*) FROM hits;" "$DB_NAME")
    log_ok "Loaded $ROW_COUNT rows into hits table"
fi

# ── Checkpoint and finalize ──────────────────────────────────────────────────

log_info "Running CHECKPOINT to flush all data to disk..."
"$PSQL" "$DB_NAME" -c "CHECKPOINT;"

log_info "Running ANALYZE to update planner statistics..."
"$PSQL" "$DB_NAME" -c "ANALYZE hits;"

# Get the database OID for pg_fusion
DB_OID=$("$PSQL" -t -A -c "SELECT oid FROM pg_database WHERE datname = '$DB_NAME';" postgres)
log_ok "Database OID: $DB_OID"

log_info "PostgreSQL left running (pgfusion can read data files while PG is up)"
log_info "For benchmark performance tuning, run:"
log_info "  $SCRIPT_DIR/tune_postgres.sh $PG_VERSION"

# ── Print usage ──────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  ClickBench setup complete!"
echo "============================================"
echo ""
echo "Database: $DB_NAME (OID: $DB_OID)"
echo "Data dir: $DATA_DIR"
echo ""
echo "Run all 43 queries with pg_fusion:"
echo "  cargo run --release -p pg_df -- \\"
echo "    -d $DATA_DIR --db-id $DB_OID \\"
echo "    -f $SCRIPT_DIR/queries.sql -t"
echo ""
echo "Run a single query:"
echo "  cargo run --release -p pg_df -- \\"
echo "    -d $DATA_DIR --db-id $DB_OID \\"
echo "    -c 'SELECT COUNT(*) FROM hits' -t"
echo ""
echo "Run the benchmark script:"
echo "  $SCRIPT_DIR/run.sh $PG_VERSION"
echo ""
