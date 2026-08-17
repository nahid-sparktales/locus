---
name: gsd-context
description: Build or refresh GSD codebase intelligence mid-flight: map architecture, trace dependencies and data flow, document important subsystems, and capture verified learnings. Use when a large codebase is unfamiliar, the roadmap is stale, or implementation discovers hidden structure.
---

# GSD Context for Locus

Adapted from Get Shit Done by Lex Christopherson under the MIT License.

1. Start from repository entry points, manifests, tests, and version-control state.
2. Map only relationships that materially affect the active goal: ownership, boundaries, data flow, persistence, side effects, and verification seams.
3. Prefer evidence with paths and symbols over generic summaries.
4. When discoveries invalidate planning assumptions, pause and update `.planning/STATE.md` and the affected plan before continuing.
5. Record stable learnings in `.planning/codebase/`; keep transient investigation notes out of durable documentation.

Read `references/workflows.md` for map, graph, documentation, and learning capture.

Pre-flight: re-check every architecture claim against current files and label inferred relationships explicitly.
