# Native extraction acceptance

**Final result: 1,989 native tests passed, zero failures, zero skips.** The final real app-host run completed on October 5, 2026 using production changes through `86077f43` and the final independent `ec94166` release artifact. Xcode result inspection confirms `Passed`; all world gates and the companion input case executed successfully. See [machine-readable result](agent-worlds-verification/native-final-result.json).

This records the native checkpoints and verification after removal of the old world implementation. Audit commit `d7f05e63` preceded changes; `533acf6b` pins the shared contract and `ed51b2cd` separates canonical native conversation work.

## Executed evidence

- Xcode 26.6 / macOS SDK 26.5, arm64: `build-for-testing` passed with bundled backend/provider downloads disabled.
- Original native baseline: 116 tests passed. Additive bridge and canonical service/presentation checkpoint: 126 tests passed.
- Shared Swift contract: 74 checks passed, including all 57 SDK fixture vectors and 17 native session, runtime range, capability and replay checks.
- A first full direct-XCTest run exercised 1982 tests, with 2 skips and 72 assertion failures. The failures were confined to BrowserInputTests (1), FeatureLogicTests (1), and public accessibility dependent TranscriptFollowTests (58), TaskCapsuleModelTests (10), TranscriptSelectionTests (2). The disposable command-line wrapper did not supply the application's complete Info.plist or AppKit/AX lifecycle. This result is not a green full suite.
- The corrected harness copies the exact built app to a fresh directory, preserves its resources, Info.plist and signing entitlements, changes only its bundle identity, and runs Xcode's generated app-hosted `.xctestrun` against that copy. It leaves the user's running Locus untouched. All 12 initial browser/Info/AX checks passed. All 99 tests across the three formerly failing AX classes and AgentWorldBridgeTests then passed, with no skips or failures. No application behavior or test assertion was weakened to obtain that result.
- The 11 bridge tests include real secured WKWebView loading, malformed schema rejection, migrated/reset/corrupt preferences, project A/B cosmetic isolation, queued native work surviving disable/upgrade/workspace revocation, actual missing-file failure, an uncaught external JavaScript exception, and an infinite JavaScript loop with the native health deadline. Canonical bindings remain intact. Native termination callback coverage is distinct from an OS process-kill experiment.
- The actual packaged WK test used verified ZIP SHA256 `090c697ed4c4c16f7bb0a4c284fe1cfead62cb7e7b335862c6e5da483c5c3421`. It asserts six roster/scene labels and statuses, negotiated native mode with no demo agents, visible scene frames, successful artwork loading, bounded placement descriptions, native selection without conversation creation, every metadata backdrop and style preview, default/context appearance behavior, lifecycle disposal, and revocation/retry. It passed in the real app host. [Secured WK snapshot](agent-worlds-verification/native-secured-wk.png).
- Separately, the isolated actual UI fixture app was inspected through native CUA; see the native scene, quarters, chat/tools, board, calendar and context screenshots and the main acceptance ledger. Synthetic fixture dispatch rejects provider work. No live user task was submitted.

The first wrapper's `document.hidden=true` correctly paused the renderer and produced a blank scene snapshot. The real Xcode app-host lifecycle fixed both this visibility condition and AX setup. Visible-scene assertions remain mandatory whenever the artifact test is selected; the test skips explicitly if no artifact path is supplied.

## Reproduction

Run the real app-host harness from the Locus checkout:

```sh
LOCUS_AGENT_WORLDS_TEST_PLUGIN=/absolute/path/to/verified/extracted/plugin \
  Tools/RunAgentWorldsNativeTests.sh
```

It runs the entire LocusTests target by default. Set `LOCUS_NATIVE_TEST_SELECTION` to comma-separated `LocusTests/Class[/method]` values for diagnosis. `LOCUS_NATIVE_TEST_BUILD_ROOT` selects the log/result directory; `LOCUS_NATIVE_TEST_DERIVED_DATA` optionally reuses an existing DerivedData directory. The script creates a fresh app copy per run so stale resources cannot mask removals. It never changes global permissions, stops an installed app, or installs an artifact into user settings.

Executed checkpoint logs/results were `/tmp/locus-agent-worlds-native-acceptance/tests.log` (original full wrapper), `/tmp/locus-agent-worlds-apphost/focused.xcresult` (12 corrected tests), and `/tmp/locus-agent-worlds-apphost/regressions.xcresult` (99 corrected tests). These were pre-cutover checkpoints; the final full app-host result above and below completes that requirement.


## Thin-host cutover and additional native gates

The thin-host removal is `c6237049`, following the explicit pre-cutover audit and parity gates. Web screens require version 2. At that checkpoint native Social Studio retained a separate version-1 path; native Social Studio/OpenPost support has since been removed. The independent Social Studio plugin uses the generic version-1 plugin-panel protocol. The test results here describe the extraction checkpoint. Locus no longer owns a theme catalog, nautical enums, legacy web commands/snapshots, world model art, or a renderer polling loop. `LegacyAgentWorldPreferenceMigration` is a bounded, one-way cosmetic import using installed presentation metadata and authorized profile IDs; original keys remain untouched. Current visual preferences are keyed by plugin/screen and a hash of the canonical workspace.

