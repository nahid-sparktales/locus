# Task reliability, measurement, and restoration

This extends [verified-task recovery](VerifiedTaskRecovery.md). Implementation
and deterministic validation are separate from provider campaign results. The
user explicitly deferred live-provider recovery and comparative benchmark
campaigns. No paid provider campaign was executed for this change.

## Phase 1: execution and planning

`TaskJournal` links sessions, runs, goals, and capsule attempts to one logical
task, distinct from the checkout identifier. Helpers inherit that journal.
Ordinary Work still does not create a Goal or require a reviewer automatically.
Identity chats do not create task journals or expose task detail history.

Plans are immutable database records. The saved approval reference contains
`id`, `revision`, `content_hash`, and `execution_path`; the database binds it to
the logical task. Execution validates that exact reference and supplies the
saved content to the worker. Changed source files invalidate initial admission;
changed plan revisions or checkout bindings invalidate execution. Approved
references are retained in session and run records for restart and retry.
Declared acceptance checks still run before a result can be verified.

The shared planning contract uses the available question capability. Clear,
small Work requests remain direct. Plan and Grill are read-only; material
decisions, interfaces, constraints, and acceptance criteria define the stopping
point. Exhaustive Grill is explicit. Bundled planning instructions use
deliverable-sized steps and the saved execution recipe, without compulsory
micro-commits or repeated execution-method questions.

Every routed tool invocation has its own receipt, including refusal and
interruption. Receipts retain invocation identity, execution location, task
revision, outcome, observed file fingerprints, and bounded result evidence.
Command verification reads that invocation's command/exit receipt. The legacy
last-command field is retained only for compatibility.

Goal inactivity uses persisted milestones: answered decisions, verified steps,
passing checks, changed declared artifacts, and validated source findings for
unresolved requirements. Findings must quote captured source receipts and pass
fingerprint checks. Repeated reads, repeated failures, prior artifact states,
and paraphrased reports do not advance the counter. Two completed automatic
continuation turns without evidence add a bounded recovery instruction; three
pause with the unresolved next action. User and permission waits do not count.
Milestones never waive completion checks.

Ordinary teams and capsules share review → warranted repair → affected checks
→ current review. Findings receive stable IDs. Review evidence records its
files, execution root, and approved plan/capsule revision. All configured
reviewers must return valid verdicts. Missing, malformed, interrupted, or stale
review remains unresolved. Ordinary repair cycles are limited to
`max_rounds - 1` across resume; capsule allowances retain their existing owner.
Calls for required reviewers and the ordinary final handoff are reserved before
repair. Capsule handoff remains deterministic, without another synthesis call.

Steps add `execution_kind: read | check | write`; omitted kinds remain writes.
Dependencies are preserved; writers wait for earlier readers/checks and remain
sequential in a shared checkout. Runtime-approved deterministic reads/checks
can use at most two workers with independent invocation state. Shell checks
stay sequential and retain uncertain-action journaling. Cancellation, normal
permissions, task revision checks, and the existing model scheduler remain in
effect. Source-read waves have a separate measurement policy; verifier timing
does not enable unmeasured source-read workloads.

The local benchmark executes the real verifier with 32 JSON checks at 100,
1,024, and 4,096 workspace files, one warmup and 20 paired repetitions per size.
Order alternates between serial and parallel. Each pair compares the full
normalized check evidence, including file fingerprints, as well as pass/fail.
The raw measurements are in [parallel-checks.json](../output/task-reliability-2026-09-09/parallel-checks.json).
The measured median improvements were **0.55%, 0.37%, and −0.28%**. All paired
evidence matched, but no workload reached the required 10% median improvement.
**Automatic concurrency remains disabled.** This is one machine with warm
filesystem caches; other desktop development activity was present during the
validation session. These measurements make no provider-performance claim.

## Phase 2: evaluation and accounting

Evaluation persists a run before its dependent result, including startup
failures. Execution outcome and grading outcome are separate. Truncation,
iteration limits, provider errors, cancellation, and timeout cannot pass weak
output assertions. Automated rubric grading requires an eligible configured
judge. Subjective cases may remain ungraded until a recorded human grade is
submitted; that grade cannot override execution or deterministic failure.

Configuration fingerprints include provider/protocol, model/version, account
class, mode, recipe, effort, tools, permissions, and application version.
Every started attempt stays in the completion-rate denominator. Failed attempts
retain elapsed time, usage coverage, and known spend. Judge runs and usage are
recorded separately from task execution. Fresh-database tests exercise the
actual evaluation entry point, including startup failure and truncation.

The idempotent ledger records pending calls before dispatch and settlement
afterward, across planning, execution, helpers, review, repair, compaction,
retries, images, and configured charge-reporting tools. Interrupted usage stays
pending or unknown; duplicate IDs cannot silently change the request or charge.
Reconciliation requires evidence and cannot reduce already recorded spend.
Exact subtotals use decimal arithmetic; display values additionally include
coverage, unknown charges, subscription usage, and local execution.

