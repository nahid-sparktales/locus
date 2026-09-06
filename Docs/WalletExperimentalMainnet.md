# Personal experimental mainnet build

This channel is for explicitly opted-in personal use. It is not a canary, an
audited release, or public GA, and it does not provide any of their evidence.
Production release gates and Mac App Store exclusions remain unchanged.

## Build boundary

`LocusExperimental` selects the release-type `ReleaseExperimental`
configuration. Its product is **Locus Experimental.app**; its native executable
and Swift module remain `Locus`. Bundle identifiers and protected Keychain
groups remain unchanged, so this is not a separate vault or a promise that two
copies can run together. Do not replace or modify an existing app implicitly.

Only the Direct app and nested signer compile `LOCUS_EXPERIMENTAL_MAINNET` and
use an experimental Info.plist containing the Boolean
`LocusWalletExperimentalMainnetEnabled = true`. Both the compiled opt-in and
the sealed flag are required. The ordinary Direct, Debug and App Store builds
do not receive that opt-in. The experimental app disables automatic Sparkle
updates and the production activation endpoint; local authority must be
explicitly supplied and verified by the app and signer.

This is **not Debug**: the Apple/team code-signing requirements, authenticated
XPC, signer sandbox, user-presence checks and protected Keychain access groups
are retained. The default signing selection is same-team Apple Development;
a valid same-team Apple signing identity and provisioning are the actual
requirements. Notarization and a protected release-signing Mac are not personal
channel prerequisites. An unsigned or identifier-only ad-hoc build is not a
replacement for working signer authentication and provisioned storage.

## Authority and automation

Experimental activation must explicitly identify `experimental_mainnet`, make
no audit/legal/soak approval claims, and retain exact signed network, provider,
asset, adapter, program and connector grants. Missing configuration is not
permission. Installed identities, expiration, rollback protection, scope
restriction, transaction reconstruction, simulation and exact manual approval
remain authoritative. Experimental authority must never promote into or be
counted as production canary/GA evidence.

Only the existing Locus Vault native/fungible/reviewed-swap policy subsets may
automate, after the signer's explicit policy approval and within its account,
recipient, asset, fee, spending and expiry limits. The policy validator binds
network authorization to the network's resolved chain, including the existing
Solana policy forms. No Sui policy adapter, external-wallet automation,
collectible automation or allowance-setup automation is added.

## Inputs and verification still required

Supply valid same-team signing/provisioning, an external authority signing key
with only its public key bundled, an exact signed review ceiling, and the
selected provider/connector configuration. All three mainnets still need their
correct independently checked chain identities and exact provider grants. More
than native transfers requires the corresponding asset/program/contract review
identities. Credentials and signing keys are never checked into this repository.

The dedicated local issuer is `Tools/SignWalletExperimentalMainnet.swift`. It
does not call the production capability/evidence issuer, notarization, an RPC
provider, or a wallet. Run it only against an explicitly built experimental app:

```sh
xcrun swift Tools/SignWalletExperimentalMainnet.swift \
  /canonical/path/Locus\ Experimental.app \
  /canonical/path/retained-archive.zip \
  /canonical/path/unsigned-experimental-capability.json \
  /canonical/path/signed-review-restriction.json \
  /canonical/path/signed-review-ceiling.json \
  /canonical/path/external-private-key.base64 \
  /canonical/path/new-experimental-history.json
```

The input capability uses schema 3, stage `experimental_mainnet`, an explicitly
chosen positive revision, canonical whole-second UTC issue/expiry dates, and
exact network/capability/connector grants. Its evidence hash must be empty;
approvals, regions and canary limits must be empty arrays. The signed review
restriction must have the exact same revision and dates and remain within the
bundled non-activating ceiling. Both provider identities and their configured
HTTPS URLs are required for every selected mainnet. Connector configuration
digests must match the sealed configuration. At least one mainnet must be
explicitly selected; selecting all three does not infer an action cross-product.

The issuer verifies same-team Apple signatures, sealed contents, app/signer
identifiers, 40-hex CodeDirectory identities, source revision and bundle version.
Both bundles need the true experimental Boolean; the authority verification key
and signed ceiling are loaded from the nested `WalletSigner.xpc`, matching the
runtime's bundled-authority lookup. Conflicting outer authority overrides are
rejected. The supplied external key and ceiling must match those sealed values.
The key file must be owned by the caller, readable only by that owner, a regular
single-link file and outside the app. Symlink paths and existing output files
are rejected. Use resolved canonical paths (for example `/private/tmp`, not its
`/tmp` alias). Swift/CryptoKit/Security and the existing review/provider
validation tools are required; no private key or provider URL is printed.

Output is one signed initial experimental transition in a schema-1 history.
The issuer preserves the supplied positive revision; it neither allocates a
counter nor resets signer-owned rollback state. Initial-only issuance is not a
renewal mechanism: a retained candidate with prior authority requires an
explicit prior-history renewal implementation, and a rebuilt candidate still
needs a higher revision accepted by the signer's existing state. Leases expire
within 31 days. Do not discard protected state to work around rejection.

The archive is streamed and hashed independently from the inspected app. The
issuer **does not verify that the archive contains that same app**, nor does it
claim notarization, packaging reproducibility, funded transaction results or
release evidence. Retain the exact app and archive together and verify their
packaging relationship separately before relying on the archive identity.

Pure issuer tests use disposable keys and a temporary, explicitly synthetic
Security identity reader; the shipped CLI has no bypass. Its actual signature
reader is separately tested for unsigned-bundle rejection. A positive real
signed-app issuance and runtime exercise still require configured providers,
the external signing key/ceiling and a same-team provisioned build. None have
been performed by these tests. The production distribution audit deliberately
rejects experimental products. A local compile or synthetic test is not a
signed-mainnet execution pass.
