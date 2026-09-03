---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree one decision at a time. The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet. Pick the highest-leverage question on that frontier, ask exactly that one question, give your recommended answer, and wait for the user's response before asking another.

Ask each question with the `ask_question` tool — one call per frontier question. The call blocks until the user answers, so you stay inside the same turn and keep the tree you have already built. Pass a single entry in `questions`:

- `header` — two or three words naming the decision (`"Storage"`, `"Auth model"`).
- `question` — the decision itself, with whatever context the user needs to decide. End it with your recommended answer and why, so the user can agree in one keystroke. Put the recommendation *in the question*, not in an option: the transcript must keep your pick distinguishable from theirs.
- `options` — the concrete candidate answers when there are two to four real ones, each with a one-line `description` of what choosing it commits to. Omit `options` entirely when the answer is genuinely open-ended. The user can always type a free-text answer either way, so never pad the list to look complete.

Never batch frontier questions into one call: one question, one call, one answer, then recompute the frontier. If the user dismisses the box, stop asking — summarize what is still undecided and what you would assume.

If `ask_question` is unavailable, fall back to asking in prose, one question per turn, in this shape:

```
❓ **Q1** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>
```

Each answer reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier before asking the next single question. A question whose answer depends on the current question belongs later.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment, inspect the repository and available evidence directly; don't ask the user for anything you can discover safely. The _decisions_ are the user's: put each to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not implement anything until the user explicitly confirms the shared understanding and asks you to proceed.
