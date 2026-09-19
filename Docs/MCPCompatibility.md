# Connect and use MCP servers

Open **Settings → Extensions → MCP servers** to add a server or diagnose an
existing connection. Choose the transport from the server's setup instructions:
Streamable HTTP, a local STDIO command, or Legacy SSE. Local commands are available
in the app build; network transports are also supported.

## Diagnose a connection

Choose **Test**, then expand **Connection details** if it fails. Locus reports the
connection stage, endpoint or executable, elapsed time, HTTP status when available,
underlying errors, and recent STDIO error output. **Copy diagnostics** copies the
redacted report for a support issue. Tokens, credential values, URL credentials,
and query values are removed; HTTP response bodies are not collected. STDERR is
limited to the latest 16 KiB and retained in memory for the current connection.

An HTTP 401 or 403 means the endpoint answered but rejected authentication. A
connection refusal means the host and port did not accept a connection; changing
tokens will not fix an unreachable endpoint. A closed STDIO connection can mean
the process exited before initialization; its error output often identifies the
missing argument or configuration. Locus does not claim a process exit code when
the MCP SDK cannot supply one.

The connection timeout includes initialization and initial catalog discovery.
Its default is 10 seconds, adjustable from 1 to 120 seconds under Advanced
settings. Tool requests have a separate timeout, defaulting to 60 seconds.
Automatic protocol negotiation is the default. Select Legacy initialization only
when the server's compatibility requirements call for it.

### Macuse

[Macuse's setup guide](https://macuse.app/docs/configuration/stdio) documents this
local command:

```text
Command: /Applications/Macuse.app/Contents/MacOS/macuse
Arguments (one per line): mcp
```

Macuse must be running or configured to auto-launch. Its documented HTTP endpoint
is `http://127.0.0.1:35729/mcp`, but the port is configurable: check Macuse's
**Server → Settings** and use that value. Locus does not replace a different port
automatically. For bearer authentication, generate an API key in Macuse and store
it in Locus's credential editor. See [Macuse HTTP setup](https://macuse.app/docs/configuration/streamable-http)
and [API keys](https://macuse.app/docs/configuration/api-keys).

## Settings and credentials

Advanced settings include working directory, timeouts, environment-variable
passthrough, headers sourced from environment variables, and the environment
variable containing a bearer token. Multiple secret environment variables and
headers can be saved together. Editing one value preserves other entries;
removing an entry is explicit. Literal credential values stay in Locus's native
credential store, and only runtime credentials are sent to the agent in memory.

**Allow HTTP OAuth on this Mac** is an optional compatibility setting for local
applications. It is off by default and applies only to a user-configured HTTP
server at `localhost`, `127.0.0.1`, or `::1`. Its HTTP OAuth endpoints must have
exactly the same origin, including port. This is an exception to MCP's HTTPS
authorization-server requirement, not permission to use HTTP OAuth on a LAN or
public host. Local requests bypass proxies and do not follow redirects. PKCE,
state checks, issuer/resource binding, and native credential storage still apply.
Changing the origin or disabling the option invalidates reuse of those credentials.

OAuth servers must accept the existing `locus://mcp/oauth` application callback
(`locusx://mcp/oauth` in LocusX). A separate HTTP callback listener is not provided.

## Resources, prompts, and screenshots

Servers do not need to provide tools to connect. The catalog shows their
resources, resource templates, and prompts. Resource access can be **All**,
**Selected**, or **None**; prompts require explicit enablement. Agent-specific
policies further narrow this access. Preview allowed entries and choose **Add to
chat** to include them as attributed external content.

For templates, retain the original template URI and supply its arguments
separately. Locus checks the template's permission before expanding it. Servers
can optionally suggest argument values. Resource links returned by permitted
tools can also be read explicitly, even when absent from the original catalog.
Links are never fetched automatically.

Locus handles both legacy catalog notifications and modern subscriptions. Changed
catalogs are refreshed, and resource updates invalidate cached reads. A server
that declines update subscriptions can still be used; refresh explicitly to
check for new content. **Share current workspace root** is an optional legacy
compatibility setting, off by default. Roots provide context rather than enforce
filesystem permissions.

MCP screenshots and image resources are delivered to compatible models and shown
in their tool result cards. Supported formats are PNG, JPEG, GIF, and WebP, up to
10 images per result, 15 MiB per image, and 25 MiB combined. Invalid or oversized
images receive a readable omission message. Previews belong to the conversation,
not the workspace; they follow its restore, fork, and deletion lifecycle.

Long-running MCP tasks appear in the run Inspector with status, results, **Check
status**, and cancellation controls. Opening the Inspector reads saved task
records; an explicit status check contacts the server. Structured input forms
support choices, multiple selections, defaults, and validated numeric values.

Sampling, MCP Apps, audio payloads, arbitrary binary downloads, and persistent
connection-log history are not supported by this expansion.
