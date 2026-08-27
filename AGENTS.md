# Project agent instructions

At the start of any task-oriented session—any interaction where tools will
be used to produce deliverables—invoke the `task-observer` skill before
beginning work. Keep it active throughout execution, review, and follow-up
discussion so reusable workflow improvements are captured.

Whenever any skill is loaded, check `skill-observations/log.md` for OPEN
observations tagged to that skill and apply those insights to the current
work even if the live skill has not been updated yet. Load task-observer and
other applicable skills independently; do not chain their activation.

When the `vercel-cli` skill is used for repository linking, production
promotion, aliases, or rollback, also use `vercel-cli-extras` when it is
installed.
