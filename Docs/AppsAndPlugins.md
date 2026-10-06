# Apps and plugins in Locus

Open **Manage Plugins → Browse** (also available through Settings → Extensions).
One search covers direct connections, installable Locus plugins, and apps available
to your selected ChatGPT account. **Install** reviews a local plugin package;
**Connect** links an account. Nothing connects or installs just by browsing.
Existing Installed, MCP Servers, and Skills controls remain available.

## ChatGPT apps

1. Add a ChatGPT account in Manage Accounts and install its runtime component.
2. In Browse, choose ChatGPT apps and select that account.
3. Choose Connect to open the provider-supplied ChatGPT connection page. Complete
   sign-in there, return to Locus, and Refresh.
4. Enable the connected app in Locus. Start a Work chat with that account.

Selections are saved separately per account. Locus uses the bundled Codex helper's
`app/list`, `app/installed`, and `config/batchWrite` interfaces. The helper owns
ChatGPT authentication; Locus does not export its tokens to other model providers.
This lists apps available to the account, not an unrestricted public store mirror.

Enabled apps are available to visible ChatGPT Work chats with broad tool access.
Just Chat, Plan, Grill, restricted agents, read-only roles, and background helper
agents do not gain hosted tools from this setting. Narrowly scoped agents should
use direct connections, where Locus can enforce individual tool permissions.
Each hosted action uses native one-time approval; session-wide and permanent
approval options are never selected. App activity appears in the chat tracker.
The experimental Codex `plugin/install` interface is not used.

If an account or runtime cannot report available apps, Browse shows the error or
sign-in requirement. It does not present a fabricated catalog or claim readiness.
Availability remains subject to account, region, workspace, and provider policy.

## Direct connections

These use the existing MCP connection, credential, project-scope, and agent-access
controls and can be used with compatible ChatGPT, Claude, and local-model agents.
Review the preset, authenticate, test the connection, then choose the project scope.

| Connection | How it connects | Setup requirements |
| --- | --- | --- |
| Jira / Confluence | Atlassian remote MCP, `/v2/mcp` | Atlassian sign-in and any organization approval |
| Notion | Notion remote MCP | Notion sign-in and shared page permissions |
| GitHub | Existing GitHub MCP preset | Supported device sign-in or a scoped token |
| Slack | Slack remote MCP | A user token from an approved internal or published Slack app; this is not anonymous or generic OAuth setup |
| Google Calendar | Bundled local MCP adapter to Calendar API | Google sign-in; lists calendars and events, creates/updates/deletes events after normal tool approval |
| Google Drive | Bundled local MCP adapter to Drive API | Google sign-in; read-only file search and text export |

The Google adapter runs with Locus's bundled Python runtime. It does not install
an unreviewed package. Tokens live in the native credential store and are passed
to the adapter in memory. It refreshes access tokens with Google's token endpoint,
limits responses to 2 MiB, refuses authenticated redirects, and never retries a
write automatically. Calendar creation does not invite attendees. Drive supports
Google Docs text, Sheets CSV, Slides text, and small text files; other formats
return metadata and a link.

Release builders must configure `LocusGoogleOAuthClientID` and
`LocusGoogleOAuthCallbackScheme` with the existing native Google OAuth setup,
enable Calendar and Drive APIs, and configure the consent screen for
`calendar.calendarlist.readonly`, `calendar.events`, and `drive.readonly`.
Google verification may be required before distributing to external users.
A build without that OAuth configuration reports setup is required.

These connections expose tools to agents. They do not silently import an entire
Drive, subscribe to Slack, or replace Locus's built-in calendar or local task board.

## Portable plugin packages

Locus accepts the root portable manifest alongside its legacy format:

```text
my-plugin/
  plugin.json
  mcp.json
  skills/
    my-workflow/SKILL.md
```

Example `plugin.json`:

```json
{
  "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "My team's workflow",
  "extensions": {
    "com.openai": { "interface": { "displayName": "My workflow" } }
  }
}
```

Example `mcp.json`:

```json
{ "mcpServers": { "my-service": { "url": "https://example.com/mcp" } } }
```

