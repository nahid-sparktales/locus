# Locus Vault provider disclosures

Provider availability is release-manifest and region gated. Bundled client IDs
are public identifiers and are restricted and rotated vendor-side.

| Capability | Intended primary | Intended fallback / boundary |
| --- | --- | --- |
| Ethereum RPC/indexing | Alchemy | QuickNode; user-defined HTTPS endpoint; chain ID verified |
| Solana RPC/indexing | Alchemy | QuickNode; genesis identity verified; native transfers use one reconstructed System Program instruction; SPL and the safe Token-2022 subset use one reconstructed `TransferChecked` and either verify the program-scoped signer-derived recipient associated token account or create it with an exact idempotent Associated Token Program instruction after proving the address unallocated; Token-2022 transfer fees, hooks, confidentiality, pausing, delegates, memo/CPI requirements, unknown extensions, and other altered semantics are rejected; balances use validated [`getTokenAccountsByOwner`](https://solana.com/docs/rpc/http/gettokenaccountsbyowner) raw integer amounts; collectible discovery uses bounded, ownership-validated [`getAssetsByOwner`](https://developers.metaplex.com/das-api/methods/get-assets-by-owner), quarantines every unknown holding, and excludes active/non-raster media |
| Sui data/execution | Alchemy GraphQL | QuickNode GraphQL; Foundation HTTPS endpoint in development only; full Base58 genesis checkpoint digest verified on each read; partial/error-bearing, oversized, cross-chain, stale, unstable-pagination, duplicate-asset, misowned-object, contradictory-effect, and truncated nested-activity responses rejected; native and Coin totals reconcile coin objects and the address accumulator; finalized activity records only exact transaction/effects evidence and owner Coin deltas; unknown Coin types and owned non-Coin objects are quarantined; object and activity discovery exclude BCS, display metadata, and media; exact native, signed-manifest single-object Coin, and signed-manifest publicly transferable object transfers have isolated signer rebuild, strict simulation, fresh object recheck, one-provider execution, and default-denied mainnet gates; no generic Move call or new JSON-RPC dependency |
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
