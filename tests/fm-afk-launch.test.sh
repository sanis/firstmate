#!/usr/bin/env bash
# tests/fm-afk-launch.test.sh - the script-owned, backend-aware away-daemon
# launch (bin/fm-afk-launch.sh) and the away-mode stale-artifact lifecycle fixes
# (bin/fm-afk-start.sh). Two layers:
#
#   UNIT (always run, no backend): the session-scoped stale-artifact clear on a
#   fresh entry vs a refresh, and the correct-ordered stop (daemon SIGTERM'd
#   while state/.afk is still present, .afk cleared last).
#
#   E2E TOPOLOGY (per backend, skipped when its tool is absent): the anti-
#   regression for the pane split/shrink - entering AND exiting away mode leaves
#   the captain's active tab topology UNCHANGED, because the daemon lands in a
#   NON-VISIBLE separate terminal (a herdr dedicated workspace, a detached tmux
#   session), never a split of the captain's pane. The herdr path runs on a
#   throwaway, NEVER-default HERDR_SESSION and asserts the default session is
#   byte-identical via the fm-herdr-lab.sh fleet-state tripwire; the tmux path
#   uses uniquely-named throwaway sessions killed by exact name. A harmless
#   sleeper replaces the real daemon (FM_AFK_LAUNCH_ENTRY) so the test observes
#   only the terminal lifecycle.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
START="$ROOT/bin/fm-afk-start.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

SLEEPER=$(mktemp "${TMPDIR:-/tmp}/fm-afk-sleeper.XXXXXX")
printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$SLEEPER"
chmod +x "$SLEEPER"
TRACK_TMUX_SESSIONS=""
GLOBAL_CLEANUP() {
  rm -f "$SLEEPER" 2>/dev/null || true
  local s
  for s in $TRACK_TMUX_SESSIONS; do
    tmux kill-session -t "$s" 2>/dev/null || true
  done
}
trap GLOBAL_CLEANUP EXIT

# ---------------------------------------------------------------------------
# UNIT 1: fm_afk_clear_stale_artifacts removes exactly the three stale artifacts.
# ---------------------------------------------------------------------------
unit_clear_stale() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-clear.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-escalations.since"
  : > "$st/state/.subsuper-inject-wedged"
  : > "$st/state/.wake-queue"          # durable queue must be untouched
  # Source fm-afk-start.sh inside a child bash (it sets `set -eu` and would
  # otherwise leak that into this test shell) and call the clear helper.
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    bash -c '. "$1"; fm_afk_clear_stale_artifacts "$2"' _ "$START" "$st/state"
  if [ ! -e "$st/state/.subsuper-escalations" ] \
     && [ ! -e "$st/state/.subsuper-escalations.since" ] \
     && [ ! -e "$st/state/.subsuper-inject-wedged" ]; then
    pass "clear-stale: removes escalations buffer, sidecar, and wedge marker"
  else
    fail "clear-stale: stale artifacts survived"
  fi
  if [ -e "$st/state/.wake-queue" ]; then
    pass "clear-stale: leaves the durable wake-queue intact (no pending work dropped)"
  else
    fail "clear-stale: removed the durable wake-queue"
  fi
  rm -rf "$st"
}

unit_relative_paths_are_absolute_before_daemon_launch() {
  local root home state out status linked_home
  root=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-relative-home.XXXXXX")
  mkdir -p "$root/home/state" "$root/cdpath/home/state"
  home=$(cd "$root/home" && pwd -P)
  state="$home/state"
  out=$(
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_STATE_OVERRIDE=home/state \
      bash -c '. "$1"; printf "%s\n%s\n" "$FM_HOME" "$FM_AFK_LAUNCH_STATE"' _ "$LAUNCH"
  )
  if [ "$out" = "$home"$'\n'"$state" ]; then
    pass "launcher paths: relative home and state ignore CDPATH before daemon command construction"
  else
    fail "launcher paths: relative home or state remained cwd-dependent ($out)"
  fi
  linked_home="$root/home-link"
  ln -s "$root/home" "$linked_home"
  out=$(FM_HOME="$linked_home" FM_STATE_OVERRIDE="$linked_home/state" \
    bash -c '. "$1"; printf "%s\n%s\n" "$FM_HOME" "$FM_AFK_LAUNCH_STATE"' _ "$LAUNCH")
  if [ "$out" = "$linked_home"$'\n'"$linked_home/state" ]; then
    pass "launcher paths: absolute symlink spellings are preserved"
  else
    fail "launcher paths: absolute symlink spelling changed ($out)"
  fi
  out=$(
    cd "$root" || exit 1
    FM_HOME=missing-home "$LAUNCH" help 2>&1
  )
  status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -F "FM_HOME directory cannot be resolved: missing-home" >/dev/null; then
    pass "launcher paths: unresolved relative FM_HOME fails loudly"
  else
    fail "launcher paths: unresolved relative FM_HOME did not name the bad input ($out)"
  fi
  out=$(
    cd "$root" || exit 1
    FM_HOME=home FM_STATE_OVERRIDE=missing-state "$LAUNCH" help 2>&1
  )
  status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -F "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" >/dev/null; then
    pass "launcher paths: unresolved relative FM_STATE_OVERRIDE fails loudly"
  else
    fail "launcher paths: unresolved relative FM_STATE_OVERRIDE did not name the bad input ($out)"
  fi
  rm -rf "$root"
}

