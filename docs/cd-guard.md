# cd-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the cd-guard PreToolUse seatbelt.
`bin/fm-cd-command-policy.mjs` is the single decision owner.
`bin/fm-cd-pretool-check.sh` is the stable harness transport, primary-checkout scope, and output renderer.
The tracked harness adapters forward command text without classifying it.

It is the third member of a family of primary-session guards that share the same cross-harness hook machinery:
the watcher-arm PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`) and the turn-end supervision guard (`bin/fm-turnend-guard.sh`, `docs/turnend-guard.md`).

## Purpose and boundary

The primary firstmate shell persists its working directory across tool calls.
A stray persistent top-level `cd projects/<clone>` therefore silently relocates the shell, so the next firstmate-owned command - a backlog write, an `fm-*` lifecycle call, `tasks-axi` - runs inside a project clone instead of the home.
That has actually happened: a persistent top-level `cd` caused a firstmate-owned backlog write to execute inside a project clone rather than the home.
The seatbelt denies exactly that command shape - a cwd change that persists to the primary shell - before it runs.
The drift it exists to stop is directional: the hazard is the shell leaving the home, so a `cd` whose target is the home root itself is exempt, as "The home-root exemption" below defines exactly.

This guard is not a general sandbox.
It classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is agent mistakes, the same as the watcher-arm seatbelt: an accidental bare `cd projects/foo`, not a deliberately obfuscated bypass.

## Scope: plain firstmate checkouts only

The guard fires only in a plain firstmate checkout where git-dir equals git-common-dir.
It is a silent no-op (exit 0, no output) everywhere else, so it never interferes with a crewmate or scout that legitimately works inside its own project or firstmate task worktree.

`bin/fm-cd-pretool-check.sh` owns its checkout detection; the turn-end guard's marker-aware scope is a separate contract (`docs/turnend-guard.md`).
A plain, non-worktree checkout has `git rev-parse --git-dir` equal to `git rev-parse --git-common-dir`.
A crewmate or scout task worktree - the shape `bin/fm-spawn.sh` always hands out - is a linked git worktree where the two differ, so the guard is inert there.
The checkout must also carry `AGENTS.md` and `bin/`, and any failure to confirm the primary is treated as inert, never as a block.

The cd-guard does not inspect `.fm-secondmate-home`.
It therefore applies in a git-cloned secondmate home where git-dir equals git-common-dir, but remains inert in a treehouse-leased secondmate home that is itself a linked worktree.
Secondmate child crew and scout worktrees are likewise inert under the linked-worktree test.

## Block vs allow

The discriminator is persistence to the parent shell's cwd, not the mere presence of the token `cd`.

The guard **blocks** a `cd`, `pushd`, or `popd` builtin that runs in an executed top-level position in the parent shell, because such a command persistently changes the primary shell's own working directory, with the single home-root exemption defined below.
This covers a bare `cd projects/foo`, `cd ..`, `cd`, `cd -`, an absolute `cd /some/path` (still a persistent relocation of the parent shell), `pushd <dir>`, `popd`, a leading-assignment form such as `X=1 cd foo`, quoted or escaped command-word fragments that cook to a bare builtin, and any list form where the builtin runs in the parent shell (`cd x && cmd`, `cmd; cd x`, `cmd || cd x`, `command cd x`, `command -p cd x`, `command -- cd x`, `builtin cd x`, `command builtin cd x`, `cd x >/dev/null`, and newline-separated lists).

The guard **allows** everything else, including these safe scoped forms that must never be blocked:

- A command that reaches a target without changing the shell's own cwd: `git -C <dir> ...`, `make -C <dir> ...`, or an absolute path on the command itself.
- A directory change that does not persist to the parent shell: a subshell `(cd x && ...)`, a `bash -c 'cd ...'` / `sh -c` / `zsh -c` payload, an `env -C <dir> ...`, a `find ... -execdir` runner, a pipeline stage (`cd x | cmd`), or a backgrounded `cd x &`.
- A `cd` behind a forking or exec'ing wrapper (`env`, `sudo`, `nohup`, `timeout`, `gtimeout`, `exec`), which runs in a child and never persists (and generally just fails, since `cd` is a builtin with no external program).
- A path-qualified external command named `cd`, `command`, or `builtin`, such as `./cd`, `/usr/bin/cd`, `./command`, `/usr/bin/command`, or `./builtin`, because it runs as a child process and cannot change the parent shell's cwd.
- A `command` query such as `command -v cd`, `command -V cd`, or a clustered form such as `command -pv cd`, because it reports command resolution without executing the named builtin.
- The token `cd` appearing as data: quoted text (`echo "cd projects/foo"`), a comment, a substring of another word (`cdk`, `abcd`, `record`), a `printf` payload, or any later argument word.
- A bare `cd` whose single argument resolves to the firstmate home root itself, under the exact conditions in "The home-root exemption" below.

An absolute-path `cd` to any target other than the home root is blocked on purpose: the ALLOW carve-out for absolute paths is for commands that address a target by absolute path, not for `cd`, which relocates the shell itself regardless of whether its argument is relative or absolute.
Blocking a top-level `cd` is safe in the strong sense: the guard's steady state is "always at the home", so a block never causes a wrong-directory write.

### The home-root exemption

A `cd` whose target is the home root moves the primary shell to exactly where it is supposed to sit, so it cannot produce the drift this guard exists to stop, and blocking it was a false positive.
That one shape is allowed; every other shape the guard denied before is still denied.

`bin/fm-cd-pretool-check.sh` hands the policy the home root as `--root`, reusing the checkout root it has already resolved and validated for its own scoping rather than deriving it a second way.
Supplying the root is transport plumbing only: `bin/fm-cd-command-policy.mjs` remains the sole owner of whether any given target earns the exemption.
Without `--root` the policy knows of no home and exempts nothing, so a caller that omits it falls back to the pre-exemption behavior rather than to a weaker one.
A `--root` value that is not absolute is ignored the same way, because it cannot anchor a comparison and must never be resolved against the policy process's own working directory.

The exemption is deliberately narrow.
It applies only to a node that is a bare `cd` carrying exactly one argument word, and only when that word is an unexpanded absolute literal path differing from the resolved root by nothing but duplicate or trailing slashes.
It is evaluated per node, so `cd <home> && cd projects/foo` is still denied on its second node.
All of the following stay denied exactly as before:

- Bare `cd`, `cd -`, `cd --`, and any `cd` carrying more than one argument.
- Any argument whose real value would come from shell expansion, meaning one containing `$`, a backtick, `~`, or a glob character (`*`, `?`, `[`, `]`, `{`, `}`).
- Any command containing the `$'...'` or `$"..."` quoting forms, because an exemption must never rest on a value bash could decode differently from this classifier.
- Any argument carrying a `.` or `..` component, which lands elsewhere under `set -P` than under bash's default logical `cd` when a symlink sits on the path.
- Any target that is not the root itself, including a subdirectory of the home, a project clone under it, and any other route to the same directory such as a symlink.
- `pushd` and `popd` in every form; the exemption does not touch them.
- A prefixed or wrapped form such as `builtin cd <home>`, `command cd <home>`, or `X=1 cd <home>`.
- A shell function definition such as `cd() { builtin cd "$@"; }`.

The comparison stays lexical.
The policy normalizes the argument and the root as path strings and compares them; it resolves nothing on the filesystem and still evaluates, expands, sources, and runs no byte of the submitted command.
That is why a symlink or any other second route to the home is denied: the exemption proves the spelling of the target, not its destination on disk.

### Accepted non-goals

Consistent with the agent-mistake threat model, the guard deliberately does not chase every obfuscated bypass:

- A `cd` reconstructed by a command substitution (`$(echo c)d x`) or hidden inside a brace group (`{ cd x; }`) is not blocked. Brace-group recursion is avoided because this classifier cannot reliably tell a brace group `{ cd; }` from brace expansion `{cd,foo}`, and a false block there is worse than the missed exotic bypass.
- Malformed or untokenizable syntax fails open (allow). Unlike the watcher-arm seatbelt, which fails closed on unclassifiable protected commands, the cd-guard prioritizes zero false blocks over catching a malformed bypass, because a blocked backlog write is a correctness hazard while a missed exotic `cd` is only the pre-existing status quo.

If a genuinely ambiguous command shape is found that risks a false block, the guard is not extended by guesswork; the ambiguity is escalated and the guard stays precise rather than over-eager.

## Stable reason code

Every deny carries one stable code in square brackets before its prose reason.

| Code | Meaning |
| --- | --- |
| `persistent-cd` | A top-level `cd`/`pushd`/`popd` would persistently change the primary shell's own working directory. |

The reason directs the caller to reach the target without moving the shell by using `git -C <dir>`, placing an absolute path on the intended command itself, or scoping the `cd` to a subshell.
It does not permit `cd /home/project`, because an absolute-path `cd` into a project remains a persistent directory change and is denied.
A `cd` to the home root itself is allowed outright and so never carries this reason.

## Transport and fail-open behavior

`bin/fm-cd-pretool-check.sh` supports every harness-engine entry shape used by the tracked adapters, with pi-signed sharing Pi's shape:

- Claude sends stdin JSON at `.tool_input.command` and adds `--claude` to preserve Claude's stderr-only deny requirement.
- Codex sends stdin JSON at `.tool_input.command` without `--claude`.
- Grok sends stdin JSON at `.toolInput.command`.
- OpenCode sends the exact command string through `--command <exact string>`.
- Pi and pi-signed send the exact command string through `--command <exact string>`.
- Cursor sends stdin JSON at `.tool_input.command` and adds `--cursor`, which renders the deny as Cursor's own returned decision object.

Processing order is cheapest-first: a strict-superset prefilter, then the primary-checkout scope, then the Node policy owner, which receives the scoped checkout root as `--root`.
The prefilter removes ordinary single quotes, double quotes, backslashes, carriage returns, and newlines before fast-allowing any command that carries no `cd`, `pushd`, or `popd` substring and no quoting-decoder marker (`$'` ANSI-C or `$"` locale), so quoted or escaped command-word fragments delegate to the policy while most commands never pay for the git scoping calls or the Node process.
The quoting-decoder marker set is coupled to the classifier's decoder set in `bin/fm-arm-command-policy.mjs`: adding any new quote or expansion form the classifier decodes requires extending the prefilter marker set in the same change, or it stops being a strict superset.
`bin/fm-cd-command-policy.mjs` carries the same marker set a second time, where it withdraws the home-root exemption, so such a change extends both sites and not the prefilter alone.

