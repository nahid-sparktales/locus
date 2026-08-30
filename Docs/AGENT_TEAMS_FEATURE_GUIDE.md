# Locus Agent Teams: Feature and Usage Guide

This guide explains the observable, recoverable, and adaptive agent-team features in Locus. It is written for people using the app; the protocol-level details remain in [`agent/PROTOCOL.md`](../agent/PROTOCOL.md).

## What changed at a glance

Locus can now keep a durable history of team runs, explain how agents were selected, recover interrupted work, evaluate Solo and team configurations, search workspace knowledge locally, and give each agent tightly controlled access to MCP servers.

The main areas are:

1. Adaptive Work, reliable plans, steering, and visible reasoning
2. Native Computer Control
3. Smooth streaming and transcript navigation
4. Workspace-organized chats and recoverable deletion
5. Multi-agent teams and isolated worktrees
6. Durable team runs, live boards, and Team Runs
7. Recovery and job-level controls
8. Evaluation Lab
9. Editable dispatch plans
10. Transparent scorecard routing
11. Local workspace knowledge and approved memory
12. Modern MCP resources, prompts, tasks, and security boundaries
13. Safety and compatibility behavior

## 1. Core workflow features

### Adaptive Work mode

**Work** is the default agentic mode. Neither Plan nor Build has to remain selected. Locus decides whether the request calls for an answer, inspection, planning, or implementation while staying within the current permission mode.

Plan and Build are optional toggles. Click the selected toggle again to return to Work. You can also use `/work` or `⌥W`.

Example: leave the composer in Work and send `Find why the tests fail and fix it if the cause is clear.` Locus may inspect first and then implement without requiring you to choose Plan or Build in advance.

### Reliable plan approval

Plan mode recognizes a completed plan through the structured plan tool and safe deterministic fallbacks. Clarifying questions do not trigger approval — they raise the question prompt instead (see below).

After a successful planning turn, Locus offers:

- **Proceed**: switch to Build and implement with the current permission mode
- **Revise**: stay in Plan, keep the plan visible, and focus the composer for changes
- **Cancel**: return to adaptive Work without implementing

Queued work waits until the decision is resolved, and the pending choice survives reconnects. Use `1`–`3`, arrow keys, Return, or Escape; Escape maps to Cancel.

### Questions from the agent

When the agent asks the user a question — most prominently Grill mode's one-at-a-time clarifying questions — it calls the `ask_user_question` tool, and the question replaces the composer once the turn completes, the way plan approval does. The popup shows the question, its multiple-choice options when there are any (the agent's recommended answer preselected), and always a free-text row for typing your own answer. Grill turns that write the `❓` question block without calling the tool are detected from the text as a fallback. The answer is sent back as an ordinary user message; Escape dismisses the popup so you can answer in the composer instead, and queued work waits until the question is resolved or dismissed.

Example: ask Plan mode to design a database migration. Choose Revise and send `Keep the old schema readable for one release`, then choose Proceed when the revised plan is ready.

### Steer an active response

While a turn is running, `⌘↵` and the primary send button become **Steer Now**. A steering message interrupts the active provider stream, adds the direction to the same turn, and continues without creating an intermediate completed turn.

The adjacent options are:

- **Queue for Next Turn**: wait until the current turn finishes
- **Stop & Send as New Turn**: stop the current turn, wait for its terminal event, then start a fresh turn

If a tool is already running, Locus safely finishes or stops that action before applying the steering message.

Example: while Locus is implementing a REST endpoint, send `Steer Now: use the existing repository pattern instead of adding a new service layer.` The same turn changes direction and continues.

### Visible reasoning controls

Locus displays only reasoning explicitly supplied by the selected provider or inline `<think>` output. It never reconstructs hidden or redacted reasoning and never exposes provider signatures.

Use the **Thinking** selector or `/thinking` to choose:

- **Hidden**: answers only
- **Collapsed**: reasoning appears where it occurred as a lightweight inline summary disclosure
- **Expanded**: the existing detailed reasoning cards are pinned open where they occurred

The same setting applies to live responses, resumed history, and each agent in a team.

Example: select Collapsed during normal coding, then expand only the Reviewer's inline reasoning summary when you want to understand why it rejected a change.

Tool activity follows the same chronology. **Collapsed** groups only adjacent calls into inline activity summaries such as “Read files, ran commands”; **Verbose** keeps each detailed tool card; **Hidden** shows only generic activity status at the original run position.

### Live work status

The work-status strip reports the truthful current phase, elapsed time, active tool, permission wait, steering state, estimated streaming tokens, and final provider-reported token totals.

Example: when output pauses, the status may show `Waiting for permission · bash` rather than making the app appear frozen.

