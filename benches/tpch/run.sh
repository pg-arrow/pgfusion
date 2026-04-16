#!/usr/bin/env bash
set -euo pipefail

# TPC-H benchmark runner: pgfusion vs PostgreSQL
# Runs all 22 TPC-H queries against both engines, captures timing, and produces a comparison.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PG_ARROW_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)/pg_arrow"
CONFIG_FILE="$PG_ARROW_ROOT/pg-test-config.toml"

PG_VERSION="${1:-pg18}"
RUNS="${2:-3}"  # Number of runs per query (default: 3, report best)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ── Read paths from config ───────────────────────────────────────────────────

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
PSQL="$BIN_DIR/psql"
PG_CTL="$BIN_DIR/pg_ctl"
LIB_DIR="$(cd "$BIN_DIR/../lib" && pwd)"
export DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# ── Ensure PostgreSQL is running ─────────────────────────────────────────────

if ! "$PG_CTL" -D "$DATA_DIR" status &>/dev/null; then
    log_info "Starting PostgreSQL..."
    "$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/logfile" start -w >/dev/null 2>&1
fi

DB_OID=$("$PSQL" -t -A -c "SELECT oid FROM pg_database WHERE datname = 'tpch';" postgres)

if [ -z "$DB_OID" ]; then
    echo "ERROR: Could not determine OID for 'tpch' database." >&2
    echo "Run setup.sh first." >&2
    exit 1
fi

# ── Check tuning ─────────────────────────────────────────────────────────────

PG_PARALLEL=$("$PSQL" -t -A -c "SHOW max_parallel_workers_per_gather;" tpch 2>/dev/null || echo "0")
PG_SHARED=$("$PSQL" -t -A -c "SHOW shared_buffers;" tpch 2>/dev/null || echo "?")

log_info "Database OID: $DB_OID"
log_info "Data dir: $DATA_DIR"
log_info "Runs per query: $RUNS (reporting best)"
log_info "PG parallel workers: $PG_PARALLEL | shared_buffers: $PG_SHARED"

# ── Flush dirty pages ────────────────────────────────────────────────────────

log_info "Running CHECKPOINT..."
"$PSQL" -d tpch -c "CHECKPOINT;" >/dev/null 2>&1

# ── Build release binary ─────────────────────────────────────────────────────

log_info "Building pgfusion (release)..."
cargo build --release --manifest-path "$PROJECT_ROOT/Cargo.toml" 2>&1 | tail -1
PG_FUSION="$PROJECT_ROOT/../target/release/pgfusion_cli"

if [ ! -x "$PG_FUSION" ]; then
    PG_FUSION="$(cargo metadata --manifest-path "$PROJECT_ROOT/Cargo.toml" --format-version 1 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])')/release/pgfusion_cli"
fi

if [ ! -x "$PG_FUSION" ]; then
    echo "ERROR: Could not find pgfusion_cli binary" >&2
    exit 1
fi

log_ok "Binary: $PG_FUSION"

# ── Parse queries from file ──────────────────────────────────────────────────

QUERIES_FILE="$SCRIPT_DIR/queries.sql"
RESULTS_CSV="$SCRIPT_DIR/results.csv"
RESULTS_JSON="$SCRIPT_DIR/results.json"

