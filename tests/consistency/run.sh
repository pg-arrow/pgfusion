#!/usr/bin/env bash
set -uo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Consistency Test: PostgreSQL (psql) vs pgfusion_cli
#
# Verifies that pgfusion reads the same data as native PostgreSQL after
# mutations. pgfusion reads heap files directly while PG is still running.
#
# For each mutation (INSERT/UPDATE):
#   1. Mutate via psql
#   2. Read via psql (ground truth)
#   3. Read via pgfusion up to MAX_READS times
#   4. Compare — stop early on match, report lag
# ═══════════════════════════════════════════════════════════════════════════════

# ── Config ───────────────────────────────────────────────────────────────────

MAX_READS=10           # Max pgfusion read attempts per mutation
TEST_AIDS=(99901 99902 99903)  # Row IDs reserved for this test

# ── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$(cd "$PROJECT_ROOT/.." && pwd)/pg_arrow/pg-test-config.toml"
RESULTS_FILE="$SCRIPT_DIR/results.txt"

PG_VERSION="${1:-pg18}"

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# ── TOML reader ──────────────────────────────────────────────────────────────

read_toml() {
    local section="$1" key="$2"
    awk -v section="$section" -v key="$key" '
        $0 ~ "\\[" section "\\]" { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && $1 == key { gsub(/.*= *"?|"$/, ""); print; exit }
    ' "$CONFIG_FILE"
}

# ── Resolve PG + pgfusion binaries ───────────────────────────────────────────

resolve_binaries() {
    BIN_DIR="$(read_toml "postgres.$PG_VERSION" "bin_dir")"
    DATA_DIR="$(read_toml "postgres.$PG_VERSION" "data_dir")"
    PSQL="$BIN_DIR/psql"
    PG_CTL="$BIN_DIR/pg_ctl"
    LIB_DIR="$(cd "$BIN_DIR/../lib" && pwd)"
    export DYLD_LIBRARY_PATH="$LIB_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

    for bin in "$PSQL" "$PG_CTL"; do
        [ -x "$bin" ] || { echo "ERROR: $bin not found" >&2; exit 1; }
    done

    # Build pgfusion
    log_info "Building pgfusion_cli (release)..."
    cargo build --release --manifest-path "$PROJECT_ROOT/Cargo.toml" 2>&1 | tail -1
    PG_FUSION="$PROJECT_ROOT/../target/release/pgfusion_cli"

    if [ ! -x "$PG_FUSION" ]; then
        PG_FUSION="$(cargo metadata --manifest-path "$PROJECT_ROOT/Cargo.toml" \
            --format-version 1 2>/dev/null \
            | python3 -c 'import sys,json; print(json.load(sys.stdin)["target_directory"])')/release/pgfusion_cli"
    fi

    [ -x "$PG_FUSION" ] || { echo "ERROR: pgfusion_cli not found" >&2; exit 1; }
    log_ok "Binary: $PG_FUSION"
}

# ── PostgreSQL helpers ───────────────────────────────────────────────────────

pg_ensure_running() {
    if ! "$PG_CTL" -D "$DATA_DIR" status &>/dev/null; then
        "$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/logfile" start -w >/dev/null 2>&1
    fi
}

pg_query() {
    "$PSQL" -t -A -F '|' -c "$1" test 2>&1
}

get_db_oid() {
    pg_ensure_running
    DB_OID=$(pg_query "SELECT oid FROM pg_database WHERE datname = 'test';")
    [ -n "$DB_OID" ] || { echo "ERROR: Cannot find OID for 'test' database" >&2; exit 1; }

    PG_PORT=$("$PSQL" -t -A -c "SHOW port;" postgres 2>/dev/null || echo "5432")
    PG_SOCKET_DIR=$("$PSQL" -t -A -c "SHOW unix_socket_directories;" postgres 2>/dev/null || echo "/tmp")
    PG_SOCKET_DIR=$(echo "$PG_SOCKET_DIR" | tr ',' '\n' | head -1 | xargs)
    PG_URL="host=$PG_SOCKET_DIR port=$PG_PORT dbname=test"

    log_info "Database OID: $DB_OID  |  Data dir: $DATA_DIR  |  PG URL: $PG_URL"
}

# ── Output normalization ────────────────────────────────────────────────────
# Makes psql and pgfusion output comparable.
#
# psql -t -A -F '|' outputs:    99901|1|11111
#
# pgfusion outputs a pretty table:
#   +-------+-----+----------+
#   | aid   | bid | abalance |
#   +-------+-----+----------+
#   | 99901 | 1   | 11111    |
#   +-------+-----+----------+
#   Time: 123.45ms

normalize_psql() {
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$' \
        | sort
}

normalize_fusion() {
    grep -v '^Time:'         | \
    grep -v '^+[-+]*+$'     | \
    grep -v '^$'             | \
    tail -n +2               | \
    sed 's/^[[:space:]]*|[[:space:]]*//; s/[[:space:]]*|[[:space:]]*$//' | \
    sed 's/[[:space:]]*|[[:space:]]*/|/g' | \
    grep -v '^$' | \
    sort
}

# ── Timing helper ────────────────────────────────────────────────────────────

now_ms() { python3 -c 'import time; print(time.time())'; }

elapsed_ms() {
    python3 -c "print(f'{($2 - $1) * 1000:.1f}')"
}

# ── pgfusion read + compare ─────────────────────────────────────────────────
# Runs pgfusion up to MAX_READS times, comparing against expected.
# Stops early on first match. Returns 0 on match, 1 on failure.

pgfusion_poll() {
    local read_query="$1"
    local expected="$2"

    for attempt in $(seq 1 $MAX_READS); do
        local t0; t0=$(now_ms)
        local raw; raw=$("$PG_FUSION" -d "$DATA_DIR" --db-id "$DB_OID" \
            --pg-url "$PG_URL" --checkpoint --consistent -c "$read_query" 2>&1)
        local t1; t1=$(now_ms)
        local ms; ms=$(elapsed_ms "$t0" "$t1")

        local result; result=$(echo "$raw" | normalize_fusion)

        if [ "$result" = "$expected" ]; then
            log_ok "Matched on attempt $attempt/$MAX_READS (${ms}ms)"
            echo "  pgfusion matched on attempt $attempt (${ms}ms)" >> "$RESULTS_FILE"
            echo "  pgfusion result: $result" >> "$RESULTS_FILE"
            LAST_MATCH_ATTEMPT=$attempt
            return 0
        fi

        log_info "Attempt $attempt/$MAX_READS: MISMATCH (${ms}ms)"
        log_info "  expected: $expected"
        log_info "  pgfusion: $result"
        echo "  Attempt $attempt: MISMATCH (${ms}ms)" >> "$RESULTS_FILE"
        echo "    expected: $expected" >> "$RESULTS_FILE"
        echo "    pgfusion: $result" >> "$RESULTS_FILE"
    done

    return 1
}

# ── Run one mutation + verify ────────────────────────────────────────────────

run_mutation_test() {
    local idx="$1" mutation="$2" read_query="$3" label="$4"

    echo -e "${CYAN}── Mutation ${idx}: ${label} ──${NC}"
    echo "── Mutation ${idx}: ${label} ──" >> "$RESULTS_FILE"
    echo "  Mutation:   $mutation" >> "$RESULTS_FILE"
    echo "  Read query: $read_query" >> "$RESULTS_FILE"

    # Ensure PG is running before mutation
    pg_ensure_running

    # Mutate
    pg_query "$mutation" >/dev/null 2>&1

    # Ground truth from psql
    local expected; expected=$(pg_query "$read_query" | normalize_psql)
    log_info "Expected (psql): $expected"
    echo "  Expected (psql): $expected" >> "$RESULTS_FILE"

    # Poll pgfusion
    LAST_MATCH_ATTEMPT=0
    if pgfusion_poll "$read_query" "$expected"; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
        if [ "$LAST_MATCH_ATTEMPT" -eq 1 ]; then
            echo -e "  ${GREEN}PASS${NC} — matched immediately"
        else
            echo -e "  ${YELLOW}PASS${NC} — matched after $LAST_MATCH_ATTEMPT attempts (lagged)"
        fi
        echo "  RESULT: PASS (attempt $LAST_MATCH_ATTEMPT)" >> "$RESULTS_FILE"
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        log_fail "NEVER matched after $MAX_READS attempts"
        echo "  RESULT: FAIL (no match after $MAX_READS attempts)" >> "$RESULTS_FILE"
    fi

    echo "" >> "$RESULTS_FILE"
    echo ""
}

# ── Cleanup test rows ────────────────────────────────────────────────────────

cleanup_test_rows() {
    pg_ensure_running
    local aids; aids=$(IFS=,; echo "${TEST_AIDS[*]}")
    pg_query "DELETE FROM pgbench_accounts WHERE aid IN ($aids);" >/dev/null 2>&1
}

# ── Print summary ────────────────────────────────────────────────────────────

print_summary() {
    local total=$((TOTAL_PASS + TOTAL_FAIL))

    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Summary${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  Mutations tested: $total"
    echo -e "  Passed:           ${GREEN}$TOTAL_PASS${NC}"
    echo -e "  Failed:           ${RED}$TOTAL_FAIL${NC}"
    echo -e "  Results file:     $RESULTS_FILE"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

    {
        echo ""
        echo "========================================"
        echo "  Summary: $TOTAL_PASS pass, $TOTAL_FAIL fail (of $total)"
        echo "========================================"
    } >> "$RESULTS_FILE"
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════

TOTAL_PASS=0
TOTAL_FAIL=0

resolve_binaries
get_db_oid

# Clean slate
cleanup_test_rows

# Results file header
{
    echo "========================================"
    echo "  Consistency Test Results"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""
} > "$RESULTS_FILE"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Consistency Test: PostgreSQL vs pgfusion_cli${NC}"
echo -e "${BOLD}  Max reads per mutation: $MAX_READS (stops early on match)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ── Mutation 1: INSERT ───────────────────────────────────────────────────────
run_mutation_test "1/3" \
    "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) VALUES (99901, 1, 11111, 'consistency_insert');" \
    "SELECT aid, bid, abalance FROM pgbench_accounts WHERE aid = 99901;" \
    "INSERT new row (aid=99901, abalance=11111)"

# ── Mutation 2: UPDATE ───────────────────────────────────────────────────────
run_mutation_test "2/3" \
    "UPDATE pgbench_accounts SET abalance = 22222, filler = 'consistency_update' WHERE aid = 99901;" \
    "SELECT aid, bid, abalance FROM pgbench_accounts WHERE aid = 99901;" \
    "UPDATE row (aid=99901, abalance -> 22222)"

# ── Mutation 3: INSERT second row ────────────────────────────────────────────
run_mutation_test "3/3" \
    "INSERT INTO pgbench_accounts (aid, bid, abalance, filler) VALUES (99902, 1, 33333, 'consistency_insert2');" \
    "SELECT aid, bid, abalance FROM pgbench_accounts WHERE aid IN (99901, 99902) ORDER BY aid;" \
    "INSERT second row (aid=99902), read both rows"

# ── Done ─────────────────────────────────────────────────────────────────────
cleanup_test_rows
print_summary

[ "$TOTAL_FAIL" -eq 0 ] || exit 1
