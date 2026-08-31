# Locus Vault provider disclosures

Provider availability is release-manifest and region gated. Bundled client IDs
are public identifiers and are restricted and rotated vendor-side.

| Capability | Intended primary | Intended fallback / boundary |
| --- | --- | --- |
| Ethereum RPC/indexing | Alchemy | QuickNode; user-defined HTTPS endpoint; chain ID verified |
| Solana RPC/indexing | Reviewed provider configuration | Genesis identity verified; lookup tables and instructions fully resolved |
| Sui data/execution | gRPC and GraphQL provider configuration | Chain identifier verified; no new JSON-RPC dependency |
| Ethereum swaps | Uniswap Universal Router reviewed subset | Exact input only; pinned code/commands/recipient/deadline |
| Solana swaps | Jupiter Router `/build` | Locus validates, simulates, signs, and broadcasts; no managed `/order` execution |
| Sui swaps | Pinned Cetus Aggregator V3 simple route | Package/object/coin effects, minimum output, gas, recipient checked |
| External dapps | Reown WalletKit | Explicit proposals, namespaces, methods, accounts, expiry, disconnect; telemetry off unless diagnostics opt-in |
| Explorers/media | Signed manifest entries | Display only; unknown assets quarantined; active HTML/SVG/script untrusted |

The app verifies provider network identity whenever an endpoint changes and
compares critical preparation evidence across providers where practical. It
never broadcasts the same signed transaction concurrently through multiple
providers. A failed response after submission is recorded as uncertain and
reconciled by its locally derived transaction identifier.

Providers can observe IP address and public request data and may apply their
own retention, rate-limit, availability, and regional policies. Final GA copy
must link each enabled vendor's current privacy policy and terms.
