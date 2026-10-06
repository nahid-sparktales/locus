# Agent Worlds extraction report

Status: **implemented, committed and tested locally**. The extraction and thin-host cutover passed final acceptance, including the complete native regression target. Source publication is recorded in the follow-up below. Artwork redistribution rights remain unverified, separately from implementation acceptance.

## Repositories and checkpoints

- Inspected Locus: `4cce6ebfaa31f76cd7790967ad8ce7d7e2338deb`, clean detached checkout.
- Updated Locus: `/Users/nahid/.codex/worktrees/72d5/locus`, branch `codex/agent-worlds-extraction`.
- Independent Agent Worlds: `/Users/nahid/Documents/agent-worlds`, local `main`, resulting HEAD `33ac418cf5baede6631fb68341337a9f4c126d20` (final documentation). It was moved intact out of the managed worktree directory so worktree cleanup cannot remove it. No second maintained copy remains.
- Artifact source: `ec9416679a5f4929d78ae2f19acb6e4d572eb234`; later documentation-only commits may follow.
- Audit before implementation: `d7f05e63`. Canonical native service separation: `ed51b2cd`. Native lifecycle/recovery acceptance before deletion: `0e7e7b4b`. Generic native palette/presentation cutover: `af5cc2c7`. Legacy source/assets deletion: `f53fc4e5`. Final isolated artifact evidence: `64eb65c3`. Removal of native legacy world catalogs/protocol: `c6237049`. Actual WK fault/transport acceptance: `12786fb4`. Compact native portrait layout correction: `86077f43`. Final native acceptance and generated project: `287a5142`.

Mechanical extraction, SDK/contract work, canonical native ownership, renderer fixes, lifecycle/security, UI metadata and deletion are separate commits. The new repository retains original source paths, baseline commit, asset hashes and provenance instead of copying unrelated Locus history.

## Delivered architecture

`agent-worlds` owns a transport-independent SDK 1/World lifecycle, renderer-neutral Core, the Local Line Babylon implementation, immutable source artwork, clean allowlist packaging, an explicit deterministic Mock Locus Host, tests, CI, guides, LICENSE/NOTICE and a test-only non-nautical CounterWorld. Local Line is the only production world. No provider execution, credentials, canonical queue or automatic demo fallback is present.

Locus retains the optional installed-plugin loader/window/bridge, bounded canonical display projections, narrow native intention routing and all existing app features. `SavedAgentConversationService` owns chat identities/history and accepted queued work independently of the world. Profiles, portraits, transcripts, model/provider routing, permissions, tasks, schedules, calendar/board, identities and native forms remain authoritative in Locus. Installed presentation metadata supplies confined artwork, approved color tokens, bounded labels and cosmetic choices. It cannot define native forms, execute native code or grant permissions.

Removed from active Locus inputs: `AgentWorldWeb`, `plugins/agent-world`, six native world backdrop imagesets, world asset generation scripts/prompt plans, generator-only tests, old renderer CI/package checks and the bundled marketplace entry. Shared saved-agent portrait assets remain because the ordinary profile picker owns them. No world source is fetched during the normal app build. Host boundary checks inspect source/configuration and fresh app resources; native tests inspect the compiled asset catalog.

Outpost is neither registered, selectable nor shipped. Its verified recovery archive is retained at:

`/Users/nahid/.codex/archives/agent-worlds/2026-10-05/locus-outpost-4cce6ebf/locus-outpost-source.tar.gz`

Archive SHA256: `d6694fb2258e5de2e85d8b0d4cf0a2865680d4dc9af9169c5554cc3bcb9297a3`. All 1239 restored file hashes matched the baseline-derived manifest; the original two-world package verifier passed. [Recovery instructions](agent-worlds-recovery.md).

Developer guides: [World SDK and non-nautical example](/Users/nahid/Documents/agent-worlds/docs/world-sdk.md), [wire protocol](/Users/nahid/Documents/agent-worlds/docs/host-protocol.md), [compatibility](/Users/nahid/Documents/agent-worlds/docs/compatibility.md), [assets/provenance](/Users/nahid/Documents/agent-worlds/docs/assets.md), and [packaging](/Users/nahid/Documents/agent-worlds/docs/packaging.md).

## Contract, state and compatibility

This is a breaking web contract: wire 2, SDK 1, runtime/World 0.2.0, cosmetic schema 2. Updated hosts negotiate runtime ≥0.2.0 and <0.3.0. Original Locus rejects screen 2; the extracted host rejects legacy web screen 1. After the recorded extraction acceptance, native Social Studio/OpenPost support was removed; the independent Social Studio plugin uses the generic version-1 plugin-panel protocol. App version strings alone do not establish support; the host must contain the reviewed adapter. Installation identity remains `locus/agent-world`, screen `agent-world`.

