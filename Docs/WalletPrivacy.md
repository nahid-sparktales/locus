# Locus Vault privacy disclosure — release candidate

This disclosure must be reconciled with the final application privacy policy
and approved regions before GA.

## Data kept on the Mac

The signer stores encrypted vault entropy and public account metadata. The
wallet database stores public addresses, contacts, asset trust, connection
records, transaction identifiers, decoded public effects, confirmation/finality
state, and bounded error categories. Active agent rules, cumulative budgets,
prepared intents, and decrypted keys are memory-only.

## Data Locus does not collect through wallet diagnostics

Opt-in reliability diagnostics exclude recovery words, entropy, private keys,
addresses, amounts, assets, balances, origins, WalletConnect peer metadata,
policy contents, transaction bytes, and arbitrary error text. Diagnostics are
categorical and can be disabled.

## Network disclosures

RPC, indexer, explorer, token/NFT media, swap quote, and WalletConnect relay
providers can observe network metadata such as IP address and the public chain
data needed for a request. Public addresses and transaction identifiers are
already visible on their respective blockchains. Provider routing and retention
are described in [WalletProviderDisclosures.md](WalletProviderDisclosures.md).

## Recovery boundary

Recovery phrase display and input occur in a network-disabled recovery process.
The main app receives only ceremony status and public accounts. Locus does not
upload a phrase, provide cloud backup, or ask support staff to collect it.

## Retention and deletion

Deleting the production vault removes its local encrypted vault and public
account file after user presence. A rotated preview vault remains recovery-only
until separately deleted. Public wallet metadata can be removed from the Mac,
but blockchain records and data retained independently by providers cannot be
erased by Locus.

Privacy questions and requests use the support route published with the final
regional policy. Security reports go to `security@sparktales.io` or GitHub
private vulnerability reporting.
