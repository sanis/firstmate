#!/usr/bin/env bash
# Behavior tests for the local-path guard on pull and merge request
# descriptions: bin/fm-pr-description-lib.sh and its use in bin/fm-pr-check.sh.
#
# The fixture bodies below are the relevant fragments of five REAL merge
# requests, checked by hand on 2026-08-18 and referred to here by number alone.
# Four delivered evidence as local paths and one quotes a local path as
# documentation inside a CI template. All five have since been corrected in
# place, so the fragments are captured here rather than fetched, and the correct
# delivered form (a GitLab /uploads/<hash>/ link) is captured beside them
# because not refusing THAT is just as load-bearing as refusing the rest.
#
# Every structural feature of the originals is preserved byte for byte - the
# markdown image target, the <code> span after a "local file:" label, the path
# in prose inside a fenced block, the YAML-escaped shell snippet, the run-id
# directory, the relative "shots/" index. Only the nouns are neutral, because
# this repo is shared tracked material and the projects those merge requests
# belong to are not. Their identities are recorded in the private task report.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-description-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-description-guard)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

EVIDENCE_ROOT=/var/folders/qz/8xk3mhpn1t95c2rv7_gbdlr40000gn/T/no-mistakes-evidence

# --- fixture bodies ---------------------------------------------------------

