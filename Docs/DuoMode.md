# Duo mode

Duo uses one model to prepare a plan and another to implement it. It runs in
the current conversation and shares Task Capsules' saved plans, verification,
usage limits, and recovery.

## Using v1

1. Select **Duo** in the composer’s Work menu.
2. Choose **Plan with** and **Build with** from your connected accounts and
   installed models. The pair is remembered; specialist setup is unnecessary.
3. Describe the change. Planning is read-only, and clarification stays with
   the planner.
4. Review the saved plan in the conversation. **Revise** opens the composer
   for your feedback. **Accept & build** starts the chosen builder.
5. The builder implements and verifies the plan. Follow-up messages use that
   same builder. **New plan** starts another planning cycle.

The selected mode remains Duo while its phase changes. The task keeps its
chosen model pair even if the ordinary model picker or default Duo pair changes.
Switching to Work returns ordinary messages to the normal model selection.
Model choices do not grant additional tool permissions.

Stopped builds offer **Resume**, **Ask planner for help**, and **Review recovery**.
Recovery opens the existing capsule controls for uncertain actions, checks,
usage, and requirements that need human review. Restart restores saved state
without starting model calls. A running build is shown as paused until its
saved attempt is refreshed. A failed plan save can be retried from the card.

Before execution, the runtime checks the approved revision and the plan's
declared source files. Repeated acceptance of the same handoff cannot create
another run, including when requests arrive concurrently or after restart.
As in Task Capsules, source fingerprints cover declared files, not the entire
repository. Unavailable accounts stop the stage instead of choosing a fallback.

## Scope and implementation

- V1 supports interactive regular workspace tasks. Automations and specialist
  mode menus continue to use the existing non-Duo modes.
- `DuoModel` persists task phases, the approved capsule, pending planning data,
  and credential-free model profiles. Production uses application preferences;
  tests use isolated or in-memory state.
- `DuoComposerView` supplies the two model choices, plan acceptance, revision,
  and recovery controls. `AppModel` resolves exact account routes per dispatch.
- Planning and execution continue to use the backend's `plan` and `work`
  contracts. Unaccepted plan revisions use planning calls; explicit help with
  a build uses the capsule's bounded planner-escalation allowance.
- The execution reservation stores a stable handoff ID in the capsule's run
  history within the existing SQLite write transaction. Duplicate reservations
  are rejected before another attempt or model call is created.
- Executor follow-ups require a completed saved attempt and carry the original
  request and approved plan. They have separate run records; new follow-up work
  does not rewrite the original capsule's completion evidence.
- The stronger model is not automatically used for implementation, final
  synthesis, or review. Existing capsule recovery and optional review remain
  available through its detailed view.

## Suggested next iterations

1. **Measure model pairs.** Compare successful completion, retries, elapsed
   time, and total available usage across planning and execution. Recommend
   defaults from measured results. Keep subscription usage distinct from API
   price estimates.
2. **Optional final planner review.** Let users enable one bounded review of
   the builder's diff and test evidence, with any repair performed by the builder.
3. **Better blocker handoffs.** Package the failed check, relevant changes,
   and the builder's attempted fixes when the user requests planner help.
4. **Named pairs.** Add reusable choices such as a preferred coding pair and
   a local-only pair after there is evidence that users need several defaults.
