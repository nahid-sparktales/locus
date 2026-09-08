# Manage Extensions & MCP

Install extensions and define per-agent MCP access in Locus V2.

Open Settings → Extensions.

Locus supports MCP tools, resources, prompts, long-running tasks, progress, safe structured input, OAuth, remote HTTPS servers, and—where the build allows it—local stdio servers.

## Add a server safely

1. Add a catalog entry or a reviewed server definition.
2. Connect it and complete authentication.
3. Inspect every exposed capability.
4. Allow only the profiles and tool classes that need it.
5. Test with a read-only request before enabling mutations.

Remote MCP URLs must use HTTPS. OAuth uses PKCE, an exact callback, state verification, bounded registration metadata, and a verified authorization origin. Credential-shaped form fields are refused.

The bundled GitHub preset uses GitHub App device flow when the release is configured for it. Locus validates the account, stores tokens in Keychain, refreshes them, and keeps personal-token fallback for deployments that need it.

## Per-profile policy

Read-only profiles receive only allowed read capabilities. Mutating tools require a write-capable route and the ordinary permission loop. Background MCP tasks persist their remote identifier, progress, cancellation, and terminal state so a reconnect can resume supervision without rerunning the task.

{% hint style="warning" %}
Treat every extension as code and every remote response as external data. Review the server, its scopes, and its destination before granting access.
{% endhint %}
