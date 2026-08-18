# Pull and merge request description guard verification

Audience: maintainer verification.

This record supports the guarantee that `bin/fm-pr-check.sh` refuses a request
whose description delivers evidence as a local filesystem path, and that it does
so without refusing paths quoted as documentation.
[`bin/fm-pr-description-lib.sh`](../../bin/fm-pr-description-lib.sh) is the
single owner of the rule itself; this record holds what was measured and what
the rule is known not to catch.
Re-run these checks when either forge CLI changes its description output, and
refresh the fixtures when a new false refusal or miss is found in the field.

## Forge description fetch

Verified on 2026-08-18 with `gh version 2.97.0 (2026-07-31)` and
`glab 1.113.0 (d62881304)`.

    gh pr view <number> --repo <owner>/<repo> --json body -q .body
    glab mr view <number> -R <host>/<project-path> -F json --jq .description

Both return the description on stdout and exit 0.
`glab` carries its own jq implementation, so neither command needs a JSON
processor on PATH, which is what keeps this off firstmate's dependency list.

Both are run under [`bin/fm-timeout-lib.sh`](../../bin/fm-timeout-lib.sh)'s
`fm_run_timed`, bounded by `FM_PR_DESCRIPTION_TIMEOUT` (20 seconds by default),
because a forge that accepts the connection and then never answers cannot be
detected by an exit status. A hit bound returns 124 and is treated as any other
fetch failure.

Failure exits non-zero with no usable stdout, which is what the guard's
degrade-to-warning path relies on:

    $ gh pr view 999999 --repo <owner>/<repo> --json body -q .body >/dev/null 2>&1; echo $?
    1
    $ glab mr view 999999 -R <host>/<project-path> -F json --jq .description >/dev/null 2>&1; echo $?
    1
    $ glab mr view 703 -R <host>/<absent-project> -F json --jq .description >/dev/null 2>&1; echo $?
    1

The plain `glab mr view` fallback prints a short header block (title, state,
author, labels, assignees, reviewers, comments, number, url) followed by `--`
and then the description verbatim.
Scanning that header costs nothing because none of its fields carry a
filesystem path.

## Measured discrimination

Verified on 2026-08-18 against the descriptions of five real merge requests on
one GitLab instance, across two projects, each read from the forge and each
checked by hand first.
Four delivered evidence as local paths; one quotes a local path inside a CI
template it documents.
The four defective bodies have since been corrected in place, so
`tests/fm-pr-description-guard.test.sh` carries their relevant fragments, with
every structural feature preserved and the project nouns neutralised.

| body | contains | verdict | paths named |
| --- | --- | --- | --- |
| !1333 | 7 screenshots under a run's scratch directory | refuse | 7 |
| !1325 | 3 evidence files: YAML and JSON | refuse | 3 |
| !1331 | 2 evidence files: JSON and PHP | refuse | 2 |
| !1328 | nothing | pass | 0 |
| !703 | `/tmp/glab.tgz` in a quoted shell snippet | pass | 0 |

!703 is the one that matters: a prefix match on `/tmp/` flags it, and firstmate
would then have "fixed" a documented install command inside someone's CI
template.

The corrected form of the same bodies also passes.
A GitLab `/uploads/<32-hex>/<name>` link carries an opaque segment and would be
refused by the shape rule alone; it survives only because the root prefilter
never considers it, which is why that prefilter is load-bearing rather than
decorative.

Reproduce in the repo:

    $ bash tests/fm-pr-description-guard.test.sh
    ok - !1333: seven screenshot paths refused, its relative shots/ index untouched
    ok - !1325: three YAML/JSON evidence paths refused, fenced or not
    ok - !1331: JSON transcript and PHP capture script both refused
    ok - !1328: a clean description and correct /uploads/ links pass
    ok - !703: quoted CI install commands under /tmp pass
    ok - a shared scratch root refuses only when stamped or delivered
    ok - a user home or file:// URL is refused with no second signal
    ok - a /home or /tmp segment inside a URL is not a local path
    ok - a /private twin decides as its canonical root, and nothing else does
    ok - a refused twin path is named exactly as the description wrote it
    ok - a refusal names every path, points at the recipes, and changes nothing
    ok - both forges are checked, each with its own wording
    ok - a clean description arms exactly as before
    ok - an unreadable description degrades to a warning and the report proceeds
    ok - a forge that never answers times out to a warning and the report arms
    ok - the merge path records metadata without re-litigating the description

A 16,726-byte real GitHub pull request body from this repo was scanned on the
same date and produced no findings, so the rule does not fire on ordinary
firstmate release prose.

