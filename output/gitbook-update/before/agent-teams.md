> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/agent-teams.md).

# Agent Teams

Choose adaptive Solo work or configure explicit, durable multi-model teams.

Most requests can stay **Solo**. Adaptive Work and Plan may create temporary read-only workers when parallel investigation helps; they share the selected model and fixed limits while the primary agent remains responsible for the result. Grill remains a one-question-at-a-time clarification flow and does not modify the project.

Choose an explicit team when you need named provider routes, roles, access ceilings, a dispatcher plan, dependency-ordered writers, team budgets, durable assignment history, or a final reviewer.

* [Set Up a Team](/locus-docs/agent-teams/set-up-a-team.md)
* [Run & Monitor Team Work](/locus-docs/agent-teams/run-and-monitor-team-work.md)
* [Recovery & Evaluation](/locus-docs/agent-teams/recovery-and-evaluation.md)

## Fixed boundaries

* A dispatcher can route only to profiles in the selected team.
* Hosted members require one-time Automatic Hosted Routing consent.
* Read-only specialists may overlap; write-capable jobs are ordered or isolated in bounded parallel worktrees.
* Each team has hard job, round, concurrency, model-call, token, and cost limits.
* Credentials, hidden reasoning, and provider signatures are excluded from durable run history.
* Computer Control is foreground-only, writer-only, and globally exclusive.

Teams use the same permission mode and hard safety boundaries as Solo work. Selecting a team never grants broader access by itself.

Runs now has its own inspector icon. The orchestration glyph belongs to the team dispatcher, making the difference between “open run history” and “route a team” explicit.
