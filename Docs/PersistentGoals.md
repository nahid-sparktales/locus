# Persistent goals

Persistent goals keep an objective with a chat and continue working across
ordinary agent turns. They support Solo and existing teams in Work mode.

## Using a goal

1. Open an idle ordinary chat and choose its model account or team.
2. Select **Goal** beside the composer. Enter the objective and, optionally,
   an allowance for model calls or tokens. Select **Start goal**.
3. Follow the goal card for progress and cumulative usage. Send a message to
   add instructions without replacing the objective.
4. Use **Pause** or the normal Stop control to stop automatic work. **Resume**
   returns to Work mode. **Edit** saves changes while paused; **End** finishes
   the goal without claiming its objective was achieved.

Switching to Ask, Plan, or Grill pauses the goal. Changing the selected model
or team also pauses it; use Goal to save the newly selected configuration
before resuming. Editing only the objective or allowances preserves usage.
Only one unfinished goal can belong to a chat.

Queued messages take priority over automatic continuation. Unsent drafts and
attachments remain in the composer. A successful agent turn is an intermediate
result: the goal finishes only after its coordinating agent reports evidence
that the objective is complete. Teams report this through their existing final
synthesis after required work and reviews settle.

## Limits and recovery

Locus must be running for work to execute. Quitting saves the goal; reopening
restores eligible goals and their original accounts, teams, and workspaces.
Paused, blocked, and exhausted goals require attention before continuing.

Goal allowances accumulate across turns, helpers, team stages, retries, and
restarts. They do not replace existing profile and team limits. Token usage is
the input and output usage exposed by the provider, including local and
subscription routes; it is not a currency estimate or remaining subscription
quota. Responses already in flight can exceed a token allowance. Provider-managed
internal calls can only be counted as the provider reports them. An allowance
that cannot be enforced from available measurements pauses the goal.

Permissions, required questions, and team dispatch approvals keep their existing
behavior. Losing a connection cannot answer a required question or grant an
approval. An interrupted tool or model operation whose outcome is unknown
requires review before Resume; Locus does not automatically replay that action.
Review the partial work and available usage before acknowledging recovery.

Missing accounts or checkouts and incompatible team changes block recovery.
Repeated missing or unchanged progress reports pause the goal instead of
creating an endless continuation loop. Ordinary execution errors and runtime
safety stops also stop automatic continuation.

Scheduled agents, automation workflows, Task Capsules, and private Identity
tasks retain their separate execution lifecycles. This version adds native Mac
controls and does not install a service that works after Locus quits.

## Ownership

`GoalModel` owns native presentation and continuation coordination. The
`AppModel+Goals` adapter resolves accounts and uses normal chat-worker admission.
`goals.py` owns goal state, continuation reservations, usage, and action records
inside the existing run database; `goal_runtime.py` binds that authority to a
single run and its helpers. Goal totals and recovery evidence survive ordinary
run-history retention.

Tests use disposable databases, fake model responses, and isolated native UI
fixtures. They require no live model account usage.
