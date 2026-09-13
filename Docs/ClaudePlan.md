# Claude plan accounts

Claude plan is a separate provider (`claude_plan`) from Claude API (`claude`).
Existing API keys and ChatGPT accounts keep their identifiers and settings.

## Enablement and distribution

Claude plan is enabled by default. Set `LOCUS_CAPABILITY_CLAUDE_PLAN_V1=0` in the
app/backend launch environment to disable its account picker and backend routes.
The backend advertises `claude_plan_v1`; older hosts cannot accept Claude routes.
Anthropic's approval for distributed subscription login has not been confirmed.
The [June 15 support update](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
describes subscription use by third-party SDK applications, while the
[SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) still requires
prior approval.

The Python SDK is pinned to **0.2.152** and its Claude runtime to **2.1.259**.
`Config/ClaudeRuntime.json` records official wheel URLs and SHA-256 checksums.
`Tools/PrepareClaudeRuntime.py` verifies and extracts the binary, SDK license, and
provenance. It was exercised on macOS arm64 without a signed-in account.

- Direct-download Release builds default to `LOCUS_BUNDLE_CLAUDE=component`.
  Run `Tools/PackageComponents.sh <release-directory>` to package both providers
  and include their entries in `components.json`.
  Set `LOCUS_SIGN_IDENTITY` to the distribution signing identity.
- App Store and development builds default to `LOCUS_BUNDLE_CLAUDE=build`.
  App Store builds must bundle their runtime; they cannot download it later.
- Set `LOCUS_BUNDLE_CLAUDE=skip` explicitly to omit Claude from a local build.
- For a standalone backend, point `LOCUS_CLAUDE_RUNTIME_PATH` at the verified
  runtime. Installing the SDK alone does not provide Locus's managed runtime path.
- Remote packages accept `--claude-helper` in `Tools/PackageRemoteRuntime.py`.
  Including that optional, version-checked binary explicitly enables Claude on
  the destination. Remote login uses the destination's own account directory;
  its browser callback is forwarded through the existing SSH connection.

The downloadable runtime uses the existing HTTPS, checksum, signing-identity,
archive-validation, and atomic activation checks. The SDK's bundled binary is
removed from the base Python payload so the direct-download app does not carry
an unused copy.

## Authentication and execution

Each account uses its UUID beneath the profile's `claude-accounts` directory.
The official runtime handles `auth login`, `auth status`, `auth logout`, and token
refresh. Locus does not import a user's existing Claude installation credentials
or read OAuth token files. Inherited API keys, custom endpoint settings, cloud
billing selectors, and broker secrets are explicitly overridden before launching
the SDK, whose environment merges with its parent.

The adapter uses persistent SDK session IDs and resumes them between turns.
Locus exposes its active tool registry through an in-process SDK MCP server;
Claude built-in execution tools and implicit settings sources are disabled.
Every action returns to the existing Locus tool/permission boundary. Chat has no
tools. Plan, Work, team, swarm, and helper restrictions remain enforced there.
Follow-up guidance is queued through the durable outbox for the next turn boundary.

Account, workspace, model, instructions, tool schema, and Locus session identity
protect session reuse. Forks rebuild from their copied Locus transcript rather
than sharing a live SDK session. An incomplete SDK result leaves an uncertainty
marker; a retry cannot silently replay it. Review resulting files/actions before
continuing in a new or forked task. SDK interrupts with a terminal result retain
resumable context.

Claude events are normalized to the existing managed-turn event envelope, shared
with Codex. Some internal `codex`/`chatgpt_thread` names remain for compatibility;
provider routes, credential directories, runtime versions, and session
fingerprints distinguish their owners. Child workers use the authenticated
broker and do not own credentials.

Model aliases and reasoning capabilities come from runtime initialization.
Runtime descriptions omit API-equivalent price suffixes. Usage windows are
optional and timestamped; absent utilization is unknown, not zero. Subscription
tokens are recorded without treating SDK API-equivalent costs as actual charges.
Claude plan is not an image-generation provider; separately configured image
providers remain available through Locus tools.

## Release verification still requiring a test account

Before release, exercise browser login/cancel/logout, token expiry,
two simultaneous subscription accounts (including macOS Keychain isolation),
real attachments and tools, interruption/resume, team/swarm execution, scheduled
execution, and SSH login on a second host. Verify the signed/notarized component
and an enabled App Store bundle on clean machines. Unit tests and unsigned
metadata discovery do not establish these authenticated behaviors.
