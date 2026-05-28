# Perf Harness (T076)

Reproducible benchmark for `src/reconcile.sh` against synthetic
repos of N specs × 30 tasks each. Hermetic — never hits live Linear.

## Run

```bash
# Default matrix (N = 1, 5, 10, 25, 50):
bash tests/perf/run.sh

# Custom matrix:
bash tests/perf/run.sh --n 1,5,10

# Keep the generated sandbox repos for post-mortem:
bash tests/perf/run.sh --keep-sandbox
```

## What gets measured

For each N, `run.sh`:

1. Generates a sandbox consumer repo with N specs rendered from
   `tests/perf/fixtures/spec-template/` (spec.md + plan.md +
   tasks.md, 4 phases / 30 tasks per spec).
2. Drops a valid `linear-config.yml`, a fake `.env`, and PATH-shims
   for `curl` (returns `{"data":{}}`) + `gh` (returns "no PR").
3. Times two back-to-back invocations of
   `bash src/reconcile.sh --all --dry-run --quiet` using
   `EPOCHREALTIME` (microsecond precision). First = **cold**,
   second = **hot**.

## SC thresholds (binding at N=10)

From `specs/001-spec-kit-linear-bridge/tasks.md` T076 +
`plan.md` Performance Goals:

- Cold reconcile of the 10-spec / 30-task fixture: **≤ 30s**.
- Hot reconcile of the 10-spec / 30-task fixture: **≤ 5s**.

For N ≠ 10 the harness reports timings but does not fail.

## Baselines

Current measured baselines live in `tests/perf/baselines.json`.
Regenerate by running the harness and pasting the trailing
`baselines.json rows` block into the `rows` array.

## Exit codes

- `0` — all measured N values met their threshold (or were exempt).
- `1` — at least one measured N exceeded its threshold.
- `2` — harness setup error (missing reconcile.sh, bash < 4, etc.).
