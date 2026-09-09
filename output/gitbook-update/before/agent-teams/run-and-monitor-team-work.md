> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/agent-teams/run-and-monitor-team-work.md).

# Run & Monitor Team Work

Approve a dependency plan and supervise durable, run-scoped Solo and team activity.

Choose Team from the composer or mention an eligible team. Mentioning a member can force that profile when the team and job rules allow it.

## Dispatch and approval

The dispatcher must submit a validated, acyclic job graph. Locus shows the complete plan, assignments, dependencies, exact routes, and budget before writer work begins. You can edit the dispatch plan, approve it, or cancel.

Invalid output gets a bounded repair attempt. If repair still fails, Locus names the validation reason and can continue safely with the Lead Writer when the team policy allows it.

## Execution and isolation

Read-only research and test-design jobs may overlap. Writers are dependency-ordered. Optional parallel writer worktrees start from one immutable snapshot, integrate patches in plan order, and preserve a conflicting child checkout for inspection.

New Git tasks default to a private worktree whose baseline includes tracked, staged, unstaged, and untracked non-ignored source state. Applying the result to the original workspace is explicit, conflict-checked, unstaged, and uncommitted.

## Live board and Runs

The board under the user message moves through Planning, Approval, Specialists, Coding Jobs, Review, and Complete. It shows the active agent and model, waits, duration, calls, turn-level usage, subagent counts, branch controls, Pause, and Stop. Finished boards collapse to a written result summary; every completed turn ends with an answer even when the work was mostly tools.

Runs preserves ordered events, checkpoints, evidence, visible provider reasoning, redacted tools, budgets, retries, reassignment, replay, recovery, and the files a run produced. Search Activity for a model, profile, event, or fallback. Raw events live under Technical Log.

## Selected-run accuracy

Overview and Activity calculate request text, files, steps, agents, models, usage, and timing only from the run you selected—even while another run is active. Opening or reloading an older run no longer mixes in the live run's events.

A file created and then deleted during the same run is not listed as created. Expanded request text and “Show more” state reset when you choose a different run. Produced files written by direct tools or shell commands appear in Outputs and open in the appropriate Mac app.

Images on a team request reach the dispatcher and the first coding job. Specialists and reviewers receive text evidence. The transcript records that boundary.
