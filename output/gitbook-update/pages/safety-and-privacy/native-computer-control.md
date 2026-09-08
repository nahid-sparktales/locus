# Native Computer Control

Let a foreground writer operate Mac interfaces within V2's guarded boundaries.

Computer Control is optional, off by default, and available only in the signed direct-download build after the required macOS permissions are granted. The App Store build omits it.

A foreground write-capable route can inspect accessibility state, click, type, press keys, scroll, drag, and use bounded screenshots. Only one controller may operate the Mac at a time; team researchers and background workers remain read-only.

## Screenshot consent

A screenshot remains local with Ollama. Before the first screenshot sent to a hosted provider in a session, Locus names the provider and asks. If consent is declined or the model rejects images, Locus continues with accessibility text where possible.

## Non-bypassable boundaries

Bypass cannot reveal secure fields or finalize high-consequence actions. Passwords, credential entry, contracts, purchases, privacy/security changes, irreversible deletion, uploads, installation, and security interstitials require confirmation or user takeover.

Computer Control and Browser are separate. Browser is available in both builds and operates only Locus-managed web views with its own credential, JavaScript, download, and tab boundaries.
