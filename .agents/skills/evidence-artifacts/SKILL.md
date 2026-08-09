---
name: evidence-artifacts
description: >-
  Agent-only procedure for delivering screenshots and other evidence files to a reader who is not on the machine that produced them.
  Use before putting visual or file evidence into a pull request, a merge request, or a ClickUp update, and whenever delivered evidence would otherwise be named by a local file path.
user-invocable: false
metadata:
  internal: true
---

# evidence-artifacts

This skill is the single owner of how an evidence artifact reaches its reader.
It covers screenshots, recordings, and any other file offered as proof rather than described in prose.

## The contract

Evidence presented on a surface must be uploaded to that surface and embedded so it renders there.
A path on the machine that produced the artifact is never the delivered form, because the reader cannot open it.
This binds every actor: a crewmate writing its own pull or merge request, and firstmate writing a tracker update.

The contract applies wherever the reader is somewhere else.
A scout report is exempt, because firstmate reads it on the same machine that wrote it.

Prose still carries the finding.
The artifact proves a claim the text already makes; it never replaces making it.
Upload only what that surface's readers were already entitled to see, because evidence from a private system keeps the audience it had before it became a screenshot.

The per-surface mechanics below are verified.
[`docs/verification/evidence-artifacts.md`](../../../docs/verification/evidence-artifacts.md) holds the dated commands and output, and is the place to re-prove them when a vendor surface changes.

## GitHub pull requests

GitHub exposes no API for attaching an image to a pull request, so neither `gh-axi` nor `gh api` can reach one; the web interface does it by drag and drop.
Deliver the artifact by committing it on the pull request's own branch and embedding a commit-pinned URL:

    ![what it shows](https://github.com/<owner>/<repo>/raw/<commit-sha>/<path>)

Commit it under `docs/verification/` in the repository being changed, so evidence lands in one predictable place instead of wherever each worker improvises.

Use that host-absolute `github.com` form, and no other:

- A relative image target such as `docs/evidence/x.png` does NOT work in a pull request body.
  GitHub leaves it relative, the browser resolves it against the pull request URL, and the reader gets a broken image.
- `https://raw.githubusercontent.com/...` renders on a public repository but is BROKEN on a private one, because a reader's github.com session does not authenticate that separate host.
  It is the trap form: it looks correct while testing against anything public.
- `https://github.com/<owner>/<repo>/blob/<commit-sha>/<path>?raw=1` is equivalent to the `raw` form and also renders on both.
- Pin the commit sha rather than a branch name.
  A sha-pinned URL keeps serving after the head branch is deleted, because GitHub retains the pull request's head reference.

If committing the artifact into that project's history is unwanted, the decision is above the implementation worker: report it to firstmate rather than degrading to a local path.
Committing is unretractable: the pinned artifact keeps serving after the pull request is closed and its branch is deleted, so what may be written into a repository forever is a separate question from what a reader may see today.
Stop and ask firstmate instead of committing when the repository constrains committed binaries - a declared binary-size limit, Git LFS routing, or any other artifact policy in its `AGENTS.md`, `CONTRIBUTING`, or `.gitattributes` - or when the capture shows credentials, personal data, or a third-party system.

## GitLab merge requests

`glab-axi` cannot upload, because its `api` command sends only `--field`, `--raw-field`, and `--header` and has no multipart form.
Use `glab` directly, and note that `-F` is its typed-parameter flag rather than a multipart flag, so `-F "file=@<path>"` fails with HTTP 400:

    glab api --method POST "projects/<url-encoded-project-path>/uploads" --form "file=@<path>"

The response's `markdown` field is ready to paste into the merge request description or a comment.
It is a project-relative `/uploads/<hash>/<name>` link that GitLab expands into that project's absolute upload URL when it renders in that project's context.
Upload to the project that owns the merge request, because the same link pasted into a different project does not resolve.

## ClickUp

`clickup-axi` exposes no attachment command, so the upload runs through the claude.ai ClickUp connector.
The `clickup` skill owns which session may call that connector and when these updates are posted; this section owns only how the artifact gets there.

- `clickup_attach_task_file` takes base64 `file_data` plus `file_name`, and is limited to small files, roughly under 200KB, which most screenshots exceed.
- `clickup_request_attachment_upload` handles a local file of any size.
  It returns a short-lived upload URL, ticket, HTTP method, and multipart field name, together with its own `instructions`.
  Follow those returned instructions rather than a memorized recipe, because they are what the connector currently expects and the ticket expires quickly.

Attach the artifact to the ClickUp task itself, then name the attached files in the milestone comment.
`clickup_create_comment` takes text only and has no attachment parameter, so the task attachment, not the comment body, is what carries the evidence to the reader.

## Relay

A public reply already has its own upload path.
`fmx-respond` owns the `--image` contract for Relay replies and follow-ups; do not apply the forge recipes above to it.

## When an upload is genuinely impossible

Say so plainly on the surface, name where the evidence actually lives, and route the gap to firstmate.
An honest statement that the artifact could not be embedded is an acceptable outcome.
A local file path presented as though the reader could open it is the one outcome this skill exists to prevent.
