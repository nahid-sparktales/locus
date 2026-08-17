---
name: gsd-quality
description: Apply GSD quality gates to code, security, debugging, evaluations, and interface work. Use for a structured code review, defect investigation, release audit, security pass, evaluation, or UI verification within a larger project.
---

# GSD Quality for Locus

Adapted from Get Shit Done by Lex Christopherson under the MIT License.

1. Select the narrowest quality operation that matches the risk.
2. Load the relevant Superpowers skill when available: systematic debugging for defects, verification before completion for claims, TDD for behavioral changes, and review skills for feedback.
3. Establish the intended behavior and evidence sources before inspecting implementation details.
4. Separate confirmed findings from hypotheses; rank confirmed findings by impact.
5. Fix only when the user asked for implementation. Re-run focused checks after changes and broader checks when the risk justifies them.

Read `references/workflows.md` for review, debug, security, evaluation, and UI gates.

Pre-flight: every reported defect must include reproducible evidence or a clearly marked uncertainty; every completion claim must cite fresh verification.
