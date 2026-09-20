---
name: agent-dispatcher
description: Route substantial Locus chat work to one of 27 specialist roles and load only relevant guides. Enabled for chats by default; users can turn routing off or choose a fixed role.
disable-model-invocation: true
---

# Agent Dispatcher for Locus

27 roles and 79 guides are bundled with Locus. Route by the requested deliverable,
considering each role's use_when and not_for, rather than matching its topic alone.
Trivial questions and obvious small changes need no role ceremony. The dispatcher
role is for separable orchestration; it is not the default role for every request.

1. Use the compact role catalog supplied by Locus. Read the selected role with
   `read_dispatcher_resource` and `path: "roles/<id>.md"` before using its method.
   A saved specialist or an explicitly selected role stays fixed until the user changes
   it. Automatic routing may change when the requested kind of work changes.
2. Follow the role's method, scope, output, definition of done, and loadout. Read
   relevant guides with `read_dispatcher_resource`, using their exact paths from
   `references/INDEX.md`. Ordinary work needs one to five guides;
   do not read all 79 or load multiple guides for the same capability. Conditional
   guides require established evidence from `references/SIGNALS.md`; unknown is
   not true. Respect disabled guides and use available equivalents or fallbacks.
3. For substantial or unfamiliar workspace work, build bounded read-only context
   after choosing the role. Read `references/CONTEXT.md`; if its helper is unavailable,
   use targeted file and search tools and continue. Context selection supports the
   deliverable and does not become the deliverable unless requested.
4. Complete the authorized work and verify the outcome. State observed checks and
   material gaps. Before delegating or chaining roles, read `references/DELEGATION.md`.
   A plan request ends with a plan. Same-session review remains a self-check.

Keep activity compact: mention the role and guides actually read within ordinary
progress. Distinguish planned, read, available, used, and verified resources. Do not
claim that a guide or MCP was loaded merely because the catalog lists it.

## Controls

Use `/agent-dispatcher` or `$agent-dispatcher` with these arguments:

- `on` / `off`: enable or stop routing in this conversation (`on here` / `off here`
  are aliases). Stopping immediately drops the active role.
- `on everywhere` / `off everywhere`: change the default for chats.
- `status`: inspect routing state, role, and output style without executing work.
- `<role id, name, or alias> [request]`: hold that role until the user changes it.
- `auto`: return to automatic routing.
- `context`, `context explain`, `context verbose`: inspect context for the most
  recent real request without executing it or changing the active role.
- `output`, `output compact`, `output verbose`: inspect or change activity detail.

A bare invocation with no task activates routing and waits for the user's request.
Read `references/CONTROLS.md` for scope and persistence. Inventory and map guidance
is available on demand; do not invent unsupported commands, tools, or connections.

## Host boundaries

Locus's mode, permissions, user instructions, explicitly invoked workflows, and
disabled-skill preferences remain authoritative. Roles do not grant authority or
change runtime settings. Use Locus's available internal collaboration tools for
bounded subtasks; never create user-visible chats for internal work. Work from
evidence, preserve unrelated edits, and never invent checks or external outcomes.
This native bundle uses no host activation hooks, external decision provider,
automatic service installation, or observation workflow.
