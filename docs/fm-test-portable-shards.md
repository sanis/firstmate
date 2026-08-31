# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The parallel assignment's per-script inputs are the durations of the 2026-08-20 concurrent proof, which ran 24 candidates with four workers and no failures.
[fm-test-isolation-proof.md](fm-test-isolation-proof.md) owns that record and lists every duration; refreshing the inputs means re-running `bin/fm-test-isolation-proof.sh`, so they are kept there rather than copied here.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

Those estimates are the assignment's inputs rather than current runtimes: green CI run [33100473041](https://github.com/sanis/firstmate/actions/runs/33100473041) measured the lanes at 141202 ms and 139195 ms, an imbalance of 2007 ms, with the renewal-grown `tests/fm-pr-merge.test.sh` alone at 50184 ms against the 6290 ms the proof recorded for it.
Both lanes stay far inside the 10-minute cap, so refreshing the partition is balance work needing a fresh isolation proof, not a capacity risk.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The hints came from the `fm-test-timing-portable-serial-*` artifacts of green CI run [33100473041](https://github.com/sanis/firstmate/actions/runs/33100473041) on 2026-08-27, where the lane ran 133 scripts in 3240398 ms of serial work.
That run measured every script the lane selected at the time.
The renewal that followed added `tests/fm-home-summary-refresh.test.sh` and `tests/fm-remote-transport-lanes.test.sh`, which it did not measure, so those two carry the default weight until the next refresh.
The renewal after that added four more scripts, each of which arrived carrying an upstream-supplied hint rather than the default.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for a shard to time out.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of4` | 34 | 829116 ms (~829.1 s) |
| `portable-serial-2of4` | 35 | 829112 ms (~829.1 s) |
| `portable-serial-3of4` | 35 | 829113 ms (~829.1 s) |
| `portable-serial-4of4` | 35 | 829124 ms (~829.1 s) |
| imbalance | | 12 ms |

This table was refreshed on 2026-08-27 and recomputed on 2026-08-30 for the scripts the two renewals since have added.
`tests/fm-home-summary-refresh.test.sh` and `tests/fm-remote-transport-lanes.test.sh` remain the only two estimated rather than measured, at the `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default each, so the balance above is still worth planning from.
The refresh it replaced was overdue in a way the run before it made concrete: with fifteen scripts still on the default weight, the same green run's real shard times were 773043, 716092, 1093907 and 657356 ms, so one shard spent 18m14s of a 20-minute job cap while another idled at 11m.

The single longest hint, `tests/fm-pr-check-security.test.sh` at 233979 ms, is the floor for any shard count.
That hint predates the renewal that retired the legacy PR-check migration and cut most of the script, so it now reads high; the next measured refresh is what settles the real floor.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above:

```sh
gh run download <run-id> -R <repo> --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-4 | job `timeout-minutes: 20` | Each balanced shard is about 13.7 minutes of estimated script time, leaving hang-tripwire margin for job setup and runner-speed spread. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