Empty stdin, unparseable JSON, missing `jq` on the stdin path, missing Node, a missing policy owner, or an invalid policy response all fail open with exit 0 and no output.
A broken hook must never deny every shell tool call.

## Output contract

Identical in shape to `docs/arm-pretool-check.md`:

- Allow (and inert-outside-primary) returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[persistent-cd] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[persistent-cd] reason"}` to stdout for Grok.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- Codex blocks on exit 2 and displays stderr.
- OpenCode throws only when the checker exits 2.
- Pi and pi-signed return `{block: true}` only when the checker exits 2.

## Shared classifier ownership

`bin/fm-cd-command-policy.mjs` imports the shell tokenizer and command-position analysis (`Lexer`, `splitProgram`, `commandPosition`) from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification.
`basename` remains a private helper of the shared arm classifier because the cd policy identifies shell builtins by exact cooked-word identity.
The cd-guard never duplicates shell lexing; it adds only the cd-specific decision on top of that shared classifier.
`bin/fm-arm-command-policy.mjs` runs its own CLI entry point only when invoked directly, never on import, so the two policies stay independent CLIs over one parser.

## Harness wiring

| Harness | Entry | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse Bash hook forwarding stdin with `--claude` | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse hook that anchors from `pwd -P`, verifies the hook-loaded firstmate root, and forwards the payload | Blocks on exit 2 and displays stderr. |
| Grok | `.grok/hooks/fm-primary-cd-check.json` PreToolUse hook anchored on `${GROK_WORKSPACE_ROOT:-}` | Consumes the stdout `decision=deny` object. |
| OpenCode | `.opencode/plugins/fm-primary-cd-check.js` `tool.execute.before` | Throws, which surfaces as the failed tool result. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler | Returns `{block: true}`; piggybacks on the already-loaded primary extension so no extra `-e` flag is needed. |
| Cursor | `.cursor/hooks.json` `preToolUse` hook matching `tool_name` `Shell`, forwarding stdin with `--cursor` | Prints Cursor's own `{"permission":"deny","user_message":...}` object on stdout and exits 0, because Cursor reads the returned object rather than the exit status. Without `--cursor` the Cursor-delivered payload is the Claude-settings duplicate Cursor also loads, and allows; `docs/arm-pretool-check.md` owns that shared predicate. |

