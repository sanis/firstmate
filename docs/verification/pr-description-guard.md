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
The `glab` transcripts below were re-run on 2026-08-19 with the same versions
after `-R` moved from a bare `<host>/<project-path>` to the project URL.

    gh pr view <number> --repo <owner>/<repo> --json body -q .body
    glab mr view <number> -R https://<host>/<project-path> -F json --jq .description

Both return the description on stdout and exit 0.
`glab` needs the project URL, not a bare `host/path`: the bare form is answered
by whichever instance `glab` is configured for, so a self-hosted host is
silently dropped from the address.
Measured against a host that cannot resolve, only the URL form dials it:

    $ glab mr view 1 -R bogus.invalid/gitlab-org/cli -F json --jq .description
    {"error":{"message":"failed to get merge request 1: 404 Not Found"}}
    $ glab mr view 1 -R https://bogus.invalid/gitlab-org/cli -F json --jq .description
    {"error":{"message":"failed to get merge request 1: Get \"https://bogus.invalid/api/v4/projects/gitlab-org%2Fcli/merge_requests/1?include_diverged_commits_count=true\u0026include_rebase_in_progress=true\u0026render_html=true\": dial tcp: lookup bogus.invalid: no such host"}}

Both exit 1, so the guard degrades either way, but the bare form would read a
same-path project on the default instance if one existed.
Every transcript in this section was run against public projects so a
maintainer can re-run it verbatim:

    $ gh pr view 7 --repo sanis/firstmate --json body -q .body >/dev/null 2>&1; echo $?
    0
    $ glab mr view 3740 -R https://gitlab.com/gitlab-org/cli -F json --jq .description >/dev/null 2>&1; echo $?
    0

Neither command needs a JSON processor on PATH, which is what keeps one off
firstmate's dependency list.
`gh` answers `-q` and `glab` answers `--jq` from an implementation each carries
internally, measured against a PATH holding only those two CLIs plus `git` and
`sh`:

    $ command -v jq >/dev/null 2>&1 && echo present || echo absent
    absent
    $ glab mr view 3740 -R https://gitlab.com/gitlab-org/cli -F json --jq .description >/dev/null 2>&1; echo $?
    0
    $ gh pr view 7 --repo sanis/firstmate --json body -q .body >/dev/null 2>&1; echo $?
    0

`git` does have to be present: `glab` exits non-zero without it even when the
project is named explicitly with `-R`.
That costs nothing here because firstmate already requires `git`.

Both are run under [`bin/fm-timeout-lib.sh`](../../bin/fm-timeout-lib.sh)'s
`fm_run_timed`, bounded by `FM_PR_DESCRIPTION_TIMEOUT` (20 seconds by default),
because a forge that accepts the connection and then never answers cannot be
detected by an exit status.
A hit bound returns 124 and is treated as any other fetch failure:

    $ fm_run_timed 1 sleep 5 >/dev/null 2>&1; echo $?
    124

Failure exits non-zero with no usable stdout, which is what the guard's
degrade-to-warning path relies on:

    $ gh pr view 999999 --repo sanis/firstmate --json body -q .body >/dev/null 2>&1; echo $?
    1
    $ glab mr view 999999 -R https://gitlab.com/gitlab-org/cli -F json --jq .description >/dev/null 2>&1; echo $?
    1
    $ glab mr view 3740 -R https://gitlab.com/gitlab-org/no-such-project-fm -F json --jq .description >/dev/null 2>&1; echo $?
    1

The plain `glab mr view` fallback prints a short header block, then `--`, then
the description verbatim:

    title:  chore(deps): update module golang.org/x/crypto to v0.55.0
    state:  open
    author: gitlab-dependency-update-bot
    labels: Category:GitLab CLI, automation:bot-authored, ...
    assignees: gitlab-dependency-update-bot
    reviewers: hacks4oats, GitLabDuo
    comments: 3
    number: 3740
    url: https://gitlab.com/gitlab-org/cli/-/merge_requests/3740
    --
    This MR contains the following updates:

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
    ok - attribute-shaped bytes deliver only inside an open tag
    ok - a user home or file:// URL is refused with no second signal
    ok - a /home or /tmp segment inside a URL is not a local path
    ok - a /private twin decides as its canonical root, and nothing else does
    ok - a refused twin path is named exactly as the description wrote it
    ok - a refusal names every path, points at the recipes, and changes nothing
    ok - both forges are checked, each with its own wording
    ok - the GitLab fetch addresses the task's own instance, not glab's default
    ok - a clean description arms exactly as before
    ok - an unreadable description degrades to a warning and the report proceeds
    ok - a forge that never answers times out to a warning and the report arms
    ok - the merge path records metadata without re-litigating the description