Every bridge invocation checks current installed identity/digest/root, workspace, session, grants and referenced native ownership. Envelopes, preferences, metadata, rosters and resource paths are bounded. Sequence gaps replace the projection from an authoritative snapshot. Reconnect never retries uncertain mutations. World close/revoke/upgrade, renderer errors and timeouts dispose access while native queued work continues.

Cosmetics use `Locus.AgentWorlds.preferences.v2.<pluginID>:<screenID>.<SHA256(canonicalWorkspace)>`. Narrow migration imports compatible legacy choices filtered through installed metadata/current authorized profiles; old bytes remain for rollback. Corrupt v2 storage is isolated. Reset empties only the current cosmetic namespace and prevents legacy reimport. Canonical stores retain their existing keys and contents.

## Exact local build, development and install commands

```sh
cd /Users/nahid/Documents/agent-worlds
npm ci --ignore-scripts --no-audit --no-fund
npm run check
npm run dev
```

`check` runs typecheck, tests, fresh build and package. `dev` starts the visibly labeled synthetic host on localhost; it never contacts a provider. Individual `typecheck`, `test`, `build` and `package` scripts are available. Node ≥22.18 is required; verification used Node 25.5.0/npm 11.8.0. Dependencies and CI actions are pinned.

Delivered artifact: `/Users/nahid/Documents/agent-worlds/release/agent-worlds-0.2.0.zip`

SHA256: **`4a4ca458bd1e0391e2ead1b52a58977329e85c30280218e605e992808f99eff8`**

113 files, 221,540,432 installed bytes; ZIP 221,559,432 bytes. Content digest: `71588bfd345d2ed1090385b393111f54cf6bf355d9ff00f7f0c494714c183c81`. `release/asset-manifest.json` and `.zip.sha256` accompany it. Two clean builds matched exactly; the actual 1170-input bundle graph and archive exclude Outpost, mocks, test worlds, backups and external source imports.

Review with the Locus Python environment:

```sh
cd /Users/nahid/.codex/worktrees/72d5/locus
python Tools/InstallAgentWorldsArtifact.py review \
  --artifact /Users/nahid/Documents/agent-worlds/release/agent-worlds-0.2.0.zip \
  --sha256 4a4ca458bd1e0391e2ead1b52a58977329e85c30280218e605e992808f99eff8
```

For a real install, stop Locus and its backend, then run the same tool's `install` command with that artifact/hash, `--review-digest 71588bfd345d2ed1090385b393111f54cf6bf355d9ff00f7f0c494714c183c81`, the actual `--state-root`, and chosen `--workspace`. Add `--upgrade-legacy-v1` only when intentionally replacing a legacy installation. Actual user state was not changed. Exact install/rollback examples and explicit immutable `--development-directory` snapshots are in [local installation](agent-worlds-local-install.md).

Rollout: deploy/build the compatible host, verify the immutable artifact and NOTICE, review permissions/digest, then install using the existing atomic extension manager. Rollback pins both current and previous cache digests, restores the previous compatible host/plugin pair, and leaves canonical Locus data intact. There is no invented release URL or mutable sibling/main fallback.

## Verification and remaining limits

The [T01–T40 acceptance ledger](agent-worlds-acceptance.md) records automated, browser, real WK and native UI evidence. Detailed reports cover [native tests](agent-worlds-native-acceptance.md), [native visual inspection](agent-worlds-native-visual-verification.md), [browser comparison](agent-worlds-browser-verification.md), [artifact/install checks](agent-worlds-artifact-acceptance.md) and [host ownership](agent-worlds-host-integration.md).

Tested:

- Independent repository: 222 tests with zero failures/skips, typecheck, isolated clean-clone build and byte-identical repeated package.
- Shared Swift contract: 74 checks, including all 57 pinned fixture vectors. Twenty-four malformed/incompatible cases additionally crossed actual WK transport and were rejected without native effects.
- Final Python suite: 3,138 tests and 31 subtests passed in 564.46 seconds.
- Final complete native `LocusTests`: **1,989 tests, zero failures/skips/expected failures**, in 345.776 test seconds (346.420 suite wall seconds). Includes all 16 bridge and 36 AgentWorld tests, actual isolated process termination/retry with accepted native work pending, and positive board handoff without task submission.
- Final native UI: textured close-ups, Wano/native chat and tools, portrait cancellation/application, portrait/chat persistence after reset/reopen, and compact chat-header agent switching. The detected header sizing regression was corrected in `86077f43`, then passed 42 focused tests, the reviewed fixed-build capture and the final full suite.
- Installation and recovery: isolated install/upgrade/stale-review rejection/rollback/reinstall/disable/uninstall, final app resource checks, and complete Outpost archive restoration/hash verification passed.

