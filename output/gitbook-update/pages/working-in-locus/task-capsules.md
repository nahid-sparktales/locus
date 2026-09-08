# Task Capsules

Save a detailed plan with explicit models for planning, implementation, and optional review. A capsule keeps its plan, revisions, model choices, usage allowances, and run history together.

## Set up and run

1. Connect the accounts you want to use under **Models & Providers**.
2. In **Specialists & teams**, configure reusable profiles with the desired account and model. An implementation profile needs an **Access ceiling** of **Workspace edits**. One profile can serve more than one role.
3. Open **Locus → Task Capsules…** or press **⌥⌘K** in the target workspace.
4. Describe the task or customize an editable example. Choose **Plan with**, **Implement with**, and optionally **Review with**. Set optional allowances under **Advanced · Usage limits**.
5. Select **Generate plan**. Planning is read-only; answer any clarification in its conversation. A successful structured plan saves automatically.
6. Reopen the capsule and review instructions, constraints, checks, and design decisions. **Expand steps** reveals the detail. Choose **Run plan** when ready.
7. Review stage outcomes and available usage in run history. **Review result** runs a separate read-only review; **Run again** starts another execution of an existing plan.

If profiles are missing, **Set up models** opens settings while preserving the task description. **Continue planning** returns to a waiting planner's conversation.

## Accounts remain explicit

Each stage uses the exact account assigned to its profile. An unavailable account stops the stage. ChatGPT-plan and Kimi Code membership routes never silently fall back to metered APIs. Capsule choices do not permanently replace the ordinary chat's model selection.

## Saved plans and changed files

A detailed plan can contain up to 16 ordered steps. Execution follows dependencies sequentially. Before execution, Locus checks fingerprints for files named in those steps, including planned new files. Changed, removed, or unexpectedly created files pause the handoff.

Choose **Update the plan or ask for help** to inspect the current workspace and save a revision. Fingerprints cover named files, not the whole repository. Older plans without named files have no file baseline.

## Limits, review, and recovery

Planning and standalone review have per-turn model-call allowances. Implementation, its automatic reviewer, and repairs share the execution allowance. Profile runtime and response limits still apply. A failed or malformed review does not count as approval.

Optional API cost limits are estimates for configured execution prices, not hard billing ceilings. They exclude planning, standalone review, tool charges, and image generation. Subscription routes record exposed calls and tokens without inventing per-token subscription prices.

Asking the planner for help is explicit. Repair and help allowances accumulate across the capsule, including later runs. Increasing a limit does not erase previous attempts.

Stopped work keeps the files already changed and its run evidence. Inspect them before repeating execution. Partial changes may require a revised plan; recovery returns to Task Capsules instead of silently restarting a team checkpoint.
