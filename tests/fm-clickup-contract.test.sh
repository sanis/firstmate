#!/usr/bin/env bash
# Static contract tests for the /clickup skill: frontmatter, connector facts,
# safety contracts, AGENTS.md triggers, and one-owner boundaries.
# shellcheck disable=SC2016 # Literal backticks in asserted phrases must remain unexpanded.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/clickup/SKILL.md"
AGENTS="$ROOT/AGENTS.md"
DOC="$ROOT/docs/clickup-command.md"

# These tests deliberately do NOT contain the real ClickUp space id or Project
# field UUID: naming them here would re-expose the very values the skill now
# keeps in gitignored config/clickup.json. Instead we guard structurally - a
# hardcoded connector id would be a UUID-shaped string in a tracked file.
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
assert_no_uuid() {
  ! grep -qE "$UUID_RE" "$1" || fail "$2"
}

test_clickup_skill_metadata() {
  assert_present "$SKILL" "clickup skill is missing"
  assert_grep 'name: clickup' "$SKILL" "clickup skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$SKILL" "clickup skill must be captain-invocable"
  assert_grep '  internal: true' "$SKILL" "clickup skill must be internal"
  pass "clickup skill exists with captain-invocable internal frontmatter"
}

test_clickup_skill_externalizes_instance_params() {
  assert_no_uuid "$SKILL" \
    "clickup skill hardcodes a UUID-shaped id - instance ids must live in config/clickup.json"
  assert_grep 'config/clickup.json' "$SKILL" \
    "clickup skill must read instance parameters from config/clickup.json"
  assert_grep 'development_space_id' "$SKILL" "clickup skill lost the config space-id key name"
  assert_grep 'project_field_id' "$SKILL" "clickup skill lost the config field-id key name"
  assert_grep 'expand_statuses: true' "$SKILL" "clickup skill lost the expand_statuses requirement"
  assert_grep 'available_statuses' "$SKILL" "clickup skill lost the runtime status confirmation"
  assert_grep 'include: ["description", "custom_fields"]' "$SKILL" \
    "clickup skill lost the get_task include contract"
  assert_grep 'NOT exposed by this connector' "$SKILL" \
    "clickup skill lost the sprint-points-not-writable fact"
  assert_grep 'Never attempt to write sprint points' "$SKILL" \
    "clickup skill lost the sprint-points write prohibition"
  pass "clickup skill externalizes instance parameters and keeps connector facts"
}

test_clickup_instance_params_stay_local() {
  assert_grep 'config/clickup.json' "$ROOT/.gitignore" \
    "config/clickup.json must be gitignored so instance ids never enter the repo"
  assert_no_uuid "$DOC" "clickup design doc hardcodes a UUID-shaped id - it must live in config/clickup.json"
  pass "clickup instance parameters stay local and out of tracked files"
}

test_clickup_skill_safety_contracts() {
  assert_grep 'available only to the main firstmate session' "$SKILL" \
    "clickup skill lost the main-session-only constraint"
  assert_grep 'Never brief a crewmate to call ClickUp' "$SKILL" \
    "clickup skill lost the no-crewmate-ClickUp rule"
  assert_grep 'Never act on a task assigned to someone else' "$SKILL" \
    "clickup skill lost the foreign-assignee refusal"
  assert_grep '## firstmate clarifications' "$SKILL" \
    "clickup skill lost the durable-description section name"
  assert_grep 'Never overwrite or rewrite the original description text' "$SKILL" \
    "clickup skill lost the append-only description rule"
  assert_grep 'Parking never uses a `blocked` status' "$SKILL" \
    "clickup skill lost the park-not-blocked contract"
  assert_grep 'stop, make no status change, and tell the captain' "$SKILL" \
    "clickup skill lost the missing-status stop rule"
  assert_grep 'clickup: <custom id> <internal id> <task url>' "$SKILL" \
    "clickup skill lost the linkage line format"
  assert_grep 'this skill never merges' "$SKILL" \
    "clickup skill lost the unchanged-merge-authority statement"
  if grep -q "$(printf '\342\200\224')" "$SKILL"; then
    fail "clickup skill contains an em dash"
  fi
  pass "clickup skill keeps its safety and idempotency contracts"
}

test_agents_triggers() {
  local count
  assert_grep 'When the captain invokes `/clickup`, load the `clickup` skill' "$AGENTS" \
    "AGENTS.md lost the /clickup invocation trigger"
  assert_grep 'reports its PR checks green or its PR merged, load the `clickup` skill' "$AGENTS" \
    "AGENTS.md lost the ClickUp-linked milestone trigger"
  count=$(grep -c '`clickup` skill' "$AGENTS")
  [ "$count" -eq 2 ] || fail "AGENTS.md must reference the clickup skill exactly twice (invocation + milestone), found $count"
  pass "AGENTS.md carries exactly the two clickup triggers"
}

test_one_owner_boundaries() {
  assert_no_uuid "$AGENTS" \
    "AGENTS.md hardcodes a UUID-shaped id - ClickUp connector ids belong in config/clickup.json, not AGENTS.md"
  assert_no_grep 'firstmate clarifications' "$AGENTS" \
    "AGENTS.md duplicates the durable-description contract owned by the skill"
  assert_present "$DOC" "clickup design doc is missing"
  assert_grep 'The normative procedure is owned by `.agents/skills/clickup/SKILL.md`' "$DOC" \
    "clickup design doc does not defer normative ownership to the skill"
  assert_grep '/clickup' "$ROOT/README.md" "README lost the /clickup skill-table row"
  pass "clickup contract stays single-owner with doc and README pointers"
}

test_clickup_skill_metadata
test_clickup_skill_externalizes_instance_params
test_clickup_instance_params_stay_local
test_clickup_skill_safety_contracts
test_agents_triggers
test_one_owner_boundaries
