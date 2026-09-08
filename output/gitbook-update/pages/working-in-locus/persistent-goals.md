# Persistent Goals

Give an ordinary Solo or team chat an objective that continues across turns in Work mode.

## Start and supervise a goal

1. Open an idle ordinary chat and choose the account or team that should do the work.
2. Select **Goal** beside the composer. Enter the objective and optional model-call or token allowances, then select **Start goal**.
3. Follow the goal card for progress and cumulative usage. Send a message to refine the request while keeping the objective.
4. Use **Pause** or Stop to stop automatic continuation. **Resume** returns to Work mode. **Edit** saves changes while paused. **End** closes the goal without claiming the objective was achieved.

Only one unfinished goal can belong to a chat. Switching to Ask, Plan, or Grill pauses it. Changing the model or team also pauses it; save the newly selected configuration through Goal before resuming. Editing the objective or allowances preserves accumulated usage.

Queued messages take priority over automatic continuation. Unsent drafts and attachments stay in the composer. A finished turn is an intermediate result: completion requires evidence from the coordinating agent that the objective has been achieved.

## Understand allowances

Usage accumulates across turns, helpers, team stages, retries, and restarts. Goal allowances do not replace profile or team limits. Tokens describe provider-reported input and output, not currency or remaining subscription quota. In-flight responses can exceed an allowance, and provider-internal work can only be counted as exposed by the provider.

If an allowance cannot be enforced from the available measurements, the goal pauses. Exhausted, blocked, and paused goals need attention before continuing.

## Reopen and recover

Locus must be running for work to execute. Quitting saves the goal; reopening restores eligible goals with their original account, team, and workspace. It does not install a service that works after Locus quits.

Review partial work and usage before resuming an interrupted operation with an unknown outcome. Locus does not automatically replay it. Missing accounts or workspaces, incompatible team changes, and repeated missing progress can stop continuation.

Permissions and required questions keep their normal behavior. Losing a connection or waiting longer never grants approval. Scheduled Agents, workflows, Task Capsules, and Identity tasks have separate execution lifecycles.
