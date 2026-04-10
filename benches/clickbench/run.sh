#!/usr/bin/env bash
set -euo pipefail

# ClickBench benchmark runner for pg_fusion
# Runs all 43 queries, captures timing for each, and produces a summary.

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
NC='\033[0m'

log_info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

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

# Get database OID (start server if needed, but leave it running)
if ! "$PG_CTL" -D "$DATA_DIR" status &>/dev/null; then
    "$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/logfile" start -w >/dev/null 2>&1
fi
DB_OID=$("$PSQL" -t -A -c "SELECT oid FROM pg_database WHERE datname = 'clickbench';" postgres)

if [ -z "$DB_OID" ]; then
    echo "ERROR: Could not determine OID for 'clickbench' database." >&2
    echo "Run setup.sh first." >&2
    exit 1
fi

log_info "Database OID: $DB_OID"
log_info "Data dir: $DATA_DIR"
log_info "Runs per query: $RUNS (reporting best)"

# ── Build release binary ─────────────────────────────────────────────────────

log_info "Building pg_fusion (release)..."
cargo build --release --manifest-path "$PROJECT_ROOT/Cargo.toml" 2>&1 | tail -1
PG_FUSION="$PROJECT_ROOT/../target/release/pgfusion_cli"

if [ ! -x "$PG_FUSION" ]; then
    # Try alternate target location
    PG_FUSION="$(cargo metadata --manifest-path "$PROJECT_ROOT/Cargo.toml" --format-version 1 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])')/release/pgfusion_cli"
fi

if [ ! -x "$PG_FUSION" ]; then
    echo "ERROR: Could not find pgfusion_cli binary" >&2
    exit 1
fi

log_ok "Binary: $PG_FUSION"

# ── Parse queries from file ──────────────────────────────────────────────────

QUERIES_FILE="$SCRIPT_DIR/queries.sql"
RESULTS_FILE="$SCRIPT_DIR/results.csv"

# Extract queries: split on lines starting with "-- Q"
mapfile -t QUERY_NAMES < <(grep '^-- Q' "$QUERIES_FILE" | sed 's/^-- //')
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

# ── Run benchmark ────────────────────────────────────────────────────────────

echo ""
echo "query,best_ms,status" > "$RESULTS_FILE"
printf "${CYAN}%-6s  %10s  %s${NC}\n" "Query" "Best (ms)" "Status"
printf "%-6s  %10s  %s\n" "------" "----------" "--------"

TOTAL_BEST=0
PASS=0
FAIL=0

for i in "${!QUERIES[@]}"; do
    qname="${QUERY_NAMES[$i]}"
    query="${QUERIES[$i]}"
    best_ms=""
    status="OK"

    for run in $(seq 1 "$RUNS"); do
        # Run query with timing, capture stderr for timing output
        output=$("$PG_FUSION" -d "$DATA_DIR" --db-id "$DB_OID" -c "$query" -t 2>&1) || true
        # Extract "Time: NNN.NNNms" from output (portable, no grep -P)
        ms=$(echo "$output" | sed -n 's/.*Time: \([0-9.]*\)ms.*/\1/p' | head -1)

        if [ -z "$ms" ]; then
            status="ERROR"
            break
        fi

        if [ -z "$best_ms" ] || awk "BEGIN{exit !($ms < $best_ms)}" 2>/dev/null; then
            best_ms="$ms"
        fi
    done

    if [ "$status" = "OK" ] && [ -n "$best_ms" ]; then
        printf "%-6s  %10s  %s\n" "$qname" "$best_ms" "$status"
        echo "$qname,$best_ms,$status" >> "$RESULTS_FILE"
        TOTAL_BEST=$(awk "BEGIN{print $TOTAL_BEST + $best_ms}")
        PASS=$((PASS + 1))
    else
        printf "%-6s  %10s  ${RED}%s${NC}\n" "$qname" "-" "$status"
        echo "$qname,,$status" >> "$RESULTS_FILE"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "============================================"
echo "  ClickBench Results Summary"
echo "============================================"
echo "  Passed:     $PASS / $NUM_QUERIES"
echo "  Failed:     $FAIL / $NUM_QUERIES"
echo "  Total best: ${TOTAL_BEST}ms"
echo "  Results:    $RESULTS_FILE"
echo "============================================"
