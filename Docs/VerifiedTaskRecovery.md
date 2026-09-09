# Verified completion and task recovery

Implemented September 9, 2026. This release connects completion evidence,
preserved task context, and resumable Task Capsules. Goals and capsules require
recorded checks or explicit human acceptance. Ordinary chat and Work tasks get
the context improvements without a compulsory completion contract.

## Delivered behavior

- **Working** executes the saved task. **Checking** runs its declared acceptance
  checks through the existing tool permissions.
- **Completed** requires passing, current execution evidence and settled actions.
  An assistant's claim that a check passed is explanatory text, not a receipt.
- Failed checks use the existing bounded repair allowance. Uncheckable criteria
  produce **Needs review** and stop automatic continuation. **Accept result**
  records human acceptance separately from machine verification.
- Interrupted work and exhausted allowances remain incomplete. Restart exposes
  recoverable progress without launching another execution.
- **Resume** continues an attempt, **Retry checks** inspects existing outputs,
  and **Run again** explicitly starts another execution. A configured reviewer
  is retained; this release introduces no automatic additional review model.

Goals, including team-backed goals, keep the existing goal lifecycle owner.
Capsules keep their existing plan and team execution owners. Shared task records
and evidence support both paths.

## Checks and receipts

Structured plans accept `acceptance_checks` at the plan level and on each
`step_details` entry. Goal reports accept the same declarations through
`update_goal`. Each declaration identifies a requirement and a stable check ID.
Step declarations can also include `inputs`, `outputs`, and `dependencies`.

```json
{
  "acceptance_checks": [
    {
      "id": "report-exists",
      "requirement": "Deliver the report in the workspace",
      "kind": "file_exists",
      "path": "output/report.md"
    },
    {
      "id": "report-coverage",
      "requirement": "Include the agreed migration notes",
      "kind": "file_contains",
      "path": "output/report.md",
      "value": "Migration notes"
    },
    {
      "id": "data-status",
      "requirement": "Record a successful result",
      "kind": "json_value",
      "path": "output/result.json",
      "pointer": "/status",
      "value": "ready"
    },
    {
      "id": "regression-suite",
      "requirement": "The relevant regressions pass",
      "kind": "command",
      "command": "python -m pytest tests/test_report.py",
      "timeout": 120,
      "files": ["report.py", "tests/test_report.py"]
    },
    {
      "id": "editorial-review",
      "requirement": "The owner accepts the report's tone",
      "kind": "human_review"
    }
  ]
}
```

The last criterion deliberately requires human review. Machine checks establish
their declared criteria; they do not establish that an underspecified contract
covers every aspect of the request. Plans should include every required result
and explicitly identify criteria needing judgment.

Execution writes receipt IDs, check hashes, task revisions, execution checkout,
file fingerprints, actual result, and command exit status where available.
Evidence is committed only after actual tool execution and durable observation.
Permission-denied checks remain unverified. Callers cannot submit a forged pass
field or silently remove or weaken an existing check within the same revision.

Paths are relative to the execution checkout. Command checks with `files` use
that declared scope; include every relevant input and output. Commands without
an explicit scope use the bounded workspace snapshot. Receipts become stale
when relevant files or requirements change. Original tool detail remains in the
session transcript, with durable references from task context.

## Preserved context

Full requests and steering messages are saved before acknowledgement. Requests,
corrections, the saved plan, unresolved tool failures, and task progress are
restored independently of a generated summary. Repeated corrections retain
their original order. Private Identity context remains excluded.

Compaction uses a conservative UTF-8 token estimate and bounded consecutive
sections. It processes all older exploration, retaining recent complete
exchanges and tool-call/result pairs when they fit. The new context replaces
the previous one only after a complete summary and successful persistence.
Failed summarization or persistence keeps the previous usable context. If
essential instructions exceed the selected context window, execution stops
with a specific limitation rather than silently removing instructions.

Summary calls use the selected provider route and normal usage accounting.
Native Codex receives changing task state through dynamic context delivery;
progress updates do not change the session's configuration fingerprint. Actual
compaction or unavailable provider-side history can still require restoration.

## Capsule recovery

An attempt records its plan identity, execution checkout, per-step state and
attributed usage, dependencies, declared and observed files, verification
references, cumulative usage, repair count, and outstanding action or model-call
uncertainty. Shared review and repair costs remain in the attempt total.

Before implementation, baseline checks use the actual checkout, including a
managed worktree. Verified step completion is saved before advancing. Resume
compares current files with the latest accumulated file state, so a legitimate
later capsule edit to a shared file does not invalidate earlier progress.
Unexpected input changes invalidate affected steps and dependent or shared-file
work. Compatible, unaffected verified steps use the team executor's existing
completed-job skipping. Changed plans reuse progress only when the relevant
request, constraints, decisions, step definition, dependencies, and file state
remain compatible.

