# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

- Email **security@sparktales.io** with enough detail to reproduce it, or
- Use GitHub's [private vulnerability reporting](https://github.com/nahid-sparktales/locus/security/advisories/new).

We aim to acknowledge a report within three working days and to tell you
whether we consider it in scope within a week. Please give us a reasonable
window to ship a fix before publishing.

## Supported versions

Only the latest release receives fixes. Locus is distributed as a notarized
direct download and through the Mac App Store; both track the same tag.

| Version | Supported |
| --- | --- |
| 1.10.x | Yes |
| < 1.10 | No |

## What Locus does with your credentials

Worth stating plainly, because it changed in 1.10.0 and it is the thing most
likely to be reported.

Provider API keys and MCP server tokens are stored in `~/.locus/auth.json`,
mode `0600` inside a `0700` directory. In the sandboxed Mac App Store build the
file lives in the app container instead. Earlier versions used the macOS login
keychain.

**File permissions keep those secrets from other user accounts on the Mac and
from nothing else.** Any program running as you can read that file. There is no
per-application access control and no authorization prompt — the keychain
provided those and this deliberately does not. This is a known and accepted
trade-off, not an oversight; please do not report it as a vulnerability. A
report that Locus writes credentials somewhere *other* than that file, exposes
them over the network, returns them from an API, or leaves them world-readable
is very much in scope.

## Scope

In scope:

- The macOS app and the bundled `ollama-code` agent service in `agent/`.
- The local HTTP/WebSocket API the app drives: authentication bypass, origin or
  token checks that can be defeated, path traversal out of the workspace,
  permission-system bypass that lets a tool run without approval.
- Credential handling beyond the accepted trade-off above.
- The release pipeline: signing, notarization, or the distribution audit
  accepting something it should reject.

Out of scope:

- That the agent runs with your privileges and can edit files and run commands
  you approve. That is the product.
- The shell deny list being incomplete. It is documented as "a guard rail
  against an obvious accident, not a sandbox".
- Vulnerabilities in Ollama, in a model, or in a third-party MCP server you
  chose to connect — report those to their maintainers.
- Anything requiring an attacker who already has code execution as your user.
