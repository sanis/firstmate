# Live validation — upstream renewal bringing `bin/fm-dispatch-resolve.sh` into the fork

Branch `chore/upstream-renewal-2026-09-19`, merge `a15ec5f` (52 upstream commits onto the fork).
Every transcript below was produced by running the real scripts in this worktree.

The captain's live `TYPESAFE_API_KEY` was used to make genuine calls to typesafe.ai
System One. It appears in **no** file here — verified by a verbatim sweep over every
evidence file and the whole worktree (0 hits each).

| # | Scenario | Result | Evidence |
|---|----------|--------|----------|
| 1 | Resolver stays inert with no key — incl. empty key and missing brief | pass | `01-gate-off-without-key.txt` |
| 2 | With the key, one concrete profile resolved from a written brief via jev | pass | `02-live-resolution-real-api.txt` |
| 3 | A `approval: captain` rule escalates, never auto-resolves | pass | `03-captain-approval-escalates.txt` |
| 4 | `.env` alone activates it; the process environment wins over `.env` | pass | `04-dotenv-activation-and-precedence.txt` |
| 5 | The credential never reaches stdout, stderr, or any file | pass | `05-credential-never-leaks.txt` |
| 6 | The resolver runs in this repo as shipped (no rules file yet) | pass | `real-repo-no-rules.txt` |
| 7 | The twelve conflict-resolved scripts still behave | pass | `conflicted-surface-suites.txt` |
| 8 | Documented `--changed` contributor path on the renewal branch | FAIL in round 1, fixed and passing in round 2 | `changed-selection-refusal.txt`, `changed-selection.md` |

Scenario 8 was round 1's only failure: `bin/fm-test-run.sh --changed`, the command
CONTRIBUTING.md:110 gives contributors, refuses outright on this branch because the
renewal modifies `GROK_BOT.md` and no side of the merge maps that path to a test family.
It self-heals once the captain merges (origin/main then already contains the new
GROK_BOT.md, so it leaves the changed set) and CI never uses `--changed`.

## Round 2 (after the --changed mapping fix)
- `changed-selection.md` - the documented `--changed` verification command before/after the fix, plus the GROK_BOT.md-only reproduction of the round-1 blocker.
- `changed-mapping-probes.md` - new root prose, shared capture, shared executable, and an adversarial unread test helper driven through the mapper.
- `dispatch-resolve-live.txt` - the renewed feature driven live against api.typesafe.ai with the configured key: no rules -> escalate, example rules -> clear profile.
- `dispatch-resolve-suite-hermeticity.md` - the feature's own suite failed on a machine that exports a real TYPESAFE_API_KEY; the suite now drops the ambient credential and passes from either shell.
- `owning-suite-differential.md` - the runner's own suite at HEAD vs at pure upstream tip on the same host.
