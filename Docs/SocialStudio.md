# Social Studio

See the [plugin guide](../plugins/social-studio/README.md) for installation,
the content workflow, OpenPost setup, permissions, and development checks.

## Architecture

The package uses the existing local marketplace, install/trust review, enabled
workspace rules, and Work menu. `ExtensionPluginScreen` recognizes a narrowly
scoped `social.workspace` capability, allowed only on the `social-studio` screen
and without web/agent capabilities. `AgentWorldModel.open` dispatches this screen
to `SocialStudioWindowController` before any WebKit host is created. Existing
worlds and their bridge stay unchanged.

The controller pins each window to its opening Locus project and revokes it when
the package, digest, capabilities, or enablement changes. `SocialStudioStore`
owns atomic, versioned project data and Keychain references. `OpenPostClient`
uses ephemeral native networking, a validated HTTPS origin (HTTP loopback is
allowed for development), and no redirects. UI-test windows use temporary
storage and in-memory credentials.

Local planning and remote scheduling are intentionally separate states. Draft
transfers first save an immutable body, target origin/workspace, and idempotency
key. Interrupted transfers survive app restarts. The remote publication ID is
committed only after a successful response. Schedule/publish actions validate
the saved publication and send the user-reviewed revision, never an implicitly
refreshed revision. Action idempotency keys are tied to publication, revision,
and operation. Destination states remain the authority for delivery success.

OpenPost supplies social authentication, durable scheduling, delivery, provider
validation, and its richer media/engagement tools. The native UI is initially
text-focused. It does not contain OAuth-provider implementations or a second
publishing scheduler.
