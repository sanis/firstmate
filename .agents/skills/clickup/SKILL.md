---
name: clickup
description: Run one ClickUp-driven task through intake, interview, delegation, and ClickUp lifecycle updates. Use when the captain invokes /clickup (e.g. "/clickup", "pick up a clickup task"), and again whenever a ClickUp-linked firstmate task - one whose backlog record carries a "clickup:" line - reports its PR open with checks green or its PR merged, so the matching ClickUp status and comment updates get posted. Runs entirely in the main firstmate session because the ClickUp connector is a claude.ai session tool unavailable to crewmates; the code work itself is delegated as a normal ship task.
user-invocable: true
metadata:
  internal: true
---

# clickup

Pull exactly one eligible ClickUp task into firstmate's normal delivery lifecycle, and keep its ClickUp record updated at the two lifecycle milestones.
This skill is the single owner of the ClickUp connector procedure, the eligibility filter, the durable-description contract, and the ClickUp-to-firstmate task linkage.
The delivery lifecycle itself - brief, spawn, delivery path, PR, merge authority, cleanup - stays owned by `AGENTS.md` section 7 and is not restated here.

## Runtime constraint: main session only

The ClickUp connector (the `mcp__claude_ai_ClickUp__*` tools) is a claude.ai session tool available only to the main firstmate session, never to a spawned crewmate.
Every ClickUp read and write in this skill therefore happens in the main firstmate session: at `/clickup` invocation and at each later lifecycle milestone.
Never brief a crewmate to call ClickUp, never put ClickUp connector steps in a task brief, and never wait for a crewmate to report ClickUp state.
The crewmate implements the code change through the ordinary lifecycle and knows nothing about ClickUp beyond the task context copied into its instructions.

## Configuration

This skill needs ClickUp parameters that are specific to each firstmate home, so they live in `config/clickup.json` (LOCAL, gitignored) rather than in this shared skill:

- `development_space_id` - the ClickUp space id this pipeline draws tasks from.
- `project_field_id` - the id of the "Project" custom field, a dropdown naming the product a task belongs to.
- `task_creation_lists` - OPTIONAL, LOCAL, gitignored, home-specific; an ordered array of `{ "label": <human name>, "list_id": <ClickUp list id> }` entries naming the backlog lists a newly-created task may be filed under.
  When absent or empty, the create-a-task branch of the flow (step 1 below) asks the captain for a target list id instead of offering configured choices.

Shape:

    {
      "development_space_id": "<space id>",
      "project_field_id": "<custom-field uuid>",
      "task_creation_lists": [
        { "label": "<human name>", "list_id": "<list id>" }
      ]
    }

Read this file at the start of every `/clickup` invocation and reuse its values through the run.
If the file is absent or either required key (`development_space_id`, `project_field_id`) is missing, tell the captain ClickUp is not configured for this home and stop - never guess a space or field id.

## Connector facts

These facts are the authoritative operating parameters for this procedure.

- `clickup_filter_tasks` - filter by tags, statuses, and space.
- `clickup_get_task` - always call with `include: ["description", "custom_fields"]` and `expand_statuses: true`; `available_statuses` in the response lists the statuses that actually exist on that task's list.
- `clickup_get_task_comments` and `clickup_get_threaded_comments` - read all comments (including threads) for context.
- `clickup_resolve_assignees` - resolve `"me"` to the connected user's id.
- `clickup_update_task` - sets `assignees`, `status`, `markdown_description`, `custom_fields`, and `time_estimate`.
- `clickup_create_comment` - post a comment on a task; it takes comment text only and has no attachment parameter.
- `clickup_attach_task_file` and `clickup_request_attachment_upload` - attach a file to a task. `clickup-axi` has no attachment command, so these are the only route. When a milestone update carries a screenshot or other evidence file, follow `evidence-artifacts`, which owns the upload contract and these tools' mechanics.
- The DEVELOPMENT space id and Project custom-field id are not hardcoded here; read them from `config/clickup.json` per the Configuration section above. The Project field is a dropdown naming the product a task belongs to; map its selected value to a registered project via `data/projects.md` (step 4).
- Sprint points is ClickUp's native field and is NOT exposed by this connector: there is no points parameter on update and it does not appear in `custom_fields`.
  Never attempt to write sprint points through the connector; the confirmed estimate is recorded in the description only, under the durable-description contract below.