## 2. Native Computer Control

Open **Settings → Permissions → Computer Control**. The feature is disabled by default and reports Accessibility and Screen Recording permission separately.

Computer Control is available only in the signed direct-download build. The Mac App Store build explains why it is unavailable under App Sandbox.

### Supported actions

When enabled, the writer can:

- List and activate apps
- Inspect a bounded Accessibility tree
- Click accessible elements
- Set or type text
- Press keys
- Scroll and drag
- Capture the target app window when visual context is needed

Element identifiers belong to the latest state snapshot and are refreshed after actions. Screenshots prefer the target window, exclude Locus, and keep only the newest image in model context.

Example: ask `Open Xcode, select the Locus scheme, and run the tests.` The writer inspects Xcode's accessible controls, activates the app, clicks the scheme, and presses the run shortcut.

### Permissions and screenshot consent

Read-only inspection is automatic when Computer Control is enabled. Mutations follow the global permission mode:

- Ask and Accept Edits continue to ask before computer mutations.
- Bypass permits ordinary clicks, typing, keys, scrolling, and dragging.

Local Ollama screenshots remain local. Before the first screenshot sent to a hosted provider in a session, Locus names the provider and asks for consent. If the route rejects images, Locus retries once with Accessibility text only and keeps that route text-only for the session.

Example: decline hosted screenshot consent while using Claude. Locus can continue through accessible text and controls without uploading the target window image.

### Hard safety boundaries

Bypass cannot override the following safeguards:

- Secure fields are masked.
- Credentials, password changes, browser security interstitials, contracts, and final financial transactions require user takeover.
- Irreversible deletion, privacy/security changes, installation, uploads, and other high-consequence actions require confirmation.
- Computer Control is writer-only, foreground-only, and globally exclusive.

Example: Locus may fill ordinary form text, but it stops and asks you to take over when the next field is a password or the next click would confirm a purchase.

## 3. Smooth streaming and transcript navigation

Streaming replies now use display-synchronized updates and append-only native text rendering instead of repeatedly rebuilding the full SwiftUI transcript.

Behavior while reading:

- Any upward wheel, trackpad, scrollbar, or live-scroll movement detaches auto-follow immediately.
- Streaming never moves a detached viewport.
- Returning within 24 points of the bottom re-enables follow.
- **Jump to Latest** performs the intentional animated bottom scroll and restores following.
- Finished replies replace the lightweight live text with cached Markdown.

Example: scroll up to compare an earlier code block while a 100 KB answer streams. Your viewport remains fixed. Select Jump to Latest when you are ready to follow the live answer again.

Historical message rows are isolated from active streaming updates, so long chat histories no longer re-render on every token batch.

## 4. Workspace-organized chats

Workspaces are real folders and appear as expandable groups in the sidebar. Each workspace contains its chats, remembers whether it is expanded, and sorts pinned chats before recent chats.

Use the sidebar add button to choose:

- **New Workspace Folder…**
- **Add Existing Folder…**

Selecting a workspace opens its most recent chat. If it has none, Locus creates a blank chat. Use the workspace's new-chat button or `⌘N` to create another chat under the active workspace. Older chats without workspace information appear under **Other Chats**.

Example: add `~/Projects/Locus` and `~/Projects/Website`. Each sidebar group keeps a separate chat history while remaining backed by its actual project folder.

### Recoverable individual chat deletion

Choose **Delete Chat** from a chat's context menu. Locus moves the session and metadata into a unique recovery batch without deleting project files or the workspace folder.

An **Undo** toast restores the chat. If the active chat is deleted, Locus creates a blank replacement in the same workspace first so the backend never points at a removed session.

Example: delete an obsolete debugging chat, then select Undo when you realize it contains a useful command. The chat returns to its original workspace group.

## 5. Multi-agent execution and worktree isolation

Choose Solo or Team from the composer. `@AgentName` forces an eligible member of the selected team, while `@TeamName` selects a configured team.

The dispatcher creates the approved top-level plan. Read-only planners, researchers, testers, and reviewers may run concurrently and, when adaptive delegation is enabled, may request bounded read-only child branches for narrower evidence gathering. Each logical agent gets one child wave and one final aggregation pass; writers never delegate. A plan may assign multiple write-capable coding agents, but every coding job is dependency-ordered and Locus runs them one at a time in the shared checkout.

Example: send `@Mac App Team investigate the scrolling regression, update the backend contract, implement the SwiftUI fix, run tests, and review the diff.` The dispatcher can schedule research and test-design in parallel, then run a backend coding job followed by a UI coding job.

### Global scheduling and background tasks