The first complete post-cutover real app-host run exercised 1983 tests in 412.950 seconds: 1 failure and 1 skip. The failure was an unavailable `person.crop.square.badge.plus` symbol in the generic empty state, corrected in `3c519cb3`. The skip was `CompanionPointerTests.testHostedWindowDeliversQueuedMouseMovementAndReleasesLocalListener`, whose existing activation guard reported `key=false, active=false, hidden=false, visible=true, policy=0`. All world, canonical conversation, browser, calendar, board, portrait, and accessibility regression classes otherwise passed. Its result bundle is `/tmp/locus-agent-worlds-final-native/host.jhi99q/tests.xcresult`.

Additional bridge coverage now verifies all 24 shared malformed/incompatible client vectors through the actual `WKScriptMessageHandler`, an authorized native selection through that same transport, and replay suppression. Accepted two-item native FIFO work survives explicit window close/reopen, an uncaught JavaScript exception, an infinite event-loop hang, and actual WebContent termination. Each scenario reconnects through a newly mounted SwiftUI/WK coordinator, negotiates a fresh session and authoritative snapshot, and completes both native turns exactly once. Process termination uses a test-only guarded getter for the disposable WK surface's exact PID, distinct from the app and mounted renderer; it never searches for or kills unrelated WebKit processes. This case executed and passed on this machine.

The first added close/reopen test exposed a test helper choosing a closed window with the same title. `12786fb4` searches all matching windows and names each fault scenario separately. The corrected focused run passed all 16 bridge tests, all 36 AgentWorld tests (including canonical positive board handoff), and the symbol catalog. The existing companion pointer test passed in one focused run, failed once with a missing queued OS mouse event, and explicitly skipped on an isolated retry when it could not activate. No input assertion or product behavior was changed to hide those outcomes. Focused evidence: `/tmp/locus-agent-worlds-final-focused-2/host.lDYYPq/tests.xcresult` and `companion-isolated.xcresult` in that run directory.

These runs used final independent source `ec9416679a5f4929d78ae2f19acb6e4d572eb234`, ZIP SHA256 `4a4ca458bd1e0391e2ead1b52a58977329e85c30280218e605e992808f99eff8`. The final app has 50 loose resource files and no embedded renderer paths. Inspection of its compiled `Assets.car` found 49 remaining asset names and none of the six retired world backdrops; native resource tests also assert their absence while retaining shared portraits.

WebKit logs `WEBP` reader `err=-50` warnings in both the earlier and post-cutover runs. The whole-map pale appearance matches the prior native snapshot; distance/fog versus actual close-up texture appearance is checked separately through the isolated full app UI. These warnings are retained in the logs, rather than treated as a substitute for visual evidence.


The final actual-app visual smoke confirmed full-color close-up ship/island textures, native context palettes, chat/board navigation, portrait-picker cancellation, and canonical portrait retention across cosmetic reset/reopen. It caught an AppKit `Menu` image extraction bug in the compact chat header: a portrait inside the label drew at its original size. `86077f43` places the bounded avatar beside the text/status menu. All 42 focused AgentWorld/palette tests passed, and a fresh isolated app then verified the compact portrait, the six-profile switch menu, and selecting another agent's native chat preview. [Corrected portrait header](agent-worlds-verification/native-final-portrait-header-fixed.png). All owned UI fixtures were quit before the final full suite.


## Final full native result

The final real-app test run passed **all 1,989 tests, with zero failures, zero skips, and zero expected failures**. Test execution took 345.776 seconds (346.420 seconds including suite overhead); Xcode runner elapsed time was 360.212 seconds. `xcresulttool get test-results summary` independently reports `Passed`, `passedTests: 1989`, `failedTests: 0`, and `skippedTests: 0`. The previously intermittent companion activation/mouse case passed in this final aggregate run without changing its assertions or input implementation.

The run used `Tools/RunAgentWorldsNativeTests.sh` with:

```sh
LOCUS_NATIVE_TEST_BUILD_ROOT=/tmp/locus-agent-worlds-final-green \
LOCUS_NATIVE_TEST_DERIVED_DATA=/tmp/locus-agent-worlds-native-baseline \
LOCUS_AGENT_WORLDS_TEST_PLUGIN=/var/folders/8s/h68vzwb10yg081d3vgblcx7c0000gn/T/agent-worlds-ec94166-native-ebydvamv/plugin \
Tools/RunAgentWorldsNativeTests.sh
```

Full logs: `/tmp/locus-agent-worlds-final-green/build.log` and `/tmp/locus-agent-worlds-final-green/tests.log`. Result bundle: `/tmp/locus-agent-worlds-final-green/host.8fetZB/tests.xcresult`. The secured WK snapshot above was refreshed from this exact successful final run. The source/loose-resource boundary check and compiled asset catalog inspection also passed against the exact final built app.
