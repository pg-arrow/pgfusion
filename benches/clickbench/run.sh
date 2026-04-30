#!/usr/bin/env bash
set -euo pipefail

# ClickBench benchmark runner: pgfusion vs PostgreSQL
# Runs all 43 queries against both engines, captures timing, and produces a comparison.
#
# Usage:
#   ./run.sh [pg_version] [runs] [--checkpoint] [--checkpoint-only] [--label=<text>]
#
#   --checkpoint         After a full run, save results to checkpoints/<short-hash>[-label]/
#   --checkpoint-only    Skip the benchmark run; just archive current results to checkpoints/<short-hash>[-label]/
#   --label=<text>       Tag appended to the checkpoint folder name (e.g. --label=before-optimization)
#
# Results are always copied to checkpoints/current/ at the end of every run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PG_ARROW_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)/pg_arrow"
CONFIG_FILE="$PG_ARROW_ROOT/pg-test-config.toml"

PG_VERSION="pg18"
RUNS=3
DO_CHECKPOINT=false
CHECKPOINT_ONLY=false
CHECKPOINT_LABEL=""

for arg in "$@"; do
    case "$arg" in
        --checkpoint)        DO_CHECKPOINT=true ;;
        --checkpoint-only)   DO_CHECKPOINT=true; CHECKPOINT_ONLY=true ;;
        --label=*)           CHECKPOINT_LABEL="${arg#--label=}" ;;
        --*)                 echo "Unknown flag: $arg" >&2; exit 1 ;;
        *)
            if [ "$PG_VERSION" = "pg18" ] && [[ "$arg" =~ ^pg ]]; then
                PG_VERSION="$arg"
            elif [ "$RUNS" -eq 3 ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
                RUNS="$arg"
            fi
            ;;
    esac
done

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

# ── Resolve git commit hash ──────────────────────────────────────────────────

GIT_COMMIT=""
GIT_SHORT=""
if command -v git &>/dev/null; then
    GIT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)
    GIT_SHORT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || true)
fi
if [ -z "$GIT_COMMIT" ]; then
    GIT_COMMIT=$(date -u '+%Y%m%d_%H%M%S')
    GIT_SHORT="$GIT_COMMIT"
    log_warn "Could not resolve git commit hash; using timestamp: $GIT_COMMIT"
fi

# Checkpoint folder: <short-hash>[-label]  (e.g. "f85939b" or "f85939b-before-optimization")
CHECKPOINT_SLUG="$GIT_SHORT"
[ -n "$CHECKPOINT_LABEL" ] && CHECKPOINT_SLUG="${GIT_SHORT}-${CHECKPOINT_LABEL}"
CHECKPOINT_DIR="$SCRIPT_DIR/checkpoints/$CHECKPOINT_SLUG"
CURRENT_DIR="$SCRIPT_DIR/checkpoints/current"

# ── Checkpoint-only mode: archive existing results and exit ──────────────────

save_to_dir() {
    local dest="$1"
    mkdir -p "$dest"
    [ -f "$SCRIPT_DIR/results.csv" ]  && cp "$SCRIPT_DIR/results.csv"  "$dest/results.csv"
    [ -f "$SCRIPT_DIR/results.json" ] && cp "$SCRIPT_DIR/results.json" "$dest/results.json"
    [ -f "$SCRIPT_DIR/heatmap.html" ] && cp "$SCRIPT_DIR/heatmap.html" "$dest/heatmap.html"
    [ -f "$SCRIPT_DIR/queries.sql" ]  && cp "$SCRIPT_DIR/queries.sql"  "$dest/queries.sql"
}

if [ "$CHECKPOINT_ONLY" = "true" ]; then
    if [ ! -f "$SCRIPT_DIR/results.csv" ] && [ ! -f "$SCRIPT_DIR/results.json" ]; then
        echo "ERROR: No results found to checkpoint. Run the benchmark first." >&2
        exit 1
    fi

    log_info "Checkpointing current results to $CHECKPOINT_DIR ..."
    save_to_dir "$CHECKPOINT_DIR"

    log_info "Updating checkpoints/current ..."
    save_to_dir "$CURRENT_DIR"

    log_ok "Checkpoint saved: $CHECKPOINT_DIR"
    echo "  Commit: $GIT_COMMIT"
    [ -n "$CHECKPOINT_LABEL" ] && echo "  Label:  $CHECKPOINT_LABEL"
    echo "  Slug:   $CHECKPOINT_SLUG"
    exit 0
