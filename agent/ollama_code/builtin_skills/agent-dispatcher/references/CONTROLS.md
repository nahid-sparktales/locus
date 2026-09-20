# Locus dispatcher controls

Locus persists routing settings itself. Never create activation flags or edit another
application's configuration. The Skills setting controls the default; new chats start
with routing enabled unless the user has disabled it. Session choices persist with the
chat. User requests and active Locus permissions take precedence over this bundle.

`/agent-dispatcher` and `$agent-dispatcher` accept the following arguments:

| Argument | Behavior |
| --- | --- |
| `on`, `on here` | Enable routing for this chat. |
| `off`, `off here` | Stop routing for this chat and release the active role. |
| `on everywhere`, `off everywhere` | Change the default for chats. |
| `status` | Show enabled state, current fixed/automatic role, and output style. |
| `auto` | Release an explicitly fixed role and route by the next task. |
| Role id, name, or alias, optionally followed by a task | Hold that role until explicitly changed. |
| `output`, `output compact`, `output verbose` | Inspect or set this chat's activity style. |
| `context`, `context explain`, `context verbose` | Inspect context for the previous real task. |

Inspection commands do not execute the underlying task or change its role. A selected
saved specialist remains the starting role; explicit user role selection can override it.
Changing a role never changes the active Locus mode, model, access ceiling, workspace,
connected services, or existing authorization. Do not run foreign-host hook/install tools.
No external decision service is required or enabled by this integration.
