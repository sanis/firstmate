# bin/fm-test-run.sh --changed: live mapping probes (--base HEAD, one edit at a time)

## 1. New root prose file -> the suite that measures prose
$ bin/fm-test-run.sh --list --changed --base HEAD   # after creating ZZ_NEW_PROSE_9f3a.md
tests/fm-documentation-audiences.test.sh
exit=0

## 2. Changed shared capture fixture -> its reader
$ bin/fm-test-run.sh --list --changed --base HEAD   # after touching tests/captures/no-mistakes-v1.70.1/overview.toon
tests/fm-agy-harness.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-ask-user-authority.test.sh
tests/fm-bearings-board.test.sh
tests/fm-brief.test.sh
tests/fm-calm-claude-mod.test.sh
tests/fm-calm-pi-extension.test.sh
tests/fm-captain-hold-lifecycle.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-classify-decision-key.test.sh
tests/fm-clickup-contract.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-download-lib.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-harness-adapter-references.test.sh
tests/fm-harness-precedence.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-lint-workflows.test.sh
tests/fm-lint.test.sh
tests/fm-muse-harness.test.sh
tests/fm-omp-harness.test.sh
tests/fm-operational-input.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-rovo-harness.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-task-delivery.test.sh
tests/fm-test-isolation-proof.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-trace-context-lib.test.sh
tests/fm-transition-lib.test.sh
tests/fm-vendor-auth-probe.test.sh
exit=0

## 3. Changed shared test executable -> its reader
$ bin/fm-test-run.sh --list --changed --base HEAD   # after touching tests/fm-turnend-foreign-owner-repro.py
tests/fm-cursor-primary.test.sh
tests/fm-daemon.test.sh
tests/fm-guard-stale-banner.test.sh
tests/fm-inactive-reconcile.test.sh
tests/fm-mail-check.test.sh
tests/fm-mail.test.sh
tests/fm-pi-watch-extension.test.sh
tests/fm-session-lock-ancestry.test.sh
tests/fm-supervision-events.test.sh
tests/fm-task-inbox.test.sh
tests/fm-tool-update-check.test.sh
tests/fm-turnend-foreign-owner-arm-fix.test.sh
tests/fm-turnend-guard.test.sh
tests/fm-wake-daemon-lifecycle-e2e.test.sh
tests/fm-wake-drain-unread-status.test.sh
tests/fm-wake-queue.test.sh
tests/fm-watch-arm.test.sh
tests/fm-watch-checkpoint.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-watch-triage.test.sh
tests/fm-watcher-lock.test.sh
exit=0

## 4. ADVERSARIAL: a tests/ file nothing reads must still refuse (fail closed)
$ bin/fm-test-run.sh --list --changed --base HEAD   # after creating tests/zz-nobody-reads-this-9f3a.sh
fm-test-run: no changed-test mapping for source path: tests/zz-nobody-reads-this-9f3a.sh
exit=2