fi

# ── Ensure PostgreSQL is running ─────────────────────────────────────────────

if ! "$PG_CTL" -D "$DATA_DIR" status &>/dev/null; then
    log_info "Starting PostgreSQL..."
    "$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/logfile" start -w >/dev/null 2>&1
fi

DB_OID=$("$PSQL" -t -A -c "SELECT oid FROM pg_database WHERE datname = 'clickbench';" postgres)

if [ -z "$DB_OID" ]; then
    echo "ERROR: Could not determine OID for 'clickbench' database." >&2
    echo "Run setup.sh first." >&2
    exit 1
fi

# ── Check tuning ─────────────────────────────────────────────────────────────

PG_PARALLEL=$("$PSQL" -t -A -c "SHOW max_parallel_workers_per_gather;" clickbench 2>/dev/null || echo "0")
PG_SHARED=$("$PSQL" -t -A -c "SHOW shared_buffers;" clickbench 2>/dev/null || echo "?")

if [ "$PG_PARALLEL" -lt 10 ] 2>/dev/null; then
    log_warn "max_parallel_workers_per_gather=$PG_PARALLEL (pgfusion uses 10 partitions)"
    log_warn "Run tune_postgres.sh for a fair comparison"
fi

log_info "Database OID: $DB_OID"
log_info "Data dir: $DATA_DIR"
log_info "Runs per query: $RUNS (reporting best)"
log_info "PG parallel workers: $PG_PARALLEL | shared_buffers: $PG_SHARED"
[ -n "$GIT_SHORT" ] && log_info "Commit: $GIT_SHORT ($GIT_COMMIT)${CHECKPOINT_LABEL:+ label=$CHECKPOINT_LABEL}"

# ── Flush dirty pages before benchmark ───────────────────────────────────────

log_info "Running CHECKPOINT..."
"$PSQL" -d clickbench -c "CHECKPOINT;" >/dev/null 2>&1

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

# ── Output capture dir (populated during run, moved to checkpoint after) ──────

OUTPUT_STAGING="$SCRIPT_DIR/.output_staging"
rm -rf "$OUTPUT_STAGING"
mkdir -p "$OUTPUT_STAGING"

# ── Helper: run a single query against PostgreSQL ────────────────────────────

run_pg_query() {
    local query="$1"
    # \o /dev/null suppresses result rows; \timing on prints wall-clock time
    local output
    output=$("$PSQL" -d clickbench 2>&1 <<EOF
\o /dev/null
\timing on
$query
EOF
    ) || true
    echo "$output"
}

# ── Helper: run a single query against pgfusion ─────────────────────────────

run_pgfusion_query() {
    local query="$1"
    local output
    output=$("$PG_FUSION" -d "$DATA_DIR" --db-id "$DB_OID" -c "$query" -t 2>&1) || true
    echo "$output"
}

extract_pg_time() {
    # psql timing format: "Time: 1234.567 ms" or "Time: 1234.567 ms (00:01.235)"
    echo "$1" | sed -n 's/.*Time: \([0-9.]*\) ms.*/\1/p' | head -1
}

extract_pgfusion_time() {
    # pgfusion timing format: "Time: NNN.NNNms" (no space before ms)
    echo "$1" | sed -n 's/.*Time: \([0-9.]*\)ms.*/\1/p' | head -1
}

# ── Progress bar helpers ─────────────────────────────────────────────────────

# Width of the overall progress bar in characters
PBAR_WIDTH=30

