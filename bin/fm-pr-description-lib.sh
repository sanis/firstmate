#!/usr/bin/env bash
# Detect evidence that a pull or merge request description delivers as a local
# filesystem path - a file only the machine that produced it can open.
#
# The rule against this already lived in the crewmate brief scaffold and in the
# evidence-artifacts skill, and shipped defects anyway, because nothing ever
# measured the delivered surface. This library is that measurement.
#
# The whole difficulty is separating a DELIVERED ARTIFACT from a path QUOTED AS
# DOCUMENTATION. A naive prefix match on /tmp/ flags every CI template that
# installs a tool into scratch space, and a check that cries wolf is worse than
# the defect it prevents. So the decision is made in two stages: a cheap root
# prefilter, then a shape rule.
#
#   1. Candidate roots - a path is looked at only when its root names a
#      machine-local namespace: a "file://" URL, a user home under /Users or
#      /home, a macOS per-user temp root under /var/folders, or scratch space
#      under /tmp or /var/tmp. macOS mounts those roots as symlinks into
#      /private, so a leading "/private" is folded away once before the root is
#      read rather than carrying a twin for every entry in the list; the path is
#      still reported exactly as the description wrote it. Everything else is
#      left alone, which is what keeps a GitLab "/uploads/<hash>/shot.png" link
#      - the CORRECT delivered form - from being refused by the opacity rule
#      below.
#
#   2. Verdict - a "file://" URL, a user home and a per-user temp root are
#      private by shape and always refused. Shared-shape scratch roots are
#      refused only when the path also proves it cannot be resolved elsewhere:
#      it carries an OPAQUE segment (a machine-generated token: an alphanumeric
#      run of at least 10 characters carrying at least two digits and at least
#      two letters, which is what a run id or a ULID looks like and what a
#      human-authored name never does), or it sits in a DELIVERY POSITION (a
#      markdown image or link target, or an HTML src=/href= attribute inside an
#      open tag), where the reader is literally invited to open it.
#
# The opacity test is the shape rule the fixed root list cannot be: it catches
# any evidence tool that stamps a run id, whatever root it writes under and
# whatever the file extension is. This was never a screenshots problem - the
# defects that prompted it delivered YAML, JSON and PHP as often as PNG - so
# nothing here looks at extensions.
#
# Known blind spots are recorded in docs/verification/pr-description-guard.md.

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# The forge fetch is bounded. An unreachable forge already degrades through a
# non-zero exit, but a blackholed connection would otherwise leave the CLI
# waiting forever and hang the ready report before anything is armed. A hit
# bound is just another fetch failure, never a refusal.
# bin/fm-timeout-lib.sh owns the bound itself, and documents that a non-positive
# value is not a bound, so a bad setting is rewritten rather than honoured.
FM_PR_DESCRIPTION_TIMEOUT=${FM_PR_DESCRIPTION_TIMEOUT:-20}
case "$FM_PR_DESCRIPTION_TIMEOUT" in ''|*[!0-9]*|0) FM_PR_DESCRIPTION_TIMEOUT=20 ;; esac

