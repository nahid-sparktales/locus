> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/safety-and-privacy.md).

# Safety & Privacy

Permissions, credentials, Browser, Autofill, Locus Vault, mobile access, proxies, and local persistence.

Locus is local-first, not offline-only. Data leaves the Mac only through a route or capability you enable.

* [Permission Modes](/locus-docs/safety-and-privacy/permission-modes.md) controls edits, commands, fetches, browser actions, MCP, and Computer Control.
* [Credentials & Local Data](/locus-docs/safety-and-privacy/credentials-and-local-data.md) explains credential storage, transcripts, runs, attachments, notes, browser data, and wallet material.
* [Native Computer Control](/locus-docs/safety-and-privacy/native-computer-control.md) covers guarded macOS interface automation.
* [Network Proxies](/locus-docs/safety-and-privacy/network-proxies.md) covers profiles, strict tunnel, failover, authentication, and bypass rules.
* [Browser & Dev Servers](/locus-docs/working-in-locus/browser-and-dev-servers.md) covers untrusted pages, guarded Autofill, quarantined downloads, wallet-origin isolation, and JavaScript approval.
* [Mobile, Schedules & Background Work](/locus-docs/working-in-locus/mobile-schedules-and-background-work.md) covers the private TLS companion boundary.

## Locus Vault private alpha

Locus Vault is an in-app Sepolia Wallet Hub available only after risk review and explicit enablement in signed direct-download builds. It can create or unlock an isolated vault, receive through a locally generated ERC-681 QR, show a public balance while locked, link activity to Sepolia Etherscan, and define exact decimal ETH-to-wei spending rules for agents.

Browser wallet access is a second opt-in. Enabling or revoking it clears pending work and remembered origins before tabs reload. Every website transaction requires an exact native confirmation. The Mac App Store build forces every wallet gate off.

Hard safeguards remain active in Bypass mode. Selecting a hosted model, team, extension, proxy, schedule, mobile companion, Autofill category, or wallet feature never silently widens another capability.