Real bodies were scanned on the same date as a field check that the rule does
not fire on ordinary prose.
The three largest pull request bodies in this repo - 9,901, 6,625 and 5,334
bytes - produced no findings, and neither did the 11,199-byte body of the
unrelated public
[`Infisical/ansible-collection#27`](https://github.com/Infisical/ansible-collection/pull/27).

The refusal is also proven against a live forge, not only against the fixtures.
[`Seth-Peters/treebox#41`](https://github.com/Seth-Peters/treebox/pull/41) is an
unrelated public pull request whose 36,986-byte body carries the same evidence
shape the four defective bodies did - artifacts under
`/var/folders/.../no-mistakes-evidence/<run-id>/` - and the scanner names 39
paths in it, read through the real `gh`.
The four defective bodies themselves were corrected before this guard existed
and cannot be re-created without publishing a broken description, so that public
body is what stands in for them end to end.

End to end through the real CLIs on 2026-08-18, against a throwaway `FM_HOME`
and both live forges:

    $ bin/fm-pr-check.sh t1 https://gitlab.com/gitlab-org/cli/-/merge_requests/3740
    armed: state/t1.check.sh
    (exit 0)
    $ bin/fm-pr-check.sh t2 https://github.com/sanis/firstmate/pull/7
    armed: state/t2.check.sh
    (exit 0)
    $ bin/fm-pr-check.sh t3 https://github.com/sanis/firstmate/pull/999999
    warning: could not read the description; the local-path check was skipped
    armed: state/t3.check.sh
    (exit 0)

Each of the three recorded its `pr=` line and armed its poll, so a clean
description on either forge and an unreadable one all leave the ready report
intact.
Unrelated supervision-banner output from
[`bin/fm-guard.sh`](../../bin/fm-guard.sh) is elided above; it is independent of
this check and depends only on where the command was run.

## What this misses

Every rule here fails in both directions, and choosing where was deliberate: a
guard that cries wolf gets ignored, which is worse than the defect it prevents.
The two directions are listed separately below, because a reader needs to see
which side each case falls on.

### False negatives - a local path that passes

- **A plain scratch path in prose.** `written to /tmp/report.json`, with no
  run-stamped segment and no link syntax, passes.
  It is indistinguishable in shape from `curl -o /tmp/glab.tgz`, and refusing
  both would refuse !703.
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
  passes.
  The opacity rule reaches run ids and ULIDs, not plain `mktemp` names.
- **Markdown reference definitions.** A reference-style link, `[shot]: /tmp/shot.png`
  on its own line, is a genuine delivery position but is not recognised as one:
  only the inline `](target)` form is.
  Matching the reference shape would also catch ordinary prose that ends a
  bracketed label with a colon before a path, and a false refusal costs more here
  than a miss.
- **An HTML attribute split across lines.** `src=` and `href=` are matched in
  either case, because HTML attribute names are case-insensitive and both forges
  render raw HTML in a description, but they count as a delivery only inside a
  tag that is still open on the same line.
  An attribute on a continuation line - `<img`, then `src=/tmp/shot.png` on the
  next - is therefore missed.
  That narrowing is deliberate and is what stops `make SRC=/tmp/src` from being
  read as a delivery: without it, an ordinary upper-case build or environment
  variable refuses exactly the documented-command case !703 exists to protect.
  Carrying the open-tag state across lines instead would fix the miss, but a
  single unbalanced `<` anywhere in a fenced code block would then strand every
  later line inside a phantom tag, and that trades a miss for a false refusal.
- **Machine-local paths outside the known roots.** An evidence tool writing to
  `/opt/evidence/<run-id>/` or `/srv/…` is never considered, because the opacity
  test is applied only under the candidate roots.
  Widening it refuses the correct GitLab `/uploads/<hash>/` form, so the roots
  stay.
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
  `/Users/me/a`.
  The author is then handed a string they cannot find verbatim in their own
  description.
  Widening the character class to admit spaces would swallow the surrounding
  prose into every token, so this is an accepted tradeoff; the refusal header
  still says what kind of problem to look for.
- **A path that is present but unreachable.** The guard proves the reader was
  not handed a local path.
  It cannot prove an uploaded link actually renders.
- **Anything it cannot read.** An unreachable forge, a missing CLI, an
  unsupported provider, or a forge that does not answer inside
  `FM_PR_DESCRIPTION_TIMEOUT` seconds degrades to a warning and the ready report
  proceeds.
  The guard is a measurement, not a gate that survives being blinded.

### False refusals - a quoted path that is refused anyway

These are the accepted cost of the minimum root set.
They are decisions, not oversights.

- **A home-root path quoted as documentation.** A GitHub Actions log excerpt
  naming `/home/runner/work/<repo>/<repo>/out.log` in prose is refused with no
  second signal, because a home root is private by shape and `/home/` is part of
  the required minimum root set.
  The refusal text tells the author to upload each artifact, which does not fit
  a path that was only being quoted, and
  [`AGENTS.md`](../../AGENTS.md) forbids bypassing the refusal, so the author has
  to reword the excerpt - eliding the runner prefix, or quoting the file name
  alone.
  Home roots sit in the same private-by-shape class as `/var/folders`, which is
  where the 2026-08-18 defect actually shipped, so weakening that class to
  require a second signal was not on the table.
- **A per-user temp path discussed as the subject matter.** Observed in the
  field, not hypothesised:
  [`kovidgoyal/calibre#3262`](https://github.com/kovidgoyal/calibre/pull/3262)
  is a public pull request *about* `/var` versus `/private/var` resolution, and
  quotes elided paths such as `/var/folders/.../` and
  `/private/var/folders/.../chigb/up.gif` in a log excerpt and in prose.
  The scanner names four of them.
  Nothing is delivered and nothing is unopenable; the paths are the bug being
  described.
  This is the same accepted cost as the home-root case above - a
  private-by-shape root is refused with no second signal - and it is the shape
  most likely to annoy someone whose change is itself about filesystem paths.
  The refusal is a stop, not a silent edit, so the author reads it and reworks
  the excerpt.
