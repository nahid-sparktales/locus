# Use the Locus Vault private alpha

Locus Vault is an experimental, direct-download-only wallet for a small
Sepolia private alpha. It creates a new, separate 24-word recovery phrase and
is intended only for limited test funds. It never imports or controls a
MetaMask, Phantom, Slush, or other external-wallet recovery phrase.

## Enable the private alpha

1. Install and open the signed direct-download build of Locus.
2. Open **Settings → Wallets**.
3. Choose **Review Risks and Enable**.
4. Read the experimental-risk sheet, then confirm only if you will use a new
   recovery phrase and limited Sepolia test funds.
5. Choose **Create Locus Vault**, write all 24 words down offline, and enter
   the six requested words. Locus shows the phrase only during this flow.
6. Unlock with Touch ID or the Mac password.

The setting takes effect immediately and persists on this Mac. The Mac App
Store build ignores the setting because it does not contain `WalletSigner.xpc`
and shows a direct-download-only explanation instead.

Older private-alpha installs that used
`LOCUS_ENABLE_EXPERIMENTAL_WALLET` or
`LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER` adopt those choices once. After
that migration, the in-app switches are authoritative and no Terminal setup is
needed.

## Receive Sepolia ETH

In the **Account** section, choose **Receive**. The receive sheet shows:

- the full Sepolia address and a Copy action;
- a locally generated QR code containing
  `ethereum:<address>@11155111` (ERC-681), with no amount;
- the latest cached balance and a refresh action; and
- a link to Ethereum.org's current Sepolia faucet list.

The address never leaves the Mac to create the QR code. Receiving and cached
balance display remain available while the vault is locked. Solana and Sui
public addresses are listed under **Advanced** and cannot sign in this release.

The default RPC is `https://ethereum-sepolia-rpc.publicnode.com`. An HTTPS
Sepolia endpoint can be changed under **Advanced**. The endpoint stays in
native code and is not added to model context.

## Optional browser wallet access

Browser access is a second, separate switch under **Connections**. Changing it
requires confirmation because Locus must revoke pending requests and approved
origins, rebuild the injected script set, and reload open tabs.

When enabled, the built-in browser announces **Locus Vault** through EIP-6963
with a unique provider ID for each page. It never replaces an existing
`window.ethereum`. Each website asks separately to see the public Sepolia
address; connecting does not authorize a transaction and ends on navigation,
lock, quit, or restart. Browser transactions accept Sepolia native transfers
only and always require the exact native confirmation sheet.

## Agent spending rules

An unlocked vault can give the Locus agent a narrow, session-only **Agent
Spending Rule**. Native ETH fields accept decimal ETH and are converted exactly
to canonical wei without floating point. Every rule binds its account,
network, recipient, per-transfer amount, total allowance, fee ceiling, and
expiry. Locking clears active rules. Saved templates contain no authorization.

Reviewed ERC-20 and narrow Universal Router rules remain under **Advanced**.
Until authoritative token metadata exists, their amount fields are explicitly
raw token units. Unknown effects, unlimited approvals, stale quotes, failed
simulations, code mismatches, and expired intents cannot use autonomous rules.

## Lock, disable, diagnose, or delete

Use **Lock Vault** to clear decrypted material, prepared transactions, website
grants, active rules, and signing authority. Sleep, screen/session lock, quit,
update, relaunch, or signer interruption does the same. Alpha intentionally has
no idle timeout.

**Turn Off Alpha** locks immediately, withdraws the agent capability, cancels
prepared work, revokes browser access, and leaves the encrypted vault intact.
Vault deletion is a separate destructive action under **Advanced** and is
recoverable only with the 24-word phrase.

**Copy Diagnostics** produces a local, redacted report containing build,
macOS, signer protocol/reachability, effective gates, vault state, RPC health
category, and activity counts. It excludes recovery material, signed
transactions, addresses, origins, policy contents, ABIs, and unrestricted
errors. Locus adds no remote wallet telemetry.

## Current safety boundary

- Mainnet and human-initiated sending are unavailable.
- Use only limited Sepolia test funds.
- Raw calldata, arbitrary messages, typed data, replacement transactions, and
  unknown autonomous contract effects are unavailable.
- Live MetaMask, Phantom, and Slush connections are unavailable. MetaMask
  Connect on Sepolia is the recommended next milestone after this alpha.
- Native Solana/Sui signing and every mainnet gate remain separate audited
  projects.