Each harness runs the cd-guard alongside the watcher-arm seatbelt; the two are independent checks, and either deny blocks the command.
Every shell variable reference in the Grok hook command carries an inline default (`${GROK_WORKSPACE_ROOT:-}`) because Grok expands the raw hook command before `bash -lc` runs it, the same requirement documented in `docs/arm-pretool-check.md`.

## Automated validation

`tests/fm-cd-pretool-check.test.sh` owns the acceptance matrix.
Every matrix case runs through Codex-shaped stdin, Claude-shaped stdin, Grok-shaped stdin, OpenCode-shaped CLI, and Pi-shaped CLI entry forms.
The home-root exemption is covered on two orthogonal axes.
The matrix carries it through all five entry forms, which is what proves the transport hands the policy its root on each of them.
A dedicated boundary suite then walks every argument shape that must not earn the exemption through a single entry form, because argument shape is a decision-owner concern that cannot vary by transport, and separately pins that a symlink reaching the home is denied.
The suite also proves the end-to-end cwd-leak regression (a firstmate-owned backlog write leaking into a project clone, then denied at the exact command), the checkout scoping (fires in a git-cloned secondmate fixture, inert in a crewmate/scout linked worktree, inert outside a firstmate checkout, inert outside a git repo), the fail-open transport behavior, the prefilter fast path, the policy CLI output contract including how `--root` gates the exemption, and the per-harness wiring.

