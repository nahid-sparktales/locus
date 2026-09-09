# Agent Teams

Choose adaptive Solo work or configure explicit, durable multi-model teams.

Most requests can stay **Solo**. Solo collaboration can use reusable research helpers and isolated coding helpers. Helpers inherit the active provider, account, model, and reasoning settings; the coordinating agent reviews their evidence and validates combined changes. Non-Git or unsupported coding snapshots fall back to research instead of shared writes. Grill remains a one-question-at-a-time clarification flow and does not modify the project.

Choose an explicit team when you need named provider routes, roles, access ceilings, a dispatcher plan, dependency-ordered writers, team budgets, durable assignment history, or a final reviewer.

* [Set Up a Team](agent-teams/set-up-a-team.md)
* [Run & Monitor Team Work](agent-teams/run-and-monitor-team-work.md)
* [Recovery & Evaluation](agent-teams/recovery-and-evaluation.md)

## Fixed boundaries

* A dispatcher can route only to profiles in the selected team.
* Hosted members require one-time Automatic Hosted Routing consent.
* Read-only specialists may overlap; write-capable jobs are ordered or isolated in bounded parallel worktrees.
* Each team has hard job, round, concurrency, model-call, token, and cost limits.
* Credentials, hidden reasoning, and provider signatures are excluded from durable run history.
* Computer Control is foreground-only, writer-only, and globally exclusive.

Teams use the same permission mode and hard safety boundaries as Solo work. Selecting a team never grants broader access by itself.

Runs now has its own inspector icon. The orchestration glyph belongs to the team dispatcher, making the difference between “open run history” and “route a team” explicit.

## Agents, specialists, goals, and capsules

**Manage Agents** configures persistent scheduled or event-driven Agents. **Specialists & teams** configures reusable behavior, models, and access ceilings for delegated work.

An ordinary Solo or team chat can use a [Persistent Goal](working-in-locus/persistent-goals.md) for continued work across turns. [Task Capsules](working-in-locus/task-capsules.md) save a detailed plan with planning, implementation, and optional review profiles. Each keeps its own execution and recovery controls.
