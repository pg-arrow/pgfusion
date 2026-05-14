# Benchmarking

## Criterion microbenchmarks

Run the built-in Criterion benchmarks (no external repo needed):

```bash
just bench              # run all three benchmark suites
just bench queries      # full-scan, aggregation, group-by, projection, point-lookup
just bench pipeline     # pipeline breakdown: I/O → parse → Arrow → DataFusion
just bench config       # memory limits, batch sizes, coalesce, partition counts
```

These benchmarks require a `pgbench` database registered in `pg-test-config.toml`.
Use `pgbench_test` as the database name when running `just pg-setup-pgbench`.

### Scale factors

| Scale factor | Rows (pgbench_accounts) | Size |
|---|---|---|
| SF=1 (default) | ~100k | ~15 MB |
| SF=100 | ~10M | ~1.5 GB |
| SF=10000 | ~1B | ~100 GB |

The default test setup uses SF=1. For more realistic benchmarks load a larger scale factor:

```bash
just pg-setup-pgbench pg18 sf=100    # SF=100
```

## Allocator benchmarks

pgfusion supports two allocators:

| Allocator | Feature flag | Notes |
|---|---|---|
| `mimalloc` | *(default)* | Always active unless `jemalloc` feature is enabled |
| `jemalloc` | `--features jemalloc` | [tikv-jemallocator](https://github.com/tikv/jemallocator) |

To compare allocator performance:

```bash
just bench                                          # mimalloc (default)
just bench-jemalloc                                 # jemalloc
```

Or run Criterion directly:

```bash
cargo bench --bench queries                         # mimalloc
cargo bench --bench queries --features jemalloc     # jemalloc
```

> **Note:** At SF=1 and SF=100, allocator differences are typically within noise (~1-2%).
> The workload is I/O and decode bound. Differences may be more visible at SF=10000.

## CPU profiling

Profile a benchmark run with [Samply](https://github.com/mstange/samply):

```bash
just samply-bench queries            # profile the queries suite
just samply-bench pipeline           # profile the pipeline suite
just samply-bench queries count_star # profile with a filter
just flamegraph-open                 # open the generated flamegraph.svg
```

## TPC-H and ClickBench (full comparison vs PostgreSQL)

These benchmarks live in a separate repository:
[pgfusion-benchmark](https://github.com/pg-arrow/pgfusion-benchmark).

Set `PGFUSION_BENCHMARK_DIR` to the local clone path (add to `~/.zshrc` or `~/.bashrc`):

```bash
export PGFUSION_BENCHMARK_DIR=/path/to/pgfusion-benchmark
```

The proxy recipes in this repo's `justfile` forward to that repo and automatically
inject the required env vars (`PG_ARROW_TEST_CONFIG`, `PROJECT_ROOT`).

### TPC-H (22 queries)

```bash
just tpch-setup pg18              # build dbgen and load SF=10 dataset
just tpch pg18                    # run all 22 queries vs PostgreSQL
just tpch-query 1 pg18            # run a single query (e.g. Q1)
just tpch-skip 21 pg18            # run all except Q21
just tpch-checkpoint pg18         # run and archive results
just tpch-report                  # open latest heatmap in browser
```

### ClickBench (43 queries)

```bash
just clickbench-setup pg18        # download and load hits dataset (~75 GB uncompressed)
just clickbench pg18              # run all 43 queries vs PostgreSQL
just clickbench-checkpoint pg18   # run and archive results
just clickbench-report            # open latest heatmap in browser
```

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `PGFUSION_BENCHMARK_DIR` | Yes | Path to pgfusion-benchmark clone |
| `PG_ARROW_TEST_CONFIG` | No | Override path to `pg-test-config.toml` (defaults to `pgfusion/pg-test-config.toml`) |
| `PROJECT_ROOT` | No | Override pgfusion root path (defaults to `justfile_directory()`) |
