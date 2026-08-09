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
  local home brief hits owner record hit
  home="$TMP_ROOT/owner"
  mkdir -p "$home/data"
  brief=$(scaffold "$home" evidence-owner sample --mode no-mistakes)
  owner="$SKILL"
  record="$ROOT/docs/verification/evidence-artifacts.md"

  assert_grep 'raw.githubusercontent.com' "$owner" \
    "the owner no longer records the broken GitHub form"
  assert_grep 'projects/<url-encoded-project-path>/uploads' "$owner" \
    "the owner no longer records the GitLab upload endpoint"

  assert_no_grep 'raw.githubusercontent.com' "$AGENTS" \
    "AGENTS.md absorbed forge mechanics that belong to the skill"
  assert_no_grep 'raw.githubusercontent.com' "$brief" \
    "the generated brief absorbed forge mechanics that belong to the skill"
  assert_grep 'evidence-artifacts' "$AGENTS" "AGENTS.md is missing the load trigger"

  # Narrowed to the instruction rather than the bare host: a document may name
  # that host in an installer or download command (bin/fm-bootstrap.sh already
  # does) without restating this contract. What only a second copy carries is
  # the private-repository finding, so the sweep matches the host stated
  # together with private-repository behavior on one line, over prose surfaces.
  hits=$(grep -rliE --include='*.md' \
    'raw\.githubusercontent\.com.*privat|privat.*raw\.githubusercontent\.com' \
    "$ROOT/AGENTS.md" "$ROOT/.agents/skills" "$ROOT/skills" "$ROOT/docs" 2>/dev/null | sort)

  # Owners first: without this, renaming both owner files empties the sweep and
  # the exact-set comparison would pass on nothing.
  for hit in "$owner" "$record"; do
    printf '%s\n' "$hits" | grep -qxF -- "$hit" \
      || fail "expected owner no longer states the private-repository finding: $hit"
  done

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    case "$hit" in
      "$owner"|"$record") ;;
      *) fail "the GitHub embedding mechanic gained a second owner: $hit" ;;
    esac
  done <<EOF
$hits
EOF

  # Scripts too, on the same one-owner principle: a generator that hands the
  # rule to a worker names the owner skill by path, so exactly one file under
  # bin/ may do so - bin/fm-evidence-rule-lib.sh, which both bin/fm-brief.sh and
  # bin/fm-promote.sh interpolate. A prose-only sweep could not see a second
  # generator, which is how two copies of the sentence appeared. An unrelated
  # mention of a download host (bin/fm-bootstrap.sh) does not match this.
  hits=$(grep -rlF -- '/.agents/skills/evidence-artifacts/SKILL.md' "$ROOT/bin" 2>/dev/null | sort)
  printf '%s\n' "$hits" | grep -qxF -- "$ROOT/bin/fm-evidence-rule-lib.sh" \
    || fail "no script holds the evidence rule any more: $ROOT/bin/fm-evidence-rule-lib.sh"
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    case "$hit" in
      "$ROOT/bin/fm-evidence-rule-lib.sh") ;;
      *) fail "a second generator states the evidence rule instead of sharing it: $hit" ;;
    esac
  done <<EOF
$hits
EOF
  pass "forge mechanics live only in the owner skill and its verification record"
}

# A scout promoted in place keeps its scout brief, so the ship Rules block never
# reaches it. The promotion handoff is where the rule must land, because that
# worker opens the pull request itself.
test_promotion_handoff_carries_the_rule() {
  local home meta out status brief rule
  home="$TMP_ROOT/promote"
  mkdir -p "$home/state" "$home/data"
  meta="$home/state/evidence-promote.meta"
  printf 'window=fm-evidence-promote\nkind=scout\nworktree=/tmp/wt\n' > "$meta"

  # The expected rule is read back out of a generated ship brief rather than
  # restated here, so this asserts the promoted worker gets the SAME rule the
  # brief delivers without mandating a second copy of the wording.
  brief=$(scaffold "$home" evidence-handoff sample --mode direct-PR)
  assert_present "$brief" "the reference ship brief was not scaffolded"
  rule=$(grep -F -- '/.agents/skills/evidence-artifacts/SKILL.md' "$brief")
  rule=${rule#8. }
  [ -n "$rule" ] || fail "the ship brief no longer carries an evidence rule to compare against"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-promote.sh" evidence-promote --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion with a full delivery contract should succeed"
  assert_contains "$out" "$rule" \
    "the promotion handoff does not deliver the same evidence rule the ship brief carries"
  assert_contains "$out" "$ROOT/.agents/skills/evidence-artifacts/SKILL.md" \
    "the promotion handoff does not point at the owner by a resolvable absolute path"
  pass "a promoted scout receives the ship brief's evidence rule and owner pointer"
}

test_ship_briefs_carry_the_rule_and_point_at_the_owner
test_rule_stays_out_of_scaffolds_that_deliver_no_pull_request
test_forge_mechanics_have_exactly_one_owner
test_promotion_handoff_carries_the_rule