# !1333: seven screenshots embedded as markdown images pointing at
# the run's scratch directory. Its own evidence index names the same files
# RELATIVELY ("shots/"), which must stay unflagged.
fixture_1333() {
  cat <<EOF
## Screenshots (\`shots/\`)

| file | what it shows |
| --- | --- |
| \`01-record-row-action.png\` | \`Retry export\` row action on the record list |
| \`07-no-config-refused.png\` | record whose target no longer resolves |

- Evidence: Record list: per-record 'Retry export' row action

  ![01-record-row-action]($EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/01-record-row-action.png)

- Evidence: Confirmation page: target, config count and the id that will be sent

  ![02-confirmation-page]($EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/02-confirmation-page.png)

- Evidence: After confirming: success flash and status read back as Sent

  ![03-retry-success-status-sent]($EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/03-retry-success-status-sent.png)

- Evidence: Second list: the same per-record row action

  ![04-second-list-row-action]($EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/04-second-list-row-action.png)

- Evidence: Second-list record retried and marked Sent

  ![05-second-list-retry-sent]($EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/05-second-list-retry-sent.png)

- Evidence: FAILED_PERMANENT record: danger block and separate acknowledgement checkbox

  ![06-permanent-failure-acknowledgement]($EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/06-permanent-failure-acknowledgement.png)

- Evidence: Record with an unresolvable target: refused, submit button withdrawn

  ![07-no-config-refused]($EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/07-no-config-refused.png)
EOF
}

# !1325: three evidence files, none of them an image. One sits in
# prose inside a fenced block, two in <code> spans after a "local file:" label.
fixture_1325() {
  cat <<EOF
\`\`\`text
claude-review as GitLab resolved it from $EVIDENCE_ROOT/01KZZTJB6ZKJR0D4S3D3VGPS12/merged-ci.yml:
  stage = qa1 (declared stages: ['.pre', 'setup', 'qa1', 'build', 'release', '.post'])
\`\`\`

- Evidence: CI lint response (valid:true, no errors or warnings) (local file: <code>$EVIDENCE_ROOT/01KZZTJB6ZKJR0D4S3D3VGPS12/ci-lint-response.json</code>)
- Evidence: CI lint dry-run for a master push pipeline (local file: <code>$EVIDENCE_ROOT/01KZZTJB6ZKJR0D4S3D3VGPS12/ci-lint-dryrun-master-push.json</code>)
EOF
}

# !1331: two evidence files, one JSON and one PHP capture script.
# This was never a screenshots problem, so nothing may key on an extension.
fixture_1331() {
  cat <<EOF
- Evidence: Full MCP JSON-RPC transcript (JSON) (local file: <code>$EVIDENCE_ROOT/01M08HCNG26R96B3RX8C8H395Y/mcp-transcript.json</code>)
- <code>Evidence capture driving the real \`POST /mcp\` endpoint end to end against seeded probe data - capture script at $EVIDENCE_ROOT/01M08HCNG26R96B3RX8C8H395Y/McpProbe40127TranscriptCapture.php</code>
EOF
}

# !1328: a clean description, and the CORRECT delivered form - the
# GitLab upload links !1333 now carries. Both must pass untouched.
fixture_1328() {
  cat <<'EOF'
## Intent

Deliverable: an include entry plus one concrete job, verified against the
project's own targeted tests.

- Evidence: Record list: per-record row action

  ![01-record-row-action](/uploads/759477d55398c9b49ca3462bce4e5bf9/01-record-row-action.png)

- Evidence: CI lint response (local file: <code>/uploads/ee299b0fcbc27d7229cd1e659b94d74a/ci-lint-response.json</code>)
EOF
}

# !703: the CI template's glab install commands, quoted as
# documentation. A naive prefix match on /tmp/ flags this and would have
# firstmate "fixing" a documented install command inside someone's CI template.
fixture_703() {
  cat <<'EOF'
```text
before_script:
- export GITLAB_HOST="${CI_SERVER_HOST:-gitlab.com}"
- apk add --no-cache git curl bash
- "if ! apk add --no-cache glab 2>/dev/null; then\n  echo \"glab apk package unavailable; installing glab\
  \ ${GLAB_VERSION} release binary\"\n  case \"$(uname -m)\" in\n    x86_64) GLAB_ARCH=amd64 ;;\n    aarch64|arm64)\
  \ GLAB_ARCH=arm64 ;;\n    *) GLAB_ARCH=amd64 ;;\n  esac\n  curl -fsSL \"https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${GLAB_ARCH}.tar.gz\"\
  \ -o /tmp/glab.tgz\n  tar -xzf /tmp/glab.tgz -C /tmp\n  install /tmp/bin/glab /usr/local/bin/glab\n\
  fi\n"
- "CLEANUP_ENV_PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"\n  env -i \\\n  HOME=\"$HOME\" \\\n  TMPDIR=\"/tmp\" \\\n"
```
EOF
}

# --- helpers ----------------------------------------------------------------

scan() {
  fm_pr_description_local_paths
}

assert_scan_equals() {  # <label> <expected-newline-separated> ; body on stdin
  local label=$1 expected=$2 actual
  actual=$(scan)
  [ "$actual" = "$expected" ] || fail \
    "$label: offending paths did not match"$'\n'"--- expected ---"$'\n'"$expected"$'\n'"--- actual ---"$'\n'"$actual"
}

make_case() {  # <name> -> case dir with fake forge CLIs and a fake fm-guard
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$fakebin" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # Both stubs answer the description query from FM_TEST_BODY_FILE and fail the
  # way the real CLIs do - non-zero with no stdout - when FM_TEST_FORGE_FAIL is
  # set, so the degrade-to-warning path is exercised through the real interface.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '%s\n' 0123456789abcdef0123456789abcdef01234567 ;;
  *" body "*)
    [ "${FM_TEST_FORGE_FAIL:-0}" = 0 ] || exit 1
    [ -z "${FM_TEST_BODY_FILE:-}" ] || cat "$FM_TEST_BODY_FILE"
    ;;
esac
SH
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" mr view "*)
    [ "${FM_TEST_FORGE_FAIL:-0}" = 0 ] || exit 1
    [ -z "${FM_TEST_BODY_FILE:-}" ] || cat "$FM_TEST_BODY_FILE"
    ;;
esac
SH
  chmod +x "$fake_root/bin/fm-guard.sh" "$fakebin/gh" "$fakebin/glab"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$dir"
}

run_check() {  # <case-dir> [args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_BODY_FILE="${FM_TEST_BODY_FILE:-}" \
    FM_TEST_FORGE_FAIL="${FM_TEST_FORGE_FAIL:-0}" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

state_snapshot() {  # <state dir>
  (cd "$1" && find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"
    shasum -a 256 "$f" | awk '{print $1}'
  done)
}

# --- the five real fixtures -------------------------------------------------

test_fixture_1333_refuses_seven_screenshots() {
  assert_scan_equals "!1333" \
    "$EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/01-record-row-action.png
$EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/02-confirmation-page.png
$EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/03-retry-success-status-sent.png
$EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/04-second-list-row-action.png
$EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/05-second-list-retry-sent.png
$EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/06-permanent-failure-acknowledgement.png
$EVIDENCE_ROOT/01M0A19WBRM7DGRAFZZM6ZQ2FC/shots/07-no-config-refused.png" \
    < <(fixture_1333)
  pass "!1333: seven screenshot paths refused, its relative shots/ index untouched"
}

test_fixture_1325_refuses_three_non_image_artifacts() {
  assert_scan_equals "!1325" \
    "$EVIDENCE_ROOT/01KZZTJB6ZKJR0D4S3D3VGPS12/merged-ci.yml
$EVIDENCE_ROOT/01KZZTJB6ZKJR0D4S3D3VGPS12/ci-lint-response.json
$EVIDENCE_ROOT/01KZZTJB6ZKJR0D4S3D3VGPS12/ci-lint-dryrun-master-push.json" \
    < <(fixture_1325)
  pass "!1325: three YAML/JSON evidence paths refused, fenced or not"
}

test_fixture_1331_refuses_json_and_php_artifacts() {
  assert_scan_equals "!1331" \
    "$EVIDENCE_ROOT/01M08HCNG26R96B3RX8C8H395Y/mcp-transcript.json
$EVIDENCE_ROOT/01M08HCNG26R96B3RX8C8H395Y/McpProbe40127TranscriptCapture.php" \
    < <(fixture_1331)
  pass "!1331: JSON transcript and PHP capture script both refused"
}

test_fixture_1328_passes() {
  assert_scan_equals "!1328" "" < <(fixture_1328)
  pass "!1328: a clean description and correct /uploads/ links pass"
}

test_fixture_703_passes() {
  assert_scan_equals "!703" "" < <(fixture_703)
  pass "!703: quoted CI install commands under /tmp pass"
}

# --- the discrimination the fixtures encode ---------------------------------

# shellcheck disable=SC2016 # Literal markdown and shell bytes are scanner test data.
test_scratch_root_needs_a_second_signal() {
  # The same scratch root decides differently on shape alone: a documented
  # command operand passes, a run-stamped or delivered path does not.
  assert_scan_equals "documented operand" "" < <(printf 'run `cp build.log /tmp/build.log` after the job\n')
  assert_scan_equals "delivered target" "/tmp/build.log" \
    < <(printf -- '- Evidence: the run log\n\n  ![build log](/tmp/build.log)\n')
  assert_scan_equals "html src" "/tmp/shot.png" < <(printf '<img src="/tmp/shot.png">\n')
  assert_scan_equals "run-stamped" "/tmp/run-01M0A19WBRM7DGRAFZZM6ZQ2FC/out.json" \
    < <(printf 'written to /tmp/run-01M0A19WBRM7DGRAFZZM6ZQ2FC/out.json\n')
  pass "a shared scratch root refuses only when stamped or delivered"
}

test_private_roots_always_refuse() {
  assert_scan_equals "user home" "/Users/someone/work/out.png" \
    < <(printf 'see /Users/someone/work/out.png for the capture\n')
  assert_scan_equals "linux home" "/home/someone/out.png" \
    < <(printf 'see /home/someone/out.png\n')
  assert_scan_equals "file url" "file:///Users/someone/out.png" \
    < <(printf 'open file:///Users/someone/out.png\n')
  pass "a user home or file:// URL is refused with no second signal"
}

test_paths_inside_urls_are_not_local_paths() {
  assert_scan_equals "url path" "" \
    < <(printf 'docs at https://example.invalid/home/guide and https://example.invalid/tmp/x.png\n')
  pass "a /home or /tmp segment inside a URL is not a local path"
}

# --- through fm-pr-check.sh -------------------------------------------------

test_refusal_names_paths_and_leaves_no_side_effect() {
  local dir before err rc
  dir=$(make_case refusal)
  fixture_1331 > "$dir/body.md"
  before=$(state_snapshot "$dir/home/state")
  set +e
  FM_TEST_BODY_FILE="$dir/body.md" run_check "$dir" task-a https://github.com/o/r/pull/1 \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 3 "$rc" "description refusal"
  err=$(cat "$dir/err")
  assert_contains "$err" "$EVIDENCE_ROOT/01M08HCNG26R96B3RX8C8H395Y/mcp-transcript.json" \
    "refusal did not name the offending path"
  assert_contains "$err" "McpProbe40127TranscriptCapture.php" "refusal did not name every offending path"
  assert_contains "$err" "evidence-artifacts/SKILL.md" "refusal did not point at the upload recipes"
  assert_contains "$err" "pull request" "refusal used the wrong forge noun"
  [ ! -s "$dir/out" ] || fail "refusal still reported an armed check"
  [ "$(state_snapshot "$dir/home/state")" = "$before" ] || fail "refusal changed task state"
  assert_absent "$dir/home/state/task-a.check.sh" "refusal armed a poll"
  pass "a refusal names every path, points at the recipes, and changes nothing"
}

test_gitlab_refusal_uses_merge_request_wording() {
  local dir rc err
  dir=$(make_case refusal-gitlab)
  fixture_1333 > "$dir/body.md"
  set +e
  FM_TEST_BODY_FILE="$dir/body.md" run_check "$dir" task-a \
    https://gitlab.com/g/sub/p/-/merge_requests/17 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 3 "$rc" "GitLab description refusal"
  err=$(cat "$dir/err")
  assert_contains "$err" "merge request" "GitLab refusal used the wrong forge noun"
  assert_contains "$err" "07-no-config-refused.png" "GitLab refusal did not name the paths"
  pass "both forges are checked, each with its own wording"
}

test_clean_description_arms_unchanged() {
  local dir rc out
  dir=$(make_case clean)
  fixture_1328 > "$dir/body.md"
  set +e
  FM_TEST_BODY_FILE="$dir/body.md" run_check "$dir" task-a https://github.com/o/r/pull/1 \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "clean description"
  out=$(cat "$dir/out")
  assert_contains "$out" "armed: state/task-a.check.sh" "clean description did not arm the poll"
  assert_grep "pr=https://github.com/o/r/pull/1" "$dir/home/state/task-a.meta" \
    "clean description did not record the PR"
  [ ! -s "$dir/err" ] || fail "clean description printed a diagnostic: $(cat "$dir/err")"
  pass "a clean description arms exactly as before"
}

test_unreadable_description_warns_and_proceeds() {
  local dir rc err out
  dir=$(make_case forge-down)
  set +e
  FM_TEST_FORGE_FAIL=1 run_check "$dir" task-a https://github.com/o/r/pull/1 \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "unreadable description must not block"
  out=$(cat "$dir/out")
  err=$(cat "$dir/err")
  assert_contains "$out" "armed: state/task-a.check.sh" "a forge failure blocked the ready report"
  assert_contains "$err" "warning" "a forge failure was silent instead of warning"
  pass "an unreadable description degrades to a warning and the report proceeds"
}

test_merge_path_skips_the_description_check() {
  local dir rc out
  dir=$(make_case merge-path)
  fixture_1331 > "$dir/body.md"
  set +e
  FM_TEST_BODY_FILE="$dir/body.md" run_check "$dir" --no-description-check task-a \
    https://github.com/o/r/pull/1 > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "--no-description-check must record an already-authorized merge"
  out=$(cat "$dir/out")
  assert_contains "$out" "armed: state/task-a.check.sh" "--no-description-check did not record the PR"
  pass "the merge path records metadata without re-litigating the description"
}

test_fixture_1333_refuses_seven_screenshots
test_fixture_1325_refuses_three_non_image_artifacts
test_fixture_1331_refuses_json_and_php_artifacts
test_fixture_1328_passes
test_fixture_703_passes
test_scratch_root_needs_a_second_signal
test_private_roots_always_refuse
test_paths_inside_urls_are_not_local_paths
test_refusal_names_paths_and_leaves_no_side_effect
test_gitlab_refusal_uses_merge_request_wording
test_clean_description_arms_unchanged
test_unreadable_description_warns_and_proceeds
test_merge_path_skips_the_description_check
