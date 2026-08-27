#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}

# Supervisor backends whose NATIVE agent-state source observes the supervisor
# pane's own in-pane background jobs. Declared once here and consumed by both
# bin/fm-afk-launch.sh (which refuses to prepare an in-pane daemon on one) and
# bin/fm-supervise-daemon.sh (which refuses to run blind as a tenant of its own
# target). Herdr is the only supported supervisor backend with such a source:
# bin/fm-backend.sh's fm_backend_busy_state returns a real verdict for herdr and
# 'unknown' for every other backend, so only herdr can classify the daemon's own
# host process as the supervised agent working.
FM_SUPERVISOR_NATIVE_BUSY_BACKENDS="herdr"

# Supervisor backends the away daemon knows how to inject into today. zellij,
# orca, and cmux are real backends elsewhere in firstmate (bin/fm-backend.sh)
# but the daemon has no verified composer/busy primitives wired up for them yet
# - see docs/herdr-backend.md and AGENTS.md section 4's harness-verification
# discipline. Selecting one refuses loudly, at the launcher before a terminal is
# created and again at daemon startup, instead of silently running tmux
# primitives against a pane that is not a tmux pane.
# shellcheck disable=SC2034  # read by bin/fm-supervise-daemon.sh and bin/fm-afk-launch.sh, which source this file
FM_SUPERVISOR_SUPPORTED_BACKENDS="tmux herdr"

# fm_supervisor_backend_has_native_busy: 0 when <backend>'s native agent-state
# source can observe the supervisor pane's own in-pane background jobs.
fm_supervisor_backend_has_native_busy() {  # <backend>
  local backend=$1 listed
  [ -n "$backend" ] || return 1
  for listed in $FM_SUPERVISOR_NATIVE_BUSY_BACKENDS; do
    [ "$listed" = "$backend" ] && return 0
  done
  return 1
}

# discover_own_pane_target: the pane THIS process is actually running in.
#
# Deliberately ignores FM_SUPERVISOR_TARGET, which names the pane to SUPERVISE,
# not the pane we are in. The two are the same only when the daemon is hosted
# inside its own target - the condition supervisor_pane_is_self_hosted exists to
# detect. Returns 1 with no output when this process is in no recognized pane.
discover_own_pane_target() {
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  return 1
}

# supervisor_pane_is_self_hosted: 0 when a daemon running in THIS process's pane
# would be a tenant of the very pane it must deliver into, on a backend whose
# native agent state observes that tenancy.
#
# Why this is a hard refusal and not a warning (2026-08-26 incident): the away
# daemon launched through a harness's own in-pane background tool keeps a live
# background job in the captain's pane for its whole lifetime. Herdr's claude
# agent-detection manifest classifies a pane whose footer carries a background
# shell count as `working`, pane_is_busy trusts that native verdict first, and
# the daemon then defers every injection for as long as it runs. The daemon
# cannot deliver into a pane it is a tenant of, so the correct answer is to run
# it elsewhere (bin/fm-afk-launch.sh's terminal-backed path), never to weaken the
# busy guard that protects the captain's composer.
#
# Timing-independent by construction: it compares pane identity, never rendered
# output or turn state, so it is exactly as true at launch as it is at 03:00.
supervisor_pane_is_self_hosted() {  # <backend> <target>
  local backend=$1 target=$2 own
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  fm_supervisor_backend_has_native_busy "$backend" || return 1
  own=$(discover_own_pane_target) || return 1
  [ "$own" = "$target" ]
}
