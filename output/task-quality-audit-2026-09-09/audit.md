**Locus task quality and planning audit — 9 September 2026**

Locus has enough capability to be a serious task agent. Its most valuable next improvement is a dependable connection between the user's requirements, the approved plan, the work actually performed, and the evidence that the result is correct. Task Capsules provide a good foundation, particularly for choosing different planning and execution models. Completion verification, long-context preservation, and recovery need attention before adding more overlapping modes.

This audit inspected the current working tree, based on commit `c8ea7e0`, including existing uncommitted changes. It compared implementation mechanisms with current official Codex, Claude Code, and Cowork documentation. It ran 223 focused existing backend tests successfully in 9.83 seconds and ten offline probe groups against production functions with temporary stores and synthetic model responses. No live paid model comparison or usability study was performed. The findings establish specific behaviors and weaknesses; they do not establish that one product completes real tasks more often, faster, or more cheaply.

The reproducible observations are in [probe-results.json](/Users/nahid/Documents/locus/output/task-quality-audit-2026-09-09/probe-results.json), with the isolated harness in [probes.py](/Users/nahid/Documents/locus/output/task-quality-audit-2026-09-09/probes.py). Network connections were blocked during probes. No application implementation files were changed by this audit.

**How the products compare on the requested dimensions**

| Dimension | Locus today | Relevant comparison | Recommended improvement |
|---|---|---|---|
| Correct completion | Goals persist the objective and require an evidence report, but that evidence can be unverified prose. A response ending is sometimes treated as completion despite truncation. | Codex documents outcome, constraints, and verification as goal criteria. Claude recommends tests and observable expected results. Neither document establishes a universal correctness guarantee. | Distinguish work performed, checks passed, review required, and task complete. Bind completion to applicable checks and the current task revision. |
| Corrections | Steering, durable question delivery, and scoped memory exist. Classical compaction can remove the facts needed to honor a correction. Conversation rewind does not restore files. | Claude Code documents reloading plans and instructions after compaction, and restoring tracked file edits with rewind. Codex supports steering active work and queuing later work. | Preserve current constraints outside the summary, record which correction invalidates which steps, and offer conflict-aware file restoration. |
| Elapsed time | Capsules skip repeated planning and model-generated final synthesis, but serialize every step. Restarting partially completed capsules can require revising the plan. | The competitors support sustained work and concurrent tasks. That establishes available mechanisms, not measured speed superiority. | Resume valid completed steps; batch related work; parallelize independent reads/checks where safe; measure time to an accepted result. |
| Cost | Model choice and local execution are advantages. Capsule limits separate subscription routes from metered API estimates. Some usage categories and stages are missing. | Claude Code documents cache read/write usage and separate API/wall duration. Subscription allowances and task dollar costs are different concepts in both products. | Account for the whole task and all stages, preserve unknown measurements, and make cache accounting accurate. |
| Usability | Locus exposes plans, goals, capsules, reviews, run history, output versions, and recovery. Moving between their separate flows can require the user to understand implementation details. | Cowork documents an inspectable plan with sources, files, and progress in the task interface. Codex documents planning followed by persistent goals. | One task page with its plan, verified progress, blocker, outputs, and total usage; keep advanced model recipes optional. |
| Reliability | Durable run state, revision checks, usage reservations, and handling of uncertain actions are strong foundations. Reproduced completion/context/evaluation defects weaken the result. | Public competitor documentation describes recovery features, but cannot support an uptime or task-success ranking. | Close the reproduced gaps and exercise interruption, correction, changed-input, and provider-error scenarios end to end. |

