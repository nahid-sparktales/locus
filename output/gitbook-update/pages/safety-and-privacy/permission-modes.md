# Permission Modes

Control when V2 edits, commands, fetches, browser actions, MCP, and UI control require approval.

| Mode                  | Behavior                                                                       |
| --------------------- | ------------------------------------------------------------------------------ |
| **Ask every time**    | File changes, commands, fetches, and mutations request approval                |
| **Accept file edits** | Workspace edits can apply automatically; commands and outside access still ask |
| **Bypass all**        | Ordinary tools can run without prompts, but hard safeguards remain             |

Automatic reads stay bounded to the workspace, local session state, enabled Notes scope, and capabilities explicitly exposed to the route.

## Boundaries that still ask or refuse

* Browser JavaScript and starting a dev server always ask.
* Secure fields, credentials, password changes, contracts, security interstitials, final financial actions, and other high-consequence Computer Control steps require takeover or confirmation.
* Browser file-upload pickers and typed credentials are refused.
* Hosted screenshots require first-use consent for the provider.
* Automatic hosted team routing requires separate consent.
* Mobile cannot grant permanent permissions or perform Mac-only destructive session actions.
* Evaluation fixtures disable Computer Control and mutating MCP tools.

## Hard command blocks

A deny list blocks catastrophic command patterns in every mode. Permission mode does not override workspace boundaries, credential handling, provider routing, extension policy, or operating-system entitlements.

Use Bypass only in disposable workspaces whose contents and external accounts you can afford to lose.

## Shared policy and Agent access

Tool approval mode is shared across chats and worker runtimes. Each Agent still has its own workspace/environment boundaries and explicitly allowed service actions. Receiving events from a connection does not automatically authorize sending or editing through it. Saving an empty action selection keeps all of those actions disabled.

Adding a file to Context controls what is included in the chat; it does not expand filesystem permissions. Persistent goals, teams, and Task Capsules keep the existing approval boundaries. Optional question defaults are not user approval; required decisions remain pending.
