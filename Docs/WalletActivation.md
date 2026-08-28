# Activate the experimental Locus Vault

Locus Vault is an experimental, direct-download-only wallet. It creates a new,
separate 24-word recovery phrase and is intended for limited test funds. It
does not import or control MetaMask, Phantom, or Slush accounts.

## Turn on native Sepolia signing

1. Quit Locus completely.
2. Open Terminal and run:

   ```bash
   launchctl setenv LOCUS_ENABLE_EXPERIMENTAL_WALLET 1
   ```

3. Reopen the direct-download build of Locus.
4. Open **Settings → Wallets**. The status should say **Not created** and the
   **Create Locus Vault** button should be available.
5. Create the vault, write all 24 recovery words on paper, and enter the six
   requested words. Locus shows the phrase only during this flow.
6. Unlock the vault with Touch ID or the Mac password, then use **Check
   connection** to verify the Sepolia RPC.
7. Fund only the displayed EVM address with Sepolia test ETH. Solana and Sui
   addresses are public/read-only in this release.

The default RPC is `https://ethereum-sepolia-rpc.publicnode.com`. An HTTPS
Sepolia endpoint can be supplied in Wallet Settings. The endpoint stays in
native code and is not added to model context.

## Optional browser provider

The browser provider has a separate gate so native transactions can be tested
first. Quit Locus, then run:

```bash
launchctl setenv LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER 1
```

Reopen Locus. The built-in browser will announce **Locus Vault** through
EIP-6963 and use `window.ethereum` only if no provider already owns it. Each
website must be approved by exact origin for the current Locus session.
Browser transactions currently accept Sepolia native transfers only and pass
through the same simulation and exact-confirmation path as native tools.

Native wallet tools may also call a method from a contract added under
**Contract registry & policies**. The model supplies only the registry ID,
canonical function signature, typed string arguments, and optional native
value. `WalletSigner.xpc` re-encodes the call from the normalized ABI, checks
the selector, and requires exact confirmation. Unknown contract effects cannot
use an autonomous budget. A verified ABI can be classified automatically for
the reviewed ERC-20 transfer/finite-approval adapter or the separate narrow
Universal Router V2 exact-input adapter. Those calls become policy-eligible
only after you authorize an exact contract, asset, counterparty, amount, fee,
and expiry budget in Wallet Settings. Unlimited approvals, extra router
commands, allow-revert, zero minimum output, native wrapping, and stale swaps
still require exact confirmation.

## Lock or turn it off

Use **Lock vault** whenever you want to clear decrypted material, prepared
transactions, website grants, policies, and session budgets. Sleep, quit,
updates, relaunch, or a signer interruption also locks the vault.

To disable both experimental gates, quit Locus and run:

```bash
launchctl unsetenv LOCUS_ENABLE_EXPERIMENTAL_WALLET_BROWSER
launchctl unsetenv LOCUS_ENABLE_EXPERIMENTAL_WALLET
```

Then reopen Locus. Disabling the feature does not delete the encrypted vault.
Vault deletion is a separate authenticated action in Wallet Settings and is
recoverable only with the 24-word phrase.

## Current safety boundary

- Mainnet signing is disabled.
- Use only limited Sepolia test funds.
- Raw calldata, arbitrary messages, typed data, replacement transactions, and
  unknown autonomous contract effects are disabled.
- Saved policy templates contain no authorization and must be approved again
  after each launch.
- External MetaMask, Phantom, and Slush connector definitions are present, but
  their live connection buttons remain security gated. Never enter one of
  those wallets' recovery phrases into Locus.
- The Mac App Store build intentionally does not contain `WalletSigner.xpc`.