Locus permits three simultaneous model calls by default and schedules leases fairly across chats. Leases expire after a crash or lost heartbeat. Team job, round, call, concurrency, token, and cost budgets keep orchestration bounded.

Each running chat has its own worker state, allowing other chats and workspaces to remain usable while work continues. Background permission requests pause only their originating job and navigate back to the correct chat when attention is needed. Servers, watchers, and queue workers should use the `background_service` tool: Locus owns them outside the task, shows them above the Terminal, and keeps them running when the task is stopped. They end only when explicitly stopped or the owning backend quits.

Example: start a team refactor in one workspace, switch to another chat for a question, and return later to inspect the first run's progress.

### Isolated managed worktrees

New Git team tasks use a detached private worktree by default. Locus reproduces tracked, staged, unstaged, and untracked non-ignored source state in a private baseline without changing the source checkout.

When **Run independent coding jobs in parallel worktrees** is enabled, every dependency-ready writer receives a child checkout at the same immutable snapshot. Locus runs a bounded wave, integrates patches in plan order, and emits a structured conflict while preserving the child checkout if two patches collide. Dependent writers run after the changes they need have been integrated. Specialists and reviewers see read-only state. **Use Current Folder** remains available when isolation is unsuitable; dirty submodules require an explicit choice rather than being flattened or copied unsafely.

Example: begin a team task with local uncommitted edits. The team receives a private baseline containing those edits, while your original branch, index, and working files remain untouched until you explicitly apply the patch.

## Before you start: create a team

Open **Settings → Agents & Teams**.

### Quick Team

For the shortest setup, choose **Create Quick Team** in Agents & Teams or open
the Solo/Team control beside the composer modes and choose **Create Quick
Team**. The visual builder has three lanes:

- **Dispatcher** plans the run and decides which selected helpers are useful.
- **Lead editor** is the only quick-team member allowed to edit workspace files.
- **Helpers** are optional read-only models for research, planning, and review.

Choose a lane, then select a model card. Dispatcher and Lead editor may use the
same model; Locus still gives them separate, safely scoped profiles. Models are
grouped by provider, so identical model names from different accounts remain
distinct. Hosted providers require an explicit automatic-routing approval
before **Create & Use Team** becomes available.

Quick Team saves and selects the result immediately. It uses scorecard routing,
one-time plan review, a managed worktree, automatic call budgeting, and adaptive
read-only delegation. The generated profiles and team appear in the existing
advanced sections, where every role, instruction, budget, routing weight, and
tool policy remains editable.

The composer’s Solo/Team popover shows each saved team as a card with its
dispatcher, lead editor, helper models, providers, and any setup warning. Choose
**Solo** there to return to the conversation model without deleting the team.

### Agent profiles

An agent profile describes one model and the job it is allowed to perform. A profile includes:

- A name, such as `Local Planner` or `Claude Reviewer`
- A role: Dispatcher, Planner, Researcher, Implementer, Tester, Reviewer, or Generalist
- A provider route and exact model
- Custom role instructions, with a role template as a starting point
- Capability tags, such as `swift`, `research`, or `tests`
- An access ceiling: read-only, workspace write, or computer control
- A visible checkbox list of standard tool groups for read-only agents
- A left-aligned **Advanced Settings** disclosure containing timeout, token
  limits, optional metered cost rates, and explicit MCP allowlists

Use **Test Connection** before adding a profile to a team.

Example: create these profiles:

- `Local Dispatcher`: vLLM or Ollama, Dispatcher role, read-only
- `Code Researcher`: Kimi or Ollama, Researcher role, read-only, tags `code, research`
- `Primary Writer`: Claude or another coding model, Implementer role, workspace-write access
- `Final Reviewer`: Claude or a local model, Reviewer role, read-only, tags `review, tests`

### Explicit teams

A team defines which profiles may collaborate. The dispatcher cannot discover or route to accounts outside that team.

Every team has:

- One dispatcher and an optional fallback dispatcher
- One write-capable **Lead Writer** for safe fallback and combined review fixes
- Any number of additional write-capable coding members
- Any number of read-only specialists and reviewers
- Dispatch and routing behavior
- Hard limits for jobs, rounds, concurrent calls, total model calls, metered tokens, and estimated cost
- An adaptive swarm policy with execution engine, read-only delegation toggle,
  maximum total agents, and maximum tree depth

Example: create `Mac App Team`, select `Local Dispatcher`, `Code Researcher`, `Backend Writer`, `UI Writer`, and `Final Reviewer`, then set `Backend Writer` as Lead Writer. A plan can order Backend Writer before UI Writer, while the Lead Writer remains responsible for fallback and post-review integration.

Hosted provider accounts require one-time consent under **Automatic Hosted Routing** before the dispatcher may send team data to them automatically.

