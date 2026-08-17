# GitHub MCP release configuration

Locus uses a dedicated GitHub App device flow for the bundled remote GitHub MCP preset. GitHub's remote MCP is a resource server, not an OAuth registration service, so generic dynamic-client registration is not used.

## GitHub App

Create a GitHub App owned by the Locus release organization with:

- Device Flow enabled.
- User authorization enabled.
- Repository installation with user-selected repositories.
- Repository permissions:
  - Metadata: read-only (required by GitHub).
  - Contents: read and write.
  - Issues: read and write.
  - Pull requests: read and write.
  - Actions: read-only.
  - Checks: read-only.
- No administration, deletion, organization-management, member-management, secret, or environment permissions.

The app's public client ID is the only value embedded in Locus. Device flow does not use a client secret.

## Build setting

Set `LOCUS_GITHUB_OAUTH_CLIENT_ID` in the signed release configuration. Both direct-download and Mac App Store Info.plists expose it as `LocusGitHubOAuthClientID`.

Development builds can set the `LOCUS_GITHUB_OAUTH_CLIENT_ID` environment variable. If neither value exists, Locus explains that account sign-in is unavailable and keeps **Use token instead** available.

## Runtime behavior

Locus requests a device code, opens `https://github.com/login/device`, polls at GitHub's required interval, adds five seconds after `slow_down`, and handles denial, cancellation, and expiry. It validates the returned account through GitHub's `/user` API, stores access and refresh material in macOS Keychain, and sends only the current access token to the local backend in memory.

Organization owners may still need to approve and install the app. Repository access is the intersection of the user's access and the repositories selected for the app installation.

References: [GitHub MCP host integration](https://github.com/github/github-mcp-server/blob/main/docs/host-integration.md), [GitHub App device flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app).