Anthropic streaming counters are cumulative. Ordinary input, cache reads,
five-minute writes, one-hour writes, and output remain separate; aggregate
cache counts are not charged again after duration-specific counts arrive.
Conservative reservations use the highest applicable cache-write rate.
Pricing retains source and date, and unrecognized routes/models stay unpriced.
The implementation follows the official [cache accounting](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
and [streaming usage](https://platform.claude.com/docs/en/build-with-claude/streaming)
contracts. Account discounts and provider billing modifiers are not invoices
and are not inferred by the estimate.

`usage_rates` may provide per-million category rates plus provenance on a core
configuration or agent profile. `charge_reporting_tools` may provide per-tool
provider/model, rates, and a conservative `upper_bound`; tool-reported usage or
charges settle those entries. Missing measurements remain unknown.

An optional cumulative task estimate limit is independent of Goal/capsule stage
allowances. With it enabled, unpriced metered admission or unresolved prior
metered usage pauses further paid calls. Queue, model, tool, review/repair, and
user-wait spans are retained individually. Elapsed time runs through acceptance;
overlapping spans are not added together as wall time.

## macOS task view and restoration

The follow-up [task view and restoration contract](TaskRestoration.md) documents
persisted action availability, sheet routing, selective previews, and the
additional compatibility and crash-recovery gates.

Goal, Capsule, Plan inspector, and run-history entry points open the task detail
surface. It shows request, saved plan, evidence, blocker, findings, outputs,
usage, and restoration history. Resume and acceptance retain existing Goal and
Capsule owners. Ordinary Work offers explicit result acceptance; deterministic
file/JSON checks can be retried without a model call. Shell checks use the
existing execution controls. Opening the view or restarting never executes a
task. Recipe controls remain available from the capsule task.

Structured edits, artifact/image writes, and helper integrations capture bounded
before/after content in Git workspaces and ordinary folders. Opaque shell edits,
uncertain ownership, unsafe paths, and over-limit files are shown as exclusions.
Limits are 4,096 candidate files, 64 MiB per file, and 128 MiB per restoration
batch; captured task content is also bounded. History is selective captured
changes, not an unrestricted filesystem backup.

Preview selects recorded changes and returns a token, revision, fingerprints,
diffs, and conflicts. Apply requires that token, selected paths, expected
revision, and exact preview fingerprints. Stale previews are rejected before
writes. Text reversal preserves unrelated later edits when uniquely applicable;
ambiguous/conflicting files remain untouched. Binary reversal requires an exact
recorded post-edit match. Each file is revalidated immediately before an atomic
write through directory descriptors; symlinks cannot redirect the restoration.
Recovery content and a durable journal precede writes. After interruption,
explicit recovery reverses only files still matching the recorded restoration.
External actions and conversation history are never implicitly restored.

## Additive interfaces and compatibility

The independent runtime owns schemas **15–17**. Schema **18** adds task links,
immutable plans, observations, and milestones; **19** adds task usage, limits,
and spans; **20** adds content history/restoration journals. Existing schema 14
and 17 records remain intact. Missing evidence stays
unverified, missing price/usage stays unknown, and legacy step kinds are writes.
Mobile clients can continue using the existing endpoints and tolerant models.
The runtime invocation ledger and logical-task usage projection retain their
own limits and views. Their subtotals describe overlapping calls and must not
be added together; provider dispatch still happens once.

- `GET /api/sessions/{session_id}/task`: read-only task projection.
- `POST .../task/limit`: optional cumulative estimate limit (`amount`, or null).
- `POST .../task/usage`: reconcile `id`, `amount`, and evidence `note`.
- `POST .../task/checks`: explicit safe check retry with expected `revision`.
- `POST .../task/accept`: explicit ordinary-task acceptance with `revision`.
- `POST .../task/restore`: preview (`change_ids`), apply (`token`, `revision`,
  `selected_paths`, `fingerprints`), or recover (`token`).
- `POST /api/evaluations/{suite_id}/results/{result_id}/human-grade`: recorded
  subjective grading; execution and deterministic failure remain authoritative.

## Validation records and deferred campaigns

[validation.json](../output/task-reliability-2026-09-09/validation.json) records
the tested source snapshot, selections, raw logs, UI captures, and known gaps.
The full backend run passed **2,233 tests**. Subsequent focused runs passed,
including **105 accounting/progress/recovery checks** and the real saved-plan
Work entry-point regressions. These selections overlap and must not be added
to the full-suite count. Desktop validation passed **49 model/routing/render
tests and 10 distinct UI tests** across the Goal and Capsule suites. The final
combined desktop run also repeated the new task-detail UI test successfully.
Captures show the [compact task view](../output/task-reliability-2026-09-09/TaskDetail-compact.png)
and [macOS task window](../output/task-reliability-2026-09-09/TaskDetail-macOS.png).
Deterministic tests cover restart/compaction, paraphrased inactivity, current
reviews, saved plan approval, concurrent receipt attribution, cumulative/cache
usage, duplicate settlements, failed evaluation attempts, restoration conflicts,
and interrupted restoration/checks. UI tests use isolated fixtures, never live
provider accounts.

Campaign infrastructure persists immutable configuration snapshots, three
interleaved repetitions per condition, admission reservations, failure/gap
records, and known spend per accepted result including failed attempts. Caps
are $50 / 30 calls / ten minutes per recovery scenario and $200 / 50 calls /
20 minutes per comparative case. Missing pricing or unsettled usage stops
admission; caps never increase automatically. The controlled HTTP fixture
persists an action before deliberately dropping its response; its deterministic
test verifies that the durable action log survives restart.

**Deferred, not passed:** managed ChatGPT/Codex and Anthropic live interruption
matrices; the direct Work / Plan→Work / Goal / Capsule / native Codex / native
Claude Code comparative matrix; dedicated live browser/document adapters and
mixed-provider capsule comparisons. No release gate is inferred from missing
coverage, and no superiority claim is made. The campaign module does not start
provider transport itself; provider-specific adapters/interruption orchestration
and the actual paid runs belong to the deferred campaign work.