# ---------------------------------------------------------------------------
# UNIT 2: a FRESH entry clears; a REFRESH (daemon already alive) preserves the
# current session's buffered escalations.
# ---------------------------------------------------------------------------
unit_fresh_vs_refresh() {
  local st sleep_pid lock out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-inject-wedged"
  # A live "daemon": a real process whose identity the lock records, so
  # daemon_lock_held_by_live_daemon returns true (a refresh).
  sleep 600 &
  sleep_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleep_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleep_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  # Pinned env: left ambient this inherits the herdr session of the machine
  # running the tests, hits fm-afk-start.sh's self-hosting refusal, and returns
  # before it reaches the refresh branch at all - at which point "the artifacts
  # are still there" is true because NOTHING ran, and the test cannot fail.
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' \
        "$START" 2>&1)
  # Prove the refresh branch actually executed before reading its side effects.
  case "$out" in
    *"daemon already running pid=$sleep_pid"*)
      pass "refresh: the already-running branch is the one that ran" ;;
    *) fail "refresh: entry never reached the already-running branch: $out" ;;
  esac
  if [ -e "$st/state/.subsuper-escalations" ] && [ -e "$st/state/.subsuper-inject-wedged" ]; then
    pass "refresh: daemon already alive - stale artifacts preserved (current session's buffer kept)"
  else
    fail "refresh: incorrectly cleared the current session's buffered escalations"
  fi
  kill "$sleep_pid" 2>/dev/null || true
  wait "$sleep_pid" 2>/dev/null || true
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT 3: exit ordering - fm_afk_launch_stop SIGTERMs the daemon WHILE .afk is
# still present (so its flush is not a no-op), and clears .afk last.
# ---------------------------------------------------------------------------
unit_stop_ordering() {
  local st lock marker daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  marker="$st/afk-at-term"
  # A fake daemon: on SIGTERM, record whether .afk was still present, then exit.
  bash -c '
    trap "if [ -f \"$1/state/.afk\" ]; then echo present > \"$2\"; else echo absent > \"$2\"; fi; exit 0" TERM
    while :; do sleep 0.2; done
  ' _ "$st" "$marker" &
  daemon_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$daemon_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  # shellcheck disable=SC2031 # The background daemon writes this shared file; no shell variable is reassigned.
  if [ "$(cat "$marker" 2>/dev/null || echo missing)" = present ]; then
    pass "stop-ordering: daemon SIGTERM'd while .afk still present (flush is not a no-op)"
  else
    fail "stop-ordering: .afk was already cleared when the daemon got SIGTERM"
  fi
  if [ ! -e "$st/state/.afk" ]; then
    pass "stop-ordering: .afk cleared last"
  else
    fail "stop-ordering: .afk not cleared"
  fi
  if [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop-ordering: daemon-terminal record removed"
  else
    fail "stop-ordering: record not removed"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_stop_rejects_reused_pid() {
  local st lock sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-pid-reuse.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  sleep 600 &
  sleeper_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleeper_pid" > "$lock/pid"
  printf 'different-process-identity' > "$lock/pid-identity"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if kill -0 "$sleeper_pid" 2>/dev/null; then
    pass "stop identity: stale lock cannot signal an unrelated live process"
  else
    fail "stop identity: stale lock signaled an unrelated live process"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_failed_start_rolls_back_state() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-failed-start.XXXXXX")
  mkdir -p "$st/state"
  printf 'pending\n' > "$st/state/.subsuper-escalations"
  printf 'wedged\n' > "$st/state/.subsuper-inject-wedged"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=unsupported "$LAUNCH" start >/dev/null 2>&1; then
    fail "failed start: unsupported backend unexpectedly succeeded"
  elif [ ! -e "$st/state/.afk" ] \
    && [ "$(cat "$st/state/.subsuper-escalations")" = pending ] \
    && [ "$(cat "$st/state/.subsuper-inject-wedged")" = wedged ]; then
    pass "failed start: away flag and delivery artifacts roll back"
  else
    fail "failed start: left false away state or discarded delivery artifacts"
  fi
  rm -rf "$st"
}

unit_concurrent_start_serialized() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found (concurrent start)"; return 0; }
  local st cap_session cap_pane first second rec count
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-concurrent.XXXXXX")
  cap_session="fm-afk-concurrent-cap-$$"
  tmux new-session -d -s "$cap_session" 2>/dev/null || { fail "concurrent start: captain session creation failed"; rm -rf "$st"; return 0; }
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $cap_session"
  cap_pane=$(tmux display-message -p -t "$cap_session" '#{pane_id}')
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET="$cap_pane" \
    FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" "$LAUNCH" start >/dev/null 2>&1 & first=$!
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET="$cap_pane" \
    FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" "$LAUNCH" start >/dev/null 2>&1 & second=$!
  wait "$first"; wait "$second"
  rec=$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)
  count=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | awk -v expected="$rec" '$0 == expected {n++} END{print n+0}')
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $rec"
  if [ -n "$rec" ] && tmux has-session -t "$rec" 2>/dev/null && [ "$count" -eq 1 ]; then
    pass "concurrent start: one serialized daemon terminal remains tracked"
  else
    fail "concurrent start: leaked or lost daemon terminal (count $count, record $rec)"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  tmux kill-session -t "$cap_session" 2>/dev/null || true
  rm -rf "$st"
}

unit_lock_initialization_grace() {
  local st marker initializer
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-init.XXXXXX")
  marker="$st/initialized"
  mkdir -p "$st/state/.afk-launch.lock"
  (
    sleep 0.15
    if [ -d "$st/state/.afk-launch.lock" ]; then
      printf '%s' "$$" > "$st/state/.afk-launch.lock/pid"
      ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$$" > "$st/state/.afk-launch.lock/pid-identity" 2>/dev/null ) || true
      # shellcheck disable=SC2031 # The subshell writes the path value; it does not reassign the variable.
      : > "$marker"
      sleep 0.15
      rm -rf "$st/state/.afk-launch.lock"
    fi
  ) &
  initializer=$!
  # shellcheck disable=SC2031 # The initializer communicates through this shared file path.
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_lock_acquire
    fm_afk_launch_lock_release
  ' _ "$LAUNCH" && [ -e "$marker" ]; then
    pass "launcher lock: incomplete publication receives initialization grace"
  else
    fail "launcher lock: contender removed a lock during initialization"
  fi
  wait "$initializer" 2>/dev/null || true
  rm -rf "$st"
}

unit_signal_exits_with_lock_cleanup() {
  local st marker child
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-signal.XXXXXX")
  marker="$st/resumed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_start() { sleep 30; }
    fm_afk_launch_main start
    : > "$2"
  ' _ "$LAUNCH" "$marker" &
  child=$!
  # Signal only once the lifecycle actually holds its lock. Killing before the
  # lock exists tests nothing, and on a loaded machine it used to race: the
  # lock could be created just after the kill and outlive the process.
  local locked=0 _
  for _ in $(seq 1 100); do
    if [ -d "$st/state/.afk-launch.lock" ]; then locked=1; break; fi
    sleep 0.05
  done
  [ "$locked" = 1 ] || fail "launcher signal: lifecycle never acquired its lock to interrupt"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  # The signal handler releases the lock as it exits; give that removal a
  # bounded settle rather than sampling the instant `wait` returns.
  for _ in $(seq 1 100); do
    [ -e "$st/state/.afk-launch.lock" ] || break
    sleep 0.05
  done
  if [ ! -e "$marker" ] && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher signal: TERM exits and releases the lifecycle lock"
  else
    fail "launcher signal: interrupted lifecycle resumed or retained its lock"
  fi
  rm -rf "$st"
}