The compact [final native result](agent-worlds-verification/native-final-result.json) is retained in the repository. Native log: `/tmp/locus-agent-worlds-final-green/tests.log`; result bundle: `/tmp/locus-agent-worlds-final-green/host.8fetZB/tests.xcresult`. Earlier diagnostic failures and their corrections remain in the native report; the final result does not erase them.

**NOT RUN:** live provider execution, quantitative CPU/GPU/frame/memory profiling, OS reduced-motion emulation, signed distribution, remote CI. Deterministic reduced-motion behavior is tested; a guarded isolated exact-PID WebContent process-kill and fresh-session recovery check passed while native work was pending. The native aggregate covers the complete `LocusTests` target; the separate `LocusUITests` target and unrelated Rust/wallet/Flutter suites were not run. Actual native GUI flows were inspected through isolated app fixtures. Native fixtures avoid user accounts and task submission. Browser screenshots are reviewed interaction evidence, not pixel-golden comparisons.

**Unresolved rights and artifact publication:** derivative/reference artwork rights are recorded in the independent NOTICE. At the original local acceptance checkpoint, no remote repository, push, release tag, public artifact, marketplace URL or paid asset generation had been created. The subsequent public source pushes below do not resolve artwork rights. A packaged release still needs a reviewed version/hash and a pinned release source retaining installation identity.


## Public source follow-up

After the local acceptance checkpoint above, the user explicitly authorized public source publication. [Agent Worlds](https://github.com/nahid-sparktales/agent-worlds) and [Locus Runtime](https://github.com/nahid-sparktales/locus-runtime) are now separate public repositories. Runtime source is retained at `/Users/nahid/Documents/locus-runtime`, outside the managed worktree parent. The Locus integration branch is pushed for review; publication does not merge it into Locus main.

These are source pushes, not a GitHub artifact release or registry publication. Existing artwork notices, pinned artifact hashes, local test evidence and unverified platform gates remain unchanged. Public source availability does not establish artwork rights. Subsequent remote CI results and corrections are tracked by the repositories' Actions runs and integration pull requests.

Remote source CI passed: [Agent Worlds](https://github.com/nahid-sparktales/agent-worlds/actions/runs/37408915188) ran all 222 tests and reproduced the exact ZIP hash on Linux; [Locus Runtime](https://github.com/nahid-sparktales/locus-runtime/actions/runs/37408894967) passed four Ubuntu/macOS × Python 3.10/3.14 jobs, 90 tests each.


### Locus CI diagnosis and corrections

The failing [runtime integration CI](https://github.com/nahid-sparktales/locus/actions/runs/37369851555) and [package checks](https://github.com/nahid-sparktales/locus/actions/runs/37369851189) were inspected with their logs and UI result attachments. The design and UI failures also occur on the existing main-branch run, before this extraction:

- The design audit stopped before Swift tests: three new Companion buttons raised the plain/borderless count above the existing baseline of 19. They now use the shared quiet button style; the baseline remains 19. The new World dismiss button also uses the shared icon style.
- The runtime rollback smoke fixture modified the former `ollama_code.runtime` entry point, so its intentional startup failure never ran through the extracted `locus_runtime.cli` launcher. Runtime PR #134 corrects the fixture and retains a real isolated nine-check service install/restart/failure/rollback result.
- The UI audit identified small low-contrast Files counts and Agent section headings. The Files count now uses secondary text, and Agent headings use primary text; both retain their existing semantic font sizes. A subsequent local Agent audit exposed a different XCTest issue: a wholly clipped heading retained an AX frame beneath fixed toolbar chrome. The failure image contains toolbar pixels, not heading glyphs. A trial of strict ancestor-viewport filtering removed that false positive but exposed another row with only a two-pixel AX-frame overlap and no rendered glyphs. That experimental helper was discarded. UI test assertions and contrast thresholds remain unchanged; the Agent configuration case still fails locally on macOS 26.4.1/Xcode 26.6 and needs verification on the macOS 15 CI runner.
- Escape dismissal now binds the Companion close button to the native cancel shortcut. The unchanged menu-bar UI case skipped locally because the display notch obscures the status item. A manual attempt also could not reach that status item through exposed accessibility actions. Escape/draft preservation remains unverified locally and requires the remote unobstructed UI runner.
- This extraction's fixture pin path now matches tracked lowercase `pin.json` on case-sensitive CI; manual native artifact uploads include the nested packaged-WK evidence and result bundle. Current Ruff, design audit and shared 74-check Swift contract pass.

Focused UI verification uses copied app and test-runner bundles with unique identifiers, fresh fixture state, and validated isolated launch paths. The normal Locus app and runtime were not launched or stopped. Local diagnostic logs/result bundles remain at `/tmp/locus-ci-isolated-ui`; no desktop screenshots were committed.

The compact [publication UI result](agent-worlds-verification/publication-ui-result.json) records two passing cases, the unchanged Agent configuration failure, the Companion skip, and the discarded diagnostic helper. These local results do not establish remote UI success.