## Eligibility

A task is eligible only when ALL of these hold:

- It is in the DEVELOPMENT space (the configured `development_space_id`).
- It carries the `firstmate` tag.
- Its status is `to do`.
- It is unassigned, or already assigned to the connected user (resolve `"me"` via `clickup_resolve_assignees` and compare ids).

Never act on a task assigned to someone else, in any step of this skill: no claiming, no status change, no description edit, no comment.

## Status-name safety

Status names vary per ClickUp list.
The four this skill uses - `to do`, `in progress`, `code review`, `qa` - exist across the lists checked at design time, but always confirm against the task's actual `available_statuses` (from `clickup_get_task` with `expand_statuses: true`) before setting any status.
If an expected status name is missing on that task's list, stop, make no status change, and tell the captain which status is missing on which list rather than guessing a substitute.

## The flow - one task per invocation

1. **Find.**
   Filter the configured DEVELOPMENT space for tasks tagged `firstmate` in status `to do`, and keep only eligible ones per the eligibility contract.
   If the captain named a task, use that one (after confirming it is eligible).
   Otherwise pick a sensible default - highest priority first, oldest first among equals - and name the picked task to the captain in plain language.
   When nothing is eligible, or the captain wants to work on something not yet ticketed, OFFER to create a ClickUp task - this is OPTIONAL, never forced - and present it as a choice: create one, or skip and proceed without a task.
   If the captain SKIPS, proceed with the work as an ordinary firstmate task with NO ClickUp linkage - no claim, no status changes, no linkage line, no milestone updates.
   If the captain CHOOSES to create, gather a concise title and description, present the configured `task_creation_lists` labels and have the captain pick one (or supply a list id directly when none are configured), create the task via `clickup_create_task` in the chosen list, then run it through this flow from intake exactly like an existing task (claim, interview, dispatch).
   Create it so it satisfies the same eligibility contract a pickable task must meet: the chosen configured list already sits in the DEVELOPMENT space, so pass the `firstmate` tag and `to do` status to `clickup_create_task` and set the Project custom field in the same call, confirming the status against the list's `available_statuses` first.
   A created task missing the `firstmate` tag or a Project value would not be re-found by a later eligibility scan, so set them at creation rather than after.
   Never hardcode any list id or list name in this skill; creation targets come only from `config/clickup.json`.
2. **Gather context.**
   Read the task with `clickup_get_task` (`include: ["description", "custom_fields"]`, `expand_statuses: true`), all its comments including threads, and the Project custom field.
   Comments and any prior `## firstmate clarifications` section are context: never re-ask anything already answered there.
3. **Claim.**
   If the task is unassigned, assign it to the connected user (`clickup_update_task` with `assignees` set to the resolved `"me"` id).
   If it is already self-assigned, leave the assignment as is.
4. **Scope, estimate, interview.**
   Map the Project field value to a registered project in `data/projects.md` to propose the repo, and propose a sprint-points estimate.
   If the Project value is unset or maps to no registered project, ask the captain which project it is.
   Surface genuine uncertainties - scope, acceptance, repo, estimate - and interview the captain in chat.
   When description plus comments already answer everything, keep the interview brief or skip it and just confirm the repo and estimate in one line.
5. **Persist to the description.**
   Follow the durable-description contract below to append the interview outcome and the confirmed estimate.
