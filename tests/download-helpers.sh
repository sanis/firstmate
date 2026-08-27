#!/usr/bin/env bash
# tests/download-helpers.sh - shared stubs for the bin/fm-install-*.sh suites.
#
# Source after tests/lib.sh:
#   # shellcheck source=tests/download-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/download-helpers.sh"
#
# Every installer resolves its platform with uname, fetches its pinned asset
# through bin/fm-download-lib.sh, verifies a SHA-256, and sleeps between
# retries. These four stubs are the one owner of those fakes so the ShellCheck,
# actionlint, Treehouse and Herdr suites cannot drift apart on what a fake curl
# does. Archive-layout stubs stay with the suite that owns the layout.

# fm_install_stub_uname <fakebin>
# Answers `uname -s` / `uname -m` from FM_TEST_UNAME_S / FM_TEST_UNAME_M, so a
# suite can pin a platform regardless of the host it runs on.
fm_install_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

# fm_install_stub_curl <fakebin>
# A fake curl faithful to the parts of the real interface fm_download uses: it
# parses value-taking options, honours --write-out '%{http_code}' by printing a
# status on stdout, and reports failures the way curl does - an exit code plus a
# status that is 000 when no response arrived. Driven entirely by environment:
#   CURL_COUNT          file holding the running invocation count
#   CURL_URL_LOG        file the requested URL is appended to
#   CURL_ARGS_LOG       file the full argument vector is appended to, one line
#                       per invocation, so a test can assert a caller's bounds
#                       still reach curl
#   CURL_FAIL_UNTIL     number of leading invocations that fail (default 0)
#   CURL_FAIL_RC        exit code those failures use (default 56)
#   CURL_FAIL_STATUS    status those failures report (default 000, no response)
#   CURL_PAYLOAD        file whose bytes are written to -o on success; an empty
#                       file is written when unset
fm_install_stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${CURL_COUNT:-}" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
[ -z "${CURL_COUNT:-}" ] || printf '%s\n' "$count" > "$CURL_COUNT"
[ -z "${CURL_ARGS_LOG:-}" ] || printf '%s\n' "$*" >> "$CURL_ARGS_LOG"
url=
out=
write_out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output)
      out=$2
      shift 2
      ;;
    -w|--write-out)
      write_out=$2
      shift 2
      ;;
    --connect-timeout|--max-filesize|--max-time|--retry)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
emit_status() {
  [ "$write_out" = '%{http_code}' ] || return 0
  printf '%s' "$1"
}
if [ "$count" -le "${CURL_FAIL_UNTIL:-0}" ]; then
  emit_status "${CURL_FAIL_STATUS:-000}"
  printf 'curl: (%s) stubbed failure\n' "${CURL_FAIL_RC:-56}" >&2
  exit "${CURL_FAIL_RC:-56}"
fi
if [ -n "${CURL_PAYLOAD:-}" ]; then
  cat "$CURL_PAYLOAD" > "$out"
else
  : > "$out"
fi
emit_status 200
exit 0
SH
  chmod +x "$fakebin/curl"
}

# fm_install_stub_hasher <fakebin> <sha256sum|shasum>
# Prints SHA256_STUB_HASH for whatever file it is handed and records the
# invocation on HASHER_LOG. The shasum stub insists on -a 256, so a suite can
# prove the installer asks for the right algorithm.
fm_install_stub_hasher() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
self=${0##*/}
if [ -n "${HASHER_LOG:-}" ]; then
  printf '%s\n' "$self $*" >> "$HASHER_LOG"
fi
file=$1
if [ "$self" = shasum ]; then
  algo=
  file=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -a)
        algo=$2
        shift 2
        ;;
      *)
        file=$1
        shift
        ;;
    esac
  done
  [ "$algo" = 256 ] || exit 1
fi
printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$file"
SH
  chmod +x "$fakebin/$name"
}

# fm_install_stub_sleep <fakebin>
# Collapses the retry backoff so a bounded give-up test costs no wall clock.
fm_install_stub_sleep() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}
