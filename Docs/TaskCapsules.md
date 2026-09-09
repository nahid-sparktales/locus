# Task Capsules

Task Capsules save a plan with model choices for planning, implementation,
and optional review. The implementation model receives the saved specification
and executes its ordered steps. It does not call the planning model to recreate
the plan or write a final summary.

## Getting started

1. Connect the model account you want to use, or choose a local model. For
   example, you can plan with ChatGPT and implement with Kimi Code. Kimi Code
   membership and Kimi's metered API are distinct accounts.
2. In settings, choose **Add Agent**, select an account under **Provider route**,
   and choose a model. For implementation, set **Access ceiling** to **Workspace
   edits**. One profile can handle planning and implementation, or use separate
   profiles such as ChatGPT for planning and Kimi Code for implementation.
   Choose models available on those accounts; capsules do not hard-code model names.
3. Open the composer's **Work** dropdown and choose **Task Capsules…** in the
   workspace you want to work on. **Locus → Task Capsules…** (⌥⌘K) also works.
   Opening from the composer copies your message into an empty new capsule;
   your chat draft and any unfinished capsule are preserved.
4. Describe your task, or choose an editable example and replace its bracketed
   details. The capsule name is optional. Choose **Plan with** and **Implement
   with**, and optionally select **Review with**. The same profile can serve
   multiple roles. **Advanced · Usage limits** contains the optional allowances.
5. Choose **Generate plan**. Planning happens read-only in the conversation;
   answer any clarification there. A successful structured plan is saved
   automatically. You can also save an existing conversation plan.
6. Reopen Task Capsules, inspect the instructions, checks, constraints, and design
   decisions, and choose **Run plan**. **Expand steps** shows every step’s details.
   Run history keeps each stage's outcome and available usage measurements, with
   a link back to its conversation. **Review result** performs a separate read-only
   review. An interrupted attempt offers **Resume** and **Retry checks**.
   **Run again** explicitly starts another execution.

The primary action stays visible while you review a long plan. With no agent
profiles yet, **Set up models** takes you to settings and preserves your draft.
If setup is incomplete, a message explains what is needed. Saved capsules can be searched in
the sidebar; smaller windows use a capsule menu. A waiting planner offers
**Continue planning** to return directly to its conversation. Your description
is preserved when you close the sheet or open profile settings.

Each stage uses the exact account associated with its profile. An unavailable
account stops the stage. Subscription routes never silently fall back to a
metered API account. The regular chat route is restored before a subsequent
ordinary turn; capsule model selection does not change the main model picker.

## What is saved

A capsule contains the request, plan, design decisions, constraints, step
dependencies, named files, completion checks, profile identifiers, usage
allowances, immutable revisions, and links to runs. Credentials remain with
the existing native account store and are passed to workers only in memory.

The planner can provide up to 16 detailed steps. Writes run sequentially in
the selected workspace, preserving dependency order. Each step uses the
implementation profile's instructions and existing tool permissions. Captured
older plans without detailed steps also work, but have fewer explicit checks.

Baseline fingerprints cover named step files, declared inputs and outputs, and
files referenced by acceptance checks, including files to create. Locus checks
them against the actual execution checkout before execution. Changed,
removed, or unexpectedly created files pause the handoff; **Update the plan or
ask for help** can inspect the current workspace and save a revised plan. A legacy plan
without named files has no initial file baseline. During execution, Locus
records local file changes and verified step evidence for recovery. Command
checks without an explicit file scope use a bounded workspace snapshot.

## Usage and recovery

- Planning and standalone review have a per-turn model-call allowance.
  Implementation, its automatic reviewer, and repairs share an execution-call
  allowance. Profile response-token and runtime limits still apply.
- Provider-managed native turns may contain work internal to the provider;
  Locus counts the calls and token usage that the provider exposes. These are
  application limits, not a prediction or guarantee of remaining subscription
  quota.
- Reviewer findings can trigger bounded repair rounds using the implementation
  model, followed by another review. An unavailable or malformed reviewer does
  not count as an approval. Resuming preserves the original attempt’s repair
  count. Planner-help requests keep their existing capsule-wide allowance.
- Asking the planner is explicit. Answers to its clarification questions remain
  in that help request's chain rather than consuming a new help allowance.
- The optional API cost estimate limit applies to execution with configured
  API profile prices. It is checked against estimated usage and is not a hard
  billing ceiling. It excludes planning, standalone review, tool charges, and
  image generation. Subscription routes track calls and tokens without
  inventing per-token subscription prices.
- **Edit** in **Models & limits** changes the saved recipe explicitly. It preserves
  the existing file baseline and run history. Increasing an allowance does not
  erase previous attempts.

Stopped work keeps its existing files, evidence, consumed allowance, and repair
count. **Resume** reconciles those files and continues the original attempt.
Verified, compatible steps are skipped; changed inputs invalidate affected steps
and their dependents. Later writes made by the capsule are included in its saved
file state. If implementation finished, Resume continues checks or review.

**Retry checks** inspects existing outputs without rerunning implementation.
Configured review and bounded repairs still use the remaining execution
allowance. Requirements that need human judgment show **Needs review**.
**Accept result** records your acceptance separately from machine verification.

An interrupted action with an uncertain outcome is never blindly replayed.
Inspect its result and use **Save observed outcome** before resuming. If model
usage is unsettled, **Save reviewed usage** records explicit totals; recorded
spend cannot be reduced. Increasing the original allowance remains an explicit
recipe edit. Restart restores these states without starting work.

Historical completions remain historical and are labelled unverified when
receipts are unavailable. Older plans remain runnable, but prose reports alone
cannot create verified steps. See [Verified task recovery](VerifiedTaskRecovery.md)
for the check format, migration, validation, and follow-up work.

## Ownership and local API

`TaskCapsuleModel` owns native feature state and persistence requests;
`AppModel+TaskCapsules` composes existing accounts and the worker send pipeline.
`capsules.py` owns workspace-scoped SQLite persistence at
`paths.APP_DIR/task-capsules.sqlite3`. `capsule_execution.py` validates stages
and builds the direct execution graph for the existing team runtime.

The authenticated local API provides list/create at `/api/capsules`, read and
revision-checked updates at `/api/capsules/{id}`, and baseline validation at
`/api/capsules/{id}/validate`. A `user_message` carries transient
`capsule_context` for a stage. Saved recipes contain profile IDs, while worker
routes are resolved explicitly for each dispatch.

Tests use isolated stores, fake model responses, and native UI fixtures. They
do not consume live ChatGPT, Kimi, or API account usage.
