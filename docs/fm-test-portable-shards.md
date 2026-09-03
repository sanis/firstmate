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
The hints are the slowest measurement of each script across the `fm-test-timing-portable-serial-*` artifacts of three green CI runs on 2026-09-01, [33558082172](https://github.com/kunchenguid/firstmate/actions/runs/33558082172), [33523597838](https://github.com/kunchenguid/firstmate/actions/runs/33523597838), and [33463326167](https://github.com/kunchenguid/firstmate/actions/runs/33463326167).
Those runs measured the 140 scripts that lane carried, and every hint they cover is used here in preference to an older single-run measurement.
The four scripts only this fork carries - `tests/fm-clickup-contract.test.sh`, `tests/fm-download-lib.test.sh`, `tests/fm-evidence-artifacts.test.sh`, and `tests/fm-pr-description-guard.test.sh` - keep their measurements from green fork run [33100473041](https://github.com/sanis/firstmate/actions/runs/33100473041).
All 144 scripts of the merged lane are therefore measured rather than defaulted, and the hints total 3837183 ms of conservative balance weight.
Taking the slowest of several runs rather than a single run keeps the balance honest on a slow runner: individual scripts varied by up to 20% between those three runs.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of5` | 28 | 767438 ms (~12.79 min) |
| `portable-serial-2of5` | 29 | 767435 ms (~12.79 min) |
| `portable-serial-3of5` | 29 | 767431 ms (~12.79 min) |
| `portable-serial-4of5` | 29 | 767431 ms (~12.79 min) |
| `portable-serial-5of5` | 29 | 767448 ms (~12.79 min) |
| imbalance | | 17 ms |

This table was recomputed on 2026-09-03 by replaying `bin/fm-test-run.sh`'s own assignment over the merged 144-script lane, rather than by adjusting the previous numbers, so it matches what the runner selects.
No script is on the default weight, and the worst shard's 12.79 minutes is 64% of the 20-minute job cap.

The single longest script, `tests/fm-watch-triage.test.sh` at 262626 ms, is the floor for any shard count.

Refresh the hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the table above:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R <repo> --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

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
| portable serial 1-5 | job `timeout-minutes: 20` | Each balanced shard is about 12.8 minutes of measured script time, leaving roughly 1.6x hang-tripwire margin for job setup and runner-speed spread. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finish around 7 minutes, so the step bound is the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.