New teams default to adaptive Locus execution, eight total agents, depth two,
and three simultaneous model calls. Previously saved teams with no swarm policy
remain flat for compatibility. The optional **OpenAI Responses beta** engine is
shown only for an OpenAI API account using a GPT-5.6 dispatcher; it is not used
with ChatGPT-managed accounts. If that beta path is unavailable, the run pauses
and offers **Run with Locus**—billing or execution never switches silently.

## 6. Durable team runs

### Local run history

Every team run is recorded in a local SQLite run store before its events are delivered to the interface. This makes the detailed run history authoritative and replayable even if the app reconnects.

The store records:

- Ordered lifecycle events
- Job attempts and dependencies
- Checkpoints
- Visible agent output and provider-supplied reasoning
- Redacted tool previews and results
- Evidence, timing, tokens, and estimated cost
- Stable node identity, parent identity, depth, execution engine, and attempts
- Scheduler waits, permission waits, fallbacks, revisions, and errors

It never records API keys, authorization headers, secure-field values, provider signatures, or hidden reasoning.

Example: if Wi-Fi drops during a reviewer job, reopen the same chat. Locus asks for all events after the last sequence it saw and deduplicates them, so the Inspector fills in the missing activity without duplicating earlier events.

### Live team run board

Each team request owns one durable board directly below its user message. The
same board progresses through Planning → Approval → Specialists → ordered
Coding Jobs → Review → Complete, and returns to the same message after a
relaunch. Multiple team requests in one chat keep separate boards.

During dispatch the board names the dispatcher route, elapsed time, request,
observable stage, and any bounded validation correction. At approval it shows
the complete ordered plan and its budget. While running it shows the active
agent/model, hierarchical agent tree, job position, waits, duration, calls,
tokens, branch Stop/Retry controls, Pause, and Stop.
Terminal boards collapse automatically to a result summary with Expand and
**Open Team Runs**. Raw model output and hidden reasoning are not shown.

The ordinary composer remains usable throughout. A message sent while a plan
awaits approval is queued for the next turn and cannot modify the pending plan.
The Team Progress button immediately left of the header's context meter scrolls
to the active board or opens Team Runs when the board is not in view.

### Team Runs: Overview and Activity

**Overview** explains the request, state, phase, assignments and exact models,
results, changed files, duration, usage, and recovery actions. **Activity**
groups human-readable events by phase. Its filter searches agents, event types,
job state, and attempts. Raw events and dependency details are available only
under the optional **Technical Log** disclosure.

Example: search for `fallback` to see whether the primary dispatcher failed and which fallback route Locus used.

If a dispatcher returns a plan that Locus cannot validate, the live board first
shows **Correcting dispatcher plan…**. Activity records the bounded reason.
If the corrected plan is still invalid, Locus continues safely with the team's
Lead Writer and states why specialists were skipped; raw provider output
and credentials are not written to run history.

The Team Runs assignment cards group work by job and attempt. Each row can show:

- Agent, provider, and exact model
- Assigned goal and role
- Visible output and provider-supplied reasoning
- Evidence and tool activity
- Elapsed time and token use
- Retry and reassignment actions

Example: a researcher and tester may finish independently before the writer starts. The Dependencies view makes those prerequisites visible and shows which results the writer received.

### Baseline-relative changes

For managed Git tasks, the Inspector shows work relative to the task's private baseline, including committed and uncommitted edits, new files, deletions, renames, and binary changes.

Available actions are:

- **Apply to Workspace**: check the complete patch for conflicts, then leave the applied changes unstaged and uncommitted
- **Copy Patch**: copy the current baseline-relative patch
- **Open Checkout**: open the isolated task checkout
- **Reveal in Finder**: reveal the checkout folder

Example: let a team update three Swift files in its managed checkout. Review the diff, click **Apply to Workspace**, and continue working in the original workspace with those changes still uncommitted.

### Pinning and retention

Detailed run events are retained for 90 days or until the run database reaches 2 GB, whichever happens first. Pinned runs are preserved. Ordinary chat transcripts are not removed by this retention process.

Example: pin a release investigation so its agent trace and evidence remain available beyond the normal retention window.

### Redacted `.locusrun` export

Use Team Runs' **Export** menu to create a portable `.locusrun` file.

- **Redacted .locusrun** excludes conversation, goals, output, reasoning, tool arguments, and tool results.
- **Include Visible Content…** includes content the user could already see.
- Credentials and hidden provider data are always removed.

Example: export a redacted run when reporting a scheduling bug. The file contains event order, timing, states, and usage without including the source-code discussion.

### Optional OpenTelemetry export

