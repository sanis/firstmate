#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the cd-guard PreToolUse seatbelt (docs/cd-guard.md).
#
# bin/fm-cd-command-policy.mjs is the single owner of the block/allow decision;
# it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-cd-pretool-check.sh is the stable transport: it scopes the guard to the
# real primary checkout, then drives all five harness entry forms. This suite
# proves the decision matrix, the harness-output shaping, the primary-checkout
# scoping (including the deliberate secondmate-home difference from the turn-end
# guard), the home-root exemption and its exact boundary, the fail-open
# transport behavior, the prefilter fast path, the end-to-end cwd-leak
# regression, and the per-harness wiring. No harness is spawned; live
# per-harness evidence lives in docs/cd-guard.md.
#
# The cross-harness matrix and the home-exemption boundary cover two orthogonal
# axes, so they are deliberately separate. The matrix proves every entry form
# shapes the same decision identically, including that the transport hands the
# policy its home root on all five. The boundary suite then walks the many
# argument shapes that must NOT earn the exemption through one entry form,
# because the shape of the argument is a decision-owner concern that cannot vary
# by transport.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-cd-pretool-check)

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/ with
# the transport plus both policy files (fm-cd-command-policy.mjs imports the
# shared classifier from fm-arm-command-policy.mjs). This is what the transport's
# scoping treats as the real primary firstmate checkout.
install_cd_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-command-policy.mjs"
}

