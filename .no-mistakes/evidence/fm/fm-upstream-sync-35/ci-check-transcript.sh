#!/usr/bin/env bash
# Runs the real "Verify no-mistakes signature in PR body" step out of
# .github/workflows/no-mistakes-required.yml against realistic PR bodies and
# prints exactly what a contributor sees in the GitHub Actions log.
set -u
ROOT=${1:?usage: ci-check-transcript.sh <repo-root>}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CHECK="$WORK/check.sh"
python3 - "$ROOT/.github/workflows/no-mistakes-required.yml" "Verify no-mistakes signature in PR body" "$CHECK" <<'PY'
import sys
from pathlib import Path
workflow, step_name, destination = sys.argv[1], sys.argv[2], Path(sys.argv[3])
lines = Path(workflow).read_text(encoding="utf-8").splitlines()
start = [i for i, l in enumerate(lines) if l.strip() == f"- name: {step_name}"][0]
key_indent = len(lines[start]) - len(lines[start].lstrip()) + 2
script, inside = [], False
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
while script and not script[0].strip():
    script.pop(0)
block = len(script[0]) - len(script[0].lstrip())
destination.write_text("".join(l[block:] + "\n" if l.strip() else "\n" for l in script), encoding="utf-8")
PY

# Fake `gh`: serves the PR's commits from a fixture through the workflow's own jq filter.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
expr=
while [ "$#" -gt 0 ]; do case "$1" in --jq) expr=$2; shift 2;; *) shift;; esac; done
jq -r "$expr" < "$FIXTURE"
SH
chmod +x "$WORK/bin/gh"

MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
ATTEST_OK='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0123456789abcdef0123456789abcdef01234567","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'
ATTEST_SKIP='<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0123456789abcdef0123456789abcdef01234567","steps":[{"step":"review","status":"skipped"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->'

scenario() {
  local title=$1 commits=$2 body=$3
  printf '%s\n' "$commits" > "$WORK/commits.json"
  echo "================================================================"
  echo "PR scenario: $title"
  echo "----------------------------------------------------------------"
  FIXTURE="$WORK/commits.json" PATH="$WORK/bin:$PATH" PR_BODY="$body" \
    GH_TOKEN=fake PR_AUTHOR=contributor PR_NUMBER=7 PR_REPO=sanis/firstmate \
    bash "$CHECK" 2>&1
  echo "--- check conclusion: exit $? ---"
  echo
}

scenario "opened by no-mistakes >= 1.46.0 (signature + complete attestation)" \
  '[{"commit":{"message":"feat: something"}}]' \
  "## Pipeline"$'\n\n'"$MARKER"$'\n\n'"$ATTEST_OK"$'\n'

scenario "opened by an older no-mistakes (signature only, no attestation)" \
  '[{"commit":{"message":"no-mistakes(review): applied the findings"}}]' \
  "## Pipeline"$'\n\n'"$MARKER"$'\n'

scenario "attested pipeline that skipped a required step (review=skipped)" \
  '[{"commit":{"message":"feat: something"}}]' \
  "## Pipeline"$'\n\n'"$MARKER"$'\n\n'"$ATTEST_SKIP"$'\n'

scenario "fork fallback: hand-pushed branch, unsigned body, gate commits present" \
  '[{"commit":{"message":"feat(agents): deliver evidence artifacts"}},{"commit":{"message":"no-mistakes(review): harden the one-owner sweep"}}]' \
  "## What this changes"$'\n\n'"Opened by hand because the gate push was rejected."$'\n'

scenario "never went through the gate (neither proof)" \
  '[{"commit":{"message":"feat: add a thing"}},{"commit":{"message":"fix: address review"}}]' \
  "Please merge this."$'\n'