unit_herdr_partial_create_recovery() {
  local st recorded
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-partial.XXXXXX")
  recorded="$st/recorded"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_LAUNCH_ENTRY=/bin/true \
    FM_AFK_LAUNCH_LABEL=afk-exact-label RECORDED="$recorded" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''truncated'\''
        return 1
      elif [ "$2 $3" = "workspace list" ]; then
        printf %s '\''{"result":{"workspaces":[{"workspace_id":"ws-partial","label":"afk-exact-label"}]}}'\''
      else
        printf %s '\''{"result":{"panes":[{"pane_id":"pane-exact"}]}}'\''
      fi
    }
    fm_afk_launch_record_write() { printf "%s:%s:%s" "$1" "$2" "$3" > "$RECORDED"; }
    fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cat "$recorded" 2>/dev/null || true)" = "herdr:lab:pane-exact:ws-partial" ]; then
    pass "herdr create: malformed response recovers durable exact ownership"
  else
    fail "herdr create: malformed response left terminal ownership unknown"
  fi
  rm -rf "$st"
}

unit_herdr_error_with_exact_ids_closes_exact() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-error-exact.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''{"result":{"workspace":{"workspace_id":"ws-exact"},"root_pane":{"pane_id":"pane-exact"}}}'\''
        return 1
      elif [ "$2 $3" = "pane get" ]; then
        printf %s '\''{"error":{"code":"transport_error"}}'\''
        return 2
      fi
      return 2
    }
    ! fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = "lab:pane-exact" ]; then
    pass "herdr create error: unconfirmed exact id is persisted for reconciliation"
  else
    fail "herdr create error: unconfirmed exact cleanup id was discarded"
  fi
  rm -rf "$st"
}

unit_herdr_run_failure_preserves_unconfirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-run-fail.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_backend_source() { return 0; }
    fm_backend_herdr_server_ensure() { return 0; }
    fm_backend_herdr_cli() {
      if [ "$2 $3" = "workspace create" ]; then
        printf %s '\''{"result":{"workspace":{"workspace_id":"ws-exact"},"root_pane":{"pane_id":"pane-exact"}}}'\''
        return 0
      elif [ "$2 $3" = "pane run" ]; then
        return 1
      elif [ "$2 $3" = "pane get" ]; then
        printf %s '\''{"error":{"code":"transport_error"}}'\''
        return 2
      fi
      return 2
    }
    ! fm_afk_launch_create_herdr lab:captain herdr
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = "lab:pane-exact" ]; then
    pass "herdr run failure: unconfirmed exact id remains reconcilable"
  else
    fail "herdr run failure: unconfirmed exact id was discarded"
  fi
  rm -rf "$st"
}

unit_record_failure_closes_terminal() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-fail.XXXXXX")
  closed="$st/closed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    fm_afk_launch_record_write() { return 1; }
    fm_afk_launch_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "tmux:exact-session" ]; then
    pass "record failure: newly created terminal is closed by exact id"
  else
    fail "record failure: newly created terminal leaked"
  fi
  rm -rf "$st"
}

unit_readiness_failure_rolls_back_terminal() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-not-ready.XXXXXX")
  closed="$st/closed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 1; }
    fm_afk_launch_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    fm_afk_launch_terminal_absent() { [ -e "$CLOSED" ]; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "tmux:exact-session" ] \
    && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "readiness failure: exact terminal and durable record roll back"
  else
    fail "readiness failure: terminal or record survived"
  fi
  rm -rf "$st"
}

unit_readiness_failure_preserves_unconfirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-not-ready-unconfirmed.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 1; }
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 1; }
    ! fm_afk_launch_commit_terminal tmux exact-session ""
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = exact-session ]; then
    pass "readiness failure: unconfirmed terminal retains its reconciliation id"
  else
    fail "readiness failure: unconfirmed terminal lost its reconciliation id"
  fi
  rm -rf "$st"
}

unit_tmux_absence_distinguishes_probe_failure() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-probe.XXXXXX")
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() { printf "%s" "can'\''t find session: exact-session" >&2; return 1; }
    fm_afk_launch_terminal_absent tmux exact-session
    tmux() { printf "%s" "error connecting to /tmp/tmux.sock" >&2; return 1; }
    ! fm_afk_launch_terminal_absent tmux exact-session
  ' _ "$LAUNCH"; then
    pass "tmux absence: clean missing differs from transport probe failure"
  else
    fail "tmux absence: probe failure was treated as confirmed absence"
  fi
  rm -rf "$st"
}

unit_native_lifecycle() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  # Pinned env: this case is the native path on a backend where in-pane hosting
  # is safe. Left ambient it would inherit a herdr session from the machine
  # running the tests and hit the self-hosting refusal instead.
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' \
     "$LAUNCH" start-native >/dev/null 2>&1 \
    && [ "$(cut -f1 "$st/state/.afk-daemon-terminal")" = none ] \
    && [ -e "$st/state/.afk" ] \
    && [ ! -e "$st/state/.subsuper-escalations" ]; then
    pass "native lifecycle: launcher owns state with no terminal"
  else
    fail "native lifecycle: state preparation or no-terminal record failed"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "native lifecycle: uniform stop clears state without closing a terminal"
  else
    fail "native lifecycle: uniform stop retained state"
  fi
  rm -rf "$st"
}

# The 2026-08-26 routing fix: the harness-native in-pane host is refused wherever
# the daemon would be a tenant of the pane it must deliver into. The refusal must
# land BEFORE any lifecycle state is written, so a refused entry leaves nothing
# behind and away mode is not half-entered.
unit_native_refused_on_native_busy_backend() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-refuse.XXXXXX")
  mkdir -p "$st/state"
  if out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
           HERDR_ENV=1 HERDR_PANE_ID=w1R:p1 HERDR_SESSION=default TMUX_PANE='' \
           "$LAUNCH" start-native 2>&1); then
    fail "start-native must refuse on herdr, where the daemon would block its own delivery"
  else
    pass "start-native refuses the in-pane daemon on a native-busy backend"
  fi
  case "$out" in
    *"same pane it must deliver into"*) pass "start-native refusal says what is blocked and why" ;;
    *) fail "start-native refusal did not explain the blockage: $out" ;;
  esac
  case "$out" in
    *"fm-afk-launch.sh start"*) pass "start-native refusal names the path to use instead" ;;
    *) fail "start-native refusal did not name the supported path: $out" ;;
  esac
  if [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "refused start-native wrote no lifecycle state at all"
  else
    fail "refused start-native left away-mode state behind"
  fi
  rm -rf "$st"
}

# A pane that is NOT the supervisor target is not self-hosting, so the native
# path stays available where it is safe. Without this the assertion above could
# pass by start-native having simply stopped working on herdr.
unit_native_allowed_when_daemon_is_not_the_target() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-allow.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
     HERDR_ENV=1 HERDR_PANE_ID=w9Z:p4 HERDR_SESSION=default TMUX_PANE='' \
     FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr \
     "$LAUNCH" start-native >/dev/null 2>&1 \
     && [ -e "$st/state/.afk" ]; then
    pass "start-native still proceeds when the daemon pane is not the delivery target"
  else
    fail "start-native must not refuse a daemon that lives outside its supervisor pane"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  rm -rf "$st"
}

