# fm-test-run --changed selection on chore/upstream-renewal-2026-09-19

## Changed prose in the renewal (vs origin/main)
  AGENTS.md
  CONTRIBUTING.md
  GROK_BOT.md
  README.md

## BEFORE the fix — merge commit a15ec5f's fm-test-run.sh
```
$ bin/fm-test-run.sh --list --changed
fm-test-run: no changed-test mapping for source path: GROK_BOT.md
exit=2   selected=0
```

## AFTER the fix — HEAD's fm-test-run.sh
```
$ bin/fm-test-run.sh --list --changed
exit=0   selected=222   (185s wall)

documentation-audiences suite present in selection:
tests/fm-documentation-audiences.test.sh
```

## Tight reproduction of the round-1 blocker: GROK_BOT.md alone (--base HEAD)
```
$ bin/fm-test-run.sh --list --changed --base HEAD   # only GROK_BOT.md modified
tests/fm-documentation-audiences.test.sh
exit=0
```
