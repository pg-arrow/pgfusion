#!/usr/bin/env bash
set -euo pipefail

# TPC-H benchmark runner: pgfusion vs PostgreSQL
# Runs all 22 TPC-H queries against both engines, captures timing, and produces a comparison.
#
# Usage:
#   ./run.sh [pg_version] [runs] [--checkpoint] [--checkpoint-only] [--label=<text>] [--query=N]
#
#   --checkpoint         After a full run, save results to checkpoints/<short-hash>[-label]/
#   --checkpoint-only    Skip the benchmark run; just archive current results to checkpoints/<short-hash>[-label]/
#   --label=<text>       Tag appended to the checkpoint folder name (e.g. --label=before-optimization)
#   --query=N            Run only query N (1-based); skips all others
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
QUERY_FILTER=""
QUERY_SKIP=""

for arg in "$@"; do
    case "$arg" in
        --checkpoint)        DO_CHECKPOINT=true ;;
        --checkpoint-only)   DO_CHECKPOINT=true; CHECKPOINT_ONLY=true ;;
        --label=*)           CHECKPOINT_LABEL="${arg#--label=}" ;;
        --query=*)           QUERY_FILTER="${arg#--query=}" ;;
        --skip=*)            QUERY_SKIP="${arg#--skip=}" ;;
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

# ── Benchmark identity ───────────────────────────────────────────────────────

BENCH_DB="tpch"
BENCH_TITLE="TPC-H Results Summary"
BENCH_QUERY_NAME_STRIP=true   # strip ":.*" suffix from query names
BENCH_RESULTS_IN_ROOT=true    # results.csv lives in $SCRIPT_DIR
BENCH_TUNE_WARN=false

# shellcheck source=../bench_lib.sh
source "$SCRIPT_DIR/../bench_lib.sh"
