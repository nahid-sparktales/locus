# Locus — wallet-free local build

This folder contains **Locus.app** and **Locus-macOS.zip**, version 2.4.0 (24),
for Apple Silicon Macs running macOS 14 or later.

## Install

1. Quit any running copy of Locus.
2. Drag this folder's **Locus.app** into **Applications**, replacing the existing
   Locus app if prompted. Alternatively, unzip **Locus-macOS.zip** first.
3. Open **Locus** from Applications.

Locus keeps its existing app identity and storage locations, so your current
chats, settings, and accounts remain available. Replacing the app does not
delete your saved data. Existing wallet files and Keychain items are left
untouched; this edition cannot open or use them.

Python and the ChatGPT-plan helper are included. You can continue using your
existing provider accounts or local Ollama setup. Model weights are not included.

This is a Developer ID signed local build. Notarization and public distribution
are deferred. If macOS blocks this private build, use **System Settings → Privacy
& Security → Open Anyway** for this app, then confirm Open.

## Editions and updates

**Locus** contains no wallet implementation. **LocusX** is the separate wallet
edition in the same source project, with its own profile and sign-in callbacks.
No automatic wallet import or migration is performed.

Both editions use manual app updates. Old automatic-update preferences cannot
start the updater or use the old app feed. Component download verification is
preserved.

See [VERIFICATION.md](VERIFICATION.md) for build, test, and packaging results.