# Round-trip through the public entries: the pane the daemon was launched to
# deliver into is recorded at entry, and a later refresh checks THAT pane rather
# than whatever discovery resolves at refresh time. A running daemon still
# injecting into a pane firstmate has left is this change's defining failure -
# away mode reporting a verified delivery path while nothing reaches the captain.
unit_refresh_verifies_the_daemons_recorded_delivery_pane() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-recorded-target.XXXXXX")
  mkdir -p "$st/state"
  if ! FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
       HERDR_ENV=1 HERDR_PANE_ID=w9Z:p4 HERDR_SESSION=default TMUX_PANE='' \
       FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr \
       "$LAUNCH" start-native >/dev/null 2>&1; then
    fail "recorded target: start-native refused a daemon that lives outside its delivery target"
    rm -rf "$st"; return 0
  fi
  # (1) Firstmate is still in the pane the daemon was launched to deliver into.
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" >/dev/null 2>&1
  if [ -e "$st/refreshed" ]; then
    pass "recorded target: a refresh into the daemon's own delivery pane proceeds"
  else
    fail "recorded target: refused a refresh into the pane the daemon actually delivers into"
  fi
  # (2) Firstmate has since moved to another pane; the daemon has not.
  rm -f "$st/refreshed"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
        FM_SUPERVISOR_TARGET='default:w4Q:p2' FM_SUPERVISOR_BACKEND=herdr bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" 2>&1)
  if [ ! -e "$st/refreshed" ]; then
    pass "recorded target: a daemon delivering into a pane firstmate has left is refused"
  else
    fail "recorded target: reported a verified delivery path into a pane firstmate has left ($out)"
  fi
  case "$out" in
    *"default:w1R:p1"*"default:w4Q:p2"*) pass "recorded target: the refusal names both the daemon's pane and the current one" ;;
    *) fail "recorded target: refusal did not name both panes: $out" ;;
  esac
  case "$out" in
    *"away mode is STILL ON"*) pass "recorded target: the refusal says away mode is still on" ;;
    *) fail "recorded target: refusal did not report a live away mode: $out" ;;
  esac
  if [ -e "$st/state/.afk" ]; then
    pass "recorded target: the refused refresh left away mode exactly as it found it"
  else
    fail "recorded target: the refused refresh cleared the away-mode flag it does not own"
  fi
  # (3) A record predating the field says nothing about where the daemon
  # delivers. Unknown must never refuse - "assume the worst" is still an
  # assertion - so the refresh proceeds and says the check could not be made.
  printf 'none\t-\tnative:default:w9Z:p4\n' > "$st/state/.afk-daemon-terminal"
  rm -f "$st/refreshed"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
        FM_SUPERVISOR_TARGET='default:w4Q:p2' FM_SUPERVISOR_BACKEND=herdr bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" 2>&1)
  if [ -e "$st/refreshed" ]; then
    pass "recorded target: a record with no delivery pane is not refused on an unobserved guess"
  else
    fail "recorded target: refused a legacy record without observing a mismatch ($out)"
  fi
  case "$out" in
    *"did not record which pane it delivers into"*)
      pass "recorded target: an unrecorded delivery pane is reported as unchecked" ;;
    *) fail "recorded target: did not report that the delivery pane could not be checked: $out" ;;
  esac
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  rm -rf "$st"
}

# start-native is what the /afk skill prescribes for a harness with its own
# in-pane background tool, so the recorded-target check has to hold there too.
# An in-pane daemon can outlive the harness that hosted it, which is exactly how
# a live daemon ends up still injecting into a pane firstmate has left.
unit_start_native_refresh_verifies_the_recorded_delivery_pane() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-refresh.XXXXXX")
  mkdir -p "$st/state"
  if ! FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
       TMUX_PANE='%7' HERDR_ENV='' HERDR_PANE_ID='' \
       FM_SUPERVISOR_TARGET='%7' FM_SUPERVISOR_BACKEND=tmux \
       "$LAUNCH" start-native >/dev/null 2>&1; then
    fail "start-native refresh: entry refused a supported in-pane launch"
    rm -rf "$st"; return 0
  fi
  # Firstmate is still in the pane that daemon was launched to deliver into.
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    FM_SUPERVISOR_TARGET='%7' FM_SUPERVISOR_BACKEND=tmux bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start_native
  ' _ "$LAUNCH" >/dev/null 2>&1
  if [ -e "$st/refreshed" ]; then
    pass "start-native refresh: a daemon still delivering into this pane refreshes"
  else
    fail "start-native refresh: refused a daemon delivering into the current pane"
  fi
  # Firstmate has since restarted in another pane; the daemon has not moved.
  rm -f "$st/refreshed"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
        FM_SUPERVISOR_TARGET='%9' FM_SUPERVISOR_BACKEND=tmux bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start_native
  ' _ "$LAUNCH" 2>&1)
  if [ ! -e "$st/refreshed" ]; then
    pass "start-native refresh: an orphaned daemon delivering into a pane firstmate left is refused"
  else
    fail "start-native refresh: refreshed onto a daemon delivering into a pane firstmate left ($out)"
  fi
  case "$out" in
    *"%7"*"%9"*) pass "start-native refusal names both the daemon's pane and the current one" ;;
    *) fail "start-native refusal did not name both panes: $out" ;;
  esac
  case "$out" in
    *"away mode is STILL ON"*) pass "start-native refusal says away mode is still on" ;;
    *) fail "start-native refusal did not report a live away mode: $out" ;;
  esac
  if [ -e "$st/state/.afk" ]; then
    pass "start-native refusal left away mode exactly as it found it"
  else
    fail "start-native refusal cleared the away-mode flag it does not own"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  rm -rf "$st"
}

