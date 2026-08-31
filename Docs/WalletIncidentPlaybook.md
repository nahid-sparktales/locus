# Locus Vault incident playbook

## Trigger and first response

1. Open an incident for suspected unauthorized signing, secret exposure,
   decoder/provider disagreement, stuck recovery, ambiguous broadcast,
   dependency compromise, or connection/session escape.
2. Use the signed emergency manifest to intersect away the affected chain,
   adapter, connector, or region. Never use it to add authority.
3. Revoke active browser and WalletConnect sessions and tell affected users to
   lock the vault and stop funding affected accounts.
4. Preserve versions, public hashes, categorical errors, signing identity, and
   provider timing. Never request recovery words, private keys, or raw Keychain
   data.

## Investigation and repair

Classify the boundary: recovery helper, signer/client identity, vault storage,
semantic decoder, provider evidence, browser/WalletConnect identity, policy
budget, dependency, or release pipeline. Reproduce with a fresh limited-fund
vault and add the case to the adversarial suite before the fix ships.

If confidentiality may have failed, instruct users to move assets with a
known-good wallet to a new phrase. Local deletion is not remediation for an
exposed phrase.

Ship a signed update, verify code identity and entitlements, notarize/staple,
verify the update feed, and require external verification for an audit finding
before reopening the capability.

## Mandatory pre-GA drill

The evidence artifact must prove the team can:

- disable one chain or adapter with a signed restriction;
- revoke browser and WalletConnect sessions;
- ship and install a signed/notarized update;
- restore the vault on a clean Mac and match all three addresses; and
- demonstrate that funds remain recoverable while the disabled capability is
  unavailable.

Record owners, start/end times, artifacts, failed steps, remediation, and the
date the drill was independently reviewed.