# Print overall progress bar + current activity on a single \r line.
# Args: completed total activity_label
# Overwrites current line; does NOT print a newline.
print_progress() {
    local done="$1" total="$2" label="$3"
    local filled=$(( done * PBAR_WIDTH / total ))
    local empty=$(( PBAR_WIDTH - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar="${bar}#"; done
    for (( i=0; i<empty;  i++ )); do bar="${bar}-"; done
    printf "\r${CYAN}[%s]${NC} %d/%d  %-38s" "$bar" "$done" "$total" "$label" >&2
}

# Erase the progress line before printing a permanent result row.
clear_progress() {
    printf "\r%-80s\r" "" >&2
}

# ── Run benchmark ────────────────────────────────────────────────────────────

echo ""
echo "query,pgfusion_best_ms,pgfusion_status,postgres_best_ms,postgres_status" > "$RESULTS_CSV"

printf "${CYAN}${BOLD}%-6s  %14s  %14s  %s${NC}\n" "Query" "pgfusion (ms)" "postgres (ms)" "Status"
printf "%-6s  %14s  %14s  %s\n" "------" "--------------" "--------------" "----------"

PF_TOTAL=0; PF_PASS=0; PF_FAIL=0
PG_TOTAL=0; PG_PASS=0; PG_FAIL=0

# JSON accumulator
JSON_ENTRIES=""

for i in "${!QUERIES[@]}"; do
    qname="${QUERY_NAMES[$i]}"
    query="${QUERIES[$i]}"
    query_num=$(( i + 1 ))

    # ── PostgreSQL ───────────────────────────────────────────────────────────
    pg_best=""
    pg_status="OK"
    pg_best_output=""

    for run in $(seq 1 "$RUNS"); do
        print_progress "$i" "$NUM_QUERIES" "$qname  pg run $run/$RUNS"
        raw_output=$(run_pg_query "$query")
        ms=$(extract_pg_time "$raw_output")
        if [ -z "$ms" ]; then
            pg_status="ERROR"
            # Capture first 15 lines of the error output
            pg_best_output=$(echo "$raw_output" | head -15)
            break
        fi
        if [ -z "$pg_best" ] || awk "BEGIN{exit !($ms < $pg_best)}" 2>/dev/null; then
            pg_best="$ms"
            # Capture first 15 lines of best run's output for result verification
            local_out=$("$PSQL" -d clickbench 2>&1 <<EOF2
\timing on
$query
EOF2
) || true
            pg_best_output=$(echo "$local_out" | head -15)
        fi
    done

    # ── pgfusion ─────────────────────────────────────────────────────────────
    pf_best=""
    pf_status="OK"
    pf_best_output=""

    for run in $(seq 1 "$RUNS"); do
        print_progress "$i" "$NUM_QUERIES" "$qname  pgf run $run/$RUNS"
        raw_output=$(run_pgfusion_query "$query")
        ms=$(extract_pgfusion_time "$raw_output")
        if [ -z "$ms" ]; then
            pf_status="ERROR"
            pf_best_output=$(echo "$raw_output" | head -15)
            break
        fi
        if [ -z "$pf_best" ] || awk "BEGIN{exit !($ms < $pf_best)}" 2>/dev/null; then
            pf_best="$ms"
            pf_best_output=$(echo "$raw_output" | head -15)
        fi
    done

    # Save output samples to staging dir
    printf '%s\n' "$pg_best_output" > "$OUTPUT_STAGING/${qname}_postgres.txt"
    printf '%s\n' "$pf_best_output" > "$OUTPUT_STAGING/${qname}_pgfusion.txt"

    # ── Format output ────────────────────────────────────────────────────────
    pf_display="${pf_best:--}"
    pg_display="${pg_best:--}"
    status_display="${pf_status}/${pg_status}"

    # Clear progress line, then print permanent result row
    clear_progress
    if [ "$pf_status" = "ERROR" ] || [ "$pg_status" = "ERROR" ]; then
        printf "%-6s  %14s  %14s  ${RED}%s${NC}\n" "$qname" "$pf_display" "$pg_display" "$status_display"
    else
        printf "%-6s  %14s  %14s  ${GREEN}%s${NC}\n" "$qname" "$pf_display" "$pg_display" "$status_display"
    fi

    # ── CSV ───────────────────────────────────────────────────────────────────
    echo "$qname,$pf_best,$pf_status,$pg_best,$pg_status" >> "$RESULTS_CSV"

    # ── JSON accumulator ─────────────────────────────────────────────────────
    pf_json="${pf_best:-null}"
    pg_json="${pg_best:-null}"
    # JSON-escape the query (handle backslashes and double quotes)
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

# Print completed progress bar, then newline
print_progress "$NUM_QUERIES" "$NUM_QUERIES" "done"
printf "\n" >&2

# ── Write JSON results ───────────────────────────────────────────────────────

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
COMMIT_FIELD=""
if [ -n "$GIT_COMMIT" ]; then
    COMMIT_FIELD="
  \"commit\": \"$GIT_COMMIT\",
  \"commit_short\": \"$GIT_SHORT\","
    [ -n "$CHECKPOINT_LABEL" ] && COMMIT_FIELD="${COMMIT_FIELD}
  \"label\": \"$CHECKPOINT_LABEL\","
fi

cat > "$RESULTS_JSON" <<EOF
{
  "timestamp": "$TIMESTAMP",$COMMIT_FIELD
  "runs_per_query": $RUNS,
  "pg_version": "$PG_VERSION",
  "pg_parallel_workers": $PG_PARALLEL,
  "pg_shared_buffers": "$PG_SHARED",
  "queries": [$JSON_ENTRIES
  ]
}
EOF

# ── Embed JSON into heatmap.html ─────────────────────────────────────────────

HEATMAP_FILE="$SCRIPT_DIR/heatmap.html"
if [ -f "$HEATMAP_FILE" ]; then
    log_info "Embedding results into heatmap.html..."
    # Use python to read results.json directly and embed it into heatmap.html,
    # avoiding bash variable expansion which mangles backslash escapes in JSON.
    python3 <<PYEOF
import re, json

with open('$RESULTS_JSON') as f:
    json_data = f.read()

replacement = (
    '<!-- RESULTS_DATA_START -->\n'
    '<script id="embedded-data" type="application/json">\n'
    + json_data +
    '\n</script>\n'
    '<!-- RESULTS_DATA_END -->'
)

with open('$HEATMAP_FILE') as f:
    html = f.read()

html = re.sub(
    r'<!-- RESULTS_DATA_START -->.*?<!-- RESULTS_DATA_END -->',
    lambda m: replacement,
    html,
    flags=re.DOTALL,
)

with open('$HEATMAP_FILE', 'w') as f:
    f.write(html)
PYEOF
fi

# ── Always update checkpoints/current ───────────────────────────────────────

log_info "Updating checkpoints/current ..."
save_to_dir "$CURRENT_DIR"
# Copy output samples into current/output
if [ -d "$OUTPUT_STAGING" ]; then
    mkdir -p "$CURRENT_DIR/output"
    find "$OUTPUT_STAGING" -maxdepth 1 -name '*.txt' -exec cp {} "$CURRENT_DIR/output/" \;
fi

# ── Named checkpoint: save results + output samples ─────────────────────────

if [ "$DO_CHECKPOINT" = "true" ]; then
    log_info "Saving checkpoint to $CHECKPOINT_DIR ..."
    save_to_dir "$CHECKPOINT_DIR"
    mkdir -p "$CHECKPOINT_DIR/output"

    # Copy per-query output samples into checkpoint
    if [ -d "$OUTPUT_STAGING" ]; then
        find "$OUTPUT_STAGING" -maxdepth 1 -name '*.txt' -exec cp {} "$CHECKPOINT_DIR/output/" \;
    fi

    log_ok "Checkpoint saved: $CHECKPOINT_DIR"
    echo "  Commit:  $GIT_COMMIT"
    echo "  Short:   $GIT_SHORT"
    [ -n "$CHECKPOINT_LABEL" ] && echo "  Label:   $CHECKPOINT_LABEL"
    echo "  Results: $CHECKPOINT_DIR/results.csv"
    echo "  Output:  $CHECKPOINT_DIR/output/"
fi

# Cleanup staging
rm -rf "$OUTPUT_STAGING"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  ClickBench Results Summary"
echo "============================================"
printf "  %-12s  %6s  %6s  %12s\n" "Engine" "Passed" "Failed" "Total (ms)"
printf "  %-12s  %6s  %6s  %12s\n" "------------" "------" "------" "------------"
printf "  %-12s  %6d  %6d  %12s\n" "pgfusion" "$PF_PASS" "$PF_FAIL" "$PF_TOTAL"
printf "  %-12s  %6d  %6d  %12s\n" "PostgreSQL" "$PG_PASS" "$PG_FAIL" "$PG_TOTAL"
echo ""

# Show per-query comparison where both passed
BOTH_COUNT=0
COMPARISON=""
for i in "${!QUERIES[@]}"; do
    qname="${QUERY_NAMES[$i]}"
    # Re-read from CSV
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
echo "  Heatmap: open $SCRIPT_DIR/heatmap.html"
[ "$DO_CHECKPOINT" = "true" ] && echo "  Checkpoint: $CHECKPOINT_DIR"
echo "============================================"
