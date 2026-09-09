# Install Locus

Install the wallet-free Locus 2.6.0 release and choose your model source.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- One model source: local Ollama with a downloaded model, an eligible ChatGPT plan, or a supported API account.

The packaged app includes its Python agent runtime. You do not need a separate Python installation, Homebrew, Rust, Codex CLI, or a running ChatGPT or Codex app. Ollama and model weights are separate installations.

## Install and open

1. Download **Locus-macOS.zip** from the [2.6.0 release](https://github.com/nahid-sparktales/locus/releases/tag/v2.6.0).
2. Unzip it and move **Locus.app** to Applications.
3. Open Locus and follow Getting Started. Existing users can reopen setup from **Help → Getting Started**.
4. Choose local Ollama or connect your account under **Settings → Models & Providers**.
5. Choose a workspace and review your permission mode before sending a request.

## ChatGPT-plan components

ChatGPT-plan access uses pinned Codex helpers. Direct release builds normally offer them as a separate component download when you add that account. Ollama and API-key accounts do not need the component. Downloaded components must pass checksum and SparkTales code-signature checks before installation or execution. A failed check preserves the previous installation.

Debug and Mac App Store builds bundle the helpers; direct builds can also explicitly bundle them. Use **Settings → Updates** for the component's available controls.

## Updating 2.6.0

**Locus 2.6.0 uses manual app updates.** Download and install the desired release yourself. The old signed app feed remains available to earlier wallet-era installations and does not automatically move them to wallet-free Locus. Component downloads are separate from app updates.

Installing the standard Locus app preserves existing Locus chats, accounts, settings, and browser data. Wallet files and Keychain entries are left untouched and are not automatically imported. Follow the release notes for the version you install.

## Locus and LocusX

| Edition | Wallet functionality | App data |
| --- | --- | --- |
| Locus | Excluded | Keeps the existing Locus profile |
| LocusX | Separate optional wallet implementation | Independent chats, accounts, settings, and browser profile |
| Mac App Store build target | Excluded | Uses the sandboxed app distribution |

The direct-download distribution supports optional Computer Control; the Mac App Store target excludes it. The built-in browser is available in both. The existence of a build target does not imply a currently available App Store listing.
