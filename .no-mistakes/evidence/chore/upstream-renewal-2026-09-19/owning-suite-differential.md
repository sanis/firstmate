# tests/fm-test-run.test.sh: this branch vs pure upstream tip, same host

Both runs: `bin/fm-test-run.sh tests/fm-test-run.test.sh` (key scrubbed), macOS host.

## Pure upstream tip 2bcb88c, clean clone, its own files
    34 ok
    not ok - the timed-out script left grandchild 12798 running
    FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=478633 failed=1
    exit=1

## This branch, HEAD aef88bb
    37 ok
    not ok - the timed-out script left grandchild 23209 running
    FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=533291 failed=1
    exit=1

The renewal adds three passing selector assertions (root prose, shared capture,
shared executable) and inherits exactly one failure that upstream already fails
on this machine: `test_per_script_timeout_bounds_a_hang` expects the per-script
bound to reap a TERM-ignoring grandchild via the process group, and it survives
here.

`bin/fm-timeout-lib.sh`, which owns that reaping, is byte-identical to both merge
parents:
    $ git diff --stat 2bcb88c HEAD -- bin/fm-timeout-lib.sh   # empty
    $ git diff --stat 599ea9e HEAD -- bin/fm-timeout-lib.sh   # empty
So the branch neither causes nor worsens it.