End to end through the real CLIs on 2026-08-18, against a throwaway `FM_HOME`
and both live forges:

    $ bin/fm-pr-check.sh t1 <live merge request URL>
    armed: state/t1.check.sh
    $ bin/fm-pr-check.sh t2 <live pull request URL>
    armed: state/t2.check.sh
    $ bin/fm-pr-check.sh t3 <pull request URL that does not exist>
    warning: could not read the description; the local-path check was skipped
    armed: state/t3.check.sh

The refusal itself is proven end to end in the test above rather than against a
live forge, because all four defective bodies were corrected before this guard
existed and none can be re-created without publishing a broken description.

## What this misses

Every rule here fails in both directions, and choosing where was deliberate: a
guard that cries wolf gets ignored, which is worse than the defect it prevents.
The two directions are listed separately below, because a reader needs to see
which side each case falls on.

### False negatives - a local path that passes

- **A plain scratch path in prose.** `written to /tmp/report.json`, with no
  run-stamped segment and no link syntax, passes. It is indistinguishable in
  shape from `curl -o /tmp/glab.tgz`, and refusing both would refuse !703.
- **Reproducible-looking evidence directories.** `/tmp/pytest-of-user/run/x.png`
  has no segment long enough to read as machine-generated, so it passes.
- **Run stamps that carry no letters.** `/tmp/run-1755500000/x.png` is a
  ten-digit epoch stamp, and the opacity rule wants at least two letters as well
  as two digits in the same run, so it passes.
- **Hyphen-split identifiers.** `/tmp/evidence/550e8400-e29b-41d4-a716-446655440000/x.png`
  is unmistakably machine-generated, but every run between its hyphens is under
  ten characters, so no single run clears the threshold and it passes.
- **Short mktemp suffixes.** `/tmp/fm-evidence.Ab3kZq/x.png` carries the standard
  six-character `mktemp` template, which never reaches ten characters, so it
  passes. The opacity rule reaches run ids and ULIDs, not plain `mktemp` names.
- **Markdown reference definitions.** A reference-style link, `[shot]: /tmp/shot.png`
  on its own line, is a genuine delivery position but is not recognised as one:
  only the inline `](target)` form is. Matching the reference shape would also
  catch ordinary prose that ends a bracketed label with a colon before a path,
  and a false refusal costs more here than a miss. The HTML half of this gap is
  closed - `src=` and `href=` match in either case, because HTML attribute names
  are case-insensitive and both forges render raw HTML in a description.
- **Machine-local paths outside the known roots.** An evidence tool writing to
  `/opt/evidence/<run-id>/` or `/srv/…` is never considered, because the opacity
  test is applied only under the candidate roots. Widening it refuses the
  correct GitLab `/uploads/<hash>/` form, so the roots stay.
- **Home paths written through a variable.** `~/out.png` and `$HOME/out.png`
  pass on purpose: `~/.config/tool.yml` is routinely documented as a location
  the reader has too, and refusing it would be a false refusal.
- **Windows paths.** `C:\Users\…` and UNC paths are not detected.
- **Relative targets.** A markdown image whose target is a repository-relative
  path renders broken in a GitHub pull request body but is legitimate
  elsewhere, so it is out of scope here;
  [`.agents/skills/evidence-artifacts/SKILL.md`](../../.agents/skills/evidence-artifacts/SKILL.md)
  owns that trap.
- **A refused path containing a space is named only up to that space.** A path
  token stops at the first character a path cannot contain, and a space is one of
  them, so `see /Users/me/a b/out.png` is correctly refused but reported as
  `/Users/me/a`. The author is then handed a string they cannot find verbatim in
  their own description. Widening the character class to admit spaces would
  swallow the surrounding prose into every token, so this is an accepted
  tradeoff; the refusal header still says what kind of problem to look for.
- **A path that is present but unreachable.** The guard proves the reader was
  not handed a local path. It cannot prove an uploaded link actually renders.
- **Anything it cannot read.** An unreachable forge, a missing CLI, an
  unsupported provider, or a forge that does not answer inside
  `FM_PR_DESCRIPTION_TIMEOUT` seconds degrades to a warning and the ready report
  proceeds. The guard is a measurement, not a gate that survives being blinded.

### False refusals - a quoted path that is refused anyway

These are the accepted cost of the minimum root set. They are decisions, not
oversights.

- **A home-root path quoted as documentation.** A GitHub Actions log excerpt
  naming `/home/runner/work/<repo>/<repo>/out.log` in prose is refused with no
  second signal, because a home root is private by shape and `/home/` is part of
  the required minimum root set. The refusal text tells the author to upload each
  artifact, which does not fit a path that was only being quoted, and
  [`AGENTS.md`](../../AGENTS.md) forbids bypassing the refusal, so the author has
  to reword the excerpt - eliding the runner prefix, or quoting the file name
  alone. Home roots sit in the same private-by-shape class as `/var/folders`,
  which is where the 2026-08-18 defect actually shipped, so weakening that class
  to require a second signal was not on the table.
