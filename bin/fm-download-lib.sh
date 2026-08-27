#!/usr/bin/env bash
# fm-download-lib.sh - the single owner of firstmate's retrying HTTP download.
#
# Sourced, never executed. Every installer under bin/ that fetches a pinned
# release asset does it through fm_download, so the retry policy - what is worth
# retrying, how many attempts, and how long a hopeless download may cost - is
# stated once here instead of drifting across five copies of the same flags.
#
#   fm_download <url> <output-path> [extra curl args...]
#       Downloads <url> to <output-path> with `curl -fsSL`, retrying only
#       transient failures. Extra arguments reach curl unchanged, so a caller
#       keeps its own bounds - notably --max-filesize. Returns 0 on success and
#       curl's own non-zero status otherwise. The caller owns the user-facing
#       failure message, so each installer still names its own URL and bound.
#
# Bound, and why these numbers: 4 attempts with 1s, 2s then 4s of backoff, so a
# sustained outage costs about 7 seconds of waiting rather than the minute the
# previous 6-attempt ladder spent before failing anyway. Attempts alone are not
# a bound, though, because curl leaves both ends of a request open by default:
# a 300s connect timeout, and no transfer timeout whatsoever. Both ends are
# closed here, and the arithmetic below is what the closed ends buy.
#
# Worst case, from the numbers this file sets:
#   - one attempt costs at most 20s of connect plus 30s of stall detection: 50s
#   - four attempts: 4 x 50s = 200s
#   - backoff between them: 1s + 2s + 4s = 7s
#   - total: 207s, about three and a half minutes
# That is the ceiling for the slowest possible give-up. The common failure is
# far cheaper: a request that dies during connect - a DNS failure, a refused
# connection - never spends its connect or stall budget at all, so the whole
# ladder costs only the 7s of backoff, measured at about 8s of wall clock
# against a real unroutable host.
#
# The stall guard is deliberately keyed on progress rather than elapsed time. A
# transfer sustaining at least 1024 B/s is never aborted however long it runs,
# because that is a slow download and not a dead one; only a transfer that stays
# below that floor for 30 continuous seconds is given up on. A flat wall-clock
# --max-time cannot tell those two apart and would fail a large asset on a slow
# runner, trading this stall for a new class of false failure. This bounds a
# dead transfer, not a slow one, and that is the intended trade.
#
# Classification, and why each class sits where it does. The HTTP status is the
# primary axis and curl's exit code only the secondary one, because curl reuses
# exit codes across unrelated failures: a 404 under --fail exits 22 over
# HTTP/1.1 but 56 - the same code a genuine connection reset uses - over HTTP/2
# against GitHub. The status separates them where the exit code cannot.
#
# Retried, because the identical request can succeed on a later attempt:
#   - 408, 429 and any 5xx: the server itself said "not now".
#   - No response at all (status 000) with a network-layer curl exit: a DNS
#     blip, a refused or reset connection, a timeout, an empty reply. This is
#     the class that turned a green tree red on 2026-08-26, when a pinned asset
#     download died on `curl: (35) Recv failure: Connection reset by peer`.
#   - A response that started cleanly and then hung up mid-body: the bytes are
#     still there to fetch again.
#
# Not retried, because repeating the request cannot change the answer:
#   - Any other 4xx, 404 above all. A wrong pinned version is a fact about the
#     request, so it must fail fast and loudly instead of spinning through the
#     whole ladder before failing anyway.
#   - curl 63, the caller's --max-filesize ceiling checked against a known
#     length. That is a fact about the asset, not about the network.
#     One measured caveat: against a real GitHub release asset on curl 8.7.1 the
#     same ceiling instead surfaces as exit 56 with a healthy HTTP 200, which is
#     indistinguishable from a reset and so gets retried. That is deliberately
#     left alone rather than guessed at, because curl refuses the oversized
#     transfer before reading a single body byte, so the retries cost only the
#     backoff and every attempt still refuses at the same ceiling. The bound
#     holds and the download still fails non-zero inside the ladder either way.
#   - Everything else, including a local write error and a malformed URL. An
#     unrecognized failure fails fast rather than being assumed transient.
set -u

# Bounds (overridable for tests). The shipped defaults are the four numbers the
# header's worst-case arithmetic is computed from.
# Attempts include the first try: 4 means one download plus three retries.
FM_DOWNLOAD_ATTEMPTS=${FM_DOWNLOAD_ATTEMPTS:-4}
# Seconds allowed for each attempt's connect phase. Generous for any real
# handshake, and short enough to keep the per-attempt ceiling at 50s.
FM_DOWNLOAD_CONNECT_TIMEOUT=${FM_DOWNLOAD_CONNECT_TIMEOUT:-20}
# The stall guard: bytes per second an in-flight transfer must sustain, and how
# many continuous seconds it may stay below that before curl abandons the
# attempt. 1024 B/s is far under anything a real release-asset fetch delivers,
# so this catches a dead transfer without punishing a slow one.
FM_DOWNLOAD_SPEED_LIMIT=${FM_DOWNLOAD_SPEED_LIMIT:-1024}
FM_DOWNLOAD_SPEED_TIME=${FM_DOWNLOAD_SPEED_TIME:-30}

# fm_download_transient <curl-exit-code> <http-status>
# Exit 0 when the failure is worth another attempt. See the header for why.
fm_download_transient() {
  local rc=$1 status=$2
  case "$status" in
    408|429|5??) return 0 ;;
    4??) return 1 ;;
  esac
  # No response, or one that started fine and then broke. Only the exit code is
  # left to say whether the network or the request itself failed.
  # 6 DNS, 7 connect, 16 HTTP/2 framing, 18 partial body, 28 timeout, 35 TLS or
  # recv failure, 52 empty reply, 55 send failure, 56 recv failure, 92 stream.
  case "$rc" in
    6|7|16|18|28|35|52|55|56|92) return 0 ;;
  esac
  return 1
}

fm_download() {
  local url=$1 output=$2
  shift 2
  local attempt=1 rc status delay
  while :; do
    rc=0
    status=$(curl -fsSL \
      --connect-timeout "$FM_DOWNLOAD_CONNECT_TIMEOUT" \
      --speed-limit "$FM_DOWNLOAD_SPEED_LIMIT" \
      --speed-time "$FM_DOWNLOAD_SPEED_TIME" \
      --write-out '%{http_code}' \
      "$@" "$url" -o "$output") || rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    fm_download_transient "$rc" "$status" || return "$rc"
    [ "$attempt" -lt "$FM_DOWNLOAD_ATTEMPTS" ] || return "$rc"
    delay=$((1 << (attempt - 1)))
    printf '%s: download attempt %s failed; retrying in %ss (curl %s, http %s)\n' \
      "${0##*/}" "$attempt" "$delay" "$rc" "$status" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}
