# Local Test step - fork renewal merge (10 commits through 10b93b2c)

Bounded, intent-targeted validation per CONTRIBUTING.md. 21 scripts, 6 batches,
**601 assertions, 0 failures**, ~17.1 min of test time.

## Merge shape (what the tests were run against)

    $ git rev-list --parents -n1 HEAD | tr ' ' '\n' | sed -n '2,3p'
    7c04bf260a5a37e6d5023eef75480b7ee68da96f     <- our pre-merge main
    10b93b2cc6f4241e87fccaee2e357c33a7347a53     <- upstream/main tip

    $ git rev-list --count 10b93b2c ^HEAD        # upstream commits not in HEAD
    0
    $ git rev-list --count 7c04bf2  ^HEAD        # our commits not in HEAD
    0

Nothing left to bring in from upstream, and nothing of ours dropped: both tips
are ancestors of the merge. Working tree clean; no test was edited.

## Batch results

| batch | scripts | failed | gate skips | seconds |
|---|---|---|---|---|
| 1 shared prose / brief / board / PR-description guard | 5 | 0 | 0 | 47 |
| 2 away-daemon pair (highest-risk seam) | 2 | 0 | 0 | 106 |
| 3 remote secondmate reconcile + fm-send inbox | 4 | 0 | 0 | 203 |
| 4 Pi / Claude auto-arm / Cursor-Park | 6 | 0 | 2 | 349 |
| 5 durable merged-PR reporting + inactive reconcile | 2 | 0 | 0 | 197 |
| 6 pooled slot freshen + test-family map | 2 | 0 | 0 | 121 |

The 2 gate skips are the optional Pi backend (`installed @earendil-works/pi-coding-agent
package not found`) - expected and normal, not failures.

## Both sides alive at the highest-risk seam

The away-daemon pair is where this fork's daemon-hosting fix meets upstream
5953e9b5 / 99c1a0dc. Both behaviours pass in the same run.

**Upstream's declared-wait / pause-cadence work, exercised and green:**

    ok - an enriched wedge under a declared wait uses the pause cadence and restores wedge detection on resume
    ok - housekeeping matures a busy pane's declared-wait window into exactly one recheck per window
    ok - a busy pane cannot gate the pause clear once its crew's status no longer declares the wait
    ok - housekeeping re-surfaces a stale declared pause on the long cadence and resets its window

**This fork's fix - the daemon no longer hosts itself in the pane it delivers
into - green on both backends, end to end:**

    ok - herdr e2e: captain tab pane count unchanged after start (no split)
    ok - herdr e2e: daemon launched in a separate non-visible workspace
    ok - herdr e2e: daemon pane is NOT in the captain's tab
    ok - tmux e2e: captain window pane count unchanged after start (no split-window)
    ok - tmux e2e: daemon launched in a separate detached session
    ok - tmux e2e: daemon session killed by exact id on stop

**Upstream 662a8c7d durable merged-PR reporting, alongside this fork's
PR-description-check change:**

    ok - fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge
    ok - fm-pr-merge propagates a real merge failure without silently succeeding
    ok - the merge path records metadata without re-litigating the description
    ok - an unreadable description degrades to a warning and the report proceeds

## Deliberately handed to CI, and CI's verdict on this exact tree

Four in-scope suites were handed to CI by name because they do not fit under the
step's hard 30-minute cap: `fm-pr-check-security` [746s], `fm-watch-triage` [361s],
`fm-teardown` [266s], `fm-bearings-snapshot` [182s].

Three characterised pre-existing failures stay out of the local batches:
`fm-secondmate-reconcile`, `fm-bootstrap-network-parallel`, `fm-watch-arm`. They
fail on pristine upstream and on the merge base, which predates both sides' work.

CI on this exact tree - **13 passed, the only failure being the no-mistakes gate
itself** - including all four portable serial behaviour shards, which is where
those three suites run. They PASS in CI, independently confirming them as
environment-dependent rather than caused by this merge.

    Behavior portable serial 1,pass    Behavior portable serial 3,pass
    Behavior portable serial 2,pass    Behavior portable serial 4,pass
