# Inventory and readiness

Read `references/ROLES.md` for the 27 roles, `references/INDEX.md` for the 79 local
guides, and `references/SIGNALS.md` for the 50 conditional signals. Each role's loadout
names relevant recipes; read an individual recipe at `recipes/<id>.md`.
`catalog/external-skills.json` contains optional references and fallbacks;
`catalog/mcp.json` describes potential tools. Neither catalog establishes installation,
authentication, authorization, or availability in the current chat.

Use the session's exposed skills, tools, connection statuses, and actual results to
distinguish usable, unavailable, disabled, blocked, and unknown resources. Inspection
does not install packages, connect accounts, test external writes, or execute the task.
When a resource is missing, show the documented fallback and checks that remain unavailable.
Bundled guides are read on demand with `read_dispatcher_resource`; only the dispatcher
itself is registered as a builtin skill. External guide content is never bundled here.
