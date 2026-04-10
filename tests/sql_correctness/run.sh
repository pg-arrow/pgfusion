#!/usr/bin/env bash
set -uo pipefail
trap '' PIPE

# SQL test runner for pg_fusion
# Runs each .sql file in queries/, captures timing, first 5 rows, and errors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PG_ARROW_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)/pg_arrow"
CONFIG_FILE="$PG_ARROW_ROOT/pg-test-config.toml"

PG_VERSION="${1:-pg18}"
SQL_DIR="$SCRIPT_DIR/queries"
RESULTS_FILE="$SCRIPT_DIR/results.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

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

# ── Get database OID for 'test' ──────────────────────────────────────────────

# Start server if needed, but leave it running
if ! "$PG_CTL" -D "$DATA_DIR" status &>/dev/null; then
    "$PG_CTL" -D "$DATA_DIR" -l "$DATA_DIR/logfile" start -w >/dev/null 2>&1
fi
DB_OID=$("$PSQL" -t -A -c "SELECT oid FROM pg_database WHERE datname = 'test';" postgres)

if [ -z "$DB_OID" ]; then
    echo "ERROR: Could not determine OID for 'test' database." >&2
    exit 1
fi

log_info "Database OID: $DB_OID"
log_info "Data dir: $DATA_DIR"

# ── Build release binary ─────────────────────────────────────────────────────

log_info "Building pg_fusion (release)..."
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

# ── Run SQL tests ────────────────────────────────────────────────────────────

SQL_FILES=("$SQL_DIR"/*.sql)
NUM_FILES=${#SQL_FILES[@]}
log_info "Found $NUM_FILES SQL test files"

PASS=0
FAIL=0
TOTAL_QUERIES=0
FAILED_QUERIES=0

: > "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"
echo "  pg_fusion SQL Test Results" >> "$RESULTS_FILE"
echo "  $(date '+%Y-%m-%d %H:%M:%S')" >> "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

printf "\n${CYAN}%-40s  %6s  %6s  %10s${NC}\n" "File" "Pass" "Fail" "Time (ms)"
printf "%-40s  %6s  %6s  %10s\n" "----------------------------------------" "------" "------" "----------"

for sql_file in "${SQL_FILES[@]}"; do
    fname="$(basename "$sql_file")"
    file_pass=0
    file_fail=0
    file_time=0

    echo "── $fname ──" >> "$RESULTS_FILE"

    # Extract individual queries (skip comments and blank lines, split on semicolons)
    mapfile -t QUERIES < <(
        sed 's/--.*$//' "$sql_file" | \
        tr '\n' ' ' | \
        sed 's/;/;\n/g' | \
        sed 's/^[[:space:]]*//' | \
        grep -v '^[[:space:]]*$' || true
    )

    for query in "${QUERIES[@]}"; do
        # Skip empty queries
        trimmed="$(echo "$query" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$trimmed" ] && continue

        TOTAL_QUERIES=$((TOTAL_QUERIES + 1))

        output=$("$PG_FUSION" -d "$DATA_DIR" --db-id "$DB_OID" -c "$trimmed" -t 2>&1) || true

        # Extract time
        ms=$(echo "$output" | grep -o 'Time: [0-9.]*ms' | head -1 | sed 's/Time: //;s/ms//')

        # Check for error (no time = error)
        if [ -z "$ms" ]; then
            file_fail=$((file_fail + 1))
            FAILED_QUERIES=$((FAILED_QUERIES + 1))
            echo "  [ERROR] $trimmed" >> "$RESULTS_FILE"
            echo "  Output: $(echo "$output" | sed '5q')" >> "$RESULTS_FILE"
            echo "" >> "$RESULTS_FILE"
        else
            file_pass=$((file_pass + 1))
            file_time=$(awk "BEGIN{print $file_time + $ms}")
            # Write first 5 rows of result to results file
            result_rows=$(echo "$output" | grep -v '^Time:' | grep -v '^$' | sed '5q')
            if [ -n "$result_rows" ]; then
                echo "  [OK] (${ms}ms) $trimmed" >> "$RESULTS_FILE"
                echo "$result_rows" | sed 's/^/    /' >> "$RESULTS_FILE"
                echo "" >> "$RESULTS_FILE"
            else
                echo "  [OK] (${ms}ms) $trimmed" >> "$RESULTS_FILE"
                echo "" >> "$RESULTS_FILE"
            fi
        fi
    done

    if [ "$file_fail" -eq 0 ]; then
        printf "%-40s  ${GREEN}%6d${NC}  %6d  %10s\n" "$fname" "$file_pass" "$file_fail" "$file_time"
        PASS=$((PASS + 1))
    else
        printf "%-40s  %6d  ${RED}%6d${NC}  %10s\n" "$fname" "$file_pass" "$file_fail" "$file_time"
        FAIL=$((FAIL + 1))
    fi
done

echo "" >> "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"
echo "  Summary" >> "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"
echo "  Files:   $((PASS + FAIL)) ($PASS all-pass, $FAIL with failures)" >> "$RESULTS_FILE"
echo "  Queries: $TOTAL_QUERIES ($((TOTAL_QUERIES - FAILED_QUERIES)) pass, $FAILED_QUERIES fail)" >> "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"

echo ""
echo "============================================"
echo "  SQL Test Results Summary"
echo "============================================"
echo "  Files:   $((PASS + FAIL)) ($PASS all-pass, $FAIL with failures)"
echo "  Queries: $TOTAL_QUERIES ($((TOTAL_QUERIES - FAILED_QUERIES)) pass, $FAILED_QUERIES fail)"
echo "  Results: $RESULTS_FILE"
echo "============================================"
