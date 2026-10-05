# Agent Worlds host integration and migration

This is an additive migration checkpoint. The source baseline is Locus `4cce6ebfaa31f76cd7790967ad8ce7d7e2338deb`; audit `d7f05e63` preceded implementation. The independent local repository is `/Users/nahid/.codex/worktrees/72d5/agent-worlds`. It has no dependency on this checkout. See [migration status](agent-worlds-migration-status.md) and [acceptance evidence](agent-worlds-acceptance.md) before attempting destructive cutover.

## Ownership

`SavedAgentConversationService.swift` owns canonical workspace/profile conversation bindings, historical chat ownership and queued prompts. `AppModel+SavedAgentRuntime.swift` keeps native chat creation, provider routing, permission-sensitive dispatch and work tracking. Saved-agent/Crew Chat/board/calendar callers use these native services. World close, disable, digest change and workspace revocation clear the display, not canonical queues or runs.

`AgentWorldBridgeContract.swift` implements wire2 validation and scoped sessions. `PluginScreenHost.swift` retains actual WebKit resource/navigation/security policy, verifies current installed identity/digest/root/workspace/grants on each invocation, and routes narrow intentions to native surfaces. `AgentWorldSignals.swift` projects only bounded safe display state from canonical activity. Observations coalesce v2 projection updates; v1 remains an explicitly transitional contract.

`PluginWorldPresentation.swift` validates small decorative metadata from the installed package: bounded labels, approved hex color tokens, confined image references, appearance/style choices. It cannot load native code, arbitrary URLs or a declarative form. All hosted chat, permission, model, account, agent, calendar, board and activity UI remains native. Palette propagation uses the existing native theme system.

The standalone repository owns SDK1, renderer-neutral Core, Local Line Babylon rendering, visual routes/berths/reservations, ships, islands, scenery, UI and immutable artwork. The adapter alone knows WebKit. Production bridge failure shows a recoverable unavailable state. Mock Locus Host is explicit `npm run dev` and excluded from installed artifacts.

## Compatibility and pins

Versions are Agent Worlds release0.2.0, World0.2.0, SDK1, wire2 and cosmetic preferences2. Existing Locus at the baseline rejects screen2. The updated host negotiates runtime0.2.x/SDK1/wire2; legacy screen1 remains supported during this checkpoint without redefining its semantics. Social Studio retains its separate native screen1 path. Installation identity remains `locus/agent-world`, screen `agent-world`. There is no second automatic install.

The canonical schema and57 shared valid/invalid fixtures live in `agent-worlds`. Locus vendors fixtures with reviewed SHA256s in `ProtocolFixtures/agent-worlds/PIN.json`; Swift and TypeScript validate the same messages. Updating this pin requires reviewing both repositories and rerunning both sides. App version strings alone are not a compatibility guarantee for an unpublished host change.

The protocol has a524288-byte envelope limit,500-agent projection,32-key/32KiB cosmetic store, scoped opaque session/stream identities, monotonic sequence, request correlation, cancellation/timeouts, bounded reply caches and no automatic mutation replay. Gaps invalidate the projection and request an authoritative snapshot. See the independent repository's `docs/host-protocol.md` for exact fields.

## Persistence and rollback

Canonical keys `Locus.AgentWorld.conversations.v1` and `Locus.AgentWorld.profileHistory.v1` deliberately retain their existing names and bytes. They belong to native services despite the historical prefix. No migration recreates agent IDs, transcripts, runs or provider settings.

Cosmetic v2 data uses `Locus.AgentWorlds.preferences.v2.<pluginID>:<screenID>`. The scope preserves the preexisting per-screen display scope; it is not broadened to another workspace's canonical data. The first migration reads compatible legacy sailing-area, ship-style, quarters appearance and context-enabled values. Both `grand-line` and old Outpost selection map to Local Line. Outpost resident style stays only in legacy storage. Browser storage is not relied on because production uses a nonpersistent WK data store. Camera orbit/zoom was transient before extraction, so no nonexistent persistent camera setting is claimed migrated.

V2 writes never overwrite legacy keys. An existing corrupt v2 namespace is isolated rather than reimporting obsolete legacy choices. Reset writes an empty v2 cosmetic dictionary; this marks it initialized and prevents later legacy resurrection. Disabling, uninstalling or rolling back the plugin leaves canonical stores unchanged. Downgrade uses untouched legacy visual settings; changes made only under v2 are not backported. The recovery archive contains original source/assets, not user settings or private user data.

## Safe rollout

1. Build/test the updated native host and review its contract changes.
2. In the independent repository run `npm ci`, then `npm run check`. Review `release/asset-manifest.json`, manifest/capabilities, exact ZIP SHA256 and NOTICE.
3. Rehearse the candidate in isolated state: `python Tools/VerifyAgentWorldsArtifact.py --artifact /absolute/agent-worlds-0.2.0.zip --sha256 REVIEWED_SHA --previous-plugin /absolute/verified-legacy-plugin`.
4. Use the delivered local install tool and existing digest trust/atomic manager as documented in [local installation](agent-worlds-local-install.md). No local candidate is installed into the user's real application by these tests.
5. Execute the actual packaged native acceptance test with an explicit extracted artifact path. A browser preview or development sibling import does not satisfy this gate.
6. Only after all required gates pass, remove superseded Locus renderer/assets/native world constants and replace its bundled catalog entry with a real reviewed versioned artifact source. No mutable main/latest or invented release URL is acceptable.

Rollback disables/revokes the candidate, restores the last verified plugin digest through the manager, and uses the compatible prior host build. Keep the original recovery archive and native legacy settings. The manager preserves install identity and workspace enablement. Canonical work continues through native services.

## Publication still outstanding

No remote repository, push, version tag or public release was created. First resolve the derivative artwork rights noted in NOTICE. Then create the approved `agent-worlds` remote, push the reviewed source commit, tag0.2.0, publish the exact verified ZIP/hash/manifest, and update installation metadata to that immutable version/hash while retaining identity. These are future steps, not existing release links.