# The captain-pane probe belongs to the REFRESH path, where the daemon started
# earlier and the pane may have moved since. On the fresh path the daemon's own
# startup validated the identical thing moments ago, and fm_backend_target_exists
# deliberately cannot tell a transient backend failure from genuine absence - so
# a hiccup seconds later must not tear down an entry that just came up healthy.
unit_fresh_entry_is_not_torn_down_by_a_second_pane_probe() {
  local st killed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-fresh-noreprobe.XXXXXX")
  mkdir -p "$st/state"
  killed="$st/killed"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
     FM_SUPERVISOR_TARGET='%7' FM_SUPERVISOR_BACKEND=tmux \
     FM_AFK_LAUNCH_ENTRY="$SLEEPER" KILLED="$killed" bash -c '
    . "$1"
    tmux() {
      case "$1" in
        new-session) return 0 ;;
        kill-session) printf "%s" "$3" > "$KILLED"; return 0 ;;
        has-session) return 0 ;;
      esac
      # display-message is the captain-pane probe: emulate a backend hiccup
      # AFTER the daemon has already come up and validated the same pane.
      return 1
    }
    fm_afk_launch_wait_ready() { return 0; }
    fm_afk_launch_start
  ' _ "$LAUNCH" >/dev/null 2>&1; then
    pass "fresh entry: a captain-pane probe hiccup after startup does not refuse the entry"
  else
    fail "fresh entry: a transient captain-pane probe failure tore down a healthy entry"
  fi
  if [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "fresh entry: away mode and the terminal record survive the probe hiccup"
  else
    fail "fresh entry: away-mode state was rolled back by a probe hiccup"
  fi
  if [ ! -e "$killed" ]; then
    pass "fresh entry: the daemon terminal that just came up was not torn down"
  else
    fail "fresh entry: tore down the daemon terminal it had just created"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  rm -rf "$st"
}

# ...and the refresh path still refuses a delivery target that is genuinely gone,
# so the narrowing above removes a duplicate rather than the check itself.
unit_refresh_refuses_a_dead_delivery_target() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-dead-target.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\tdaemon-session\t\t%%99\n' > "$st/state/.afk-daemon-terminal"
  : > "$st/state/.afk"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
        FM_SUPERVISOR_TARGET='%99' FM_SUPERVISOR_BACKEND=tmux bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 1; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" 2>&1)
  if [ ! -e "$st/refreshed" ]; then
    pass "refresh: a delivery target that is no longer a live pane is refused"
  else
    fail "refresh: refreshed away mode onto a delivery target that is gone ($out)"
  fi
  case "$out" in
    *"%99"*"not a live tmux pane"*) pass "refresh refusal names the dead delivery target" ;;
    *) fail "refresh refusal did not name the dead delivery target: $out" ;;
  esac
  # Control: the same refresh with a live pane proceeds.
  rm -f "$st/refreshed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    FM_SUPERVISOR_TARGET='%99' FM_SUPERVISOR_BACKEND=tmux bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" >/dev/null 2>&1
  if [ -e "$st/refreshed" ]; then
    pass "refresh: a live delivery target still refreshes the away-mode flag"
  else
    fail "refresh: refused a live delivery target"
  fi
  rm -rf "$st"
}

# A daemon ALREADY hosted in the captain's own pane is never re-created, so the
# refresh path is the only place it can be caught. Before this it was silently
# refreshed and the night stayed silent.
unit_refresh_refuses_a_pre_existing_self_hosted_daemon() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-selfhost.XXXXXX")
  mkdir -p "$st/state"
  # The record names the pane the daemon is hosted in, and it IS the captain
  # target: observed co-tenancy, not an inference from "no terminal recorded".
  printf 'none\t-\tnative:default:w1R:p1\n' > "$st/state/.afk-daemon-terminal"
  : > "$st/state/.afk"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
        FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" 2>&1)
  if [ -n "$out" ] && [ ! -e "$st/refreshed" ]; then
    pass "refresh: a pre-existing in-pane daemon is refused instead of silently refreshed"
  else
    fail "refresh: a pre-existing in-pane daemon was refreshed as if deliverable ($out)"
  fi
  case "$out" in
    *"same pane it must deliver into"*) pass "refresh refusal names what is blocked" ;;
    *) fail "refresh refusal did not explain the blockage: $out" ;;
  esac
  # This branch is only reachable from `start`, so the captain reading it has
  # just run `start`. Sending them back to `start` is a loop with no exit; the
  # pre-existing in-pane daemon must be stopped first.
  case "$out" in
    *"'bin/fm-afk-launch.sh stop'"*) pass "refresh refusal names the remedy that actually clears the block" ;;
    *) fail "refresh refusal did not tell the captain to stop the pre-existing daemon: $out" ;;
  esac
  # The refusal returns before the flag refresh WITHOUT clearing anything, so
  # away mode is still on and the daemon is still buffering. A captain who reads
  # "not entered" here walks away believing nothing is running - the mirror image
  # of the incident this change exists to make visible.
  if [ -e "$st/state/.afk" ]; then
    pass "refresh refusal leaves away mode exactly as it found it - still on"
  else
    fail "refresh refusal cleared the away-mode flag it does not own"
  fi
  case "$out" in
    *"away mode is STILL ON"*) pass "refresh refusal tells the captain away mode is still active" ;;
    *) fail "refresh refusal did not say away mode is still on: $out" ;;
  esac
  case "$out" in
    *"away mode not entered"*) fail "refresh refusal reported a live away mode as not entered: $out" ;;
    *) pass "refresh refusal does not claim away mode was never entered" ;;
  esac
  # An in-pane record that names a DIFFERENT pane delivers fine and must refresh.
  printf 'none\t-\tnative:default:w9Z:p4\n' > "$st/state/.afk-daemon-terminal"
  rm -f "$st/refreshed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" >/dev/null 2>&1
  if [ -e "$st/refreshed" ]; then
    pass "refresh: an in-pane daemon living outside the delivery target still refreshes"
  else
    fail "refresh: refused an in-pane daemon that is not a tenant of its target"
  fi
  # A LEGACY record (written before the host pane was recorded) says nothing
  # about where the daemon runs. Unknown must never become a refusal: a home
  # upgraded mid-away-session has exactly this record, and the daemon's own
  # startup check is the one that can actually observe co-tenancy.
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  rm -f "$st/refreshed"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
        FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" 2>&1)
  if [ -e "$st/refreshed" ]; then
    pass "refresh: a legacy record with no host pane is not refused on an unobserved guess"
  else
    fail "refresh: a legacy in-pane record was refused without observing co-tenancy ($out)"
  fi
  case "$out" in
    *"did not record which pane it is hosted in"*) pass "refresh says plainly that the host pane is unknown" ;;
    *) fail "refresh did not report that co-tenancy could not be observed: $out" ;;
  esac
  # The daemon that wrote this record is already running, so its own startup
  # check has already run - under a build without this rule, or with the same
  # unresolvable pane. Naming it as a backstop here would promise the captain a
  # protection that cannot fire, in the exact moment they decide how far to trust
  # away mode. The note must give them something they can act on instead.
  case "$out" in
    *"delivery path is unverified"*"'bin/fm-afk-launch.sh stop'"*)
      pass "refresh names the unverified residual and an action that resolves it" ;;
    *) fail "refresh left the captain with no action for an unverified delivery path: $out" ;;
  esac
  # Control: the same refresh with a real, separate daemon terminal proceeds, so
  # the assertions above cannot pass by refresh having stopped working.
  printf 'tmux\tdaemon-session\t\n' > "$st/state/.afk-daemon-terminal"
  rm -f "$st/refreshed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr bash -c '
    . "$1"
    daemon_lock_held_by_live_daemon() { return 0; }
    fm_backend_target_exists() { return 0; }
    fm_afk_launch_flag_write() { : > "$FM_HOME/refreshed"; }
    fm_afk_launch_start
  ' _ "$LAUNCH" >/dev/null 2>&1
  if [ -e "$st/refreshed" ]; then
    pass "refresh: a daemon in its own terminal still refreshes the away-mode flag"
  else
    fail "refresh: a deliverable daemon was refused"
  fi
  rm -rf "$st"
}

