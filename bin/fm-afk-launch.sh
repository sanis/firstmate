#!/usr/bin/env bash
# fm-afk-launch.sh - the single owner of the away-mode daemon TERMINAL lifecycle:
# launch it in a NON-VISIBLE tracked terminal per backend, record its exact id,
# tear it down by that exact id, and reconcile a leaked one after a crash.
#
# Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/fm-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever
# terminal it is already in. A harness with NO native background mechanism (pi)
# has to manufacture a terminal, and doing that by SPLITTING the captain's active
# pane visibly shrinks it - the regression this script fixes. Instead this creates
# a non-visible tracked terminal (a herdr tab/workspace with --no-focus, or a
# detached tmux session) that never touches the captain's active tab, and NEVER
# uses shell `&` (which herdr/codex can reap).
#
# The harness-native in-pane host (claude, grok) is NOT available on every
# backend. Where the backend's native agent state observes the pane's own
# background jobs - herdr, see FM_SUPERVISOR_NATIVE_BUSY_BACKENDS in
# bin/fm-supervisor-target-lib.sh - a daemon hosted in the captain's pane keeps
# that pane reading as busy for its whole lifetime and can never deliver into it
# (2026-08-26: 2169 consecutive deferrals over 8.7h). start-native refuses there
# and the terminal-backed path above is used instead, for every harness.
#
# Correct supervisor targeting: the daemon finds the captain pane to inject into
# from its OWN inherited env (discover_supervisor_target). Running it in a
# separate terminal would make it discover its OWN pane, so this captures the
# captain pane FIRST (from the pane this script runs in) and passes it in as
# FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND explicitly.
#
# Usage:
#   fm-afk-launch.sh start     Capture the captain pane, then (unless the daemon
#                              is already running) launch the daemon in a fresh
#                              non-visible terminal for the detected backend and
#                              record it. Idempotent: an already-running daemon
#                              just refreshes state/.afk; a recorded-but-dead
#                              terminal is reconciled (closed by id) first.
#                              Before reporting success it verifies once that the
#                              delivery path is not already permanently blocked
#                              (fm_afk_launch_verify_delivery_path) and rolls the
#                              whole entry back when it is.
#   fm-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#                              Refuses on a backend whose native agent state
#                              observes the pane's own background jobs, because
#                              the daemon could never deliver into its own host
#                              pane there; use `start` instead.
#   fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
#                              cleanup flushes WHILE state/.afk is still present,
#                              wait for it, close the recorded terminal by exact
#                              id, then clear state/.afk last.
#   fm-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#
# Supported backends: herdr, tmux. Others (zellij, orca, cmux) have no verified
# non-visible-launch primitive here yet and refuse loudly.
#
# Test seam: FM_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal (default bin/fm-afk-start.sh), so a topology test can run a harmless
# placeholder instead of a real daemon. FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND
# override the captured captain pane/backend (an isolated lab pane in tests).
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_LAUNCH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in
  /*) ;;
  *)
    FM_AFK_LAUNCH_HOME_INPUT=$FM_HOME
    FM_HOME=$(CDPATH='' cd -- "$FM_AFK_LAUNCH_HOME_INPUT" 2>/dev/null && pwd -P) || {
      echo "error: FM_HOME directory cannot be resolved: $FM_AFK_LAUNCH_HOME_INPUT" >&2
      exit 1
    }
    ;;
esac
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  case "$FM_STATE_OVERRIDE" in
    /*) ;;
    *)
      FM_AFK_LAUNCH_STATE_INPUT=$FM_STATE_OVERRIDE
      FM_STATE_OVERRIDE=$(CDPATH='' cd -- "$FM_AFK_LAUNCH_STATE_INPUT" 2>/dev/null && pwd -P) || {
        echo "error: FM_STATE_OVERRIDE directory cannot be resolved: $FM_AFK_LAUNCH_STATE_INPUT" >&2
        exit 1
      }
      ;;
  esac
fi
FM_AFK_LAUNCH_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LAUNCH_RECORD="$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal"
FM_AFK_LAUNCH_LOCK="$FM_AFK_LAUNCH_STATE/.afk-launch.lock"
FM_AFK_LAUNCH_WS_LABEL="firstmate-afk-daemon"

# shellcheck source=bin/fm-backend.sh
. "$FM_AFK_LAUNCH_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-supervisor-target-lib.sh"
# fm-afk-start.sh provides the daemon-lock liveness helpers and
# fm_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-start.sh"
set +e

fm_afk_launch_log() { printf 'fm-afk-launch: %s\n' "$*" >&2; }

fm_afk_launch_lock_owned() {
  local pid expected actual
  [ -d "$FM_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null) || return 1
  expected=$(cat "$FM_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null) || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

fm_afk_launch_lock_acquire() {
  local attempt=0 incomplete=0 identity
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  while [ "$attempt" -lt 200 ]; do
    attempt=$((attempt + 1))
    if mkdir "$FM_AFK_LAUNCH_LOCK" 2>/dev/null; then
      if ! printf '%s' "$$" > "$FM_AFK_LAUNCH_LOCK/pid"; then
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      fi
      identity=$(fm_pid_identity "$$" 2>/dev/null) || {
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      }
      if [ -z "$identity" ] || ! printf '%s' "$identity" > "$FM_AFK_LAUNCH_LOCK/pid-identity"; then
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      fi
      return 0
    fi
    if [ ! -s "$FM_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$FM_AFK_LAUNCH_LOCK/pid-identity" ]; then
      incomplete=$((incomplete + 1))
      if [ "$incomplete" -lt 20 ]; then
        sleep 0.05
        continue
      fi
    else
      incomplete=0
    fi
    if ! fm_afk_launch_lock_owned; then
      rm -rf "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || return 1
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  fm_afk_launch_log "timed out waiting for launcher lock"
  return 1
}

fm_afk_launch_lock_release() {
  local pid
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "$$" ] || return 0
  rm -rf "$FM_AFK_LAUNCH_LOCK"
}

fm_afk_launch_usage() {
  sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${FM_AFK_LAUNCH_ENTRY:-$FM_ROOT/bin/fm-afk-start.sh}"
}

fm_afk_launch_record_write() {  # <backend> <target> <extra>
  local pending
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_flag_write() {
  fm_afk_flag_write "$FM_AFK_LAUNCH_STATE"
}

# Read the recorded terminal into FM_AFK_REC_BACKEND/FM_AFK_REC_TARGET, plus, for
# an in-pane (`none`) record, the daemon's own host pane into FM_AFK_REC_HOST.
#
# The third field is a herdr workspace id for a herdr record - not needed to close
# by id, so it is discarded there. For a `none` record it carries where the daemon
# is hosted, in one of two accepted shapes:
#   native              the LEGACY shape, written before this field carried a
#                       pane. The host pane is UNKNOWN, and FM_AFK_REC_HOST is
#                       empty. No caller may read that as proof of anything - a
#                       home upgraded mid-away-session has exactly this record.
#   native:<pane>       the daemon's own pane target, as discover_own_pane_target
#                       resolved it at start-native time.
# Returns 1 when no record exists, 2 when it is malformed.
fm_afk_launch_record_read() {
  local extra record
  FM_AFK_REC_BACKEND=""; FM_AFK_REC_TARGET=""; FM_AFK_REC_HOST=""; extra=""
  [ -f "$FM_AFK_LAUNCH_RECORD" ] || return 1
  record=$(cat "$FM_AFK_LAUNCH_RECORD" 2>/dev/null) || record=""
  IFS=$'\t' read -r FM_AFK_REC_BACKEND FM_AFK_REC_TARGET extra \
    < "$FM_AFK_LAUNCH_RECORD" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$FM_AFK_REC_BACKEND" ] || [ -z "$FM_AFK_REC_TARGET" ]; then
    fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_AFK_REC_BACKEND" in
    herdr) [ -n "$extra" ] ;;
    tmux) : ;;
    none)
      [ "$FM_AFK_REC_TARGET" = - ] \
        && case "$extra" in
             native) FM_AFK_REC_HOST="" ;;
             native:?*) FM_AFK_REC_HOST=${extra#native:} ;;
             *) false ;;
           esac
      ;;
    *) return 2 ;;
  esac || { fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

fm_afk_launch_record_validate_if_present() {
  local result
  fm_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

# Close a recorded terminal by EXACT id (never a broad sweep). The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
fm_afk_launch_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2
  case "$backend" in
    herdr)
      fm_backend_source herdr || return 1
      local session=${target%%:*} pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "$target" 2>/dev/null
      ;;
    none)
      return 0
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_afk_launch_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 session pane out result code
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1)
      result=$?
      [ "$result" -ne 0 ] || return 1
      code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || return 1
      [ "$code" = pane_not_found ]
      ;;
    tmux)
      out=$(tmux has-session -t "$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eq "can't find session"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_close_recorded() {
  local close_result=0
  fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" || close_result=$?
  if fm_afk_launch_terminal_absent "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET"; then
    rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

fm_afk_launch_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    tmux)
      tmux has-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 attempt=0
  if [ -n "${FM_AFK_LAUNCH_ENTRY:-}" ]; then
    fm_afk_launch_terminal_alive "$backend" "$target"
    return
  fi
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    daemon_lock_held_by_live_daemon && return 0
    fm_afk_launch_terminal_alive "$backend" "$target" || return 1
    sleep 0.05
  done
  return 1
}

fm_afk_launch_commit_terminal() {  # <backend> <target> <extra> [already-recorded]
  local backend=$1 target=$2 extra=$3 already_recorded=${4:-0}
  if [ "$already_recorded" -ne 1 ] && ! fm_afk_launch_record_write "$backend" "$target" "$extra"; then
    fm_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    fm_afk_launch_close_terminal "$backend" "$target"
    return 1
  fi
  if ! fm_afk_launch_wait_ready "$backend" "$target"; then
    fm_afk_launch_log "daemon did not become ready; closing $backend:$target"
    FM_AFK_REC_BACKEND=$backend
    FM_AFK_REC_TARGET=$target
    fm_afk_launch_close_recorded
    return 1
  fi
}

fm_afk_launch_herdr_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane attempt=0
  while [ "$attempt" -lt 20 ]; do
    attempt=$((attempt + 1))
    workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { sleep 0.05; continue; }
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || return 1
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
    [ -n "$wsid" ] || return 1
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || { sleep 0.05; continue; }
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]?] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || return 1
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null) || return 1
    [ -n "$pane" ] || return 1
    printf '%s\t%s' "$wsid" "$pane"
    return 0
  done
  return 1
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {
  local read_result
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_log "reconciling leaked daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET}"
    fm_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

fm_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$FM_AFK_LAUNCH_STATE/.afk" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-inject-wedged" || result=1
  if [ "$had_afk" -eq 1 ]; then
    cp "$backup/.afk" "$FM_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$backup/$artifact" ]; then
      cp -p "$backup/$artifact" "$FM_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    fm_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Launch the daemon in a non-visible herdr terminal in the CAPTAIN's session
# (so the daemon can inject into the captain pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the captain's active tab. Prints the record line on success.
fm_afk_launch_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid pane entry cmd label recovered create_result
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    fm_afk_launch_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  label=${FM_AFK_LAUNCH_LABEL:-"$FM_AFK_LAUNCH_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    fm_afk_launch_log "herdr create failed after returning exact ids; closing $session:$pane"
    if fm_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
      FM_AFK_REC_BACKEND=herdr
      FM_AFK_REC_TARGET="$session:$pane"
      fm_afk_launch_close_recorded || true
    else
      fm_afk_launch_log "failed to persist exact id for failed herdr create"
    fi
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$session" "$label") || {
      fm_afk_launch_log "herdr create did not yield a recoverable exact workspace/pane id"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
  fi
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
    fm_afk_launch_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    fm_afk_launch_close_terminal herdr "$session:$pane"
    return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    FM_AFK_REC_BACKEND=herdr
    FM_AFK_REC_TARGET="$session:$pane"
    fm_afk_launch_close_recorded || true
    return 1
  fi
  fm_afk_launch_commit_terminal herdr "$session:$pane" "$wsid" 1 || return 1
  fm_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Launch the daemon in a detached tmux session (never a split-window in the
# captain's window). tmux pane ids are server-global, so the daemon reaches the
# captain pane by its %id from this separate session.
fm_afk_launch_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session entry cmd hash nonce
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="fm-afk-daemon-$hash-$nonce"
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write tmux "$session" ""; then
    fm_afk_launch_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_afk_launch_log "failed to create detached tmux daemon session '$session'"
    if ! rm -f "$FM_AFK_LAUNCH_RECORD"; then
      fm_afk_launch_log "failed to remove planned tmux daemon record after creation failure"
    fi
    return 1
  fi
  fm_afk_launch_commit_terminal tmux "$session" "" 1 || return 1
  fm_afk_launch_log "daemon launched in detached tmux session '$session', supervising $captain_target"
}

# Verify, once, that the delivery path away mode depends on is not ALREADY
# permanently blocked, and refuse the whole entry when it is. A refusal at the
# moment the captain steps away, naming what is blocked, beats a night of
# silence with the escalations sitting in a buffer (2026-08-26).
#
# Every condition here is timing-independent on purpose. Busy-ness deliberately
# is NOT one of them: firstmate is mid-turn running this very launcher, so the
# captain pane is legitimately busy at entry and a busy sample would refuse every
# healthy launch. Do not "improve" this into a busy probe.
fm_afk_launch_verify_delivery_path() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2
  if ! fm_backend_list_contains "$FM_SUPERVISOR_SUPPORTED_BACKENDS" "$captain_backend"; then
    fm_afk_launch_log "away mode not entered: the away daemon cannot supervise a '$captain_backend' pane (supported: $FM_SUPERVISOR_SUPPORTED_BACKENDS)"
    return 1
  fi
  if ! fm_backend_target_exists "$captain_backend" "$captain_target"; then
    fm_afk_launch_log "away mode not entered: escalations would be delivered to '$captain_target', which is not a live $captain_backend pane"
    return 1
  fi
  # The daemon must be running SOMEWHERE OTHER than the pane it delivers into.
  # A `none` record means an in-pane host, and FM_AFK_REC_HOST names WHICH pane
  # that is. Refuse only when that pane is known AND is the captain target: an
  # in-pane daemon living in some other pane delivers perfectly well, and
  # start-native supports exactly that.
  #
  # A record that does not name its host pane (the legacy shape) is UNKNOWN, and
  # unknown is never a refusal. "Assume the worst" would be one more guard
  # asserting what it never observed - the defect this whole change exists to
  # remove - and it would refuse a home that merely upgraded mid-away-session.
  # The daemon's own startup check compares real panes in its own process and
  # can therefore actually observe co-tenancy; that is the check that decides.
  #
  # Reached from the already-running refresh path, where a pre-existing in-pane
  # daemon would otherwise be silently refreshed; a fresh create always records a
  # real terminal before it gets here.
  if fm_afk_launch_record_read && [ "$FM_AFK_REC_BACKEND" = none ] \
     && fm_supervisor_backend_has_native_busy "$captain_backend"; then
    if [ -z "$FM_AFK_REC_HOST" ]; then
      fm_afk_launch_log "the running in-pane daemon's record does not name the pane it is hosted in, so co-tenancy with '$captain_target' cannot be observed here; not refusing on an unverified guess - the daemon's own startup check compares real panes and refuses there if it is a tenant of its own target"
    elif [ "$FM_AFK_REC_HOST" = "$captain_target" ]; then
      # This branch is reachable ONLY from start's already-running refresh path,
      # so the captain reading it has just run start; telling them to run start
      # again would take the same branch and refuse again, forever. Name the
      # state they are actually in: the in-pane daemon has to go first.
      fm_afk_launch_log "away mode not entered: the daemon already running is hosted in '$FM_AFK_REC_HOST', the same pane it must deliver into, and on $captain_backend its own background job keeps that pane reading as busy - so no escalation could ever be delivered. Stop it first with 'bin/fm-afk-launch.sh stop', then re-enter with 'bin/fm-afk-launch.sh start', which places the daemon in its own non-visible terminal and passes this pane in as the delivery target."
      return 1
    fi
  fi
  # Daemon liveness is NOT rechecked here: fm_afk_launch_commit_terminal already
  # owns it through fm_afk_launch_wait_ready, and a second copy would drift.
  return 0
}

# Undo a launch whose delivery path failed verification: stop the daemon if it
# came up and close the terminal we created by its exact recorded id. The caller
# then restores the pre-entry state backup, so a refused entry leaves nothing
# behind.
#
# The record is dropped by fm_afk_launch_close_recorded, and ONLY once that
# confirms the terminal is gone - the same invariant fm_afk_launch_stop keeps.
# Deleting it on an unconfirmed close would erase the one durable copy of the
# exact daemon terminal id and strand a live pane nobody can address.
fm_afk_launch_teardown_after_failed_verify() {
  local pid read_result
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || pid=""
    if [ -n "$pid" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 40); do
        fm_pid_alive "$pid" || break
        sleep 0.25
      done
    fi
  fi
  fm_afk_launch_record_read
  read_result=$?
  # 1: no record to undo. 2: malformed - fail closed exactly as reconcile/stop
  # do, rather than acting on or discarding a partial id.
  [ "$read_result" -eq 0 ] || return 0
  if [ "$FM_AFK_REC_BACKEND" = none ]; then
    rm -f "$FM_AFK_LAUNCH_RECORD" 2>/dev/null || true
    return 0
  fi
  fm_afk_launch_close_recorded || \
    fm_afk_launch_log "could not confirm teardown of the daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET} after a refused entry; its exact id stays recorded in $FM_AFK_LAUNCH_RECORD - close it by that id or run 'bin/fm-afk-launch.sh reconcile'"
}

fm_afk_launch_start() {
  local captain_target captain_backend backup artifact had_afk=0 result
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 1
  fi
  # Capture the captain pane FIRST, before creating anything.
  captain_target=$(discover_supervisor_target) || {
    fm_afk_launch_log "could not resolve the captain supervisor pane (set FM_SUPERVISOR_TARGET)"; return 1; }
  captain_backend=$(discover_supervisor_backend) || {
    fm_afk_launch_log "could not resolve the captain supervisor backend (set FM_SUPERVISOR_BACKEND)"; return 1; }

  mkdir -p "$FM_AFK_LAUNCH_STATE"

  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    # An already-running daemon is never re-created, so this refresh is the ONLY
    # place a PRE-EXISTING undeliverable daemon can be caught - including one
    # hosted in the captain's own pane from before this routing rule existed.
    # Verified BEFORE the flag refresh, so a refusal leaves lifecycle state
    # exactly as it found it and nothing has to be rolled back.
    fm_afk_launch_verify_delivery_path "$captain_target" "$captain_backend" || return 1
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! fm_afk_launch_reconcile; then
    result=1
  else
    if fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      result=0
    else
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$captain_backend" in
      herdr) fm_afk_launch_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
      tmux)  fm_afk_launch_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
      *)
        fm_afk_launch_log "no non-visible daemon-launch primitive for backend '$captain_backend' yet (supported: herdr, tmux)"
        result=1
        ;;
    esac
  fi
  if [ "$result" -eq 0 ] && ! fm_afk_launch_verify_delivery_path "$captain_target" "$captain_backend"; then
    fm_afk_launch_teardown_after_failed_verify
    result=1
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native() {
  local backup artifact had_afk=0 result=0 captain_target captain_backend own_host
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 1
  fi
  # Refuse the harness-native in-pane host wherever the daemon would become a
  # tenant of the pane it must deliver into. Checked before any lifecycle state
  # is written, so a refused entry never has to be rolled back; the return gate
  # above stays the outermost guard.
  #
  # This is the code half of a rule the /afk skill states in prose. Both must
  # agree, and a documented procedure that walks the captain into an
  # undeliverable channel is exactly what happened on 2026-08-26, so the
  # launcher enforces it rather than trusting the instruction to be followed.
  # Unlike `start`, this path creates no terminal, so it does not need discovery
  # to succeed - the daemon repeats it in its own process. Take whatever the
  # discovery prints (it prints its fallback even when it reports one) and refuse
  # only on a combination that is definitely self-blocking; an unresolved
  # fallback is tmux, which is not.
  captain_target=$(discover_supervisor_target) || true
  captain_backend=$(discover_supervisor_backend) || true
  # The pane this launcher runs in IS the pane the harness will host the daemon
  # in, so record it: a later refresh can then compare real panes instead of
  # inferring co-tenancy from the absence of a terminal. Empty when this process
  # is in no recognized pane, which is recorded as unknown rather than guessed.
  own_host=$(discover_own_pane_target) || own_host=""
  if supervisor_pane_is_self_hosted "$captain_backend" "$captain_target"; then
    fm_afk_launch_log "refusing the in-pane away daemon on $captain_backend: it would run inside '$captain_target', the same pane it must deliver into, and its own background job keeps that pane reading as busy for its whole lifetime - no escalation could ever be delivered. Use 'bin/fm-afk-launch.sh start', which runs the daemon in its own non-visible terminal and passes this pane in as the delivery target."
    return 1
  fi
  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  fm_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    elif ! fm_afk_launch_flag_write; then
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if [ -n "$own_host" ]; then
      fm_afk_launch_record_write none - "native:$own_host" || result=1
    else
      fm_afk_launch_record_write none - native || result=1
    fi
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_stop() {
  local pid pid_identity current_identity result=0 read_result
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate).
  pid=""
  pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  fi
  if [ -n "$pid" ]; then
    if ! kill -TERM "$pid" 2>/dev/null; then
      fm_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
      fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    }
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  # (2) Close the daemon's own terminal by exact id.
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_close_recorded || result=1
  fi
  # (3) Clear the away-mode flag LAST.
  if ! rm -f "$FM_AFK_LAUNCH_STATE/.afk"; then
    fm_afk_launch_log "failed to clear away-mode flag"
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_log "away mode stopped; daemon terminal torn down and .afk cleared"
  else
    fm_afk_launch_log "away mode stopped; terminal teardown remains recorded for retry"
  fi
  return "$result"
}

fm_afk_launch_main() {
  local result
  # Traps first, lock second. Acquiring before the handlers exist leaves a
  # window where a signal terminates this process by default action and leaks
  # the lock directory, which then blocks the next away-mode launch until the
  # stale-owner reclaim path clears it. fm_afk_launch_lock_release only removes
  # a lock this process owns, so arming it before acquisition is safe.
  trap fm_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  fm_afk_launch_lock_acquire || return 1
  case "${1:-start}" in
    start) fm_afk_launch_start ;;
    start-native) fm_afk_launch_start_native ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_lock_release || result=1
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