Under **Settings → Agents & Teams → Optional Telemetry**, Locus can send completed Solo and team traces through the official OpenTelemetry SDK and OTLP/HTTP exporter.

The configured value may be an OTLP base URL or a legacy full `/v1/traces` URL. Automatic export is sampled metadata only. Sending visible content is an explicit, per-run confirmation in the Runs inspector. The optional Authorization header is stored unencrypted in ordinary local app settings; it is never placed in logs, local events, trace attributes, or error text.

Example: point Locus at an internal OpenTelemetry collector to compare dispatcher latency across machines. A failed collector does not fail the chat; the export is marked failed after three bounded attempts and can be retried manually.

## 7. Recovery and job controls

### Durable checkpoints

Locus creates checkpoints after:

- Dispatch validation
- Each terminal specialist wave
- Every writer turn
- Review
- Revision
- Final synthesis

Checkpoints describe reusable completed results and the current private baseline. They do not contain replayable tool commands.

Example: if Locus quits after the writer finishes but before review, the writer's checkout and diff remain intact. Recovery starts a continuation attempt; it does not repeat the writer's previous edits.

### Startup recovery

On startup, Locus checks whether an unfinished run has lost both its worker and scheduler lease. It then offers recovery without making a provider call automatically.

Available choices are:

- **Resume**: continue from the latest valid checkpoint
- **Inspect**: open the run without spending tokens
- **Discard Run**: mark the run discarded while leaving workspace files untouched

If a model, credential, profile, team, or checkout is missing, Locus shows a repair checklist and keeps the run inspectable.

Example: after restarting your Mac, select **Resume** on a recoverable run. Completed read-only research is reused if its team fingerprint and baseline still match; the interrupted job starts as a new attempt.

### Pause at a safe boundary

**Pause at Safe Boundary** requests a cooperative pause:

- Provider streams are interrupted cooperatively.
- Cancellable tools stop.
- A non-cancellable action finishes before the paused checkpoint is written.
- Pending permissions and computer actions are cancelled and must be requested again later.

Example: pause a long team run before closing your laptop. Resume it later from the Inspector without automatically replaying a shell command or UI action.

### Retry a job

In the Dependencies view, choose **Retry with Same Agent**. Locus creates a new attempt and invalidates only jobs that depend on the retried result. Unrelated completed branches remain reusable.

Example: retry a failed test-analysis job while keeping an already completed documentation-research job.

### Reassign a job

Choose **Reassign** and select an eligible member of the same explicit team. Locus applies the same dependency invalidation rules.

Reassignment cannot:

- Select an account outside the team
- Elevate the job's access
- Change a completed coding job or replace the team's Lead Writer during recovery

Example: move a read-only reviewer job from a temporarily unavailable hosted model to a local reviewer profile.

### Replay and duplicate

- **Replay Same Baseline** creates a new run from the original immutable task baseline.
- **Duplicate from Current Workspace** creates a new run from the workspace as it exists now.

Example: replay the same baseline with different routing weights for a fair comparison. Use Duplicate instead when you want the next run to include edits made since the original task began.

### Stop, discard, and checkout cleanup

- **Stop Run** cancels all jobs in the active orchestration.
- **Discard Run** discards orchestration state but never deletes workspace files.
- **Clean Up Managed Checkout** snapshots and removes an unused private checkout; Restore Worktree recreates it later.

Example: discard a failed experiment but leave its checkout available for inspection. Clean it up later to reclaim disk space without losing the restorable snapshot.

## 8. Evaluation Lab

Open **Settings → Agents & Teams → Evaluations**.

### Reusable suites and cases

An evaluation suite contains one or more cases. Each case can define:

- Prompt and tags
- Solo or team target
- A selected team
- Coding or read-only mode
- Timeout
- Per-case orchestration budget; team cases apply every job, round, call, concurrency, and token limit, while Solo cases use the timeout and call limit
- Deterministic assertions
- Optional subjective rubric and reviewer judge
- Passing score

Suites can be imported from or exported to JSON.

Example: create a `Swift Regression` suite with one Solo case and one Team case that both ask Locus to fix the same fixture bug.

### Immutable evaluation fixtures

When a Git-backed suite is saved, Locus captures an immutable private baseline for each case. Every execution replays that fixture into a new disposable checkout.

Evaluation changes can never be applied to the source workspace. Computer Control and mutating MCP tools are disabled.

Example: save a suite while `Parser.swift` contains a known bug. Even if the real workspace is fixed next week, replaying that case still starts from the original buggy fixture.

### Deterministic assertions

Supported checks include:

- Command exit status
- Required or forbidden files
- Exact, contains, or regular-expression file content
- Allowed or forbidden changed paths
- JSON value and schema checks
- Expected text or regular-expression output