# The daemon entry itself must refuse a self-hosting launch BEFORE it writes
# state/.afk. Refusing after would leave away mode half-entered: the flag set,
# the watcher queueing durable wakes, and no supervisor able to drain them -
# worse than the incident it replaces.
unit_afk_start_refuses_self_hosting_before_writing_the_flag() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-start-selfhost.XXXXXX")
  mkdir -p "$st/state"
  # A live daemon lock, so the control case below exits at the already-running
  # branch instead of exec'ing a real daemon.
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf '%s' "$$" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$$" > "$st/state/.supervise-daemon.lock/pid-identity" ) || true

  if out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
           HERDR_ENV=1 HERDR_PANE_ID=w1R:p1 HERDR_SESSION=default TMUX_PANE='' \
           FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr \
           "$START" 2>&1); then
    fail "fm-afk-start.sh must refuse to host the daemon in the pane it delivers into"
  else
    pass "fm-afk-start.sh refuses to host the daemon in its own delivery target"
  fi
  case "$out" in
    *"pane it must deliver into"*) pass "the entry refusal says what is blocked" ;;
    *) fail "the entry refusal did not explain the blockage: $out" ;;
  esac
  case "$out" in
    *"fm-afk-launch.sh start"*) pass "the entry refusal names the path to use instead" ;;
    *) fail "the entry refusal did not name the supported path: $out" ;;
  esac
  if [ ! -e "$st/state/.afk" ]; then
    pass "the refused entry left no away-mode flag behind"
  else
    fail "the refused entry left away mode half-entered"
  fi

  # Control: the same pane hosting a daemon that delivers ELSEWHERE is allowed,
  # and does write the flag - so the refusal above is specific, not a blanket
  # failure of this entry.
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
        HERDR_ENV=1 HERDR_PANE_ID=w9Z:p4 HERDR_SESSION=default TMUX_PANE='' \
        FM_SUPERVISOR_TARGET='default:w1R:p1' FM_SUPERVISOR_BACKEND=herdr \
        "$START" 2>&1)
  if [ -e "$st/state/.afk" ]; then
    pass "a daemon entry outside its delivery target still enters away mode ($out)"
  else
    fail "a deliverable daemon entry was refused ($out)"
  fi
  rm -rf "$st"
}

unit_native_entry_preserves_prepared_state() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-entry.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  : > "$st/state/.subsuper-escalations"
  # Same pinning as unit_fresh_vs_refresh: ambient herdr env would trip the
  # self-hosting refusal before any of the prepared-state handling runs, and the
  # "nothing was mutated" assertion would hold vacuously.
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_STATE_PREPARED=1 \
        TMUX_PANE='' HERDR_ENV='' HERDR_PANE_ID='' bash -c '
    . "$1"
    FM_AFK_DAEMON=/bin/true
    fm_afk_start_main
  ' _ "$START" 2>&1)
  case "$out" in
    *"starting supervise daemon"*)
      pass "native entry: the prepared-state path ran through to daemon startup" ;;
    *) fail "native entry: never reached daemon startup: $out" ;;
  esac
  if [ -e "$st/state/.afk" ] && [ -e "$st/state/.subsuper-escalations" ]; then
    pass "native entry: launcher-prepared lifecycle state is not rewritten"
  else
    fail "native entry: launcher-prepared lifecycle state was mutated"
  fi
  rm -rf "$st"
}

unit_close_failure_preserves_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-close-fail.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\texact-session\towned\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 1; }
    ! fm_afk_launch_reconcile
  ' _ "$LAUNCH"
  if [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "teardown failure: exact terminal record is preserved"
  else
    fail "teardown failure: exact terminal record was discarded"
  fi
  rm -rf "$st"
}

unit_record_publication_atomic() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-atomic.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\told-session\towned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    mv() { return 1; }
    ! fm_afk_launch_record_write tmux new-session owned
  ' _ "$LAUNCH" \
    && [ "$(cat "$st/state/.afk-daemon-terminal")" = $'tmux\told-session\towned' ] \
    && ! find "$st/state" -name '.afk-daemon-terminal.pending.*' -print -quit | grep -q .; then
    pass "record publication: failed atomic rename preserves the complete prior record"
  else
    fail "record publication: failed write truncated or replaced the prior record"
  fi
  rm -rf "$st"
}

unit_malformed_record_fails_closed() {
  local st acted
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-malformed.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  acted="$st/acted"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" ACTED="$acted" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { : > "$ACTED"; }
    ! fm_afk_launch_reconcile
  ' _ "$LAUNCH" \
    && [ ! -e "$acted" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "record read: malformed record fails closed without acting on a partial id"
  else
    fail "record read: malformed record was acted on or discarded"
  fi
  rm -rf "$st"
}

unit_stop_malformed_record_fails_closed() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-malformed.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop: malformed terminal record preserves away state and fails closed"
  else
    fail "stop: malformed terminal record cleared protected lifecycle state"
  fi
  rm -rf "$st"
}

unit_tmux_planned_record_and_collision() {
  local st first second
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-plan.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() {
      if [ "$1" = new-session ]; then
        [ -s "$FM_AFK_LAUNCH_RECORD" ] || return 9
        printf "%s" "$4" > "$FM_HOME/created-name"
        return 1
      fi
      [ "$1" != kill-session ] || : > "$FM_HOME/killed"
      return 1
    }
    ! fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-daemon-terminal" ] && [ ! -e "$st/killed" ]; then
    pass "tmux launch: planned exact target is recorded before creation and removed on failure"
  else
    fail "tmux launch: creation began before exact target publication"
  fi
  first=$(cat "$st/created-name")
  rm -rf "$st"

  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-unique.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    tmux() {
      [ "$1" != new-session ] || { printf "%s" "$4" > "$FM_HOME/created-name"; return 1; }
      [ "$1" != kill-session ] || : > "$FM_HOME/killed"
      return 1
    }
    ! fm_afk_launch_create_tmux captain:0 tmux
  ' _ "$LAUNCH" && [ ! -e "$st/killed" ]; then
    second=$(cat "$st/created-name")
    if [ "$first" != "$second" ]; then
      pass "tmux launch: unique names eliminate collision teardown"
    else
      fail "tmux launch: consecutive launches reused a session name"
    fi
  else
    fail "tmux launch: creation failure attempted session teardown"
  fi
  rm -rf "$st"
}

