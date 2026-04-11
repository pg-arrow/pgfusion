#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL performance tuning for ClickBench benchmarking
# Configures parallelism, memory, and JIT to match pgfusion's 10-partition setup.
# Uses ALTER SYSTEM SET (writes to postgresql.auto.conf, reversible with ALTER SYSTEM RESET ALL).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PG_ARROW_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)/pg_arrow"
CONFIG_FILE="$PG_ARROW_ROOT/pg-test-config.toml"

PG_VERSION="${1:-pg18}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Read paths from config ───────────────────────────────────────────────────

if [ ! -f "$CONFIG_FILE" ]; then
    log_err "Config file not found: $CONFIG_FILE"
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

# ── Ensure PostgreSQL is running ─────────────────────────────────────────────

if ! "$PG_CTL" -D "$DATA_DIR" status &>/dev/null; then
    log_info "Starting PostgreSQL..."
    "$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/logfile" start -w >/dev/null 2>&1
fi

log_info "Applying performance tuning for ClickBench..."

# ── Apply settings via ALTER SYSTEM ──────────────────────────────────────────

"$PSQL" -d postgres -q <<'SQL'
-- Parallelism: match pgfusion's 10-partition workers
ALTER SYSTEM SET max_parallel_workers_per_gather = 10;
ALTER SYSTEM SET max_parallel_workers = 10;
ALTER SYSTEM SET max_worker_processes = 16;

-- Force planner to use parallelism (pgfusion always uses 10 partitions)
ALTER SYSTEM SET parallel_tuple_cost = 0;
ALTER SYSTEM SET parallel_setup_cost = 0;
ALTER SYSTEM SET min_parallel_table_scan_size = 0;

-- Memory: analytical workload tuning (default 128MB shared_buffers is far too low)
ALTER SYSTEM SET shared_buffers = '8GB';
ALTER SYSTEM SET work_mem = '256MB';
ALTER SYSTEM SET effective_cache_size = '24GB';
ALTER SYSTEM SET maintenance_work_mem = '2GB';

-- JIT: analogous to pgfusion's vectorized DataFusion execution
ALTER SYSTEM SET jit = on;
ALTER SYSTEM SET jit_above_cost = 0;
ALTER SYSTEM SET jit_inline_above_cost = 0;
ALTER SYSTEM SET jit_optimize_above_cost = 0;

-- I/O: SSD-optimized concurrent reads
ALTER SYSTEM SET effective_io_concurrency = 200;

-- Huge pages: graceful fallback on macOS
ALTER SYSTEM SET huge_pages = 'try';
SQL

log_ok "Settings written to postgresql.auto.conf"

# ── Restart PostgreSQL (shared_buffers requires restart) ─────────────────────

log_info "Restarting PostgreSQL for settings to take effect..."
"$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/logfile" restart -w >/dev/null 2>&1
log_ok "PostgreSQL restarted"

# ── Verify settings ─────────────────────────────────────────────────────────

echo ""
printf "${CYAN}%-40s  %s${NC}\n" "Parameter" "Value"
printf "%-40s  %s\n" "----------------------------------------" "----------"

for param in \
    max_parallel_workers_per_gather \
    max_parallel_workers \
    max_worker_processes \
    parallel_tuple_cost \
    parallel_setup_cost \
    min_parallel_table_scan_size \
    shared_buffers \
    work_mem \
    effective_cache_size \
    maintenance_work_mem \
    jit \
    jit_above_cost \
    jit_inline_above_cost \
    jit_optimize_above_cost \
    effective_io_concurrency \
    huge_pages; do
    val=$("$PSQL" -t -A -c "SHOW $param;" postgres)
    printf "%-40s  %s\n" "$param" "$val"
done

# ── Run ANALYZE on clickbench if the database exists ─────────────────────────

if "$PSQL" -lqt | cut -d \| -f 1 | grep -qw "clickbench"; then
    echo ""
    log_info "Running ANALYZE on clickbench.hits..."
    "$PSQL" -d clickbench -c "ANALYZE hits;"
    log_ok "ANALYZE complete"
fi

echo ""
log_ok "PostgreSQL tuning complete. Ready for benchmarking."