Distribute through an existing Locus marketplace source with a plugin entry
pointing at the package folder. The existing trust review and digest checks apply.
Root portable identity and fixed `skills/` and `mcp.json` locations take precedence;
OpenAI metadata cannot redirect these components. `extensions.com.openai` supplies
presentation metadata, with `.codex-plugin/plugin.json` as compatibility fallback.
`extensions.com.locus` can declare existing Locus screens or panels. Legacy packages
continue to use their `.codex-plugin/plugin.json` paths. Hooks and other unsupported
components are reported in review, not executed implicitly.

### Plugin-owned windows

Declare local HTML through `extensions.com.locus.panels`. A panel can use
`plugin.tools` to call its plugin's MCP tools and `chat.compose` to prepare an
editable chat. Its `tools` list identifies operations hidden from agents; public
tools from the same plugin remain callable. Hidden tools belonging only to
another panel cannot be called. Panel networking is blocked; the MCP backend
owns remote requests.

For Python tools, `${LOCUS_PYTHON}` resolves to Locus's running interpreter.
`${PLUGIN_ROOT}` and `${PLUGIN_DATA}` locate installed code and retained data.
Use `env_vars: ["PYTHONPATH"]` when importing Locus's bundled MCP SDK, whose
site-packages directory is separate from the interpreter. Run with `-B` to avoid
modifying the reviewed package with bytecode files.

The panel hello includes `toolContextVersion: 1`. Native tool requests attach
the opening project's canonical workspace, panel ID, and installed digest;
Locus validates these and passes them in MCP request metadata:

```json
{"com.locus/panel": {"version": 1, "workspace": "/project", "pluginId": "catalog/plugin", "panelId": "desk", "digest": "reviewed-package-digest"}}
```

Project-aware backends should use this metadata for each request, rather than
process cwd or startup environment. Changing the selected chat does not change
an existing panel's project. Legacy callers without context retain their
previous current-project behavior. Requests are revoked when the installed
digest or project enablement changes; remote actions already accepted may still
complete. Closing a panel cancels its pending requests without retrying writes.
Panels support bounded responses up to 1,000,000 characters and
arguments up to 256 KiB; paginate content rather than return whole data stores.

## Interactive MCP Apps

Tools may declare `_meta.ui.resourceUri` referencing an HTML `ui://` resource with
MIME type `text/html;profile=mcp-app`. After a tool result, choose **Open interactive
result** inside the chat. The connection's **Resources, prompts and apps** section
can also open a tool's app. Text results remain usable without opening the UI.

The host implements the `2026-01-26` MCP Apps protocol's initialization, tool
input/result delivery, `tools/call`, `ui/message` as a reviewed draft, `ui/open-link`
as a reviewed HTTPS link, and ping. Model-hidden tools with app visibility stay
hidden from the model but can be requested by that app subject to agent policy.

Each panel runs in a nonpersistent WebView and an opaque-origin sandboxed iframe.
Response-header CSP prevents the app from weakening its sandbox. Only declared
HTTPS asset origins can load; direct fetches, forms, other frames, local files,
and camera/microphone access are blocked. Every tool action asks for native
confirmation and is bound to the same server, session, agent permissions, and
connection fingerprint. Changing these invalidates the view. Results and HTML
are bounded; views expire after one hour and must be reopened.

This is a deliberately restricted MCP Apps host, not full ChatGPT UI emulation.
`window.openai`-only widgets, direct browser networking, pop-out/fullscreen modes,
and server sampling are not supported. App-only resource reads and model-context
updates are not advertised. UI state is in memory; reopen from the connection
catalog after restarting Locus. Only direct MCP results use this panel host;
ChatGPT-hosted apps currently expose their text results in the activity tracker.

References: [OpenAI app server](https://learn.chatgpt.com/docs/app-server#apps-connectors),
[portable plugins](https://developers.openai.com/plugins/build/plugins),
[MCP Apps](https://modelcontextprotocol.io/extensions/apps/overview),
[Atlassian MCP](https://atlassian.github.io/atlassian-mcp-server/),
[Notion MCP](https://developers.notion.com/guides/mcp/get-started-with-mcp),
[Slack MCP](https://docs.slack.dev/ai/slack-mcp-server/).