unit_stop_validates_before_signal() {
  local st sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-validate.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 & sleeper_pid=$!
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf '%s' "$sleeper_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleeper_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1 || true
  if kill -0 "$sleeper_pid" 2>/dev/null && [ -e "$st/state/.afk" ]; then
    pass "stop validation: malformed record causes no daemon or state side effects"
  else
    fail "stop validation: malformed record signaled daemon or cleared state"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_lock_requires_complete_metadata() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-metadata.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_pid_identity() { return 1; }
    ! fm_afk_launch_lock_acquire
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher lock: incomplete metadata fails acquisition and releases lock"
  else
    fail "launcher lock: incomplete metadata was accepted"
  fi
  rm -rf "$st"
}

unit_stop_surfaces_afk_removal_failure() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-remove.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    rm() { local last=${!#}; [ "$last" != "$FM_AFK_LAUNCH_STATE/.afk" ]; }
    ! fm_afk_launch_stop
  ' _ "$LAUNCH"; then
    pass "stop state: away-flag removal failure is surfaced"
  else
    fail "stop state: away-flag removal failure reported success"
  fi
  rm -rf "$st"
}

unit_stop_confirms_daemon_exit() {
  local st daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-live.XXXXXX")
  mkdir -p "$st/state/.supervise-daemon.lock"
  : > "$st/state/.afk"
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  bash -c 'trap "" TERM; while :; do sleep 1; done' &
  daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    seq() { printf "1\n"; }
    sleep() { :; }
    kill() {
      command kill "$@"
      if [ "$1" = -TERM ]; then
        rm -rf "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock"
      fi
    }
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && kill -0 "$daemon_pid" 2>/dev/null \
    && [ ! -e "$st/state/.supervise-daemon.lock" ] \
    && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop liveness: captured live daemon preserves lifecycle state after lock release"
  else
    fail "stop liveness: lock release was mistaken for captured daemon exit"
  fi
  kill -KILL "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_refresh_validates_record() {
  local st daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-record.XXXXXX")
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf 'tmux\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 & daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=tmux bash -c '
      . "$1"
      ! fm_afk_launch_start && ! fm_afk_launch_start_native
    ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ]; then
    pass "refresh record: malformed terminal identity fails closed"
  else
    fail "refresh record: malformed terminal identity was accepted"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_clear_failure_aborts_entry() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-clear-fail.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_reconcile() { return 0; }
    fm_afk_clear_stale_artifacts() { return 1; }
    ! fm_afk_launch_start_native
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ] && [ -e "$st/state/.subsuper-escalations" ]; then
    pass "clear failure: native entry aborts and restores prior state"
  else
    fail "clear failure: native entry proceeded or lost prior state"
  fi
  rm -rf "$st"
}

unit_confirmed_absence_succeeds() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-confirmed-absent.XXXXXX")
  mkdir -p "$st/state"
  printf 'tmux\texact-session\towned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 0; }
    fm_afk_launch_reconcile
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "confirmed absence: cleanup succeeds and removes the stale record"
  else
    fail "confirmed absence: close error incorrectly failed reconciliation"
  fi
  rm -rf "$st"
}

unit_incomplete_restore_retains_backup() {
  local st backup
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-restore-fail.XXXXXX")
  mkdir -p "$st/state"
  backup=$(mktemp -d "$st/state/.afk-launch-backup.XXXXXX")
  printf 'prior\n' > "$backup/.afk"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    cp() { return 1; }
    ! fm_afk_launch_restore_backup "$2" 1
  ' _ "$LAUNCH" "$backup" && [ -d "$backup" ] && [ -e "$backup/.afk" ]; then
    pass "rollback restore: incomplete restoration retains its recovery backup"
  else
    fail "rollback restore: incomplete restoration discarded its backup"
  fi
  rm -rf "$st"
}

unit_flag_write_failure_aborts() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-flag-fail.XXXXXX")
  mkdir -p "$st/state"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_flag_write() { return 1; }
    ! fm_afk_launch_start_native
  ' _ "$LAUNCH"
  if [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "flag failure: lifecycle aborts without active state"
  else
    fail "flag failure: lifecycle reported active state"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# E2E herdr: topology invariant.
# ---------------------------------------------------------------------------
e2e_herdr() {
  command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found (herdr e2e)"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (herdr e2e)"; return 0; }
  # shellcheck source=tests/herdr-test-safety.sh
  . "$ROOT/tests/herdr-test-safety.sh"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  local SESSION home_tmp cap_ws cap_tab cap_pane target
  local before during after ws_before ws_during ws_after out dtgt dtab
  SESSION="fm-lab-afk-launch-e2e-$$"
  export HERDR_SESSION="$SESSION"
  home_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e-home.XXXXXX")
  E2E_HERDR_CLEANUP() {
    # shellcheck disable=SC2031 # Cleanup reads the caller's resolved target; it does not reassign it.
    FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
      FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr "$LAUNCH" stop >/dev/null 2>&1 || true
    herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
    rm -rf "$home_tmp" 2>/dev/null || true
  }
  fm_herdr_lab_prepare "$SESSION" || { fail "herdr e2e: could not prepare isolated lab session"; return 0; }
  fm_backend_source herdr || { E2E_HERDR_CLEANUP; fail "herdr e2e: fm_backend_source herdr failed"; return 0; }
  fm_backend_herdr_server_ensure "$SESSION" || { E2E_HERDR_CLEANUP; fail "herdr e2e: lab server did not start"; return 0; }

  out=$(fm_backend_herdr_cli "$SESSION" workspace create --cwd "$ROOT" --label captain --no-focus 2>/dev/null)
  cap_ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  cap_tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  cap_pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  if [ -z "$cap_ws" ] || [ -z "$cap_pane" ]; then E2E_HERDR_CLEANUP; fail "herdr e2e: could not create captain workspace"; return 0; fi
  target="$SESSION:$cap_pane"
  before=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_before=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>&1

  during=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_during=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')
  dtgt=$(cut -f2 "$home_tmp/state/.afk-daemon-terminal" 2>/dev/null || true)
  dtab=$(fm_backend_herdr_cli "$SESSION" pane get "${dtgt#*:}" 2>/dev/null | jq -r '.result.pane.tab_id // empty')

  if [ "$before" = "$during" ]; then pass "herdr e2e: captain tab pane count unchanged after start (no split)"; else fail "herdr e2e: captain tab pane count changed ($before -> $during)"; fi
  if [ "$ws_during" -gt "$ws_before" ]; then pass "herdr e2e: daemon launched in a separate non-visible workspace"; else fail "herdr e2e: no separate daemon workspace created"; fi
  if [ -n "$dtab" ] && [ "$dtab" != "$cap_tab" ]; then pass "herdr e2e: daemon pane is NOT in the captain's tab"; else fail "herdr e2e: daemon pane shares the captain tab ($dtab)"; fi
  case "$dtgt" in "$SESSION":*) pass "herdr e2e: daemon terminal scoped to the lab session" ;; *) fail "herdr e2e: daemon terminal not in the lab session ($dtgt)" ;; esac

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$target" FM_SUPERVISOR_BACKEND=herdr "$LAUNCH" stop >/dev/null 2>&1

  after=$(fm_backend_herdr_cli "$SESSION" pane list --workspace "$cap_ws" 2>/dev/null | jq --arg t "$cap_tab" '[.result.panes[]?|select(.tab_id==$t)]|length')
  ws_after=$(fm_backend_herdr_cli "$SESSION" workspace list 2>/dev/null | jq '[.result.workspaces[]?]|length')
  if [ "$after" = "$before" ]; then pass "herdr e2e: captain tab pane count restored after stop"; else fail "herdr e2e: captain tab pane count not restored ($before -> $after)"; fi
  if [ "$ws_after" = "$ws_before" ]; then pass "herdr e2e: daemon workspace removed by exact id on stop"; else fail "herdr e2e: daemon workspace leaked ($ws_before -> $ws_after)"; fi
  if [ ! -e "$home_tmp/state/.afk-daemon-terminal" ] && [ ! -e "$home_tmp/state/.afk" ]; then pass "herdr e2e: record + .afk cleared on stop"; else fail "herdr e2e: record or .afk not cleared"; fi

  E2E_HERDR_CLEANUP
}

