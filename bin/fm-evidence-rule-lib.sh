#!/usr/bin/env bash
# Single source of the evidence-delivery rule handed to a worker.
# Chosen shape: a shared string both generators interpolate, matching how this
# repo already shares mechanics between scripts. bin/fm-brief.sh writes the rule
# into a ship brief and bin/fm-promote.sh sends it to a scout promoted in place,
# which keeps its scout brief; two independently edited copies of the sentence
# would drift the moment one was corrected.
# The owner pointer is absolute on purpose: a crewmate works inside another
# project's worktree, where a repo-relative skill path does not resolve.
# The mechanics themselves stay in the evidence-artifacts skill this points at.
# Source only, no side effects. set -u / set -e safe.

# shellcheck disable=SC2016  # the backticks are literal Markdown around the path in the delivered rule, not a command substitution.
fm_evidence_rule_text() {  # <fm-root>
  printf 'Evidence you present in a PR or MR must be uploaded to it and embedded so it renders - a path on this machine is never the delivered form, because no reviewer can open it. If your work produces screenshots or other evidence files, follow `%s/.agents/skills/evidence-artifacts/SKILL.md`.' "$1"
}