Required deterministic failures always fail the case.

Example: require `swift test` to exit with `0`, require `Tests/ParserTests.swift`, forbid changes under `Secrets/**`, and require `Package.swift` to contain a specific dependency version.

### Blind subjective judge

If a case has a rubric, select a Reviewer profile as the judge. The judge sees the case, rubric, output, diff, tests, and evidence, but not provider or model names.

The score is labelled subjective and cannot override a required deterministic failure.

Example rubric: “Score maintainability, clarity, and test coverage from 0–100.” Set the passing threshold to 85. A score of 92 still fails if the required test command failed.

### Results and comparisons

Evaluation reports compare configurations by:

- Pass rate
- Average subjective score
- Median and p95 latency
- Model calls and retries
- Prompt and completion tokens
- Estimated cost
- Failure categories

Example: run the same suite against Solo, `Local Team`, and `Hosted Team`. Use the report to decide whether the team improves pass rate enough to justify additional latency or cost.

Successful, unpinned evaluation checkouts are eligible for automatic cleanup after seven days. Failed or pinned fixtures are retained for inspection.

## 9. Editable dispatch plans

### One approval for the complete plan

Every native Locus team pauses once after the dispatcher returns a validated
plan and before any jobs begin. The plan appears in the request's live board
with its jobs, assignments, dependencies, and budget.

- **Run Plan** approves the entire dependency graph. Locus does not ask again
  for each model, agent, job, or step.
- **Re-dispatch** rejects that candidate and asks the dispatcher for a
  replacement, which is shown for approval when ready.
- **Cancel** stops the run before any jobs begin.

Security-sensitive tool permission prompts remain separate and continue to
follow the selected permission mode. Older teams saved as Automatic are moved
to this one-time plan review behavior when Locus loads them.

### Dispatch graph editor

The editor lets you:

- Change the plan summary
- Add or remove specialist jobs
- Edit job goals
- Change dependencies
- Reassign eligible agents
- Adjust the run's job, round, call, concurrency, hosted-token, and estimated-cost limits

Locus validates every edit continuously. **Run Plan** remains disabled if the graph has a cycle, unknown member, missing capability, invalid writer, missing consent, or invalid budget.

Example: the dispatcher proposes Research → Writer → Review. Add a parallel Test Design job and make Writer depend on both Research and Test Design before selecting **Run Plan**.

### Re-dispatch and cancel

- **Re-dispatch** asks the dispatcher for a new plan within the remaining budget.
- **Cancel** returns without starting the plan.

The pending one-time approval survives reconnects.

### Automatic and fixed call budgets

New teams use **Automatic** call budgeting: an adaptive pool capped at 100 model
calls. Coding models work in bounded slices. After each slice Locus either
continues the same coding job, or preserves enough calls for later ordered
writers, review, possible Lead Writer revision, and synthesis. Older teams that
still have the former untouched 12-call default migrate to Automatic; explicitly
customized limits remain Fixed.

A coding job reaching its model-call allocation or the separate 100-step team
writer guard is incomplete, never successful. Locus checkpoints and pauses the
run with an accurate reason and Resume/Discard actions. Later writers, review,
and synthesis do not begin until the coding job genuinely completes. Solo turns
retain their independent 40-step safety ceiling.

Example: select Re-dispatch when the proposed plan spends three specialist jobs on documentation but the task is primarily a test failure.

## 10. Transparent scorecard routing

### Manual and scorecard modes

Team routing can be:

- **Manual**: use the agents assigned by the dispatch plan.
- **Scorecard**: choose eligible specialists, testers, and reviewers using observed results.

The dispatcher, fallback dispatcher, and writer remain fixed.

### Hard gates

Before scoring, Locus excludes candidates that fail any required boundary, including:

- Explicit team membership
- Required role or capability tags
- Access ceiling
- Privacy and hosted-routing consent
- Context capacity
- Available credentials and model
- Provider health

Example: a reviewer with the best quality history is excluded if its hosted account is unavailable. Locus records that exclusion and considers the remaining eligible reviewers.

### Balanced 100-point score

The default score is:

- Quality: 40%
- Reliability: 20%
- Privacy/locality: 15%
- Latency: 15%
- User-entered cost: 10%

Weights are visible and editable. Locus uses up to the last 50 comparable live and evaluation results with recency weighting. Before five comparable evaluations exist, quality is pulled toward neutral and displayed as **Limited data**.

Example: a local Ollama tester may win a test-triage job because it is private, fast, and reliable, while a hosted reviewer wins a security-review job due to much stronger matching evaluation quality.

### Routing explanations

Every routing decision records:

- Eligible candidates
- Excluded candidates and reasons
- Each score component
- Limited-data status
- Fallback behavior
- Final selection

