# The dispatch-resolve suite on the machine that actually holds the key

The renewal's headline arrival is `bin/fm-dispatch-resolve.sh`, gated on
`TYPESAFE_API_KEY`. The captain is setting that key up locally, so from now on
their shell exports it. Driving the feature's own suite from such a shell is
the realistic end-user run, and it is the run that broke.

## Before: suite run from a shell that exports a real TYPESAFE_API_KEY

    $ bin/fm-test-run.sh tests/fm-dispatch-resolve.test.sh
    not ok - absent key prints nothing on stdout (expected '', got 'dispatch-resolve:
      status: clear
      model: jev-1.13.0   latency_ms: 414   tokens: 812/60
      rule: rule_4 (A simple bug fix with a stated root cause.)   confidence: 0.9
      ...
    FM_TEST_SUMMARY total=1 failed=1 skipped_gate=0
    exit=1

The suite's own comment says the key "comes from the caller's env", so the
absent-key case only means absent when the caller happens to have none. The
tool is correct — it found the key it was given and resolved a profile. The
case is the thing that was not hermetic, and it aborted the suite at the first
assertion, hiding the seventeen cases behind it.

No network was touched: the fake curl on PATH answers every call.

## Fix

`tests/fm-dispatch-resolve.test.sh` now drops the ambient credential at the top
of the file, before any case runs. Each case that wants a key still supplies
its own with a `TYPESAFE_API_KEY=$KEY run ...` prefix, so nothing else changes.

    unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE

`TYPESAFE_API_KEY_PRIVATE` goes too: that is the name the tool re-homes the key
under internally, and two of the fakes assert children never see either.

## After: same shell, same real key exported

    $ bin/fm-test-run.sh tests/fm-dispatch-resolve.test.sh
    18 ok, 0 not ok
    FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=14059
    exit=0

And from a shell with no key at all, unchanged:

    $ env -u TYPESAFE_API_KEY bin/fm-test-run.sh tests/fm-dispatch-resolve.test.sh
    18 ok, 0 not ok   exit=0

The suite now reads the same from either shell. The real key appears nowhere in
either transcript.
