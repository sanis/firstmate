#!/usr/bin/env node
// Semantic policy for the cd-guard: does a shell command persistently change the
// PRIMARY firstmate shell's own working directory?
//
// A stray persistent top-level `cd projects/<clone>` silently relocates the
// primary shell, so the next firstmate-owned command (a backlog write, an
// fm-* lifecycle call, tasks-axi) runs inside a project clone instead of the
// home. This policy blocks exactly that class of command; the environmental
// scoping to the real primary checkout lives in the bin/fm-cd-pretool-check.sh
// transport, not here. See docs/cd-guard.md for the full contract.
//
// One narrow exemption: a bare `cd` whose single argument provably resolves to
// the firstmate home root is allowed, because the home is exactly where the
// primary shell belongs and moving INTO it cannot cause the drift this guard
// exists to stop. The transport passes that root with --root; without it no
// command is ever exempt, so the guard degrades to its pre-exemption behavior
// rather than to a weaker one.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "persistent-cd":
    "a persistent top-level directory change in the primary firstmate checkout is blocked; it would move the shell out of the home so a later firstmate-owned command runs inside a project clone. Reach the target without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...).",
};

// Directory-changing builtins that mutate the calling shell's own cwd.
const CD_BUILTINS = new Set(["cd", "pushd", "popd"]);

// Wrappers that fork or exec a child before reaching the builtin, so a cd behind
// them never persists to the parent shell (and generally just fails, since cd is
// a builtin with no external program). `command` is deliberately NOT here: it
// runs the builtin in the current shell, so `command cd x` still persists.
const FORKING_WRAPPERS = new Set(["env", "sudo", "nohup", "timeout", "gtimeout", "exec"]);

// Quoting forms this classifier decodes into a cooked word value. Their
// presence anywhere in the command withdraws the home exemption, because a
// relaxation must never rest on a value bash could decode differently. This
// marker set is COUPLED to the decoder set in bin/fm-arm-command-policy.mjs and
// to the transport prefilter in bin/fm-cd-pretool-check.sh: a new decoded quote
// form REQUIRES extending all three in the same change.
const QUOTING_DECODER_MARKERS = ["$'", '$"'];

// Characters that make a word's real value depend on shell expansion the
// classifier deliberately never performs: parameter and command substitution,
// tilde expansion, and pathname expansion. A target carrying any of them cannot
// be proven equal to the home root, so it is never exempt.
const UNPROVABLE_TARGET = /[$`~*?[\]{}]/;

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// A top-level command-list node persists its cwd change to the parent shell
// unless it runs in a subshell context: backgrounded with a trailing `&`, or a
// stage of a pipeline (bash runs every pipeline stage in a subshell).
function nodePersists(separators, index) {
  if (separators[index] === "&") return false;
  if (isPipe(separators[index]) || isPipe(separators[index - 1])) return false;
  return true;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

// The whole home-root exemption, in one predicate so its conditions cannot
// drift apart. True only for a bare `cd <home root>`: no leading assignment, no
// wrapper, no `builtin`/`command` prefix, exactly one argument word, and that
// word an unexpanded absolute literal that normalizes to the supplied home
// root. Anything else - including a subdirectory of the home, a project clone
// under it, `pushd`/`popd` in any form, and every argument shape whose value
// the shell would compute rather than take literally - stays denied.
function isExemptHomeCd(position, wordIndex, homeRoot, decoderMarker) {
  if (!homeRoot || decoderMarker) return false;
  if (position.index !== 0 || wordIndex !== 0) return false;
  if (position.wrappers.length > 0) return false;
  if (position.words.length !== 2) return false;
  if (position.words[0].value !== "cd") return false;
  const target = position.words[1];
  if (!target.literal || target.subs.length > 0 || target.unquotedExpansion) return false;
  if (UNPROVABLE_TARGET.test(target.value)) return false;
  // Required before normalizing: path.resolve consults process.cwd() for a
  // relative input, and this policy must never resolve a target against a cwd
  // that is not the shell's own.
  if (!path.isAbsolute(target.value)) return false;
  // A `.` or `..` component lands somewhere else under `set -P` than under
  // bash's default logical cd when a symlink sits on the path, so no such
  // target is provable. Rejecting them leaves path.resolve collapsing only
  // duplicate and trailing slashes, which no shell mode changes.
  if (target.value.split("/").some((segment) => segment === "." || segment === "..")) return false;
  return path.resolve(target.value) === homeRoot;
}

function hasPathQualifiedCommandPrefix(position) {
  return position.words
    .slice(position.prefixAssignments, position.index)
    .some((word) => word.value.includes("/") && word.value.split("/").at(-1) === "command");
}

function hasCommandQueryPrefix(position) {
  let commandPrefix = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (word.value === "command") {
      commandPrefix = true;
      continue;
    }
    if (commandPrefix && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

function decision(command, root = "") {
  const homeRoot = root && path.isAbsolute(root) ? path.resolve(root) : "";
  const decoderMarker = QUOTING_DECODER_MARKERS.some((marker) => command.includes(marker));
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The cd-guard's threat
  // model is agent mistakes - an accidental bare `cd projects/foo` always
  // tokenizes - so we prioritize zero false blocks over catching malformed or
  // deliberately obfuscated bypasses, which stay out of scope by design.
  if (lexed.error) return { decision: "allow" };

  const { nodes, separators } = splitProgram(lexed.tokens);
  for (let index = 0; index < nodes.length; index += 1) {
    if (!nodePersists(separators, index)) continue;
    // commandPosition ignores subshell/brace groups, quoted data, comments, and
    // substitutions (they contribute no top-level command word), and skips
    // leading assignments and wrappers to find the executed command word.
    const position = commandPosition(nodes[index]);
    if (hasPathQualifiedCommandPrefix(position)) continue;
    if (hasCommandQueryPrefix(position)) continue;
    let command = position.command;
    let wordIndex = position.index;
    while (command && (command.value === "builtin" || command.value === "command")) {
      wordIndex += 1;
      command = position.words[wordIndex];
    }
    if (!command) continue;
    if (!CD_BUILTINS.has(command.value)) continue;
    if (position.wrappers.some((wrapper) => FORKING_WRAPPERS.has(wrapper))) continue;
    if (isExemptHomeCd(position, wordIndex, homeRoot, decoderMarker)) continue;
    return deny("persistent-cd");
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, root: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name === "--root") {
      if (i + 1 >= argv.length) throw new Error("--root requires a value");
      result.root = argv[i + 1];
      i += 1;
      continue;
    }
    if (name.startsWith("--root=")) {
      result.root = name.slice("--root=".length);
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.root);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