Open the Timeline and inspect a routing event row to read the explanation.

### Hard cost ceiling

Teams can define a maximum estimated cost per run using the cost rates entered on agent profiles. The run stops when the ceiling is exceeded.

Example: set a hosted team to a maximum estimated cost of `$5`. Even if model-call and token budgets remain, Locus will not continue routing paid calls after the estimated total crosses that limit.

## 11. Memory 2.0 and local workspace knowledge

Open **Settings → Knowledge**.

The main page follows a three-step model: the agent suggests a durable memory,
you review it, and later turns recall it only when relevant. A record has a
scope (personal, workspace, or one agent), a type (preference, fact, decision,
procedure, or relationship), confidence, optional expiry, and source
provenance. Conflicts are never silently overwritten: choose **Keep Both** or
**Replace Older**. The UI explains why recalled items matched. Index model,
exclusions, rebuild, import/export, and destructive maintenance live under
**Advanced Memory Settings**. **Review Health** marks expired records stale and
reports conflicts without silently rewriting them.

### Workspace-isolated text index

Enable **Index this workspace** to build a local FTS5 text index. Each canonical workspace has its own database, so results cannot cross workspace boundaries.

Locus excludes:

- Git-ignored files
- User-configured exclusion globs
- Hidden, build, and vendor directories
- Symlink escapes
- Binary files
- Files larger than 2 MB
- Common credential, environment-secret, key, and certificate files

Example: open Project A and ask, “Where is session recovery implemented?” Agents may retrieve matching snippets from Project A, but never from Project B's index.

### Incremental indexing

The index updates after workspace-open events, Locus file mutations, and native filesystem notifications. Content hashes prevent unchanged files from being reprocessed.

Use **Rebuild Index** when changing broad exclusions or troubleshooting stale results.

Example: after renaming `RunStore.py`, the watcher removes the old path and indexes the new path without rebuilding the entire project.

### Optional local vector search

Enter an installed local Ollama embedding model to add semantic search. Embeddings are sent only to a loopback Ollama `/api/embed` endpoint.

Changing models starts a new vector generation and rebuilds it in the background. Text search remains available if vector search is unavailable.

Example: with a local embedding model selected, “where do interrupted tasks continue?” can find recovery code even when the exact word `resume` is absent.

### Agent knowledge search

Eligible agents receive the permission-free `search_workspace_knowledge` tool. Results include bounded snippets, relative paths, line ranges, freshness, and whether they came from text, vectors, or approved memory.

Retrieved content is marked as untrusted data. It cannot change system instructions, permissions, agent membership, or access boundaries. Just Chat remains isolated from workspace knowledge.

Example: a researcher searches `scheduler lease cleanup`, cites the matching files and lines, and passes that evidence to the writer. A malicious instruction found in a source comment is treated as project text, not as an instruction to the agent.

### Approved encrypted memory

Memory stores preferences, facts, decisions, procedures, and relationships only
after explicit approval. Text ranking and optional local semantic vectors are
combined with confidence, recency, pin, stale, and validity signals. Memory
content and semantic vectors remain AES-256-GCM encrypted at rest.

Create memory with:

- **Remember** in Knowledge settings
- `/remember your text` in a workspace chat

Memories can be inspected, edited, pinned, linked to their source, marked stale, or deleted. They are never saved automatically from ordinary conversation.

Example: use `/remember ReleaseMAS must never expose Computer Control`. Future eligible agents can retrieve that convention in this workspace.

### Delete all knowledge

**Delete All Workspace Knowledge…** removes the workspace's text/vector index and approved memories. It does not delete project files or chat transcripts.

## 12. Modern MCP support

MCP servers are managed under **Settings → Extensions**. Agent-specific access is configured in each profile under **MCP access · none by default**.

### Deferred resources

Agents can search and read allowlisted MCP resources without loading every server item into every prompt.

The tools are:

- `search_extension_resources`
- `read_extension_resource`

Server catalogs follow their cache lifetime and are bounded by item count and payload size. Returned resources are treated as untrusted external evidence.

Example: allow a researcher to search an internal documentation server and read only the two resources relevant to an API migration.

### Deferred prompts

Agents can discover and load explicitly allowlisted MCP prompts with:

- `search_extension_prompts`
- `load_extension_prompt`

Prompts require explicit allowlisting because they introduce instructions rather than ordinary evidence.

Example: allow only the `security-review` prompt for a Reviewer profile. Other prompts exposed by the same server remain unavailable.

### Long-running MCP tasks

Servers that support MCP Tasks can return a task ID for long-running work. Locus persists:

