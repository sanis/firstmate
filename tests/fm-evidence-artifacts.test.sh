#!/usr/bin/env bash
# Behavioral regressions for the evidence-delivery rule reaching workers through
# generated instructions, and for it keeping a single owner.
#
# The defect this guards: a worker put four browser screenshots into a merge
# request body as absolute paths on its own machine. The evidence was real and
# no reviewer could see it. A rule that never reaches the generated brief would
# reproduce that exactly.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
SKILL="$ROOT/.agents/skills/evidence-artifacts/SKILL.md"
AGENTS="$ROOT/AGENTS.md"
# The prefix deliberately avoids the skill name: generated briefs embed absolute
# home paths, so a matching prefix would satisfy these assertions by accident.
TMP_ROOT=$(fm_test_tmproot fm-evidence-rule)

scaffold() {  # <home> <id> <fm-brief args...>
  local home=$1 id=$2
  shift 2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BRIEF" "$id" "$@" >/dev/null 2>&1
  printf '%s\n' "$home/data/$id/brief.md"
}

test_ship_briefs_carry_the_rule_and_point_at_the_owner() {
  local home brief mode id
  home="$TMP_ROOT/ship"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR local-only; do
    id="evidence-$mode"
    brief=$(scaffold "$home" "$id" sample --mode "$mode")
    assert_present "$brief" "$mode: brief was not scaffolded"
    assert_grep 'a path on' "$brief" "$mode: generated brief dropped the local-path prohibition"
    assert_grep 'never the delivered form' "$brief" \
      "$mode: generated brief dropped the delivered-form rule"
    assert_grep '.agents/skills/evidence-artifacts/SKILL.md' "$brief" \
      "$mode: generated brief does not point at the evidence-artifacts owner"
    # The pointer must be an absolute path: a crewmate works in another project's
    # worktree, where a repo-relative skill path does not resolve.
    assert_grep "$ROOT/.agents/skills/evidence-artifacts/SKILL.md" "$brief" \
      "$mode: skill pointer is not resolvable from a project worktree"
  done
  pass "every ship delivery mode carries the evidence rule and a resolvable owner pointer"
}

test_rule_stays_out_of_scaffolds_that_deliver_no_pull_request() {
  local home brief
  home="$TMP_ROOT/other"
  mkdir -p "$home/data"

  brief=$(scaffold "$home" evidence-scout sample --scout)
  assert_present "$brief" "scout brief was not scaffolded"
  assert_no_grep 'skills/evidence-artifacts' "$brief" \
    "scout brief carries a rule for a surface it never writes"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='Handle sample work.' \
    "$BRIEF" evidence-mate --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/evidence-mate/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_no_grep 'skills/evidence-artifacts' "$brief" \
    "secondmate charter duplicated a crewmate delivery rule"
  pass "scaffolds that open no pull request stay free of the rule"
}

# The mechanics are vendor behavior that changes. Two copies would drift the
# moment one is corrected, so only the owner and its verification record may
# state them.
test_forge_mechanics_have_exactly_one_owner() {
  local home brief hits
  home="$TMP_ROOT/owner"
  mkdir -p "$home/data"
  brief=$(scaffold "$home" evidence-owner sample --mode no-mistakes)

  assert_grep 'raw.githubusercontent.com' "$SKILL" \
    "the owner no longer records the broken GitHub form"
  assert_grep 'uploads' "$SKILL" "the owner no longer records the GitLab upload endpoint"

  assert_no_grep 'raw.githubusercontent.com' "$AGENTS" \
    "AGENTS.md absorbed forge mechanics that belong to the skill"
  assert_no_grep 'raw.githubusercontent.com' "$brief" \
    "the generated brief absorbed forge mechanics that belong to the skill"
  assert_grep 'evidence-artifacts' "$AGENTS" "AGENTS.md is missing the load trigger"

  # Prose surfaces only. bin/fm-bootstrap.sh names the same host in an unrelated
  # installer command, which is not a second copy of this contract.
  hits=$(grep -rl --include='*.md' 'raw\.githubusercontent\.com' \
    "$ROOT/AGENTS.md" "$ROOT/.agents/skills" "$ROOT/skills" "$ROOT/docs" 2>/dev/null | sort)
  [ "$hits" = "$(printf '%s\n%s\n' "$ROOT/.agents/skills/evidence-artifacts/SKILL.md" \
    "$ROOT/docs/verification/evidence-artifacts.md" | sort)" ] \
    || fail "the GitHub embedding mechanic gained a second owner: $hits"
  pass "forge mechanics live only in the owner skill and its verification record"
}

test_ship_briefs_carry_the_rule_and_point_at_the_owner
test_rule_stays_out_of_scaffolds_that_deliver_no_pull_request
test_forge_mechanics_have_exactly_one_owner
