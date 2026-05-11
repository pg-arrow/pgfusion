#!/usr/bin/env bash
set -euo pipefail

# TPC-H setup for pgfusion benchmarking
# Builds dbgen, generates data at the requested scale factor,
# loads it into PostgreSQL, then leaves the server running.
#
# Usage: ./setup.sh [pg_version] [scale_factor]
#   pg_version:   key from pg-test-config.toml (default: pg18)
#   scale_factor: TPC-H scale factor (default: 1, i.e. ~1GB)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PG_ARROW_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)/pg_arrow"
CONFIG_FILE="$PG_ARROW_ROOT/pg-test-config.toml"

PG_VERSION="${1:-pg18}"
SCALE_FACTOR="${2:-10}" # SF1 = ~1GB, SF10 = ~10GB

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Read paths from pg-test-config.toml ──────────────────────────────────────

if [ ! -f "$CONFIG_FILE" ]; then
  log_err "Config file not found: $CONFIG_FILE"
  log_err "Run setup-postgres.sh first:  ./pg_arrow/scripts/setup-postgres.sh -b $PG_VERSION -B -i -t"
  exit 1
fi

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
LIB_DIR="$(cd "$BIN_DIR/../lib" && pwd)"
export DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

DB_NAME="tpch"
DBGEN_DIR="$SCRIPT_DIR/tpch-dbgen"
DATA_GEN_DIR="$SCRIPT_DIR/data_sf${SCALE_FACTOR}"

# ── Helper: load all TPC-H tables ───────────────────────────────────────────

load_tables() {
  local tables=(region nation part supplier partsupp customer orders lineitem)
  for table in "${tables[@]}"; do
    local tbl_file="$DATA_GEN_DIR/${table}.tbl"
    if [ ! -f "$tbl_file" ]; then
      log_err "Missing data file: $tbl_file"
      exit 1
    fi
    log_info "Loading $table..."
    # dbgen outputs | as delimiter with a trailing |; strip trailing |
    sed 's/|$//' "$tbl_file" | "$PSQL" "$DB_NAME" -c "\\copy $table FROM STDIN WITH (FORMAT csv, DELIMITER '|')"
    local count
    count=$("$PSQL" -t -A -c "SELECT COUNT(*) FROM $table;" "$DB_NAME")
    log_ok "  $table: $count rows"
  done
}

# ── Build dbgen ──────────────────────────────────────────────────────────────

if [ ! -x "$DBGEN_DIR/dbgen" ]; then
  log_info "Cloning and building TPC-H dbgen..."
  if [ ! -d "$DBGEN_DIR" ]; then
    git clone https://github.com/electrum/tpch-dbgen.git "$DBGEN_DIR"
  fi
  cd "$DBGEN_DIR"
  make -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" MACHINE=MAC DATABASE=POSTGRESQL
  cd "$SCRIPT_DIR"
  log_ok "dbgen built"
else
  log_ok "dbgen already built"
fi

# ── Generate data ────────────────────────────────────────────────────────────

if [ -d "$DATA_GEN_DIR" ] && [ -f "$DATA_GEN_DIR/lineitem.tbl" ]; then
  log_ok "Data already generated at $DATA_GEN_DIR (SF=$SCALE_FACTOR)"
else
  log_info "Generating TPC-H data at scale factor $SCALE_FACTOR..."
  mkdir -p "$DATA_GEN_DIR"
  cd "$DBGEN_DIR"
  ./dbgen -s "$SCALE_FACTOR" -f
  mv ./*.tbl "$DATA_GEN_DIR/"
  cd "$SCRIPT_DIR"
  log_ok "Data generated:"
  for f in "$DATA_GEN_DIR"/*.tbl; do
    log_ok "  $(basename "$f"): $(du -h "$f" | cut -f1)"
  done
fi

# ── Start PostgreSQL ─────────────────────────────────────────────────────────

if "$PG_CTL" -D "$DATA_DIR" status &>/dev/null; then
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
  ROW_COUNT=$("$PSQL" -t -A -c "SELECT COUNT(*) FROM lineitem;" "$DB_NAME" 2>/dev/null || echo "0")
  if [ "$ROW_COUNT" -gt 0 ] 2>/dev/null; then
    log_ok "Table 'lineitem' has $ROW_COUNT rows — skipping load"
  else
    log_info "Tables empty or missing, loading data..."
    "$PSQL" "$DB_NAME" <"$SCRIPT_DIR/create.sql"
    load_tables
  fi
else
  log_info "Creating database '$DB_NAME'..."
  "$BIN_DIR/createdb" "$DB_NAME"
  "$PSQL" "$DB_NAME" <"$SCRIPT_DIR/create.sql"
  load_tables
fi

# ── Checkpoint and finalize ──────────────────────────────────────────────────

log_info "Running CHECKPOINT to flush all data to disk..."
"$PSQL" "$DB_NAME" -c "CHECKPOINT;"

log_info "Running ANALYZE on all tables..."
"$PSQL" "$DB_NAME" -c "ANALYZE;"

DB_OID=$("$PSQL" -t -A -c "SELECT oid FROM pg_database WHERE datname = '$DB_NAME';" postgres)
log_ok "Database OID: $DB_OID"

log_info "PostgreSQL left running"

# ── Print usage ──────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  TPC-H setup complete! (SF=$SCALE_FACTOR)"
echo "============================================"
echo ""
echo "Database: $DB_NAME (OID: $DB_OID)"
echo "Data dir: $DATA_DIR"
echo "Scale:    SF$SCALE_FACTOR"
echo ""
echo "Run with pgfusion:"
echo "  cargo run --release --bin pgfusion_cli -- \\"
echo "    -d $DATA_DIR --db-id $DB_OID"
echo ""
echo "Run benchmark:"
echo "  $SCRIPT_DIR/run.sh $PG_VERSION"
echo ""