- Task and originating run/job/tool-call IDs
- Progress and state
- Cancellation
- Terminal result
- Reconnect lookup information

Locus never reconnects or spends work automatically at startup; lookup and cancellation are explicit.

Example: an allowlisted code-analysis tool starts a ten-minute scan. Close and reopen the Inspector, then explicitly look up the persisted task to recover its progress or cancel it.

### Secure input requests

MCP form input accepts only schema-valid, non-sensitive fields. Credentials, API keys, payments, and similar sensitive data must use a verified out-of-band HTTPS URL flow.

Declining or cancelling input returns a normal terminal result to the originating job.

Example: a server may ask for a report title in an in-app form. If it needs an API credential, Locus opens the server's verified authorization URL instead of placing the secret in a model-visible form.

### Hardened OAuth

MCP OAuth uses:

- PKCE
- Server metadata discovery
- Exact issuer validation
- Exact redirect scheme, host, port, and path validation
- No token passthrough between origins

Tokens remain in the local credential store.

Example: an OAuth callback using the correct scheme but a different host or path is rejected rather than accepted as “close enough.”

### Per-agent MCP policy

Every profile starts with no MCP access. A policy can explicitly allow:

- Server IDs
- Tool names
- Resource URIs or names
- Prompt names

Read-only agents can use only allowlisted tools that the server marks read-only and non-destructive. Mutating MCP tools remain writer-only and continue through Locus permissions and hard guardrails. Dispatchers and reviewers remain read-only.

Example: give `Code Researcher` read access to `search_issues` and an engineering-handbook resource. Give only `Primary Writer` access to `update_issue`, which still asks for permission according to the current permission mode.

## 13. Safety and compatibility behavior

### Independent capability flags

Each major area can be disabled independently without deleting its stored data:

- `LOCUS_CAPABILITY_DURABLE_RUNS`
- `LOCUS_CAPABILITY_RECOVERY_CONTROLS`
- `LOCUS_CAPABILITY_EVALUATIONS`
- `LOCUS_CAPABILITY_ADAPTIVE_ROUTING`
- `LOCUS_CAPABILITY_WORKSPACE_KNOWLEDGE`
- `LOCUS_CAPABILITY_MODERN_MCP`

They are enabled by default. Set a flag to `0`, `false`, `no`, `off`, or `disabled` before launching the backend to turn off that capability.

Example: launch a support build with `LOCUS_CAPABILITY_MODERN_MCP=0` to isolate an MCP compatibility problem while keeping run history and recovery available.

### Existing data remains compatible

- Existing chats and session JSONL files remain valid.
- The chat transcript remains the canonical conversation history.
- Older team and profile settings decode with safe defaults.
- Older agent-activity snapshots appear as legacy, non-replayable runs when inspected.
- Solo mode continues to work without team configuration.
- Disabled features leave their stored data in place.

### Non-bypassable boundaries

The platform keeps these boundaries regardless of team or permission settings:

- Teams are explicit and non-recursive.
- At most one coding job may mutate a task checkout at a time; all writer jobs are transitively dependency-ordered.
- Read-only agents cannot elevate themselves or invoke mutation tools.
- Computer Control remains writer-only, foreground-only, and unavailable in evaluations.
- Evaluation changes cannot be applied to the source workspace.
- Locus does not automatically merge, commit, or apply team changes.
- Reopening Locus never automatically resumes work or spends hosted tokens.
- Hidden reasoning, provider signatures, and credentials are never reconstructed or persisted.

## End-to-end example

Suppose you want a team to fix a Swift concurrency bug safely:

1. In **Settings → Agents & Teams**, create a local Dispatcher, a read-only Researcher, one or more workspace-write Implementers, and a read-only Reviewer. Choose one Implementer as Lead Writer.
2. Create `Swift Team`, choose scorecard routing, and set a `$3` estimated-cost ceiling.
3. In the composer, select Team and `Swift Team`, then send: `Investigate and fix the actor-isolation warnings. Add regression tests.`
4. Review the proposed dependency graph. Add a parallel test-design job if needed, then choose **Run Plan**.
5. Use the live board while the team works, then click **Open Team Runs** for routing explanations, evidence, tokens, and checkpoints.
6. If the reviewer fails, retry or reassign only that job.
7. Review the baseline-relative diff and choose **Apply to Workspace**. Locus leaves the changes unstaged and uncommitted.
8. Save the task as an Evaluation case with required test and changed-path assertions.
9. Add `/remember Concurrency fixes require actor-isolation regression tests` so future eligible agents can retrieve the convention.
10. Export a redacted `.locusrun` if you need to share the orchestration trace without sharing code or conversation content.

This workflow keeps model routing visible, mutations isolated, recovery explicit, and long-term memory under user control.
