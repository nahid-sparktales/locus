# Ask, Work, Plan & Grill

Choose conversation, adaptive work, planning, or a one-question-at-a-time Grill interview.

Locus separates conversation-only requests from project work and guided clarification.

| Mode          | Best for                                                                        | Project behavior                            |
| ------------- | ------------------------------------------------------------------------------- | ------------------------------------------- |
| **Ask** | Explanations, brainstorming, and attached material                              | Workspace tools are disabled                |
| **Work**      | Adaptive inspection, planning, implementation, and bounded research or isolated coding delegation | Tools are enabled as needed                 |
| **Plan**      | A reviewable implementation plan before changes                                 | Inspection and planning only until approval |
| **Grill**     | Stress-testing an idea or plan through one focused question at a time           | Does not modify anything                    |

![Plan mode with generated outputs, subagent activity, and context usage visible in the Overview inspector](https://831891047-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2FdQ03BivzJFZ7fKsPFhiD%2Fuploads%2F32XidrEy7OgDjkWCxOys%2Flocus-v2-plan.png?alt=media)

**Work** is the default agentic mode. It can answer directly, inspect first, implement, or ask helpers for research or isolated coding work. Select an explicit team only when you want named routes, a dispatcher plan, and team budgets.

## Grill mode

Use **Grill**, ⌥G, or `/grill` to refine a request through one focused question at a time. It develops a shared understanding before project changes. After approval, implementation continues in Work.

Required questions remain pending until answered; they do not gain approval from elapsed time. Optional questions can appear above the composer while independent work continues. Their visible recommendation may be used after Skip or the displayed timeout. A defaulted recommendation is labeled as such and is never permission to perform a protected action.

Older saved mode values remain compatible. Use the current Ask, Work, Plan, and Grill labels when choosing a mode.

## Plan approval

A completed Plan presents:

* **Proceed** to implement in Work under the current permission mode;
* **Revise** to keep the plan visible and request changes; or
* **Cancel** to return to Work without implementing.

Clarifying questions do not trigger plan approval. A queued message waits until the decision is resolved, and the decision survives reconnects.

## Steering and stopping

During a run, type direction and use **Steer Now** or ⌘↵ to interrupt the current provider stream and continue the same turn. You can also queue a message for the next turn or stop and send it as a fresh turn. When the composer is empty, the send control becomes Stop; Escape also stops.

## Attachments in every mode

Drag files onto the composer or conversation, or paste an image with ⌘V. Images can reach Work, Plan, and Grill, not only Ask. On a team run, the dispatcher and first coding job receive the image; specialist goals and review remain text-only.

Attachments are carried in memory for the active turn and are **not persisted**. A restored chat shows attachment names, not image bytes. If a provider rejects image input, Locus retries once without the images and records a note.

## ChatGPT conversation contract

Each ChatGPT-plan account has a **Codex-native mode** toggle. New accounts begin with Locus's own prompt and tools so approved memory, cross-chat context, and the skill index remain available. Existing accounts keep their previous setting.

Turn Codex-native mode on when you want the model's Codex prompt, voice, and Codex-shaped tools. Locus still enforces its permission prompts, deny lists, and edit previews, but approved memory, cross-chat continuity, and the skill index are deliberately absent. Changing the toggle restarts the conversation's server-side context.

Reasoning effort applies per turn. Optional OpenAI web search is off by default and sends search queries to OpenAI when enabled.

## Continue beyond one turn

Use [Goal](../working-in-locus/persistent-goals.md) for an ordinary Solo or team chat that should continue toward a saved objective. Use [Task Capsules](../working-in-locus/task-capsules.md) for a saved plan with explicit planning, implementation, and optional review models.