Run:

```sh
bash -n bin/fm-cd-pretool-check.sh
shellcheck bin/fm-cd-pretool-check.sh tests/fm-cd-pretool-check.test.sh
node --check bin/fm-cd-command-policy.mjs
node --check bin/fm-arm-command-policy.mjs
tests/fm-cd-pretool-check.test.sh
tests/fm-arm-pretool-check.test.sh
```

## Live validation record, 2026-07-11

Each harness ran against a scratch primary-shaped firstmate checkout: a plain git repo with `AGENTS.md`, `bin/` holding the real `fm-cd-pretool-check.sh`, `fm-cd-command-policy.mjs`, and `fm-arm-command-policy.mjs` plus a no-op dummy `fm-arm-pretool-check.sh`, a `projects/foo/` stand-in clone, and the tracked harness hook config.
No live watcher, fleet state, or the captain's real primary checkout was involved.
Each harness was told to run, as separate tool calls, a top-level `cd projects/foo && touch <abs>/BLOCKED` (must be denied) and a subshell `(cd projects/foo && touch <abs>/ALLOWED)` (must run), with the sentinel files as the observable.

Harness versions and outcomes:

- **Claude Code 2.1.207** - blocked. Claude reported the top-level command "denied by the `PreToolUse` hook (`fm-cd-pretool-check.sh`)", the `BLOCKED` sentinel was absent, and the subshell form was permitted to run. A prior control `touch` proved the harness executed commands.
- **codex-cli 0.144.0** - blocked. Codex logged `error=Command blocked by PreToolUse hook: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[persistent-cd] a persistent top-level directory change ..."}`, the `BLOCKED` sentinel was absent, and the subshell `ALLOWED` sentinel was created. Both the arm and cd PreToolUse hooks ran per command (two `hook: PreToolUse Completed` lines), confirming Codex re-feeds the payload to each hook in the array.
- **OpenCode 1.17.18** - blocked. `opencode run` printed `✗ cd projects/foo && touch ... failed` with `Error: {"hookSpecificOutput":...,"permissionDecision":"deny"},"systemMessage":"[persistent-cd] ..."}`, the `BLOCKED` sentinel was absent, and the subshell `ALLOWED` sentinel was created.
- **Pi 0.80.6** - blocked. The `BLOCKED` sentinel was absent while the subshell `ALLOWED` sentinel was created; that differential (top-level denied, subshell run, in the same session) can only come from the guard.
- **grok 0.2.93** - inconclusive live run: the Grok Build API returned `402 Payment Required: Grok Build usage balance exhausted`, so the model never issued the probe commands. The grok cd hook (`.grok/hooks/fm-primary-cd-check.json`) is structurally identical to the arm-seatbelt grok hook already live-validated on 2026-07-09 (`docs/arm-pretool-check.md`) - same `${GROK_WORKSPACE_ROOT:-}` anchoring and same PreToolUse deny consumption - and the grok-shaped stdin path (`.toolInput.command` in, `{"decision":"deny"}` out) is covered by `tests/fm-cd-pretool-check.test.sh`. Re-run once the Grok balance is restored to close the live gap.

The launch commands mirrored `docs/arm-pretool-check.md`'s validation:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO "$PROMPT"
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts --no-context-files --no-session "$PROMPT"
grok --trust -p "$PROMPT" --permission-mode bypassPermissions --output-format plain
```
