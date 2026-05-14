# Testing

## Setup (once)

Install test tooling:

```bash
cargo install cargo-nextest    # parallel test runner (required)
cargo install cargo-insta      # snapshot review tool
cargo install cargo-llvm-cov   # coverage (optional)
```

Clone [`pg-test-harness`](https://github.com/pg-arrow/pg-test-harness) and set `PG_HARNESS_DIR`:

```bash
git clone https://github.com/pg-arrow/pg-test-harness /path/to/pg-test-harness
export PG_HARNESS_DIR=/path/to/pg-test-harness   # add to ~/.zshrc or ~/.bashrc

just pg-setup-pgbench pg18   # build PG18, init cluster, load pgbench SF=1 (~100k rows)
just test-sql-seed           # seed SQL correctness snapshots against live PG (run once)
```

## Running tests

```bash
just test                    # unit tests (no PG needed)
just test-sql                # SQL correctness: snapshot diff only (no PG needed)
just test-sql-seed           # re-seed snapshots against live PG
just test-sql-validate       # force re-validate all snapshots against live PG
just test-consistency        # MVCC visibility tests (requires live PG)
just test-consistency-full   # + #[ignore] tests (clog/rollback)
just test-all                # test-sql + test-consistency
```

## Environment variables

| Variable | Description |
|---|---|
| `PG_HARNESS_DIR` | Path to pg-test-harness clone (required for `pg-setup-*` recipes) |
| `INSTA_SKIP_PG` | Set to skip PG connection in sql correctness tests (snapshot diff only) |
| `INSTA_FORCE_PG_VALIDATE=1` | Force re-validate all snapshots against live PG |
| `PG_TEST_NO_CHECKPOINT=1` | Skip CHECKPOINT in consistency tests (WAL streaming path) |
| `PG_VERSION` | Default PostgreSQL version (`pg18`) |
