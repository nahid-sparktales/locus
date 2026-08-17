# Workflow operations

## Discuss

Map the phase's decision tree. Ask one material preference at a time only after repository facts are exhausted. Write settled decisions and deferred questions to the phase context file.

## Plan

Split work into independently verifiable steps. Every step states its intended outcome, affected area, dependency, verification, and rollback or safe stopping point. Keep the plan within the active phase.

## Execute

Read the plan immediately before work. Implement in dependency order, run the focused check for each step, update state only after evidence exists, and stop at user approvals or unsafe external actions.

## Verify

Trace each acceptance criterion to code and test evidence. Report gaps as gaps. Record follow-up work instead of weakening the criterion.

## Progress and resume

Summarize verified phases, active phase, current step, blockers, pending decisions, changed files, tests, and the next safe action. Re-read the workspace before trusting stale state.
