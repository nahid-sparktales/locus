---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree one decision at a time. The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet. Pick the highest-leverage question on that frontier, ask exactly that one question, give your recommended answer, and wait for the user's response before asking another.

Each question should be formatted like so:

```
❓ **Q1** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>
```

Each answer reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier before asking the next single question. A question whose answer depends on the current question belongs later.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment, inspect the repository and available evidence directly; don't ask the user for anything you can discover safely. The _decisions_ are the user's: put each to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not implement anything until the user explicitly confirms the shared understanding and asks you to proceed.