Partially executed steps continue with their existing files available for
inspection. An uncertain mutation pauses recovery for an observed outcome;
recording that outcome does not authorize an identical replay. An interrupted
model call with unsettled usage also needs explicit reconciliation. Reviewed
usage cannot reduce already recorded spend. Resume retains the original
attempt's consumed allowance and repair count; increasing limits is an explicit
recipe edit.

If implementation already finished, recovery proceeds to checks or review.
Repairs rerun affected checks and the configured reviewer. Reusing a saved plan
does not invoke the planner or add a model-generated final summary. Capsule
writes remain sequential.

The execution request adds `resume_attempt_id` and optional `checks_only` to
`capsule_context`. Capsule snapshots add `attempts`; each attempt exposes step
progress, verification status, usage, and a specific blocker. Revision-checked
capsule updates support `accept`, `resolve_action`, and `resolve_usage`. Goal
snapshots expose verification status, check declarations, and evidence IDs;
goal acceptance is also revision checked.

## Migration and compatibility

- The run database advances from schema **13 to 14**, adding `task_records`,
  `task_evidence`, and `capsule_attempts`. Existing run and goal tables and
  history are preserved.
- New capsule payloads use schema **2**. Existing capsule revisions and run
  links remain readable; missing checks, inputs, outputs, or attempts decode
  with tolerant defaults in the desktop client.
- Session context uses additive journal records. Original requests and raw
  transcripts remain available; successful compaction is a committed context
  record, not a rewrite of history.
- Historical completion stays historical and is labelled unverified when
  evidence is absent. Older plans remain runnable, but cannot skip steps as
  verified until new execution evidence exists.
- No credentials or account selections are migrated. An older application
  encountering the newer run schema uses its existing read-only compatibility
  behavior; restoring a pre-upgrade data copy is required for a writable
  downgrade.

Recovery snapshots currently allow 4,096 workspace files and fingerprints up to
64 MiB per file. Git workspaces respect ignored files; non-Git scans exclude
common dependency and build directories. Explicitly declared files can still
be checked. Initial capsule baselines are limited to 256 distinct files.
Existing session safeguards remain 64 MiB per session and 2 MiB per record.
Exceeding a required bound produces an explicit limitation. Large-workspace
performance and broader snapshot scaling remain unbenchmarked.

## Foundation validation

The focused backend suites passed **776 tests**, including 53 verification and
recovery regressions. They cover task verification, capsules, goal lifecycle,
compaction, sessions, native context delivery, persistence, and team execution.
They include a real team executor with fixture providers: interrupt immediately
after a verified step, reconstruct the service, and resume the same attempt
without repeating that step or calling a planner/synthesis model.

Regression cases include missing artifacts, forged prose, denied tools, stale
receipts, truncation, exhausted calls, constraints after character 2,000,
unresolved native and classical failures, failed compaction, recorded summary
usage, shared-file changes, divergent checkouts, duplicate resume, stale
revisions (including plan or file changes during the final checks), interrupted
mutations, persistence failures, and legacy migration.

The selected desktop tests passed: **52 model/render tests and 9 UI tests**.
Seeded recovery scenarios cover paused progress, Needs review, recovery controls,
and separate human acceptance. The Debug desktop build succeeded with ad hoc
signing. Test stores and provider responses are isolated fixtures.

Saved [validation results and logs](../output/verified-task-recovery-2026-09-09/validation.json)
include the exact test selections and build configuration. Compact desktop
renders show [paused recovery](../output/verified-task-recovery-2026-09-09/Recovery-paused.png)
and [Needs review](../output/verified-task-recovery-2026-09-09/Recovery-needs_review.png).

Live paid-provider interruption/recovery, external actions against real services,
and comparative task completion/time/cost benchmarks were not run. Native
provider behavior is covered by deterministic fixtures, not a live subscription
session. These are validation limits, not measured parity claims against Claude
or Codex.

## Task reliability extension

The subsequent two-phase implementation adds immutable plan approval references,
execution-evidence progress detection, shared bounded team repair, invocation
receipts, evaluation startup/grading fixes, whole-task usage accounting, a unified
macOS task detail view, and selective file restoration. Task migrations 18–20 follow the independent runtime’s 15–17 migrations and
are additive to the schema 14 foundation described above.

See [Task reliability implementation and validation](TaskReliability.md) for
interfaces, measured local checks, current validation records, and limitations.
The user deferred all live-provider recovery and comparative benchmark campaigns
until after feature implementation. Those release gates remain open; local
regressions and timing measurements do not count as live-provider passes.
7. Unify the broader task interface and implement selective file restoration.
8. Evaluate the five proposed differentiation ideas: reusable checks from
   corrections, visible assumptions that would invalidate a plan, measured
   time/cost recipe previews, undoing one intent while keeping later work, and
   opt-in validity checks for completed results. Their differentiation still
   needs current competitive validation.

Before distribution, exercise live-provider recovery and real external-action
uncertainty with disposable tasks. The deterministic validation does not consume
or estimate those live-provider results.

The macOS task surface and selective file restoration follow-up is documented
in [Task restoration](TaskRestoration.md), with separate raw acceptance records.
