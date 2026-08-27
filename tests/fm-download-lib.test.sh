#!/usr/bin/env bash
# Retry policy owned by bin/fm-download-lib.sh, and its four installer callers.
#
# Regression origin: on 2026-08-26 the required Herdr CI lane on main died in
# setup, before a single test ran, on `curl: (35) Recv failure: Connection reset
# by peer` while fetching a pinned release asset. One reset turned a green tree
# red and cost a morning proving nothing was wrong with the code. The installers
# now share one retrying download, and these tests pin the four behaviours that
# make the retry safe rather than merely persistent: a clean first attempt, a
# recovery from a transient failure, a fast refusal to retry a missing asset,
# and a bounded give-up that still fails.
#
# Everything here drives the real interface - fm_download as installers source
# it, and the installer scripts themselves - against a local curl stub. Nothing
# reaches the network and nothing asserts implementation source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/download-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/download-helpers.sh"

LIB="$ROOT/bin/fm-download-lib.sh"

TREEHOUSE_INSTALLER="$ROOT/bin/fm-install-treehouse.sh"
HERDR_INSTALLER="$ROOT/bin/fm-install-herdr.sh"
SHELLCHECK_INSTALLER="$ROOT/bin/fm-install-shellcheck.sh"
ACTIONLINT_INSTALLER="$ROOT/bin/fm-install-actionlint.sh"

# The pinned Treehouse linux/amd64 digest published on the v2.0.1 release
# (https://github.com/kunchenguid/treehouse/releases/tag/v2.0.1). Compared
# against installer behavior, never against installer source.
TREEHOUSE_SHA_LINUX_AMD64=1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2
# The pinned Herdr linux x86_64 digest published on the v0.7.4 release
# (https://github.com/ogulcancelik/herdr/releases/tag/v0.7.4).
HERDR_SHA_LINUX_X86_64=bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059

# The bound the library publishes, read from the library itself so these tests
# follow a deliberate policy change instead of pinning a stale number.
ATTEMPTS=$(bash -c '. "$1"; printf "%s\n" "$FM_DOWNLOAD_ATTEMPTS"' _ "$LIB")

# fm_download_driver <tmp>: write a script that sources the library and calls
# fm_download exactly as an installer does, so these tests exercise the shipped
# interface rather than a re-implementation of it. Arguments after the output
# path are forwarded to fm_download unchanged.
fm_download_driver() {
  local tmp=$1 driver="$1/driver.sh"
  cat > "$driver" <<SH
#!/usr/bin/env bash
set -eu
# shellcheck disable=SC1091
. "$LIB"
url=\$1
output=\$2
shift 2
fm_download "\$url" "\$output" "\$@"
SH
  chmod +x "$driver"
  printf '%s\n' "$driver"
}

# fm_download_setup <prefix>: a temp root with a fakebin holding the curl and
# sleep stubs, printed as "<tmp> <fakebin>".
fm_download_setup() {
  local tmp fakebin
  tmp=$(fm_test_tmproot "$1")
  fakebin=$(fm_fakebin "$tmp")
  fm_install_stub_curl "$fakebin"
  fm_install_stub_sleep "$fakebin"
  printf '%s %s\n' "$tmp" "$fakebin"
}