The comparison above uses [Codex long-running work](https://learn.chatgpt.com/docs/long-running-work), [Codex prompting and steering](https://learn.chatgpt.com/docs/prompting), [Claude Code best practices](https://code.claude.com/docs/en/best-practices), [Claude context preservation](https://code.claude.com/docs/en/context-window), [Claude checkpointing](https://code.claude.com/docs/en/checkpointing), [Claude usage accounting](https://code.claude.com/docs/en/costs), and [Cowork's task interface](https://academy.claude.com/tutorials/navigating-the-claude-desktop-app). These are feature and behavior references, not independent comparative benchmarks.

**1. Make completion reflect verified outcomes — highest priority**

The goal contract instructs the agent to supply verification evidence. The validator requires a nonempty list of strings, and reconciliation accepts a `complete` report after checking lifecycle conditions. It does not establish that the strings correspond to actual successful checks.

The offline probe created a goal to write a required file, submitted “All checks passed.” as evidence without executing a tool, and reconciled the goal. The goal became completed although the file did not exist. This proves that the runtime permits false completion; it does not measure how frequently a live model makes that claim. See [goal validation](/Users/nahid/Documents/locus/agent/ollama_code/goal_runtime.py:45) and [completion reconciliation](/Users/nahid/Documents/locus/agent/ollama_code/goals.py:669).

A second probe returned an output-limit response. Locus emitted an incomplete-answer warning while recording the terminal reason as `complete`. That disagreement can propagate to downstream completion decisions. See [response termination](/Users/nahid/Documents/locus/agent/ollama_code/core.py:3364).

Introduce structured acceptance checks appropriate to the task: artifact existence and contents, command results, application behavior, source-backed claims, or a human review criterion where correctness is subjective. Store the check result, relevant artifact version, execution location, and task revision. An agent statement should explain evidence, not substitute for it. A simple text edit should not require an expensive independent model review; a focused deterministic check may suffice. Truncation and exhausted execution allowances should yield an incomplete state.

**2. Preserve constraints and evidence through long tasks — highest priority**

The classical compaction path includes only user and assistant prose and truncates each message to its first 2,000 characters before asking for a summary. Tool results are excluded. It then replaces the conversation with the new system prompt and generated summary. The original session record may remain available, but essential evidence is absent from the summarizer's input and immediate working context.

The probe placed an API-compatibility constraint after character 2,000 and a failing-test marker in tool output. Neither reached the summarizer. See [compaction implementation](/Users/nahid/Documents/locus/agent/ollama_code/core.py:4366). This specifically concerns Locus's classical compaction path; it must not be generalized to every provider-managed native Codex compaction operation.

Claude Code explicitly documents re-injecting its saved plan and root instructions and re-reading selected recent files after compaction. That is a concrete preservation mechanism worth matching, with its documented limits. [Claude context preservation](https://code.claude.com/docs/en/context-window).

Keep the current task requirements, user corrections, unresolved failures, decisions, and acceptance-check references as durable structured state. Re-inject that state after compaction and model changes. Summarize older exploration, retain a recent transcript tail, and include bounded tool-evidence references. Add a behavioral check that issues an early constraint, forces compaction, and then verifies that the final result still respects it.

**3. Detect progress from work, not wording**

Goals already protect against repeated identical progress reports. However, the progress fingerprint hashes the report's summary, evidence strings, and next step. Five probe turns performed no actions and simply changed the wording of the summary. The no-progress count stayed at one. See [progress detection](/Users/nahid/Documents/locus/agent/ollama_code/goals.py:674).

Measure progress through changes in accepted evidence: newly resolved questions, completed checks, useful source findings, changed artifacts, and finished plan steps. New research can count without a file edit; activity alone should not. After repeated unchanged failures, try a bounded different approach, request one specific missing decision, or pause with the blocker. Preserve the existing cumulative budgets and protection against replaying uncertain mutations.

**4. Close the correction and review loop consistently**

Capsules already have a useful review loop: an optional reviewer returns a structured verdict, warranted findings trigger bounded implementation repairs, and the reviewer is called again. Missing or malformed review output is not accepted as approval. Preserve this behavior. See [capsule repair and re-review](/Users/nahid/Documents/locus/agent/ollama_code/server.py:940).

The ordinary team path handles a review-requested repair but then proceeds toward final synthesis with the earlier review results; it does not run the reviewer again in that repair branch. The initial test evidence supplied to review is also the latest assistant output, rather than a structured bundle of command receipts. Reviewers can still inspect sources and run available tools, so this is not a claim that they can never verify independently. See [ordinary repair branch](/Users/nahid/Documents/locus/agent/ollama_code/server.py:990) and [review evidence input](/Users/nahid/Documents/locus/agent/ollama_code/server.py:900).

Reuse the capsule behavior for ordinary teams. Link each finding to the changed artifact and a confirming check; reopen only unresolved findings. This prevents stale review verdicts and avoids reviewing unrelated work repeatedly.

Locus's chat checkpoints restore conversation state, todos, selected context, and active plan. They do not restore edited files. Claude Code can restore tracked edits alongside conversation state, although Bash changes and most subagent edits are outside its rewind coverage. A Locus restoration flow should preview exactly which local changes it can restore and preserve concurrent user edits. See [Locus checkpoint restoration](/Users/nahid/Documents/locus/Locus/AppModel+BackendEvents.swift:977) and [Claude rewind limitations](https://code.claude.com/docs/en/checkpointing).

**5. Task Capsules: preserve the model handoff, improve resumability**

The current capsule flow is substantive:

1. The chosen planner inspects sources read-only and submits up to 16 detailed steps with constraints, decisions, dependencies, file paths, and checks.
2. Locus saves an immutable revision, source fingerprints, profile identifiers, limits, and run links.
3. Execution validates the saved revision and named-file baseline, converts the existing plan to ordered jobs, and runs the selected implementation profile.
4. An optional reviewer can trigger bounded repair and re-review.
5. Execution neither asks the planner to recreate the plan nor spends another model call on final synthesis. Planner help is an explicit action.

These are real strengths, not features Locus is missing. Exact account selection and the absence of silent subscription-to-API fallback are also useful. Sources: [capsule documentation](/Users/nahid/Documents/locus/Docs/TaskCapsules.md), [planner request](/Users/nahid/Documents/locus/Locus/AppModel+TaskCapsules.swift:81), and [execution graph](/Users/nahid/Documents/locus/agent/ollama_code/capsule_execution.py:20).

The limitations are in the handoff's assumptions and recovery:

- **Partial work invalidates the original baseline.** Changing an unnamed dependency passed validation in the probe; changing the named file through a simulated completed first step failed validation. This is documented behavior. It prevents some unsafe reuse but can force a revised plan just to continue unfinished work.
- **Validation and execution need the same location.** The dispatch layer validates `workspace_root`, while tools can execute in a separate `cwd` managed checkout. A probe with an unchanged source root and divergent execution file was admitted. The production checkout API supports this split. This establishes a dispatch-layer gap; the full desktop entry flow was not reproduced. Bind fingerprints explicitly to the actual checkout before execution. See [capsule dispatch](/Users/nahid/Documents/locus/agent/ollama_code/capsule_execution.py:135) and [checkout switching](/Users/nahid/Documents/locus/agent/ollama_code/core.py:1649).
- **Every step is serialized.** A predecessor is added even for steps the author marks independent, and every step is a writer job. Keeping shared writes sequential is sensible, but independent reading and checks could use a separate bounded lane.
- **Checks are descriptions.** A well-written plan can ask for tests, but a string saying “check output” is not itself an executed result.
- **Capsules and goals have separate lifecycles.** Capsule runs explicitly bypass goal binding. A capsule does not automatically gain the persistent goal's completion/recovery behavior. See [goal binding exclusion](/Users/nahid/Documents/locus/agent/ollama_code/server.py:773).

Give each step a durable completion record containing the plan revision, inputs, outputs, checks, and usage. On resume, verify completed steps against their expected post-execution state. Retain valid work and invalidate only affected dependent steps. Ask the planner to revise the affected section when an assumption actually changes; preserve the other accepted decisions. This is the strongest capsule improvement for completion, corrections, time, and cost together.

**6. Optimize planning effort and its instructions**

Ordinary Plan approval currently sends an instruction to implement “the plan you just created.” It relies on conversational context rather than explicitly binding the execution request to an immutable plan revision. The UI does retain an active plan, but that is not the same as a durable execution contract. See [plan approval](/Users/nahid/Documents/locus/Locus/AppModel+PlanAndCheckpoints.swift:80).

Use one underlying task specification for Work, Plan, Grill, Capsules, and Goals. These can remain different user-facing entry points. The shared state should contain the objective, constraints, decisions and their evidence, acceptance checks, approved plan revision, execution location, completed steps, pending input, and cumulative usage. Switching modes should not require reconstructing what the task means.

Planning depth should match the work:

| Task shape | Planning approach | Execution and verification |
|---|---|---|
| Clear, small, reversible change | Brief internal plan or direct work | One coherent change and its relevant check |
| Unclear scope or important product choice | Inspect available facts, ask the smallest consequential question | Continue when the choice is resolved; preserve its scope |
| Several related components or a model handoff | Durable capsule with interface boundaries and acceptance checks | Resume by validated step; run integration checks at meaningful boundaries |
| Consequential or difficult change | Deeper investigation, explicit assumptions, optional independent review | Bounded repair and confirmed resolution of findings |

Grill mode already asks one decision at a time and tells the agent to discover repository facts itself. Its bundled workflow also asks it to exhaust the entire decision tree. Keep that exhaustive behavior available when requested, but give ordinary planning a stopping rule: material decisions resolved, remaining assumptions visible, acceptance checks defined. Otherwise minor decisions can generate needless user interruptions. The native prompt and mode instructions also describe different question transports and turn behavior; normalize them around a capability-aware question contract. Sources: [mode instructions](/Users/nahid/Documents/locus/Locus/Models/ScheduleModels.swift:48), [native mode prompt](/Users/nahid/Documents/locus/agent/ollama_code/core.py:1759), and [bundled grilling instructions, audited as product content](/Users/nahid/Documents/locus/agent/ollama_code/builtin_skills/grilling/SKILL.md).

Optional imported planning skills need a compatibility pass. The bundled writing-plans workflow asks for implementation code, fine-grained test/commit steps, and another execution-method choice. The executing-plans workflow references additional Superpowers skills and its own stopping rules. These are not necessarily activated on every plan; when invoked, they can add ceremony or conflict with Locus's saved recipe. Adapt them to the existing capsule contract, permissions, and actual capabilities. See [bundled planning workflow](/Users/nahid/Documents/locus/agent/ollama_code/builtin_skills/writing-plans/SKILL.md) and [execution workflow](/Users/nahid/Documents/locus/agent/ollama_code/builtin_skills/executing-plans/SKILL.md).

Prefer deliverable-sized capsule steps with enough interface detail for the chosen executor. Avoid asking the planner to prewrite every implementation line. Preserve inexpensive saved-plan reuse, avoid repeating global checks after every tiny step, and escalate only unresolved blockers with their relevant evidence. Parallelize independent read-only work before considering isolated parallel coding. Do not promise a fixed speedup without measurement.

**7. Make whole-task cost and elapsed time trustworthy**

The Anthropic stream parser records `input_tokens` but discards the cache-read and cache-creation categories. A probe supplied 100 ordinary input tokens, 5,000 cache-read tokens, and 2,000 cache-creation tokens; only 100 were recorded and no provider usage fields retained the others. These categories have distinct accounting implications and should not simply be priced as ordinary input. See [Anthropic usage parsing](/Users/nahid/Documents/locus/agent/ollama_code/remote.py:850).

Classical compaction also bypasses the ordinary usage accounting path: the synthetic summarizer reported 625 total tokens while the core cumulative counters remained unchanged. Capsule documentation correctly says its optional cost limit excludes planning, standalone review, tools, and image generation. The usage dashboard's main total is orchestration cost, with solo usage recorded separately as tokens. The problem is fragmented coverage, not the absence of all metering. Sources: [compaction call](/Users/nahid/Documents/locus/agent/ollama_code/core.py:4414), [usage recording](/Users/nahid/Documents/locus/agent/ollama_code/runstore.py:3822), and [usage summary UI](/Users/nahid/Documents/locus/Locus/UsageDashboardView.swift:310).

Record planning, execution, helpers, review, repair, compaction, and known tool costs under one task identity. Keep known API estimates, subscription usage, local execution, and unknown costs distinguishable. Show coverage when any component is unknown; never turn missing measurement into “free.” Keep a user-configured whole-task estimate limit separate from per-stage call allowances and from provider billing enforcement.

Measure elapsed time through an accepted result, including corrections. Break it into queue time, model generation, tools, review/repair, and waiting for the user. That tells the team whether to fix orchestration, context churn, slow tools, or excessive questioning. Claude's documented API/wall duration and cache usage are useful reference points, not proof that its estimates equal a bill. [Claude usage accounting](https://code.claude.com/docs/en/costs).

**8. Repair evaluation before using it to select models or advertise results**

The real evaluation entry point failed in an isolated store with a foreign-key error. It inserts a result referencing a run before creating the run. See [evaluation startup](/Users/nahid/Documents/locus/agent/ollama_code/evaluation_runtime.py:52), [result insertion](/Users/nahid/Documents/locus/agent/ollama_code/evaluations.py:119), and [foreign-key schema](/Users/nahid/Documents/locus/agent/ollama_code/runstore.py:303).

After explicitly precreating the expected run records solely to probe the downstream behavior, two more gaps appeared: a solo case stopped at `max_iterations` could pass a weak output assertion, and a rubric-only case with no configured judge passed without evaluating its rubric. Missing cost became zero. Comparison aggregation also merged distinct solo providers/models into one `solo` group. See [evaluation termination and judging](/Users/nahid/Documents/locus/agent/ollama_code/evaluation_runtime.py:208) and [comparison grouping](/Users/nahid/Documents/locus/agent/ollama_code/evaluations.py:411).

Fix startup ordering, classify incomplete runs accurately, reject or mark ungraded a required rubric without a judge, preserve unknown costs, and identify configurations by provider/model/version/settings/tool access. These are specific defects, not a request to replace the audit with a dashboard.

Afterward, use identical fixtures and acceptance criteria for Locus, native Codex, and native Claude Code. Separately compare Locus modes and recipes: direct, plan then work, goal, and capsule. Match the model where possible and record account type, effort, context, permissions, tool availability, app version, machine, and starting files. Report unmatched conditions explicitly. Browser/computer/document tasks need their own scenarios because the current evaluation runner disables several of those surfaces.

Start with representative work: a reproducible bug fix, multi-file change, long-context correction, interrupted capsule, changed dependency, document artifact, browser task, and provider failure. Repeat each condition; report raw sample sizes. Grade outcomes with predetermined checks and blinded human review where appropriate. Measure completion without intervention, human correction count and time, automatic repair attempts, elapsed time to acceptance, and known cost per accepted result. Include failures in the denominator and their consumed time and cost.

**Implementation order and acceptance criteria**

| Order | Work | Evidence that it improved |
|---|---|---|
| 1 | Completion/truncation, context retention, capsule execution-location validation, evaluation startup/grading | The reproduced false-success and context-loss cases no longer occur; divergent execution inputs are rejected or explicitly replanned |
| 2 | Shared task specification, step receipts, selective capsule resume, consistent repair/re-review | Interrupt after a valid step, restart, and finish without repeating it; a correction invalidates only affected work |
| 3 | Complete usage coverage, objective progress detection, proportional planning and instruction cleanup | Unknown usage stays unknown; paraphrased inactivity stops; simple tasks avoid unnecessary planning exchanges |
| 4 | Unified task UI, measured read-only concurrency, evidence-based model recipes | Less user effort and lower time/cost per accepted result on the same task set without lower acceptance quality |

Existing UI performance work should be measured rather than duplicated. The current uncommitted [panel audit](/Users/nahid/Documents/locus/Docs/PanelPerformanceAudit.md) already addresses repeated state publication, row construction, and file scanning. This audit did not establish live frame-time gains or that those changes have shipped. Validate long transcripts and large individual outputs on the real app, alongside task-flow usability.

**Five additional product ideas**

These are differentiation hypotheses. I did not find these exact integrated experiences in the Locus implementation and official competitor material inspected; this is not proof that no extension, experiment, or undocumented release offers them. Each builds on capabilities that already exist.

1. **Turn a correction into a reusable check.** When the user fixes a recurring mistake, propose a scoped acceptance check and show an example of what it would catch. Apply accepted checks across the user's chosen models. Include scope, an expiry/edit option, and evidence of where the check ran. The benefit is preventing repeated mistakes rather than merely recalling a preference.
2. **Show what would invalidate a plan.** Link important plan assumptions to files, source documents, decisions, and external facts. When one changes, show the affected steps, retained work, and the smallest revision required. The user sees why a saved plan became stale.
3. **Preview the time/cost tradeoff for this task.** Use measured results from similar local tasks to offer a few execution recipes with uncertainty ranges: quickest likely acceptable result, lower likely API spend, or more independent checking. Show missing evidence rather than inventing precise forecasts. Compare predicted and actual results after execution.
4. **Undo one requested change while keeping later work.** Let the user select an intent such as “the navigation redesign,” preview its file changes and dependent edits, and selectively reverse it while preserving unrelated work. For external tools, offer explicit supported compensating actions; never imply every action can be undone.
5. **Keep a completed result valid for a chosen period.** Attach an opt-in validity window to selected acceptance checks. If a dependency or source change invalidates the result, reopen the affected part with the reason and a bounded repair proposal. This differs from a generic schedule by tracking whether the accepted outcome still holds.

The first delivery should be dependable completion and resumable capsules. Those improvements make model choice useful in practice: the user can trust the handoff, see what has been verified, and continue without paying to reconstruct the task.