# fm_pr_description_awk_program: the scanner, kept in a quoted heredoc so its
# regexes carry both quote characters without shell escaping.
fm_pr_description_awk_program() {
  cat <<'AWK'
function strip_trailing(t) {
  # A path at the end of a sentence collects the period.
  sub(/[.]+$/, "", t)
  return t
}

# macOS mounts /tmp, /var and /etc as symlinks into /private, so any tool that
# realpath-normalises an evidence path emits the /private twin of a root below.
# Fold that one prefix away instead of lengthening the root list with a twin for
# every entry. Classification only - the caller still reports the original.
function canonical_root(p) {
  if (p ~ "^/private/") return substr(p, 9)
  return p
}

function classify(p,   c) {
  if (p ~ "^file://[/]*[^/]") return "private"
  c = canonical_root(p)
  if (c ~ "^/Users/[^/]") return "private"
  if (c ~ "^/home/[^/]") return "private"
  if (c ~ "^/var/folders/[^/]") return "private"
  if (c ~ "^/tmp(/|$)") return "scratch"
  if (c ~ "^/var/tmp(/|$)") return "scratch"
  return "none"
}

# A machine-generated token: one alphanumeric run of at least 10 characters
# carrying at least two digits and at least two letters. Human-authored names
# break into short separator-delimited words ("no-mistakes-evidence") or carry
# no digits at all ("01-transaction-row-action").
function is_opaque_segment(seg,   flat, n, parts, i, run, j, ch, digits, letters) {
  flat = seg
  gsub(/[^A-Za-z0-9]/, " ", flat)
  n = split(flat, parts, " ")
  for (i = 1; i <= n; i++) {
    run = parts[i]
    if (length(run) < 10) continue
    digits = 0
    letters = 0
    for (j = 1; j <= length(run); j++) {
      ch = substr(run, j, 1)
      if (ch ~ /[0-9]/) digits++
      else letters++
    }
    if (digits >= 2 && letters >= 2) return 1
  }
  return 0
}

function has_opaque_segment(p,   n, segs, i) {
  n = split(p, segs, "/")
  for (i = 1; i <= n; i++) {
    if (is_opaque_segment(segs[i])) return 1
  }
  return 0
}

# Is this position inside an HTML tag that is still open? Everything through the
# last ">" belongs to tags already closed, so only the text after it can hold an
# open one, and a "<" opens a tag only when a tag name follows it.
function in_open_tag(before,   rest) {
  rest = before
  sub(/^.*>/, "", rest)
  return rest ~ /<[A-Za-z]/
}

# The reader is invited to open it: a markdown image or link target, or an HTML
# src=/href= attribute. HTML attribute names are case-insensitive, so both cases
# are spelled out as character classes rather than with an inline flag no POSIX
# awk carries - but reading those bytes as a delivery ANYWHERE would refuse
# "make SRC=/tmp/src", an ordinary documented build command, so the attribute
# counts only inside a tag that is actually open.
function is_delivered(before) {
  if (before ~ "\\]\\($") return 1
  if (before ~ "([sS][rR][cC]|[hH][rR][eE][fF])[ \t]*=[ \t]*[\"']?$" && in_open_tag(before)) return 1
  return 0
}

function report(p) {
  if (p in seen) return
  seen[p] = 1
  print p
}

BEGIN {
  # A path token runs to the first character a path cannot contain, so markdown
  # punctuation, quotes, backslash-escaped snippets and HTML tags all end it.
  tail = "[A-Za-z0-9._+~/-]*"
  candidate = "file://" tail "|/(Users|home|tmp|var|private)" tail
  boundary = "[A-Za-z0-9._+~/:-]"
}

{
  line = $0
  # How much of the record "line" has already given up. Both the delivery
  # position and the preceding character are properties of the whole record, so
  # they are read from $0 at the absolute position rather than from the
  # remainder, whose own start is not the start of anything.
  consumed = 0
  while (length(line) > 0 && match(line, candidate)) {
    start = consumed + RSTART
    len = RLENGTH
    token = substr($0, start, len)
    before = substr($0, 1, start - 1)
    # A leading path character means this "/tmp" is the tail of something
    # longer - a URL path, a longer directory name - and not a root at all.
    if (start == 1 || substr($0, start - 1, 1) !~ boundary) {
      token = strip_trailing(token)
      kind = classify(token)
      if (kind == "private") report(token)
      else if (kind == "scratch" && (has_opaque_segment(token) || is_delivered(before))) report(token)
    }
    consumed = start + len - 1
    line = substr($0, consumed + 1)
  }
}
AWK
}

# fm_pr_description_local_paths: read a description body on stdin, print each
# offending path once in first-appearance order. Always succeeds; an empty body
# simply prints nothing.
fm_pr_description_local_paths() {
  # LC_ALL=C keeps the A-Za-z0-9 ranges byte-exact and stops a description
  # carrying invalid multibyte sequences from aborting the scan under awks that
  # validate them.
  LC_ALL=C awk "$(fm_pr_description_awk_program)"
}

