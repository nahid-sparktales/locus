<p align="center">
  <img src="Locus/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="88" alt="Locus icon: a black mark on a lime tile">
</p>

<h1 align="center">Locus for macOS</h1>

<p align="center">
  A native, private AI workspace for planning, building, and reviewing software.
</p>

<p align="center">
  <a href="https://github.com/nahid-sparktales/locus/actions/workflows/ci.yml"><img alt="Locus CI" src="https://github.com/nahid-sparktales/locus/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/nahid-sparktales/locus/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/nahid-sparktales/locus?display_name=tag&sort=semver"></a>
  <a href="LICENSE"><img alt="Apache 2.0 license" src="https://img.shields.io/badge/license-Apache--2.0-8fbf27"></a>
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-111111">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-111111">
</p>

<p align="center">
  <a href="https://locushost.co">Website</a> ·
  <a href="https://github.com/nahid-sparktales/locus/releases/latest">Download</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

![Locus workspace with the project sidebar, adaptive composer, and files inspector](Docs/locus-workspace-dark.png)

Locus brings conversations, plans, file context, change review, a retained
terminal, agent teams, scheduled work, and an agent-drivable browser into one
SwiftUI app. The interface stays close to the project while every run remains
inspectable and under your control.

Local Ollama is the default. ChatGPT plans and API-backed providers are used
only after you add and select an account; Locus never silently switches to a
paid route.