6. **Decide.**
   - Clear enough: confirm `in progress` exists in `available_statuses`, move the task to `in progress`, then create a normal firstmate ship task on the confirmed repo through the standard lifecycle (`AGENTS.md` section 7), on that project's registered delivery mode.
     Record the linkage per the linkage contract below before reporting the dispatch to the captain.
   - Still unclear: park it - leave it assigned, leave the description updated with what IS known, do NOT move it to `in progress`, and report to the captain what is missing.
     Parking never uses a `blocked` status or any other status change; the task simply stays `to do` and assigned, and a later `/clickup` resumes it from the accumulated description.
7. **Code review milestone.**
   When the delegated ship task reaches its normal PR-ready signal - the PR open with checks green per section 7 - the main session posts a ClickUp comment (`clickup_create_comment`) containing a short implementation summary and the full PR URL, and moves the task to `code review` (after confirming that status exists).
   If that update carries a screenshot or other evidence file, load `evidence-artifacts` and attach it before writing the comment.
8. **QA milestone.**
   When that PR merges - detected by the normal merge monitoring - the main session moves the ClickUp task to `qa` (after confirming that status exists).

The captain's merge approval is unchanged throughout: this skill never merges, and firstmate's merge authority stays exactly what `AGENTS.md` section 7 grants.

## Durable-description contract

The ClickUp task description is the durable memory this pipeline accumulates across invocations.

- Read the current description first, via `clickup_get_task`.
- Append a dated block under a `## firstmate clarifications` heading (create the heading on first use, reuse it afterwards): every interview question with the captain's answer, plus the confirmed sprint-points estimate as its own line.
- Never overwrite or rewrite the original description text or any prior clarifications block; write back the full original text plus the appended block via `clickup_update_task` `markdown_description`.
- On a later invocation, this accumulated section is context like any comment: reuse it instead of re-asking.

## Linkage contract

This section is the one owner of the ClickUp-to-firstmate task linkage.

- When the ship task is created, record one line in that backlog item's note: `clickup: <custom id> <internal id> <task url>` - for example `clickup: DEV-1234 <clickup-internal-id> https://app.clickup.com/t/<clickup-internal-id>`.
  The custom id and internal id both come from the claimed ClickUp task; the internal id is what the connector's update and comment calls take.
- The ClickUp task's custom id (for example `DEV-1234`) MUST appear in the delegated ship task's branch name and in its MR/PR title, so ticket and code cross-reference both ways.
  The branch name may carry the raw id (for example `dev-1234-short-slug`), but the MR/PR title and the delegated ship task's commit subject MUST both stay valid Conventional Commits with the id embedded compliantly, never displacing the `type(scope):` prefix.
  Embed the id either in trailing parentheses on the subject/title - for example `feat(scope): short description (DEV-1234)` - or in a `Refs: DEV-1234` (or `Closes: DEV-1234`) footer.
  A subject prefix that replaces the type, such as `DEV-1234: short description`, is WRONG because it breaks Conventional Commits.
  Firstmate writes the ship brief accordingly: it includes the custom id in the branch name and embeds it Conventional-Commits-compliantly in the title and commit subject, in addition to the `clickup:` backlog line above.
  This applies only to ClickUp-linked tasks; work the captain chose to leave unticketed carries no such requirement.
- A firstmate task whose backlog record carries a `clickup:` line is ClickUp-linked: on its PR-checks-green report and on its merge, load this skill and run the matching milestone step before reporting or cleanup.
- The milestone signals themselves (PR-ready report shapes, merge detection) are owned by `AGENTS.md` sections 7 and 8; this skill only adds the ClickUp side effects at those existing points.

## Safety and idempotency

- If the captain is unavailable mid-interview, wait or park; the claimed task stays assigned with the description holding everything learned so far, and nothing is lost by ending the session.
- Re-invocation is safe by construction: step 2 reads description, clarifications, and comments first, so a resumed task continues instead of duplicating claims, questions, or ship tasks.
  If a linked ship task already exists for the ClickUp task, do not create a second one; report its current state instead.
- A connector error or missing status stops the affected step with a plain report to the captain; never guess ids, statuses, or assignees.
- Destructive ClickUp actions (deleting tasks, removing others' comments, changing others' assignments) are out of scope for this skill entirely.
