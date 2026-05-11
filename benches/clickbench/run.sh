#!/usr/bin/env bash
set -euo pipefail

# ClickBench benchmark runner: pgfusion vs PostgreSQL
# Runs all 43 queries against both engines, captures timing, and produces a comparison.
#
# Usage:
#   ./run.sh [pg_version] [runs] [--checkpoint] [--checkpoint-only] [--label=<text>] [--query=N]
#
#   --checkpoint         After a full run, save results to checkpoints/<short-hash>[-label]/
#   --checkpoint-only    Skip the benchmark run; just archive current results to checkpoints/<short-hash>[-label]/
#   --label=<text>       Tag appended to the checkpoint folder name (e.g. --label=before-optimization)
#   --query=N            Run only query N (1-based); skips all others
#
# Results are always written to checkpoints/current/ during the run.

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
  --checkpoint) DO_CHECKPOINT=true ;;
  --checkpoint-only)
    DO_CHECKPOINT=true
    CHECKPOINT_ONLY=true
    ;;
  --label=*) CHECKPOINT_LABEL="${arg#--label=}" ;;
  --query=*) QUERY_FILTER="${arg#--query=}" ;;
  --skip=*)  QUERY_SKIP="${arg#--skip=}" ;;
  --*)
    echo "Unknown flag: $arg" >&2
    exit 1
    ;;
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

BENCH_DB="clickbench"
BENCH_TITLE="ClickBench Results Summary"
BENCH_QUERY_NAME_STRIP=false  # keep full query names as-is
BENCH_RESULTS_IN_ROOT=false   # results.csv lives in checkpoints/current/
BENCH_TUNE_WARN=true          # warn when max_parallel_workers_per_gather < 10

# shellcheck source=../bench_lib.sh
source "$SCRIPT_DIR/../bench_lib.sh"
