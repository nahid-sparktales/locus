# Chaining and delegation in Locus

Use internal collaboration only when independent work improves the requested result.
Use the tools actually exposed by Locus; do not simulate workers or create new user-facing
chats for subtasks. If delegation is unavailable, complete the work sequentially.

Give each worker one role appropriate to its bounded job, its exact role resource path,
the objective, concrete inputs, scope, accepted decisions, owned artifacts, constraints,
expected output, and meaningful verification. Keep the handoff proportional; do not dump
the conversation. Workers report what they changed, checked, and could not establish.
Parallel writers need disjoint ownership or workspace isolation; otherwise order writes.
Mechanical lookups need no role. A worker should return work needing further splitting
to its coordinator instead of recursively becoming a dispatcher.

A verifier uses reviewer, tester, or security-auditor rather than the producing role.
Reviewing another worker from the same session is still a self-check; describe it honestly.
Choose different lenses only when they add useful evidence, and verify reported results.
An explicitly invoked workflow that defines its own workers keeps its own handoff method.

Chains are optional. Follow only as far as the user's deliverable requires; a plan request
ends at a plan. Read each role before switching, pass the prior result forward, and report
changes compactly. Usually no more than three role hops are needed. A fixed role suppresses
automatic chaining; under it, delegate that role over disjoint scopes, with a separate
verifier when appropriate. Host permissions and existing authorization govern every step.
