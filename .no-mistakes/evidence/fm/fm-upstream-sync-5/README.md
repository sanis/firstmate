# Evidence - fork sync: merge upstream/main (5 commits through 8fa0505)

Merge commit `6cee070`, parents `6b0fd49` (fork main) and `8fa0505` (upstream tip).

| Artifact | What it shows |
| --- | --- |
| `startup-network-real-layout.txt` | The parallelized startup network sweep run against this home's real clone layout (64 origin-backed clones, 0 remote secondmates), with elapsed numbers for the merge commit and its pre-merge parent, and the inherited clone-refresh budget cut-off both hit. |
| `startup-network-real-layout-merge-commit-output.txt` / `...-pre-merge-output.txt` | Raw output of those two runs. |
| `startup-network-fail-closed-ordering.txt` | Three concurrently probed remote mates, each rigged to a different failure: every refusal keeps its own host and reason and is replayed in spawn order, and the timeline shows the probes actually overlapping. |
| `startup-network-parallel-transcript.txt` | Full transcript the parallel test emitted: bootstrap output plus the remote operation timeline, for both the concurrent path and the sequential fallback. |
| `wake-count-both-directions.txt` | The wake-count fix, both directions: an absent queue now reports "did not use the bounded paused recheck", a genuine flood still fails with its real count, and the pre-fix control shows the misreported flood with no number. |
| `pr-body-compliance-check.txt` | This repo's PR body compliance check, executed for real: a documentation placeholder attestation ahead of the real one fails a fully compliant PR with a message that reads like an out-of-date tool. |
| `fork-gate-surfaces-live.txt` | `fm-pr-check.sh` refusing a description that pastes local evidence paths (exit 3) and accepting the same description with uploaded links, plus proof that `fm-pr-merge.sh` really does default to `--squash` on GitHub. |
| `fork-surfaces-intact.txt` | The fork's carried surfaces after the merge: the login-shell revert still matches upstream exactly, the four deliberately diverging test files still diverge with their exact content, git's own ignore engine still keeps `config/` local, and the ClickUp / attestation / evidence-artifacts case lists. |
| `merge-shape-and-scope.txt` | Both parents intact and the same shape as the two preceding syncs, all five upstream commits present as ancestors, `038d0f7` absent, nothing touched under `projects/ data/ state/ config/ .no-mistakes/`, and no tool-version floor moved. |
| `pi-supervision-branch-poster.png` / `.svg` | The incoming architecture poster, rendered headless at its native 1200x860. |
| `targeted-test-runs.txt` | Every test file the merge changed plus the fork-carried surfaces, with per-file results and the one by-design opt-in gate skip. |
| `pi-merge-note-surface.txt` | The merged Pi merge-note surface: the later commit supersedes the earlier icon change, so only the routine boat renders and the captain-facing note is deliberately never printed. |