> [!TIP]
> Want the supported app instead of a development checkout? Download the latest
> signed build from [GitHub Releases](https://github.com/nahid-sparktales/locus/releases/latest).

## What Locus does

- **Works in your project.** Add files and folders to context, search the workspace, review diffs, use a retained terminal, and preview sites without leaving the conversation.
- **Browses like a browser.** The agent shares your tabs: it reads pages as addressable elements, clicks and types with real input rather than synthetic events, aims at coordinates for canvases and maps, captures regions of the viewport, watches the console and network, and presents itself as a phone when you ask for a mobile viewport. Find in page, page zoom and per-tab device settings are there for you too.
- **Plans before it changes things.** Use Chat, Plan, or Build mode and choose how often file, command, browser, Computer Control, and MCP actions require approval.
- **Runs solo or as a team.** Adaptive Work can route tasks to specialists, or you can define explicit agent teams with model, tool, memory, and runtime limits.
- **Keeps runs inspectable.** Timelines, evidence, costs, checkpoints, pause/resume state, and recovery actions stay available in the Runs inspector.
- **Works from your phone.** The optional [Locus Mobile](https://github.com/nahid-sparktales/locus-mobile) companion for iOS and Android pairs directly over your LAN or Tailscale, with no Locus cloud relay.
- **Supports local and hosted models.** Use Ollama, a ChatGPT plan, OpenAI, Anthropic Claude, Moonshot Kimi, or an OpenAI-compatible endpoint.
- **Stores work locally by default.** Sessions, run records, and encrypted memory live on your Mac. Hosted providers receive prompts only when you select them.
- **Experiments with guarded wallet actions.** Direct-download builds can enable a separate, limited-fund Locus Vault in Settings, receive Sepolia ETH, review clear transaction summaries, and give the agent session-scoped spending rules backed by signer isolation and exact confirmation.

![Scheduled tasks in the Locus Activity Center](Docs/locus-schedules-dark.png)

## Inspector

The right-hand inspector keeps project tools beside the conversation:

- Changes and files
- Terminal and checkpoints
- Runs and `AGENTS.md`
- Plans and browser tabs
- Model Router scorecards and proxy management

Panels open when they are useful and can be collapsed when you want more room.

![Planning a task in the Locus inspector](Docs/locus-plan-dark.png)

## Mobile companion

Mobile Access is off by default. When enabled, Locus creates a private TLS gateway on your Mac and pairs phones with a five-minute, one-use code. The phone pins the Mac certificate, and no provider credentials, local-agent ports, or cloud relay are exposed.

<table>
  <thead>
    <tr>
      <th>Mac setup</th>
      <th>iOS and Android pairing</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><a href="Docs/locus-mobile-access-dark.png"><img src="Docs/locus-mobile-access-dark.png" alt="Mobile Access settings in dark mode" width="560"></a></td>
      <td align="center"><a href="Docs/locus-mobile-pairing-dark.png"><img src="Docs/locus-mobile-pairing-dark.png" alt="Locus Mobile manual pairing in dark mode" width="220"></a></td>
    </tr>
  </tbody>
</table>

The first mobile release can create and continue chats, follow streaming work, stop runs, answer one-time approvals, and run or pause schedules. Terminal, browser, file editing, permanent permissions, account settings, and destructive session actions remain Mac-only. See the [Locus Mobile repository](https://github.com/nahid-sparktales/locus-mobile) for platform setup and development instructions.

## Models and accounts

Locus starts with local Ollama and never silently switches to a paid route.

| Account | Authentication | Notes |
| --- | --- | --- |
| Ollama | Local service | Default; model weights stay on your machine |
| ChatGPT plan | OpenAI-managed browser sign-in | Uses eligible plan access, not an API key; needs a one-time component download |
| OpenAI API | API key | Separate from ChatGPT plan usage and billing |
| Claude | Anthropic API key | Native Anthropic messages route |
| Kimi / Kimi Code | Moonshot API key | Standard and coding endpoints |
| Custom endpoint | Provider API key | Any compatible OpenAI-style base URL |

The model picker can also browse and install compatible GGUF models from Hugging Face. Ollama and model weights are not bundled.

## Permissions and privacy

Locus has three permission modes:

- **Ask every time** approves file changes, commands, and fetches individually.
- **Accept file edits** applies edits inside the workspace while still asking for commands and outside access.
- **Bypass all** runs tools without asking and is intended only for disposable workspaces.

Credentials are stored in macOS Keychain or user-readable local credential stores and are sent only to the provider you configure. The bundled agent communicates with the app over authenticated loopback connections. Memory is encrypted with AES-256-GCM, with its key stored in Keychain.

The direct-download build can optionally provide guarded Computer Control. It is off by default and is not available in the sandboxed Mac App Store build. The built-in browser remains available in both distributions.

## Proxy routing

Manual HTTP/HTTPS and SOCKS5 proxies can cover Locus app requests, model and agent traffic, the built-in browser, downloads, Git, and the integrated terminal. SOCKS5 routes use remote DNS. Loopback services and Ollama remain direct so the app can reach its own local runtime.

The Proxy Manager in the right inspector adds named profiles, traffic-class, workspace, and provider assignments, strict tunnel mode, and health-ranked failover. Strict mode ignores custom bypass entries and blocks external traffic when no configured route is available. Health checks report latency and the externally observed exit address; when automatic failover is enabled, Locus checks the pool every minute and selects the fastest healthy standby. These controls apply to Locus, not to other Mac apps or the operating system as a whole.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- One model source: Ollama with a tool-capable model, an eligible ChatGPT plan, or a supported API account

The release bundle includes its Python agent runtime. End users do not need Python, Homebrew, Rust, Codex CLI, the Codex app, or the ChatGPT app.

The helpers behind ChatGPT-plan accounts are a separate download. They are large, they are idle unless you sign in to a plan, and most people never need them — so Locus offers them the first time you add a ChatGPT-plan account rather than bundling them for everyone. See [ChatGPT plan support](#chatgpt-plan-support).

## Install

1. Download `Locus-macOS.zip` from [locushost.co](https://locushost.co) or [GitHub Releases](https://github.com/nahid-sparktales/locus/releases/latest).
2. Move Locus to Applications and open it.
3. Choose a workspace and model, then start in Chat, Plan, or Build mode.

Direct-download builds from 1.14.0 onward check the stable release channel and can install signed updates when Locus quits. Mac App Store installations use the App Store update service.

### Locus Vault

The notarized direct-download build is developing a public multichain,
self-custodial [Locus Vault](Docs/WalletActivation.md). A network-disabled
recovery window owns the 24-word phrase ceremony and sends entropy directly to
the isolated signer over a single-use authenticated channel; the main app sees
only public accounts and ceremony status. One phrase deterministically derives
one Ethereum, Solana, and Sui account.

Mainnet is default-denied. A short-lived signed manifest can enable only code
already reviewed in the build, only in counsel-approved regions, and only when
its hashed audit/operational evidence satisfies the invited-canary or GA gate.
The checked-in manifest enables nothing. Reviewed native-SOL, classic SPL,
narrowly safe Token-2022 `TransferChecked`, and standalone plugin-free Metaplex
Core `TransferV1` builders plus quarantined token and collectible discovery are
implemented, while mainnet signing remains gated.
Ethereum ERC-20 holdings can be enumerated through Alchemy's bounded,
chain-verified [Token API](https://www.alchemy.com/docs/data/token-api/token-api-endpoints/alchemy-get-token-balances)
pages. Locus accepts only canonical contract addresses
and integer base-unit balances, rejects duplicate contracts and unstable page
keys, and imports no provider token names, decimals, logos, or media. Unknown
contracts enter quarantine; signed-manifest assets retain their reviewed local
metadata and can use the same snapshot balance.
ERC-721 and ERC-1155 holdings use Alchemy's
[metadata-free owner endpoint](https://www.alchemy.com/docs/reference/nft-api-endpoints/nft-api-endpoints/nft-ownership-endpoints/get-nf-ts-for-owner-v-3).
Every page must keep the same block number, block hash, and total; each item is
reduced to its canonical standard, contract, token ID, and positive integer
quantity. ERC-721 quantities must be exactly one. Provider names, descriptions,
URIs, images, collection data, and spam classifications are discarded before
the wallet model sees the collectible.
Digital Asset Standard responses for Metaplex Token Metadata, Core, and
compressed Bubblegum holdings are ownership-validated; active SVG/HTML/script
media is never promoted as a wallet image. A signed-manifest Core collectible
can reach a separate exact-transfer path only after Locus reparses its current
on-chain `AssetV1` account. The asset must be uncompressed, standalone,
plugin-free, owned by the vault, and keep the same update authority through
simulation and the pre-sign recheck. The app and Rust signer independently
rebuild the one `TransferV1` instruction; collection-backed, plugin-bearing,
compressed, Token Metadata, programmable, and Bubblegum transfers remain
read-only. This Core adapter remains testnet-only until an approved release pins
and verifies the deployed upgradeable program evidence. Sui native balances now use the
[current GraphQL API](https://sdk.mystenlabs.com/sui/clients/graphql), bind the
full Base58 genesis checkpoint digest, reject
stale checkpoints and partial GraphQL results, and reconcile coin-object and
balance-accumulator totals before updating Wallet Hub. Sui Coin discovery uses
bounded, checkpoint-stable pagination and canonical Move marker types; unknown
Coins enter quarantine until the user or a signed review manifest trusts them.
For curated Coin sends, Locus enumerates the exact owned
`Coin<T>` objects at one checkpoint, validates each object's BCS UID and raw
balance, reconciles the object subtotal, and selects one deterministic
sufficient object. Fragmented and accumulator-only balances remain unsendable
until a separately reviewed merge shape exists. The isolated signer rebuilds
only `SplitCoins` from that one object followed by `TransferObjects`, with one
distinct reviewed SUI gas object; it exports no generic Move-call authority.
Owned non-Coin Move objects are discovered at a pinned checkpoint with exact
owner, object ID, version, digest, type, and public-transfer evidence. They enter
Collectibles quarantine without BCS contents, display metadata, or remote media.
Finalized Sui transaction activity is likewise read through the checkpoint-bound
GraphQL path. It records only validated transaction effects and owner-specific
SUI or Coin balance changes; unknown Coin types remain quarantined, failed
effects cannot claim balance changes, and opaque BCS or Move-call data is not
accepted. The signer core now has a deterministic, typed builder for the single
object-backed native SUI transfer shape. Provider coin selection
is checkpoint-pinned and validates the exact `Coin<SUI>` BCS, object reference,
owner, raw balance, and aggregate coin-object balance before choosing one
deterministic sufficient gas coin; fragmented or accumulator-only funds are not
silently widened into a different transaction shape. The provider can now
dry-run signer-built native-transfer bytes without broadcasting: Locus requires
the exact transaction/effects digests, selected gas object, recipient credit,
sender debit, and computed gas fee to match the reviewed transfer. The staged
XPC flow repeats object and simulation evidence immediately before signing,
consumes the intent, executes through one GraphQL provider, requires finality,
and records transport ambiguity without automatic fallback. Testnet can use
this exact subset; mainnet is still disabled until signed launch and adapter
review manifests authorize it for an approved region.
Curated `Coin<T>` sends use the same staged path. Simulation must return exactly
the Coin sender debit, recipient credit, and separate native-SUI gas debit; the
signer then rechecks both object references, balances, checkpoints, type, fee,
and effects before consuming an exactly approved intent. Only Coin metadata in
the signed review manifest can reach this mainnet adapter.
Signed-manifest Sui collectibles have a similarly narrow transfer path for one
exact, non-generic Move object that the provider proves is publicly transferable
and owned by the sender. The signer rebuilds only `TransferObjects` for that
object with a distinct reviewed SUI gas coin. A fresh checkpoint recheck must
preserve object ID, version, digest, type, owner, and public-transfer status;
simulation must show the exact object changing to the reviewed recipient while
the gas object remains sender-owned and the only balance change is the bounded
SUI fee. Arbitrary object BCS and Move calls never enter exported authority, and
mainnet remains launch- and adapter-gated.
Solana token sends use the signer-derived recipient associated token account,
creating it idempotently through an exact reviewed instruction when it is still
unallocated. Token-2022 transfer-altering extensions, Core collection/plugin
variants, Token Metadata and compressed-collectible transfers, versioned
messages, Sui object creation/deletion activity and gRPC execution migration,
full swaps, external wallets, and WalletConnect remain closed until their
implementation and evidence gates pass. Finalized Sui activity does record
strict non-Coin ownership transitions for the tracked account, while validating
and ignoring same-owner writes and gas/Coin object mutations.

The Mac App Store target embeds neither recovery nor signer service. See the
[security gate](Docs/WalletSecurityGate.md),
[threat model](Docs/WalletThreatModel.md), and
[launch readiness checklist](Docs/WalletLaunchReadiness.md) for implemented
boundaries, remaining work, and the evidence required before public GA.

## ChatGPT plan support

ChatGPT-plan accounts are served by two helpers from OpenAI's Codex project. They come to about 268 MB installed and do nothing unless a plan is signed in, so the direct download does not carry them: Locus offers the component when you add a ChatGPT-plan account, downloads about 104 MB once, and keeps it until you remove it. Ollama, API-key and custom-endpoint accounts never download it.

The component is signed by SparkTales. Because it lands outside the app's notarized seal, Locus verifies the archive's checksum and then checks each binary against SparkTales' code-signing identity before anything is moved into place or run — a payload that fails either check installs nothing and leaves any previous install untouched. Removing the component reclaims the space and can be undone by adding a plan account again.

Mac App Store builds still bundle the helpers, because the App Store does not permit downloading executable code.

## Project status

Locus is in active development. GitHub Releases are the stable, signed delivery
channel; `main` may contain work intended for a later release. The source gate
covers the native app, bundled agent, protocol contracts, security-sensitive
packaging, and representative interface flows.

- [Latest release](https://github.com/nahid-sparktales/locus/releases/latest)
- [Changelog](CHANGELOG.md)
- [Open issues](https://github.com/nahid-sparktales/locus/issues)
- [Security policy](.github/SECURITY.md)

## Build from source

The checked-in Xcode project can be opened directly. Clone with `--recurse-submodules` if you also want the pinned Locus Mobile source. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) only when changing `project.yml` or adding source files.

Source builds require Xcode 26 and the Rust version pinned in
`WalletSignerCore/rust-toolchain.toml` (currently 1.97.1) through
[rustup](https://rustup.rs/):

```bash
brew install xcodegen
rustup toolchain install 1.97.1 --profile minimal --component rust-src,clippy,rustfmt
rustup target add aarch64-apple-darwin x86_64-apple-darwin --toolchain 1.97.1
xcodegen generate
open Locus.xcodeproj
```

Select the **Locus** scheme and run **My Mac**. The first build downloads the relocatable Python runtime and pinned Codex dependencies, then compiles the required helpers; later builds reuse those artifacts.

The `Release` configuration deliberately does not embed the Codex helpers; it records in `CodexAppServerProvenance.txt` that they are component-delivered, and `Tools/PackageComponents.sh <output-directory>` builds, strips, signs and publishes them together with the `components.json` feed the app reads. `Debug` and `ReleaseMAS` still embed them, so local ChatGPT work needs no download. Override with `LOCUS_BUNDLE_CODEX=build|component|skip`.

### Tests

Run the Swift tests:

```bash
xcodebuild test \
  -project Locus.xcodeproj \
  -scheme Locus \
  -destination 'platform=macOS' \
  -only-testing:LocusTests
```

Run the agent tests:

```bash
cd agent
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
.venv/bin/python -m pytest -q
```

Run the mobile checks and either native debug build:

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --simulator --no-codesign
```

## Architecture

See [Architecture and ownership boundaries](Docs/Architecture.md) for the
module map, dependency rules, and reviewability guardrails.

The SwiftUI app owns the interface, workspace access, native terminal, Keychain integration, and permission surfaces. A bundled Python service owns agent orchestration, model streaming, tools, sessions, and run persistence. They communicate over authenticated REST and WebSocket endpoints bound to `127.0.0.1`.

Inside the app, each feature — provider accounts, agent teams, run history, live team runs, extensions, workspace knowledge, evaluations, schedules, the activity center, and more — is its own observable model with its own tests, and views observe those models directly. `AppModel` stays a thin composition root: it wires the models together, runs the turn state machine, and translates backend events into one-line calls on the feature that owns them.

ChatGPT-plan requests use a pinned Codex App Server child process over local JSONL/stdio while keeping Locus's permission manager and tool set in control. In the direct download that child is the downloaded component; in the App Store build it is bundled. Either way the agent resolves it from one path that it re-checks on demand, so installing the component takes effect without restarting the agent or losing a session.

```text
Locus/          SwiftUI application
LocusTests/     Swift unit tests
LocusUITests/   macOS UI tests
agent/          Bundled Python agent service
mobile/         Pinned Locus Mobile repository for iOS and Android
ProtocolFixtures/ Shared Mac/mobile protocol envelopes
Tools/          Build, packaging, and audit scripts
Docs/           Guides and screenshots
```

For protocol and orchestration details, see the [agent README](agent/README.md), [wire protocol](agent/PROTOCOL.md), and [Agent Teams guide](Docs/AGENT_TEAMS_FEATURE_GUIDE.md).

## Contributing and security

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a change, keep pull requests focused, include tests for changed
behavior, and update documentation when the product surface changes. Use the
[issue chooser](https://github.com/nahid-sparktales/locus/issues/new/choose) for
reproducible bugs and feature proposals.

For vulnerabilities, follow the [security policy](.github/SECURITY.md) and use
GitHub's private vulnerability reporting. Do not put credentials, private
workspace contents, session transcripts, or decrypted local data in a public
issue.

## License

Licensed under the [Apache License 2.0](LICENSE), © 2026 SparkTales Inc. Third-party components retain their own licenses; the shipped inventory is documented in [ThirdPartyNotices.md](Locus/Resources/ThirdPartyNotices.md).
