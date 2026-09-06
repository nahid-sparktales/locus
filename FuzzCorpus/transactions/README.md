# Synthetic decoder branches

`decoder-branches.json` contains unsigned public fixtures, not wallet state or
release evidence. `WalletFuzzDecoderFixtures` supplies only the exact synthetic
read responses used by these inputs; all unmatched reads fail without networking.

- Solana sender: the existing public `native-transfer.json` fixture account.
- Solana source/destination/mint/recipient/lookup/Core-object public keys: 32
  repeated bytes `0b`/`0c`/`0d`/`07`/`28`/`14`. Blockhash: 32 repeated `09` bytes.
- SPL uses six decimals and amount 25; new-ATA setup is idempotent. The v0 ALT
  has the official 56-byte layout, active deactivation marker, slot 1, and one
  recipient at index 0. Index 1 is deliberately out of range.
- Sui sender: the existing public native-transfer fixture account. Coin/object/
  gas/recipient addresses: 32 repeated `44`/`66`/`55`/`22` bytes. Object version
  and digest are 7 and the repeated address byte; stale seeds change only the
  selected input version to 8. Gas price/budget are 1000/1000000; amount is 25.
- Token-2022 remains unsupported by this dapp decoder and is a rejection seed;
  this corpus does not expand the enabled transaction surface.

The native suite checks exact actions and awaited provider-read sequences for
every entry. The materializer includes all entries in their target corpora.
