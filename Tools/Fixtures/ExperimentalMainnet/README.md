# Synthetic experimental issuer compatibility fixture

`issuer-runtime.json` is output from the dedicated CLI's synthetic test binary,
whose temporary source replaces only the Apple Security identity reader. Source
revision, CodeDirectory hashes, provider identities, native asset label, archive
contents and signing key are disposable test data, not release or wallet data.
The private key is not included. The shipped issuer has no synthetic mode.

The public fixture preserves actual CLI-produced signatures and digests. Test
the runtime verifier using its recorded `verificationTimeISO8601`, which lies
inside its fixed lease, and its explicit synthetic installed identity. This is
not valid installed-app authority: no real signed application has those hashes.
It is not evidence of notarization, funded transfers, provider verification,
archive/app correlation, canary admission, or an audited release.