# ---------------------------------------------------------------------------
# E2E tmux: topology invariant (captain window untouched; daemon in a separate
# detached session).
# ---------------------------------------------------------------------------
e2e_tmux() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found (tmux e2e)"; return 0; }
  local cap_session home_tmp cap_pane before during after rec
  cap_session="fm-afk-launch-cap-$$"
  home_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-tmux-home.XXXXXX")
  tmux new-session -d -s "$cap_session" 2>/dev/null || { fail "tmux e2e: could not create captain session"; rm -rf "$home_tmp"; return 0; }
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $cap_session"
  cap_pane=$(tmux display-message -p -t "$cap_session" '#{pane_id}')
  before=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$cap_pane" FM_SUPERVISOR_BACKEND=tmux FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>&1

  during=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')
  rec=$(cut -f2 "$home_tmp/state/.afk-daemon-terminal" 2>/dev/null || true)
  TRACK_TMUX_SESSIONS="$TRACK_TMUX_SESSIONS $rec"
  if [ "$before" = "$during" ]; then pass "tmux e2e: captain window pane count unchanged after start (no split-window)"; else fail "tmux e2e: captain window pane count changed ($before -> $during)"; fi
  if [ -n "$rec" ] && tmux has-session -t "$rec" 2>/dev/null && [ "$rec" != "$cap_session" ]; then pass "tmux e2e: daemon launched in a separate detached session"; else fail "tmux e2e: no separate daemon session ($rec)"; fi

  FM_HOME="$home_tmp" FM_STATE_OVERRIDE="$home_tmp/state" \
    FM_SUPERVISOR_TARGET="$cap_pane" FM_SUPERVISOR_BACKEND=tmux "$LAUNCH" stop >/dev/null 2>&1

  after=$(tmux list-panes -t "$cap_session" | wc -l | tr -d ' ')
  if [ "$after" = "$before" ]; then pass "tmux e2e: captain window pane count unchanged after stop"; else fail "tmux e2e: captain window changed ($before -> $after)"; fi
  if [ -n "$rec" ] && ! tmux has-session -t "$rec" 2>/dev/null; then pass "tmux e2e: daemon session killed by exact id on stop"; else fail "tmux e2e: daemon session leaked ($rec)"; fi
  if [ ! -e "$home_tmp/state/.afk-daemon-terminal" ] && [ ! -e "$home_tmp/state/.afk" ]; then pass "tmux e2e: record + .afk cleared on stop"; else fail "tmux e2e: record or .afk not cleared"; fi

  tmux kill-session -t "$cap_session" 2>/dev/null || true
  rm -rf "$home_tmp" 2>/dev/null || true
}

unit_clear_stale
unit_relative_paths_are_absolute_before_daemon_launch
unit_fresh_vs_refresh
unit_stop_ordering
unit_stop_rejects_reused_pid
unit_failed_start_rolls_back_state
unit_concurrent_start_serialized
unit_lock_initialization_grace
unit_signal_exits_with_lock_cleanup
unit_herdr_partial_create_recovery
unit_herdr_error_with_exact_ids_closes_exact
unit_herdr_run_failure_preserves_unconfirmed_record
unit_record_failure_closes_terminal
unit_readiness_failure_rolls_back_terminal
unit_readiness_failure_preserves_unconfirmed_record
unit_tmux_absence_distinguishes_probe_failure
unit_native_lifecycle
unit_native_refused_on_native_busy_backend
unit_native_allowed_when_daemon_is_not_the_target
unit_refresh_verifies_the_daemons_recorded_delivery_pane
unit_start_native_refresh_verifies_the_recorded_delivery_pane
unit_fresh_entry_is_not_torn_down_by_a_second_pane_probe
unit_refresh_refuses_a_dead_delivery_target
unit_refresh_refuses_a_pre_existing_self_hosted_daemon
unit_afk_start_refuses_self_hosting_before_writing_the_flag
unit_native_entry_preserves_prepared_state
unit_close_failure_preserves_record
unit_record_publication_atomic
unit_malformed_record_fails_closed
unit_stop_malformed_record_fails_closed
unit_tmux_planned_record_and_collision
unit_stop_validates_before_signal
unit_lock_requires_complete_metadata
unit_stop_surfaces_afk_removal_failure
unit_stop_confirms_daemon_exit
unit_refresh_validates_record
unit_clear_failure_aborts_entry
unit_confirmed_absence_succeeds
unit_incomplete_restore_retains_backup
unit_flag_write_failure_aborts
e2e_herdr
e2e_tmux

[ "$FAILED" -eq 0 ] || exit 1
