# /clickup command design

The normative procedure is owned by `.agents/skills/clickup/SKILL.md` and is not restated here.
This document records the agreed design behind that skill: the runtime architecture that shapes it, the connector facts it operates on, and the rationale for its captain-decided contracts.

## Runtime architecture

The ClickUp connector (the `mcp__claude_ai_ClickUp__*` tools) is a claude.ai session tool available only to the main firstmate session, not to spawned crewmates.
That single constraint shapes the whole design:

- `/clickup` is a procedure skill the main firstmate session follows, not a shell script and not a crewmate deliverable.
- Every ClickUp read and write happens in the main session: at invocation, and again at each lifecycle milestone of the delegated work.
- The code implementation itself is delegated as a normal firstmate ship task through the existing lifecycle (`AGENTS.md` section 7); the crewmate never touches ClickUp.
- The link between the two sides is one durable `clickup:` line in the ship task's backlog note, owned by the skill's linkage contract.

## Pipeline summary

One invocation processes at most one ClickUp task - it finds an eligible one, creates one when the captain chooses, or (when the captain skips) proceeds with no ClickUp task at all:

1. Find eligible tasks in the DEVELOPMENT space (tag `firstmate`, status `to do`, unassigned or self-assigned) and pick one; when nothing is eligible or the captain wants unticketed work, offer - never force - a create-a-task branch, where skip proceeds as an ordinary firstmate task with no ClickUp linkage and create files a new task via `clickup_create_task` in a configured `task_creation_lists` target (or a captain-supplied list id), initialized to satisfy the same eligibility contract (`firstmate` tag, `to do` status, a DEVELOPMENT-space list, and a Project value) so a later eligibility scan can re-find it, before running the rest of the flow.
2. Gather description, all comments, and the Project custom field as context.
3. Claim the task if unassigned.
4. Propose repo (Project field mapped through `data/projects.md`) and a sprint-points estimate, then interview the captain on genuine uncertainties only.
5. Append the interview outcome and confirmed estimate to the ClickUp description under a dated `## firstmate clarifications` section.
6. Either move to `in progress` and dispatch a normal ship task, or park (assigned, still `to do`) and report what is missing.
7. At PR-open-with-green-checks, attach any evidence file to the task first, then post a ClickUp comment with the implementation summary, the full PR URL, and the names of those attachments, and move the task to `code review`.
8. At merge, move the task to `qa`.

Firstmate's merge authority is unchanged throughout; the milestones only add ClickUp side effects to reporting points the lifecycle already has.

## Connector facts the skill encodes

- Tools: `clickup_filter_tasks`, `clickup_get_task` (with `include: ["description", "custom_fields"]` and `expand_statuses: true`), `clickup_get_task_comments`, `clickup_get_threaded_comments`, `clickup_resolve_assignees`, `clickup_update_task` (`assignees`, `status`, `markdown_description`, `custom_fields`, `time_estimate`), `clickup_create_comment`, `clickup_create_task` (create-a-task branch only), `clickup_attach_task_file` and `clickup_request_attachment_upload` (evidence attachments).
- The two attachment tools were established later, on 2026-08-09, and their behavior is recorded in [`docs/verification/evidence-artifacts.md`](verification/evidence-artifacts.md); the delivery contract they serve is owned by the `evidence-artifacts` skill, while the ClickUp mechanics live in the `/clickup` skill because only the main session can call the connector.
- The DEVELOPMENT space id and Project custom-field id are home-specific and are not hardcoded in the shared skill; they live in `config/clickup.json` (LOCAL, gitignored) and are read at `/clickup` start. See the skill's Configuration section for the file shape and the absent-config stop rule.
- The Project custom field is a dropdown naming the product a task belongs to; its selected value maps to a registered project through `data/projects.md`.
- Sprint points is ClickUp's native field and is not exposed by this connector: no points parameter on update, and it does not appear in `custom_fields`.

Except where a bullet above records a later date, these facts were established interactively with the connector during design (2026-07-22) and are recorded in the skill as operating parameters.
This crewmate-authored change could not re-verify them - the connector only exists in the main session - so the first main-session run is the runtime verification point; any drift stops the affected step per the skill's safety rules.

## Captain-decided contracts and rationale

- **Estimate lives in the description only.**
  Sprint points cannot be written through the connector, so the confirmed estimate goes into the `## firstmate clarifications` section instead of a field write that would silently fail or corrupt `custom_fields`.
- **Park, not `blocked`.**
  An unclear task stays assigned and `to do` with the description updated; the captain chose park-and-tell over a `blocked` status so no status noise appears on the board and a later `/clickup` resumes seamlessly.
- **Append-only description.**
  The clarifications section accumulates across invocations and doubles as the idempotency mechanism: re-reading it (plus comments) before acting prevents duplicate claims, repeated questions, and duplicate ship tasks.
- **Status names are confirmed at runtime.**
  Statuses vary per ClickUp list; the four used (`to do`, `in progress`, `code review`, `qa`) existed on every list checked, but the skill still requires confirming `available_statuses` per task and stops rather than guessing when one is missing.
- **Never touch someone else's task.**
  Eligibility is unassigned-or-self only, enforced before every action, not just at find time.

## Ownership map

- `.agents/skills/clickup/SKILL.md` - the procedure, eligibility filter, durable-description contract, and linkage contract.
- `AGENTS.md` section 7 - the `/clickup` invocation trigger; section 8 - the ClickUp-linked milestone trigger.
- `AGENTS.md` sections 7 and 8 remain the owners of the ship lifecycle and milestone signals themselves; the skill only attaches ClickUp side effects to them.
- `tests/fm-clickup-contract.test.sh` - static contract tests keeping the skill, triggers, and one-owner boundaries in place.