mapfile -t QUERY_NAMES < <(grep '^-- Q' "$QUERIES_FILE" | sed 's/^-- //' | sed 's/:.*//')
mapfile -t QUERIES < <(
    awk '
        /^-- Q[0-9]/ { if (q) print q; q=""; next }
        /^--/ { next }
        { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") q = q ? q " " $0 : $0 }
        END { if (q) print q }
    ' "$QUERIES_FILE"
)

NUM_QUERIES=${#QUERIES[@]}
log_info "Loaded $NUM_QUERIES queries"

# ── Helper: run a single query against PostgreSQL ────────────────────────────

run_pg_query() {
    local query="$1"
    local output
    output=$("$PSQL" -d tpch 2>&1 <<EOF
\o /dev/null
\timing on
$query
EOF
    ) || true
    echo "$output" | sed -n 's/.*Time: \([0-9.]*\) ms.*/\1/p' | head -1
}

# ── Helper: run a single query against pgfusion ─────────────────────────────

run_pgfusion_query() {
    local query="$1"
    local output
    output=$("$PG_FUSION" -d "$DATA_DIR" --db-id "$DB_OID" -c "$query" -t 2>&1) || true
    echo "$output" | sed -n 's/.*Time: \([0-9.]*\)ms.*/\1/p' | head -1
}

# ── Run benchmark ────────────────────────────────────────────────────────────

echo ""
echo "query,pgfusion_best_ms,pgfusion_status,postgres_best_ms,postgres_status" > "$RESULTS_CSV"

printf "${CYAN}${BOLD}%-6s  %14s  %14s  %s${NC}\n" "Query" "pgfusion (ms)" "postgres (ms)" "Status"
printf "%-6s  %14s  %14s  %s\n" "------" "--------------" "--------------" "----------"

PF_TOTAL=0; PF_PASS=0; PF_FAIL=0
PG_TOTAL=0; PG_PASS=0; PG_FAIL=0
JSON_ENTRIES=""

for i in "${!QUERIES[@]}"; do
    qname="${QUERY_NAMES[$i]}"
    query="${QUERIES[$i]}"

    # ── PostgreSQL ───────────────────────────────────────────────────────────
    pg_best=""
    pg_status="OK"

    for run in $(seq 1 "$RUNS"); do
        ms=$(run_pg_query "$query")
        if [ -z "$ms" ]; then
            pg_status="ERROR"
            break
        fi
        if [ -z "$pg_best" ] || awk "BEGIN{exit !($ms < $pg_best)}" 2>/dev/null; then
            pg_best="$ms"
        fi
    done

    # ── pgfusion ─────────────────────────────────────────────────────────────
    pf_best=""
    pf_status="OK"

    for run in $(seq 1 "$RUNS"); do
        ms=$(run_pgfusion_query "$query")
        if [ -z "$ms" ]; then
            pf_status="ERROR"
            break
        fi
        if [ -z "$pf_best" ] || awk "BEGIN{exit !($ms < $pf_best)}" 2>/dev/null; then
            pf_best="$ms"
        fi
    done

    # ── Format output ────────────────────────────────────────────────────────
    pf_display="${pf_best:--}"
    pg_display="${pg_best:--}"
    status_display="${pf_status}/${pg_status}"

    if [ "$pf_status" = "ERROR" ] || [ "$pg_status" = "ERROR" ]; then
        printf "%-6s  %14s  %14s  ${RED}%s${NC}\n" "$qname" "$pf_display" "$pg_display" "$status_display"
    else
        printf "%-6s  %14s  %14s  ${GREEN}%s${NC}\n" "$qname" "$pf_display" "$pg_display" "$status_display"
    fi

    echo "$qname,$pf_best,$pf_status,$pg_best,$pg_status" >> "$RESULTS_CSV"

    # ── JSON accumulator ─────────────────────────────────────────────────────
    pf_json="${pf_best:-null}"
    pg_json="${pg_best:-null}"
    query_escaped=$(printf '%s' "$query" | sed 's/\\/\\\\/g; s/"/\\"/g')
    [ -n "$JSON_ENTRIES" ] && JSON_ENTRIES="$JSON_ENTRIES,"
    JSON_ENTRIES="$JSON_ENTRIES
    {\"name\":\"$qname\",\"sql\":\"$query_escaped\",\"pgfusion_ms\":$pf_json,\"pgfusion_status\":\"$pf_status\",\"postgres_ms\":$pg_json,\"postgres_status\":\"$pg_status\"}"

    # ── Totals ────────────────────────────────────────────────────────────────
    if [ "$pf_status" = "OK" ] && [ -n "$pf_best" ]; then
        PF_TOTAL=$(awk "BEGIN{printf \"%.3f\", $PF_TOTAL + $pf_best}")
        PF_PASS=$((PF_PASS + 1))
    else
        PF_FAIL=$((PF_FAIL + 1))
    fi

    if [ "$pg_status" = "OK" ] && [ -n "$pg_best" ]; then
        PG_TOTAL=$(awk "BEGIN{printf \"%.3f\", $PG_TOTAL + $pg_best}")
        PG_PASS=$((PG_PASS + 1))
    else
        PG_FAIL=$((PG_FAIL + 1))
    fi
done

# ── Write JSON results ───────────────────────────────────────────────────────

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
cat > "$RESULTS_JSON" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "runs_per_query": $RUNS,
  "pg_version": "$PG_VERSION",
  "pg_parallel_workers": $PG_PARALLEL,
  "pg_shared_buffers": "$PG_SHARED",
  "queries": [$JSON_ENTRIES
  ]
}
EOF

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  TPC-H Results Summary"
echo "============================================"
printf "  %-12s  %6s  %6s  %12s\n" "Engine" "Passed" "Failed" "Total (ms)"
printf "  %-12s  %6s  %6s  %12s\n" "------------" "------" "------" "------------"
printf "  %-12s  %6d  %6d  %12s\n" "pgfusion" "$PF_PASS" "$PF_FAIL" "$PF_TOTAL"
printf "  %-12s  %6d  %6d  %12s\n" "PostgreSQL" "$PG_PASS" "$PG_FAIL" "$PG_TOTAL"
echo ""

BOTH_COUNT=0
COMPARISON=""
for i in "${!QUERIES[@]}"; do
    qname="${QUERY_NAMES[$i]}"
    line=$(grep "^$qname," "$RESULTS_CSV")
    pf_ms=$(echo "$line" | cut -d, -f2)
    pf_st=$(echo "$line" | cut -d, -f3)
    pg_ms=$(echo "$line" | cut -d, -f4)
    pg_st=$(echo "$line" | cut -d, -f5)

    if [ "$pf_st" = "OK" ] && [ "$pg_st" = "OK" ] && [ -n "$pf_ms" ] && [ -n "$pg_ms" ]; then
        ratio=$(awk "BEGIN{printf \"%.2f\", $pg_ms / $pf_ms}")
        COMPARISON="${COMPARISON}
$(printf "  %-6s  %12s  %12s  %8sx" "$qname" "$pf_ms" "$pg_ms" "$ratio")"
        BOTH_COUNT=$((BOTH_COUNT + 1))
    fi
done

if [ "$BOTH_COUNT" -gt 0 ]; then
    printf "  ${BOLD}Per-query comparison (both passed, ratio = PG/pgfusion):${NC}\n"
    printf "  %-6s  %12s  %12s  %9s\n" "Query" "pgfusion" "postgres" "Ratio"
    printf "  %-6s  %12s  %12s  %9s\n" "------" "------------" "------------" "---------"
    echo "$COMPARISON"
    echo ""
fi

echo "  Results: $RESULTS_CSV"
echo "           $RESULTS_JSON"
echo "============================================"
