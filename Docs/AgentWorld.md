# Agent Worlds integration

Agent Worlds is an independently built Locus plugin. Its first installed world is **Local Line**. The renderer, World SDK, developer mock host, artwork/provenance and release pipeline live in the separate `agent-worlds` repository. Locus no longer contains `AgentWorldWeb`, the bundled Agent World plugin, Outpost/Local Line models, native quarters backdrops or the asset-generation pipeline. No plugin is silently installed or downloaded from a sibling checkout.

Locus remains the authority for saved agents, chats, tools, tasks, activity, permissions and persistence. The world receives a bounded read-only projection and submits validated native intentions. Agent selection opens the existing native chat/workspace; Captain's Quarters retains the native composer and browser, board, calendar and other tool panels. Plugin presentation metadata provides decorative labels, style tokens and confined package images. It cannot provide native code or add permissions. The ordinary shared agent portrait gallery remains a Locus profile feature.

## Compatibility

The preserved installation identity is `locus/agent-world`, with screen ID `agent-world`. Candidate runtime versions are 0.2.x, SDK version 1, bridge protocol 2 and visual-preferences schema 2. A host must support screen protocol 2 and complete its capability/session handshake; its app version number alone is not a compatibility promise. Existing version-1 plugins retain their prior semantics, and Social Studio's native capability stays on protocol 1. An unsupported world is unavailable rather than silently falling back to synthetic profiles.

Canonical profile/chat data stays in Locus. Disposable visual preferences are scoped by installed screen and workspace; migration preserves old keys for rollback. Session, scope and stream invalidation clears the displayed projection. Side effects are validated against current authorization, native identifiers, explicit capabilities and bounded message shapes.

## Review and install a candidate

Obtain an explicitly reviewed ZIP and its complete SHA-256 from the independent repository. There is currently no published release or implicit remote catalog URL. Review it using the Python environment with Locus's backend dependencies installed:

```sh
python Tools/InstallAgentWorldsArtifact.py review \
  --artifact /absolute/path/agent-worlds-0.2.0.zip \
  --sha256 REVIEWED_ZIP_SHA256
```

The report includes the exact plugin content digest, manifest, capabilities and file inventory. The helper's `install` subcommand requires that reviewed digest, an explicit extension-state root, and explicit scope/workspace. Stop the app and backend before that offline state change; run `--help` for the full arguments. A version-1 upgrade additionally requires `--upgrade-legacy-v1`. `rollback` requires both current and prior reviewed content digests. The helper preserves `locus/agent-world` and uses the existing plugin manager's cache/trust/scope/rollback machinery. No actual user installation occurs during the verification commands below.

For development, build and run the separate repository's explicit mock host. Production has no automatic demo fallback. The installer also accepts `--development-directory` for an explicit built plugin directory; its UI is labeled as development. Never point Locus at renderer source or a dependency directory.

## Verify the host and exact artifact

```sh
python Tools/VerifyAgentWorldsHostBoundary.py
python Tools/VerifyAgentWorldsArtifact.py \
  --artifact /absolute/path/agent-worlds-0.2.0.zip \
  --sha256 REVIEWED_ZIP_SHA256
LOCUS_AGENT_WORLDS_TEST_PLUGIN=/absolute/reviewed/extracted/plugin \
  Tools/RunAgentWorldsNativeTests.sh
```

The installer rehearsal uses isolated temporary state. Supply `--previous-plugin` with a restored, verified prior package when testing upgrade/rollback. The native runner uses a unique disposable app-host identity and accepts the artifact through the secured WebKit transport. `VerifyAgentWorldsHostBoundary.py --resources /absolute/fresh/Locus.app/Contents/Resources` additionally checks loose app resources; native image tests verify that removed backdrops are absent from the compiled asset catalog. Normal CI keeps protocol/host checks. The manual pinned-artifact workflow accepts only an explicit HTTPS archive URL and digest. It does not rebuild the renderer inside Locus.

See [artifact acceptance](agent-worlds-artifact-acceptance.md), [browser comparison](agent-worlds-browser-verification.md), [native visual verification](agent-worlds-native-visual-verification.md), and [protocol fixtures](../ProtocolFixtures/agent-worlds/wire-v2.json) for evidence and compatibility details. [The extraction audit](agent-worlds-extraction-audit.md) records the original boundary; [recovery instructions](agent-worlds-recovery.md) identify the verified external Outpost/source archive. Historical UX/art-generation documents describe the preserved baseline, not current runtime/build inputs.

The candidate remains unpublished. Its independent `NOTICE` records unverified derivative/reference-art redistribution rights; extraction does not invent a blanket asset license.
