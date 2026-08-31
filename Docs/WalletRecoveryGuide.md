# Locus Vault recovery guide

## Before funding

- Write all 24 words on durable offline media in the displayed order.
- Complete the verification challenge.
- Keep at least two physically separate copies protected from fire, theft, and
  casual photography.
- Never store the phrase in chat, email, screenshots, cloud notes, passwordless
  text files, support tickets, or diagnostics.
- Verify the Ethereum, Solana, and Sui receive addresses with a small transfer.

## Restore on a clean Mac

1. Install a verified notarized direct-download build.
2. Open Locus Vault and choose **Restore from 24 Words**.
3. Enter the Locus Vault phrase only in the separate recovery window.
4. Confirm that all three public addresses match the original records.
5. Refresh activity and balances before signing.

The release derives one account per chain and has no account picker, BIP-39
passphrase, hardware-wallet derivation, or cloud backup.

## Rotate an earlier preview vault

Choose **Rotate for Mainnet**, record and verify the new production phrase, then
move funds deliberately. The earlier encrypted vault remains recovery-only and
cannot sign mainnet transactions. Delete it only after recovery and transfer
checks are complete.

## Suspected compromise

Lock the vault, revoke connections, disable active agent rules, and use a known-
good wallet on a clean device to move assets to a new phrase. Deleting local
files does not make an exposed phrase safe. Contact security without sending
the phrase or private transaction bytes.
