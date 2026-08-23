#!/usr/bin/env bash
# Behavior guard for the `Require no-mistakes` PR compliance check
# (.github/workflows/no-mistakes-required.yml).
#
# Regression origin: the gate does not always get to open the PR itself. With
# the gate registered against a repository the author cannot push to and no fork
# URL set, the push is rejected, the branch reaches the remote by hand, and the
# PR body carries no pipeline signature - so this check failed a change every
# pipeline step had actually run on. The check now accepts either proof, and the
# cases below pin both plus the failure that must stay a failure.
#
# The workflow YAML is the contract: the step's shell is extracted from it and
# executed with a fake `gh`, so these assert what the check DOES rather than
# what its source says.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
STEP_NAME="Verify no-mistakes signature in PR body"
# The deterministic signature no-mistakes writes into a PR body it opens.
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
# The structured step attestation the signature alone no longer stands in for.
# no-mistakes >= 1.46.0 emits this comment beside the signature, and the check
# requires review, test and document to each read exactly "completed" - a quota
# skip or an agent skip is deliberately not compliant.
ATTESTATION='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0123456789abcdef0123456789abcdef01234567","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'
# The same attestation with one required step skipped rather than completed.
ATTESTATION_SKIPPED='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0123456789abcdef0123456789abcdef01234567","steps":[{"step":"review","status":"skipped"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'

TMP_ROOT=$(fm_test_tmproot fm-nm-required)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CHECK="$TMP_ROOT/check.sh"
CALLS="$TMP_ROOT/gh-calls"

# Extract the named step's `run:` block scalar from the workflow. Strict by
# design: anything other than exactly one matching step with a non-empty script
# is an error, so a restructured workflow fails loudly instead of testing stale
# text.
python3 - "$WORKFLOW" "$STEP_NAME" "$CHECK" <<'PY'
import sys
from pathlib import Path

workflow, step_name, destination = sys.argv[1], sys.argv[2], Path(sys.argv[3])
lines = Path(workflow).read_text(encoding="utf-8").splitlines()

starts = [
    i for i, line in enumerate(lines)
    if line.strip() == f"- name: {step_name}"
]
if len(starts) != 1:
    sys.exit(f"expected exactly one step named {step_name!r}, found {len(starts)}")

start = starts[0]
key_indent = len(lines[start]) - len(lines[start].lstrip()) + 2
script = []
inside = False
for line in lines[start + 1:]:
    indent = len(line) - len(line.lstrip())
    if line.strip() and indent < key_indent:
        break
    if not inside:
        if line.strip() == "run: |" and indent == key_indent:
            inside = True
        continue
    if line.strip() and indent <= key_indent:
        break
    script.append(line)

if not any(line.strip() for line in script):
    sys.exit(f"step {step_name!r} has no `run: |` script")

body = list(script)
while body and not body[0].strip():
    body.pop(0)
block_indent = len(body[0]) - len(body[0].lstrip())
destination.write_text(
    "".join(line[block_indent:] + "\n" if line.strip() else "\n" for line in body),
    encoding="utf-8",
)
PY

# Fake `gh api --paginate <endpoint> --jq <expr>`: records the call and applies
# the workflow's own jq expression to a canned commits response, so the jq
# filter under test is really executed.
write_fake_gh() {
  local fixture=$1
  cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
expression=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --jq)
      expression=\$2
      shift 2
      ;;
    *) shift ;;
  esac
done
if [ -z "\$expression" ]; then
  echo "fake gh: expected a --jq expression" >&2
  exit 64
fi
jq -r "\$expression" < "$fixture"
SH
  chmod +x "$FAKEBIN/gh"
}

# write_commits <file> <message>...: a commits payload shaped like the GitHub
# pull request commits endpoint.
write_commits() {
  local destination=$1
  shift
  local message first=1
  {
    printf '['
    for message in "$@"; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"commit":{"message":%s}}' "$(printf '%s' "$message" | jq -Rs .)"
    done
    printf ']\n'
  } > "$destination"
}

OUT=''
RC=0

# run_check [--no-body] <body>: run the extracted step with the given PR body.
run_check() {
  rm -f "$CALLS"
  set +e
  if [ "${1:-}" = --no-body ]; then
    OUT=$(env -u PR_BODY PATH="$FAKEBIN:$PATH" \
      GH_TOKEN=fake PR_AUTHOR=contributor PR_NUMBER=7 PR_REPO=owner/repo \
      bash "$CHECK" 2>&1)
  else
    OUT=$(PATH="$FAKEBIN:$PATH" PR_BODY="$1" \
      GH_TOKEN=fake PR_AUTHOR=contributor PR_NUMBER=7 PR_REPO=owner/repo \
      bash "$CHECK" 2>&1)
  fi
  RC=$?
  set -e
}

test_signed_body_passes_without_calling_the_api() {
  write_commits "$TMP_ROOT/commits.json" "feat: something"
  write_fake_gh "$TMP_ROOT/commits.json"

  run_check "## Pipeline"$'\n\n'"$MARKER"$'\n\n'"$ATTESTATION"$'\n'
  expect_code 0 "$RC" "a body carrying the signature and its step attestation must pass"
  assert_contains "$OUT" "Found no-mistakes signature in PR #7 body." \
    "the passing run must say the body signature was found"
  assert_contains "$OUT" "Pipeline step attestation is valid" \
    "the passing run must say the step attestation was accepted, not just the signature"
  assert_absent "$CALLS" "a signed body must not need the commits API"
  pass "a body carrying the signature and a complete attestation passes without an API call"
}