make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape as primary plus the .fm-secondmate-home marker: a secondmate's own
# primary session, which the cd-guard DOES guard (unlike the turn-end guard).
make_secondmate_fixture() {
  local dir=$1
  make_primary_fixture "$dir" >/dev/null
  printf 'sm-cd-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree - the shape bin/fm-spawn.sh hands crewmate/scout
# tasks. git-dir and git-common-dir differ, so the guard must be inert.
make_child_worktree_fixture() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/cd-guard-test-branch
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
CHECK="$PRIMARY/bin/fm-cd-pretool-check.sh"
# The transport resolves its root with `pwd -P`, so the home exemption can only
# ever match the fixture's physical spelling. On macOS $TMPDIR reaches the same
# directory through a /var -> /private/var symlink, which is exactly the
# non-matching spelling test_home_exemption_needs_the_exact_root pins as denied.
PRIMARY_PHYS=$(cd "$PRIMARY" && pwd -P)

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

# BLOCK: a persistent top-level cwd change in the parent shell.
matrix_case B01 deny 'cd projects/foo'
matrix_case B02 deny 'cd ..'
matrix_case B03 deny 'cd'
matrix_case B04 deny 'cd -'
matrix_case B05 deny 'cd /abs/path'
matrix_case B06 deny 'pushd projects/foo'
matrix_case B07 deny 'popd'
matrix_case B08 deny 'X=1 cd projects/foo'
matrix_case B09 deny 'cd projects/foo && tasks-axi add x'
matrix_case B10 deny 'echo before; cd projects/foo'
matrix_case B11 deny 'true && cd projects/foo'
matrix_case B12 deny 'tasks-axi done x || cd projects/foo'
matrix_case B13 deny 'cd "projects/foo"'
matrix_case B14 deny '"cd" projects/foo'
matrix_case B15 deny 'sleep 1 & cd projects/foo'
matrix_case B16 deny 'command cd projects/foo'
matrix_case B17 deny 'cd projects/foo >/dev/null'
matrix_case B18 deny $'cd projects/foo\necho done'
matrix_case B19 deny "\$'\\143d' projects/foo"
matrix_case B20 deny "c'd' projects/foo"
matrix_case B21 deny 'c"d" projects/foo'
matrix_case B22 deny 'c\d projects/foo'
matrix_case B23 deny 'builtin cd projects/foo'
matrix_case B24 deny 'command builtin cd projects/foo'
matrix_case B25 deny 'builtin command cd projects/foo'
matrix_case B26 deny 'command -p cd projects/foo'
matrix_case B27 deny 'command -- cd projects/foo'

# ALLOW: not a persistent top-level cwd change (scoped, data, or non-cd).
matrix_case A01 allow 'git -C projects/foo status'
matrix_case A02 allow 'cat /abs/path/file'
matrix_case A03 allow 'ls projects/foo'
matrix_case A04 allow 'echo "cd projects/foo"'
matrix_case A05 allow 'grep cd file'
matrix_case A06 allow '(cd projects/foo && pwd)'
matrix_case A07 allow "bash -c 'cd projects/foo'"
matrix_case A08 allow 'env -C projects/foo make'
matrix_case A09 allow 'make -C projects/foo build'
matrix_case A10 allow 'find . -execdir cd {} \;'
matrix_case A11 allow 'cd projects/foo | cat'
matrix_case A12 allow 'cat foo | cd bar'
matrix_case A13 allow 'cd projects/foo &'
matrix_case A14 allow 'abcd project'
matrix_case A15 allow 'cdk deploy'
matrix_case A16 allow 'env cd projects/foo'
matrix_case A17 allow 'sudo cd projects/foo'
matrix_case A18 allow 'x=$(cd foo && pwd)'
matrix_case A19 allow 'dirs'
matrix_case A20 allow "echo 'pushd x'"
matrix_case A21 allow 'git checkout main'
matrix_case A22 allow "sh -c 'cd projects/foo && ls'"
matrix_case A23 allow "printf '%s\\n' 'cd projects/foo'"
matrix_case A24 allow 'ls -la'
matrix_case A25 allow './cd projects/foo'
matrix_case A26 allow '/tmp/cd projects/foo'
matrix_case A27 allow '/usr/bin/cd projects/foo'
matrix_case A28 allow './builtin cd projects/foo'
matrix_case A29 allow 'c\d\ projects/foo'
matrix_case A30 allow './command cd projects/foo'
matrix_case A31 allow '/usr/bin/command cd projects/foo'
matrix_case A32 allow '/tmp/builtin cd projects/foo'
matrix_case A33 allow 'command -v cd'
matrix_case A34 allow 'command -V cd'
matrix_case A35 allow 'command -pv cd'
matrix_case A36 allow 'command -vp cd'

# HOME EXEMPTION across every entry form: a persistent cd INTO the home root is
# allowed because it cannot move the shell out of the home, while a cd deeper
# into the home stays denied. These prove the transport hands the policy its
# home root on all five entry forms; test_home_exemption_boundary owns the
# argument shapes that must not earn the exemption.
matrix_case H01 allow "cd $PRIMARY_PHYS"
matrix_case H02 allow "cd $PRIMARY_PHYS && tasks-axi list"
matrix_case H03 deny "cd $PRIMARY_PHYS/projects/clone"

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-cd-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[persistent-cd\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the persistent-cd reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "cd-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 5 harness entry forms, block/allow all correct"
}

# --- home-root exemption boundary ------------------------------------------

# One entry form is enough here: the matrix already proves all five agree.
expect_cd_decision() {
  local expected=$1 label=$2 cmd=$3 out rc
  out=$("$CHECK" --claude --command "$cmd" 2>&1); rc=$?
  if [ "$expected" = allow ]; then
    expect_code 0 "$rc" "$label must be allowed"
    [ -z "$out" ] || fail "$label allow must produce no output: $out"
    return
  fi
  expect_code 2 "$rc" "$label must stay denied"
  assert_contains "$out" '[persistent-cd]' "$label deny must carry the reason code"
}

test_home_exemption_boundary() {
  # Allowed: exactly one literal argument that resolves to the home root.
  expect_cd_decision allow 'bare cd to the home root' "cd $PRIMARY_PHYS"
  expect_cd_decision allow 'cd home, single-quoted' "cd '$PRIMARY_PHYS'"
  expect_cd_decision allow 'cd home, double-quoted' "cd \"$PRIMARY_PHYS\""
  expect_cd_decision allow 'cd home with a trailing slash' "cd $PRIMARY_PHYS/"
  expect_cd_decision allow 'cd home then another command' "cd $PRIMARY_PHYS && tasks-axi list"
  expect_cd_decision allow 'cd home in a subshell' "(cd $PRIMARY_PHYS && tasks-axi list)"

  # Denied: not one literal argument.
  expect_cd_decision deny 'bare cd' 'cd'
  expect_cd_decision deny 'cd -' 'cd -'
  expect_cd_decision deny 'cd --' 'cd --'
  expect_cd_decision deny 'cd with two arguments' "cd $PRIMARY_PHYS $PRIMARY_PHYS"
  expect_cd_decision deny 'cd home plus a trailing word' "cd $PRIMARY_PHYS extra"

  # Denied: the argument's real value would come from shell expansion.
  expect_cd_decision deny 'cd through a variable' 'cd $FM_HOME'
  expect_cd_decision deny 'cd through a command substitution' "cd \$(echo $PRIMARY_PHYS)"
  expect_cd_decision deny 'cd through a backtick substitution' "cd \`echo $PRIMARY_PHYS\`"
  expect_cd_decision deny 'cd through tilde expansion' 'cd ~'
  expect_cd_decision deny 'cd through a tilde-rooted path' 'cd ~/firstmate'
  expect_cd_decision deny 'cd home with a trailing glob star' "cd $PRIMARY_PHYS*"
  expect_cd_decision deny 'cd home with a glob question mark' "cd $PRIMARY_PHYS?"
  expect_cd_decision deny 'cd home with a bracket glob' "cd ${PRIMARY_PHYS}[12]"
  expect_cd_decision deny 'cd home with a brace expansion' "cd $PRIMARY_PHYS{,x}"

  # Denied: quoting forms this classifier decodes. The exemption never rests on
  # a value bash could decode differently.
  expect_cd_decision deny 'cd home in ANSI-C quoting' "cd \$'$PRIMARY_PHYS'"
  expect_cd_decision deny 'cd home in locale quoting' "cd \$\"$PRIMARY_PHYS\""

  # Denied: pushd/popd are untouched by the exemption in every form.
  expect_cd_decision deny 'pushd to the home root' "pushd $PRIMARY_PHYS"
  expect_cd_decision deny 'bare pushd' 'pushd'
  expect_cd_decision deny 'popd with the home root' "popd $PRIMARY_PHYS"

  # Denied: a shell function definition named cd.
  expect_cd_decision deny 'a cd function definition' 'cd() { builtin cd "$@"; }'

  # Denied: any target that is not the home root itself.
  expect_cd_decision deny 'cd into a project clone under the home' "cd $PRIMARY_PHYS/projects/clone"
  expect_cd_decision deny 'cd into a subdirectory of the home' "cd $PRIMARY_PHYS/bin"
  expect_cd_decision deny 'cd above the home' "cd ${PRIMARY_PHYS%/*}"
  expect_cd_decision deny 'cd home via a .. component' "cd $PRIMARY_PHYS/projects/.."
  expect_cd_decision deny 'cd home via a . component' "cd $PRIMARY_PHYS/."
  expect_cd_decision deny 'a relative cd that cannot be resolved' 'cd projects/clone'

  # Denied: the exemption covers a bare cd only, not a prefixed or wrapped one.
  expect_cd_decision deny 'builtin cd to the home root' "builtin cd $PRIMARY_PHYS"
  expect_cd_decision deny 'command cd to the home root' "command cd $PRIMARY_PHYS"
  expect_cd_decision deny 'an assignment-prefixed cd to the home root' "X=1 cd $PRIMARY_PHYS"

  # Denied: the exemption is per node, so a later deniable cd still blocks.
  expect_cd_decision deny 'cd home followed by cd into a clone' \
    "cd $PRIMARY_PHYS && cd $PRIMARY_PHYS/projects/clone"

  pass "cd-guard: cd into the home root is allowed and every other cd shape stays denied"
}

test_home_exemption_needs_the_exact_root() {
  local link
  link="$TMP_ROOT/primary-symlink"
  ln -s "$PRIMARY_PHYS" "$link"
  # The exemption compares normalized paths, never filesystem identity: a
  # symlink that reaches the home is a different path and stays denied.
  expect_cd_decision deny 'cd home through a symlink' "cd $link"
  pass "cd-guard: the home exemption matches the resolved root path, not another route to it"
}

# --- primary-checkout scoping ----------------------------------------------

test_fires_in_secondmate_home() {
  local dir out rc
  dir=$(make_secondmate_fixture "$TMP_ROOT/secondmate")
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 2 "$rc" "cd-guard must fire in a secondmate's own primary session (unlike the turn-end guard)"
  assert_contains "$out" '[persistent-cd]' "secondmate-home block must carry the reason code"
  pass "cd-guard: fires in a secondmate home (its own primary session is a primary)"
}

test_inert_in_child_worktree() {
  local base dir out rc
  base="$TMP_ROOT/child-base"
  dir="$TMP_ROOT/child-wt"
  make_child_worktree_fixture "$base" "$dir" >/dev/null
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert in a crewmate/scout linked worktree"
  [ -z "$out" ] || fail "cd-guard produced output in a child worktree: $out"
  pass "cd-guard: inert in a crewmate/scout task worktree (linked git worktree)"
}

test_inert_when_not_firstmate_repo() {
  local dir out rc
  dir="$TMP_ROOT/not-firstmate"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  install_cd_scripts "$dir"   # bin/ present but no AGENTS.md
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert without AGENTS.md (not a firstmate checkout)"
  [ -z "$out" ] || fail "cd-guard produced output outside a firstmate checkout: $out"
  pass "cd-guard: inert in a non-firstmate repo (no AGENTS.md)"
}

test_inert_when_not_a_git_repo() {
  local dir out rc
  dir="$TMP_ROOT/no-git"
  mkdir -p "$dir"
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"   # AGENTS.md + bin/ but no git repo
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert when the checkout is not a git repo"
  [ -z "$out" ] || fail "cd-guard produced output in a non-git dir: $out"
  pass "cd-guard: inert when not inside a git repo"
}

# --- end-to-end cwd-leak regression ----------------------------------------

test_e2e_cwd_leak_regression() {
  local sandbox home home_updated leaked out rc
  sandbox="$TMP_ROOT/e2e"
  home="$sandbox/home"
  mkdir -p "$home/data" "$home/projects/clone/data"
  printf '## In flight\n' > "$home/data/backlog.md"

  # Without the guard, the persistent primary shell's cwd leaks: a stray
  # `cd projects/clone` makes the next firstmate-owned backlog write land in the
  # clone, and the home backlog is never updated.
  (
    cd "$home" || fail "cannot enter home"
    cd projects/clone || fail "cannot enter clone"
    printf -- '- [x] demo done\n' >> data/backlog.md
  )
  home_updated=0
  grep -q 'demo done' "$home/data/backlog.md" && home_updated=1
  leaked=0
  grep -q 'demo done' "$home/projects/clone/data/backlog.md" 2>/dev/null && leaked=1
  [ "$home_updated" -eq 0 ] || fail "baseline: home backlog was updated, cwd leak did not reproduce"
  [ "$leaked" -eq 1 ] || fail "baseline: backlog write did not leak into the clone"

  # With the guard, the exact stray command is denied before it can run, so the
  # real harness never lets cwd leave the home.
  out=$("$CHECK" --claude --command 'cd projects/clone' 2>&1); rc=$?
  expect_code 2 "$rc" "guard must deny the stray persistent cd that caused the leak"
  assert_contains "$out" '[persistent-cd]' "leak-preventing block must carry the reason code"
  pass "cd-guard: reproduces the cwd leak and denies the exact command that causes it"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "cd-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json at all' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "cd-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$(PATH="$fakebin" "$CHECK" --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "cd-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # jq deliberately absent: the stdin transport cannot extract the command.
  out=$(printf '{"tool_input":{"command":"cd projects/foo"}}' | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "cd-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path ----------------------------------------------------

test_prefilter_skips_node_without_cd_substring() {
  local dir fakebin marker tool tool_path out rc
  dir="$TMP_ROOT/prefilter"
  make_primary_fixture "$dir" >/dev/null
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter-fake")
  marker="$TMP_ROOT/prefilter-node-called"
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  # No cd/pushd/popd substring: the prefilter must fast-allow before scoping or
  # the policy runtime is ever consulted.
  out=$(PATH="$fakebin" "$dir/bin/fm-cd-pretool-check.sh" --command 'git status' 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no cd/pushd/popd substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "cd-guard: prefilter fast-allows (skips node) when no cd/pushd/popd substring is present"
}

# --- policy CLI contract ----------------------------------------------------

test_policy_cli_direct() {
  local policy
  policy="$ROOT/bin/fm-cd-command-policy.mjs"
  [ "$(node "$policy" --command 'cd projects/foo' | cut -f1)" = deny ] \
    || fail "policy CLI must deny a bare top-level cd"
  [ "$(node "$policy" --command 'git -C projects/foo status')" = allow ] \
    || fail "policy CLI must allow git -C"
  [ "$(node "$policy" --command '(cd projects/foo && pwd)')" = allow ] \
    || fail "policy CLI must allow a subshell-local cd"
  [ "$(node "$policy")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  pass "cd-guard: fm-cd-command-policy.mjs CLI honors the deny/allow output contract"
}

test_policy_cli_root_argument() {
  local policy root_phys
  policy="$ROOT/bin/fm-cd-command-policy.mjs"
  root_phys=$(cd "$ROOT" && pwd -P)
  # Without --root the policy knows of no home, so nothing is exempt. That keeps
  # a caller that forgets the argument on the pre-exemption behavior rather than
  # on a weaker one.
  [ "$(node "$policy" --command "cd $root_phys" | cut -f1)" = deny ] \
    || fail "policy CLI must deny a cd to the home root when no --root is supplied"
  [ "$(node "$policy" --command "cd $root_phys" --root "$root_phys")" = allow ] \
    || fail "policy CLI must allow a cd to the supplied root"
  [ "$(node "$policy" --command "cd $root_phys" --root="$root_phys")" = allow ] \
    || fail "policy CLI must accept the --root=<value> form"
  [ "$(node "$policy" --command "cd $root_phys/bin" --root "$root_phys" | cut -f1)" = deny ] \
    || fail "policy CLI must deny a cd below the supplied root"
  # A relative root cannot anchor a comparison, so it grants no exemption rather
  # than being resolved against this process's cwd.
  [ "$(node "$policy" --command "cd $root_phys" --root bin | cut -f1)" = deny ] \
    || fail "policy CLI must ignore a relative --root instead of resolving it against its own cwd"
  pass "cd-guard: fm-cd-command-policy.mjs --root gates the home exemption"
}

# --- per-harness wiring -----------------------------------------------------

# Delegated to bin/fm-lint.sh, the single owner of the lint definition including
# --external-sources; calling the linter directly here would be a second copy of
# that definition, and would disagree the moment this checker sourced a shared
# library.
test_scripts_are_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-cd-pretool-check.sh" 2>&1) \
    || fail "bin/fm-cd-pretool-check.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-cd-pretool-check.sh is clean under bin/fm-lint.sh"
}

test_full_acceptance_matrix
test_home_exemption_boundary
test_home_exemption_needs_the_exact_root
test_fires_in_secondmate_home
test_inert_in_child_worktree
test_inert_when_not_firstmate_repo
test_inert_when_not_a_git_repo
test_e2e_cwd_leak_regression
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_cd_substring
test_policy_cli_direct
test_policy_cli_root_argument
test_scripts_are_shellcheck_clean
