---
name: writing-plans
description: Prepare a saved implementation plan for a substantial multi-step request.
---

Inspect the relevant code and constraints. Keep small clear Work requests direct. Explicit Plan mode is read-only. Ask only questions that materially affect the result, using the question capability available in this runtime.

Create deliverable-sized steps with dependencies, affected files, interfaces and acceptance checks. Include error and recovery behavior where material. Group implementation and its meaningful validation in the same deliverable. Classify a step as read, check or write; default to write. Only runtime-approved independent reads and deterministic file/JSON checks may overlap. Shell checks and writers remain sequential.

Stop when material decisions are settled and state remaining low-impact assumptions. Avoid compulsory micro-commits, line-by-line implementation scripts and companion workflows. Save the exact plan with submit_plan before requesting approval. Use Locus's saved execution recipe and approved plan reference for handoff; do not ask the execution-method question again. Stale approval requires saving and approving the refreshed plan.
