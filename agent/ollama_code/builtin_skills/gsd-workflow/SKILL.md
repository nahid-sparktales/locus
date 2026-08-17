---
name: gsd-workflow
description: Run a methodical GSD phase workflow for large or iterative builds: discuss requirements, write a phase plan, execute in bounded steps, verify outcomes, and resume from recorded state. Use for multi-phase implementation, roadmap progress, or work that must survive interruptions.
---

# GSD Workflow for Locus

Adapted from Get Shit Done by Lex Christopherson under the MIT License. Locus uses its native plans, agents, approvals, and checkpoints; it does not invoke GSD's Node installer or hooks.

1. Read `.planning/PROJECT.md`, `ROADMAP.md`, and `STATE.md` when present.
2. Resolve discoverable facts from the workspace before asking the user.
3. For an unclear phase, discuss decisions before planning. For a clear phase, write a decision-complete plan with verification commands.
4. Execute one bounded plan slice at a time. Keep `.planning/STATE.md` current after verified boundaries, not speculative progress.
5. Verify the phase against its acceptance criteria and concrete test output before marking it complete.
6. On interruption, record the exact completed step, current evidence, blockers, and next command so another chat can resume safely.

Read `references/workflows.md` for the requested discuss, plan, execute, verify, phase, or progress operation.

Pre-flight: confirm that claimed progress matches files and test evidence, and that no unresolved checkpoint is presented as complete.
