# Local wallet fixtures

These are development verification inputs, not release approvals. The scenario
catalog separates implemented checks from missing stateful suites. A checked-in
scenario is not evidence that it ran or passed. Record results against the exact
source, tool and fixture identities after executing the relevant runner.

## Current proof boundaries

- Anvil's return-only token/NFT/router bytecode proves calldata, transaction
  transport and rejection of success-only settlement evidence. It does not prove
  ERC-20 balances, NFT ownership or Uniswap settlement. The small allowance
  contracts prove finite storage changes, not owner/token/spender isolation.
- `EVM/StatefulAssets.sol` adds stateful positive/negative asset fixtures. It is
  not yet compiled or deployed by the runner. The exact Solidity compiler
  artifact and compiled bytecode must be reviewed and locked before doing so.
  No stub is labelled a real Uniswap V2/V3 or Permit2 implementation. Actual
  protocol source/build/deployment identities remain an explicit missing input.
- Solana currently runs a real native-transfer path. SPL, permitted Token-2022,
  ATA and standalone Core deployment/account fixtures remain missing. Never load
  mutable programs by cloning a live network during this suite.
- `SuiLocalSigner` is a separate test-only executable with one public fixed key.
  It depends directly on pinned upstream Sui libraries, never Locus signer code.
  It accepts bounded Swift-reconstructed BCS for narrow transfers, has no network
  or key-import path, and is not included in any Xcode/product target. The local
  test independently compares its digest to the Swift reconstruction.
- Production Rust still rejects every unknown Sui genesis. The local test is
  Swift/GraphQL integration evidence, not production signer authorization or
  derivation evidence. Never substitute a mainnet/testnet identity for localnet.
- `Sui/` supplies a minimal coin marker and public-transfer object Move package
  pinned to the chosen Sui framework commit. Compilation, publication, package
  digest recording, coin/object fixtures and their live tests remain required.

## Running and recording

Use `Tools/RunWalletChainTests.sh`, `Tools/RunWalletSolanaTests.sh`, and
`Tools/RunWalletSuiTests.sh`. All cooperate with `WalletTestExecution.py` for
exclusive app-test/service sessions. Supply separate DerivedData paths. The
Sui runner fetches its independent fixture's exact locked dependencies before
the locked, offline build; it does not rely on the production signer's cache.
It never changes the user's Sui client configuration.

Before promoting any scenario from missing to implemented:

1. Pin source and executable/archive identities; regenerate the fixture lock.
2. Exercise the real supported state transition with exact pre/post effects.
3. Assert the rejected counterpart and no unintended broadcast or authority.
4. Run crash/restart tests against persisted records, not only a new RPC client.
5. Capture a sanitized result receipt and actual test-result bundle. Never store
   request bodies, signed bytes, private material or real wallet addresses in
   release evidence. Public fixture identities are development-only inputs.

Missing tool/artifact hashes and unimplemented scenarios fail the fixture
readiness check. No production manifest is activated by this directory.