# fm_pr_description_fetch <provider> <host> <project-path> <number> <url>
# Print the description body on stdout. Returns non-zero when the forge cannot
# be reached, read, or answered inside FM_PR_DESCRIPTION_TIMEOUT seconds; every
# caller must degrade to a warning rather than block, because a network hiccup
# must never stop a legitimate ready report.
# Keep only the description from a plain `glab mr view`, which prefixes a header
# block closed by a line that is exactly "--". The subject of this measurement is
# the description alone: a header field carries free text, and a title naming a
# path would otherwise refuse a body that never mentioned one, which the author
# could not act on by editing the description.
# Output with no such line is an unrecognised format, and is passed through
# whole rather than measured as empty, because a guard that silently reads
# nothing is the defect this exists to prevent.
fm_pr_description_strip_header() {
  LC_ALL=C awk '
    body { print; next }
    $0 == "--" { body = 1; next }
    { held[n++] = $0 }
    END { if (!body) for (i = 0; i < n; i++) print held[i] }
  '
}

fm_pr_description_fetch() {
  local provider=$1 host=$2 project_path=$3 number=$4 url=$5 rc=0 plain described
  case "$provider" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      [ -n "$url" ] || return 1
      # The URL addresses the instance the task was validated against. A bare
      # number with --repo is answered by whichever instance gh is configured
      # for, so a repository of the same name elsewhere could supply a
      # description this request never carried.
      fm_run_timed "$FM_PR_DESCRIPTION_TIMEOUT" \
        gh pr view "$url" --json body -q .body 2>/dev/null
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 || return 1
      # The JSON form is exact. Older glab builds without --jq still answer the
      # plain view, whose description is recovered by dropping its header, so
      # the check keeps working across versions.
      # 124 is the one status that does not fall through to that fallback: the
      # fallback exists for a build that rejects --jq, which fails instantly,
      # whereas a hit bound means the host is not answering at all and retrying
      # it would burn a second full bound before the warning is printed.
      # -R takes the project URL, not a bare host/path; see bin/fm-pr-poll.sh.
      # The attempt is captured rather than streamed: a failing glab answers on
      # STDOUT too, and letting that reach the caller would prepend an error
      # blob to the fallback body and measure both as one description.
      described=$(fm_run_timed "$FM_PR_DESCRIPTION_TIMEOUT" \
        glab mr view "$number" -R "https://$host/$project_path" -F json --jq .description 2>/dev/null) || rc=$?
      case "$rc" in
        0) printf '%s\n' "$described"; return 0 ;;
        124) return 124 ;;
      esac
      plain=$(fm_run_timed "$FM_PR_DESCRIPTION_TIMEOUT" \
        glab mr view "$number" -R "https://$host/$project_path" 2>/dev/null) || return "$?"
      printf '%s\n' "$plain" | fm_pr_description_strip_header
      ;;
    *)
      return 1
      ;;
  esac
}

# fm_pr_description_refuse <provider> <paths>
# Name every offending path and point at the upload recipes, so the fix is
# obvious rather than a puzzle.
fm_pr_description_refuse() {
  local provider=$1 paths=$2 noun total shown
  case "$provider" in
    gitlab) noun="merge request" ;;
    *) noun="pull request" ;;
  esac
  total=$(printf '%s\n' "$paths" | wc -l | tr -d ' ')
  shown=$paths
  if [ "$total" -gt 20 ]; then
    shown=$(printf '%s\n' "$paths" | head -20)
  fi
  {
    printf 'error: the %s description delivers evidence as local file paths no reader can open\n' "$noun"
    printf '%s\n' "$shown" | sed 's/^/  /'
    [ "$total" -gt 20 ] && printf '  ... and %s more\n' "$((total - 20))"
    printf 'upload each artifact to the %s and embed the link it returns; the recipes are in\n' "$noun"
    printf '  .agents/skills/evidence-artifacts/SKILL.md\n'
  } >&2
}