test_succeeds_on_the_first_attempt() {
  local tmp fakebin driver rc out
  read -r tmp fakebin < <(fm_download_setup fm-download-first)
  driver=$(fm_download_driver "$tmp")

  rc=0
  out=$(CURL_COUNT="$tmp/count" PATH="$fakebin:$PATH" \
    "$driver" https://example.invalid/asset.tar.gz "$tmp/asset" 2>&1) || rc=$?

  [ "$rc" -eq 0 ] || fail "a healthy download did not succeed"$'\n'"$out"
  [ "$(cat "$tmp/count")" -eq 1 ] || fail "a healthy download did not stop at one attempt"
  [ -f "$tmp/asset" ] || fail "a healthy download did not write the output file"
  assert_not_contains "$out" "retrying" "a healthy download announced a retry"
  pass "fm_download succeeds on the first attempt without retrying"
}

test_recovers_from_a_connection_reset() {
  local tmp fakebin driver rc out
  read -r tmp fakebin < <(fm_download_setup fm-download-reset)
  driver=$(fm_download_driver "$tmp")

  # The incident's exact shape: the connection is reset before any response
  # arrives, so curl reports a network-layer failure and no HTTP status.
  rc=0
  out=$(CURL_COUNT="$tmp/count" CURL_FAIL_UNTIL=2 CURL_FAIL_RC=35 CURL_FAIL_STATUS=000 \
    PATH="$fakebin:$PATH" \
    "$driver" https://example.invalid/asset.tar.gz "$tmp/asset" 2>&1) || rc=$?

  [ "$rc" -eq 0 ] || fail "fm_download did not recover from a connection reset"$'\n'"$out"
  [ "$(cat "$tmp/count")" -eq 3 ] || fail "fm_download did not retry twice before succeeding"
  [ -f "$tmp/asset" ] || fail "fm_download did not write the output file after recovering"
  assert_contains "$out" "download attempt 1 failed; retrying" \
    "fm_download did not disclose its first retry"
  pass "fm_download retries a connection reset and then succeeds"
}

test_retries_a_server_side_transient_status() {
  local tmp fakebin driver rc out status
  read -r tmp fakebin < <(fm_download_setup fm-download-5xx)
  driver=$(fm_download_driver "$tmp")

  # 503 and 429 are the server saying "not now", so the identical request can
  # succeed later. 408 is the same promise from the request timing out.
  for status in 503 500 429 408; do
    rm -f "$tmp/asset"
    rc=0
    out=$(CURL_COUNT="$tmp/count" CURL_FAIL_UNTIL=1 CURL_FAIL_RC=22 CURL_FAIL_STATUS="$status" \
      PATH="$fakebin:$PATH" \
      "$driver" https://example.invalid/asset.tar.gz "$tmp/asset" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "fm_download did not retry HTTP $status"$'\n'"$out"
    [ "$(cat "$tmp/count")" -eq 2 ] || fail "fm_download did not retry HTTP $status exactly once"
    assert_contains "$out" "http $status" "fm_download did not report the $status it retried"
    rm -f "$tmp/count"
  done
  pass "fm_download retries a server-side transient status (408, 429, 5xx)"
}

test_missing_asset_fails_fast() {
  local tmp fakebin driver rc out rc_shape
  read -r tmp fakebin < <(fm_download_setup fm-download-404)
  driver=$(fm_download_driver "$tmp")

  # curl's exit code for a 404 under --fail is not stable: it is 22 over
  # HTTP/1.1 and 56 - the code a genuine reset also uses - over HTTP/2 against
  # GitHub. A wrong pin must fail fast under either, so the status decides.
  for rc_shape in 22 56; do
    rm -f "$tmp/count"
    rc=0
    out=$(CURL_COUNT="$tmp/count" CURL_FAIL_UNTIL=99 CURL_FAIL_RC="$rc_shape" CURL_FAIL_STATUS=404 \
      PATH="$fakebin:$PATH" \
      "$driver" https://example.invalid/wrong-version.tar.gz "$tmp/asset" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "fm_download reported success for a missing asset (curl $rc_shape)"
    [ "$(cat "$tmp/count")" -eq 1 ] \
      || fail "fm_download retried a missing asset (curl $rc_shape): $(cat "$tmp/count") attempts"
    assert_not_contains "$out" "retrying" "fm_download announced a retry for a missing asset"
  done
  pass "fm_download refuses to retry a missing asset whatever exit code curl picks"
}

test_permanent_client_and_local_failures_are_not_retried() {
  local tmp fakebin driver rc case_rc case_status
  read -r tmp fakebin < <(fm_download_setup fm-download-permanent)
  driver=$(fm_download_driver "$tmp")

  # 403 cannot be waited out; curl 63 is the caller's own --max-filesize
  # ceiling, a fact about the asset; curl 23 is a local write error.
  while read -r case_rc case_status; do
    [ -n "$case_rc" ] || continue
    rm -f "$tmp/count"
    rc=0
    CURL_COUNT="$tmp/count" CURL_FAIL_UNTIL=99 CURL_FAIL_RC="$case_rc" CURL_FAIL_STATUS="$case_status" \
      PATH="$fakebin:$PATH" \
      "$driver" https://example.invalid/asset.tar.gz "$tmp/asset" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "fm_download reported success for curl $case_rc / http $case_status"
    [ "$(cat "$tmp/count")" -eq 1 ] \
      || fail "fm_download retried curl $case_rc / http $case_status: $(cat "$tmp/count") attempts"
  done <<'EOF'
22 403
63 200
23 200
EOF
  pass "fm_download fails fast on client, ceiling, and local-write failures"
}

test_gives_up_within_the_published_bound() {
  local tmp fakebin driver rc out
  # Without at least one retry in the bound this test could not tell a give-up
  # from a single attempt, and would pass while proving nothing.
  [ "$ATTEMPTS" -ge 2 ] \
    || fail "the published attempt bound is $ATTEMPTS, so a retry ladder is not being exercised"
  read -r tmp fakebin < <(fm_download_setup fm-download-outage)
  driver=$(fm_download_driver "$tmp")

  rc=0
  out=$(CURL_COUNT="$tmp/count" CURL_FAIL_UNTIL=99 CURL_FAIL_RC=35 CURL_FAIL_STATUS=000 \
    PATH="$fakebin:$PATH" \
    "$driver" https://example.invalid/asset.tar.gz "$tmp/asset" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "a sustained outage did not fail"$'\n'"$out"
  [ "$(cat "$tmp/count")" -eq "$ATTEMPTS" ] \
    || fail "a sustained outage used $(cat "$tmp/count") attempts, not the published bound of $ATTEMPTS"
  pass "fm_download gives up after exactly $ATTEMPTS attempts and still fails"
}

test_caller_arguments_reach_curl_unchanged() {
  local tmp fakebin driver args
  read -r tmp fakebin < <(fm_download_setup fm-download-args)
  driver=$(fm_download_driver "$tmp")

  CURL_ARGS_LOG="$tmp/args" PATH="$fakebin:$PATH" \
    "$driver" https://example.invalid/asset.tar.gz "$tmp/asset" --max-filesize 15000000 \
    >/dev/null 2>&1 || fail "fm_download failed while forwarding caller arguments"

  args=$(cat "$tmp/args")
  assert_contains "$args" "--max-filesize 15000000" \
    "fm_download dropped the caller's --max-filesize bound"
  assert_contains "$args" "-fsSL" \
    "fm_download stopped failing on HTTP errors, staying silent, or following redirects"
  assert_contains "$args" "--connect-timeout" "fm_download left the connect phase unbounded"
  pass "fm_download forwards caller bounds and keeps curl's own safety flags"
}

# --- the callers ------------------------------------------------------------
#
# Each installer keeps the behaviour it had before the shared helper existed:
# it recovers from a blip, it still names its URL when the download is hopeless,
# and it still exits non-zero. ShellCheck's and actionlint's own success paths
# stay covered by tests/fm-lint.test.sh and tests/fm-lint-workflows.test.sh.

# fm_download_stub_tar_binary <fakebin> <name> <version-output>: a tar stub that
# unpacks a single executable of <name> answering --version with <version-output>,
# matching the archive layout the Treehouse installer expects.
fm_download_stub_tar_binary() {
  local fakebin=$1 name=$2 version=$3 payload
  payload="$fakebin/$name-payload"
  cat > "$payload" <<SH
#!/usr/bin/env bash
printf '%s\n' '$version'
SH
  chmod +x "$payload"
  cat > "$fakebin/tar" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "-C" ]; then
    cp "$payload" "\$2/$name"
    chmod +x "\$2/$name"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/tar"
}

test_treehouse_installer_recovers_and_keeps_its_bound() {
  local tmp fakebin destination rc out args
  read -r tmp fakebin < <(fm_download_setup fm-treehouse-recover)
  destination="$tmp/bin"
  fm_install_stub_uname "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_download_stub_tar_binary "$fakebin" treehouse v2.0.1

  rc=0
  out=$(CURL_COUNT="$tmp/count" CURL_ARGS_LOG="$tmp/args" \
    CURL_FAIL_UNTIL=2 CURL_FAIL_RC=35 CURL_FAIL_STATUS=000 \
    SHA256_STUB_HASH="$TREEHOUSE_SHA_LINUX_AMD64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$TREEHOUSE_INSTALLER" "$destination" 2>&1) || rc=$?

  [ "$rc" -eq 0 ] || fail "the Treehouse installer did not survive a connection reset"$'\n'"$out"
  [ "$(cat "$tmp/count")" -eq 3 ] || fail "the Treehouse installer did not retry twice"
  [ -x "$destination/treehouse" ] || fail "the Treehouse installer did not install the binary"
  args=$(cat "$tmp/args")
  assert_contains "$args" "--max-filesize 15000000" \
    "the Treehouse installer lost its bounded download ceiling"
  pass "the Treehouse installer survives a reset and keeps its bounded ceiling"
}

test_herdr_installer_recovers_and_keeps_its_bound() {
  local tmp fakebin destination rc out args payload
  read -r tmp fakebin < <(fm_download_setup fm-herdr-recover)
  destination="$tmp/bin"
  fm_install_stub_uname "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum

  # The Herdr asset is the binary itself, so the stubbed download must deliver
  # something the installer's version and protocol gates can actually run.
  payload="$tmp/herdr-payload"
  cat > "$payload" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'herdr 0.7.4\n' ;;
  status) printf '{"client":{"protocol":16}}\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
# Only the protocol lookup the Herdr installer performs.
sed -n 's/.*"protocol":[[:space:]]*\([0-9][0-9]*\).*/\1/p'
SH
  chmod +x "$fakebin/jq"

  rc=0
  out=$(CURL_COUNT="$tmp/count" CURL_ARGS_LOG="$tmp/args" CURL_PAYLOAD="$payload" \
    CURL_FAIL_UNTIL=2 CURL_FAIL_RC=56 CURL_FAIL_STATUS=200 \
    SHA256_STUB_HASH="$HERDR_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$HERDR_INSTALLER" "$destination" 2>&1) || rc=$?

  [ "$rc" -eq 0 ] || fail "the Herdr installer did not survive a mid-body hang-up"$'\n'"$out"
  [ "$(cat "$tmp/count")" -eq 3 ] || fail "the Herdr installer did not retry twice"
  [ -x "$destination/herdr" ] || fail "the Herdr installer did not install the binary"
  args=$(cat "$tmp/args")
  assert_contains "$args" "--max-filesize 25000000" \
    "the Herdr installer lost its bounded download ceiling"
  pass "the Herdr installer survives a mid-body hang-up and keeps its bounded ceiling"
}

test_every_installer_fails_fast_and_names_its_url() {
  local tmp fakebin destination rc out installer label
  read -r tmp fakebin < <(fm_download_setup fm-installer-404)
  fm_install_stub_uname "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum

  while read -r label installer; do
    [ -n "$label" ] || continue
    rm -f "$tmp/count"
    destination="$tmp/bin-$label"
    rc=0
    out=$(CURL_COUNT="$tmp/count" CURL_FAIL_UNTIL=99 CURL_FAIL_RC=22 CURL_FAIL_STATUS=404 \
      SHA256_STUB_HASH=0000000000000000000000000000000000000000000000000000000000000000 \
      FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
      PATH="$fakebin:$PATH" "$installer" "$destination" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "the $label installer reported success for a missing asset"$'\n'"$out"
    [ "$(cat "$tmp/count")" -eq 1 ] \
      || fail "the $label installer retried a missing asset: $(cat "$tmp/count") attempts"
    assert_contains "$out" "download failed for https://github.com/" \
      "the $label installer did not name the URL it failed to download"
  done <<EOF
treehouse $TREEHOUSE_INSTALLER
herdr $HERDR_INSTALLER
shellcheck $SHELLCHECK_INSTALLER
actionlint $ACTIONLINT_INSTALLER
EOF
  pass "every installer fails fast on a missing asset and names the URL"
}

test_succeeds_on_the_first_attempt
test_recovers_from_a_connection_reset
test_retries_a_server_side_transient_status
test_missing_asset_fails_fast
test_permanent_client_and_local_failures_are_not_retried
test_gives_up_within_the_published_bound
test_caller_arguments_reach_curl_unchanged
test_treehouse_installer_recovers_and_keeps_its_bound
test_herdr_installer_recovers_and_keeps_its_bound
test_every_installer_fails_fast_and_names_its_url