# The signature alone used to be the whole proof. It is not any more, and the
# body is decided on its own contents: an unattested signature is refused inside
# the signature branch rather than falling through to the commit proof, so a
# gate-written commit cannot quietly stand in for the attestation.
test_a_signature_without_attestation_fails() {
  write_commits "$TMP_ROOT/commits.json" "no-mistakes(review): applied the findings"
  write_fake_gh "$TMP_ROOT/commits.json"

  run_check "## Pipeline"$'\n\n'"$MARKER"$'\n'
  expect_code 1 "$RC" "a signature with no step attestation must fail"
  assert_contains "$OUT" "structured pipeline step attestation is missing or unparseable" \
    "the refusal must name the missing attestation, not report a generic policy violation"
  assert_absent "$CALLS" \
    "a signed body is decided on the body alone and is never rescued by the commit proof"
  pass "a bare signature no longer proves the pipeline ran"
}

test_an_incomplete_required_step_fails() {
  write_commits "$TMP_ROOT/commits.json" "feat: something"
  write_fake_gh "$TMP_ROOT/commits.json"

  run_check "## Pipeline"$'\n\n'"$MARKER"$'\n\n'"$ATTESTATION_SKIPPED"$'\n'
  expect_code 1 "$RC" "a required step that only skipped must fail"
  assert_contains "$OUT" "review=skipped" \
    "the refusal must name the step that is not completed and the status it carried"
  pass "a skipped required step is not a completed pipeline"
}

test_gate_commits_pass_an_unsigned_body() {
  write_commits "$TMP_ROOT/commits.json" \
    "feat(agents): deliver evidence artifacts" \
    "no-mistakes(review): harden the one-owner sweep"$'\n\n'"Review findings applied."
  write_fake_gh "$TMP_ROOT/commits.json"

  run_check "## What this changes"$'\n\n'"Opened by hand because the gate push was rejected."$'\n'
  expect_code 0 "$RC" "gate commits must prove the pipeline ran when the body is unsigned"
  assert_contains "$OUT" "Found no-mistakes gate commits in PR #7." \
    "the passing run must say the gate commits were found"
  pass "a gate-signed commit passes a PR whose body no-mistakes never wrote"
}

test_missing_body_is_not_a_crash() {
  write_commits "$TMP_ROOT/commits.json" "no-mistakes(ci): fix the failing check"
  write_fake_gh "$TMP_ROOT/commits.json"

  run_check --no-body
  expect_code 0 "$RC" "an absent PR body must fall through to the commit proof, not error"
  assert_contains "$OUT" "Found no-mistakes gate commits in PR #7." \
    "an empty body must still reach the commit proof"
  pass "an absent PR body is handled instead of aborting the check"
}

test_ungated_pr_still_fails() {
  write_commits "$TMP_ROOT/commits.json" \
    "feat: add a thing" \
    "fix: address review"
  write_fake_gh "$TMP_ROOT/commits.json"

  run_check "Please merge this."$'\n'
  expect_code 1 "$RC" "a PR that never went through the gate must fail"
  assert_contains "$OUT" "::error::This PR was not raised through no-mistakes." \
    "the failure must name the rule it enforces"
  assert_contains "$OUT" "$MARKER" \
    "the failure must show the signature no-mistakes writes"
  assert_contains "$OUT" "no-mistakes(<step>):" \
    "the failure must name the second accepted proof"
  assert_contains "$OUT" "PR author: contributor" \
    "the failure must name the PR author"
  pass "a PR with neither proof still fails with actionable guidance"
}

test_unreadable_commits_fail_as_their_own_reason() {
  # An API that could not be read is not evidence of a missing pipeline, so it
  # must not be reported as one.
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: HTTP 502" >&2
exit 1
SH
  chmod +x "$FAKEBIN/gh"

  run_check "Please merge this."$'\n'
  expect_code 1 "$RC" "an unreadable commits API must fail the check"
  assert_contains "$OUT" "so the gate-commit proof was not evaluated" \
    "an API failure must be reported as itself"
  assert_not_contains "$OUT" "This PR was not raised through no-mistakes." \
    "an API failure must not be reported as a policy violation"
  pass "an unreadable commits API fails as its own reason, not as a policy violation"
}

test_gate_wording_in_a_commit_body_is_not_a_proof() {
  # Only a gate-written SUBJECT counts. A commit that merely quotes the gate's
  # commit convention in its message body must not launder an ungated PR.
  write_commits "$TMP_ROOT/commits.json" \
    "docs: describe the gate"$'\n\n'"no-mistakes(review): is what the gate writes."
  write_fake_gh "$TMP_ROOT/commits.json"

  run_check "Please merge this."$'\n'
  expect_code 1 "$RC" "gate wording inside a commit body must not count as proof"
  pass "only a gate-written commit subject counts as the second proof"
}

test_signed_body_passes_without_calling_the_api
test_a_signature_without_attestation_fails
test_an_incomplete_required_step_fails
test_gate_commits_pass_an_unsigned_body
test_missing_body_is_not_a_crash
test_ungated_pr_still_fails
test_unreadable_commits_fail_as_their_own_reason
test_gate_wording_in_a_commit_body_is_not_a_proof
