# Native extraction acceptance

This records the native checkpoint before removal of the old world implementation. Audit commit `d7f05e63` preceded changes; `533acf6b` pins the shared contract and `ed51b2cd` separates canonical native conversation work.

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

Executed checkpoint logs/results were `/tmp/locus-agent-worlds-native-acceptance/tests.log` (original full wrapper), `/tmp/locus-agent-worlds-apphost/focused.xcresult` (12 corrected tests), and `/tmp/locus-agent-worlds-apphost/regressions.xcresult` (99 corrected tests). A clean full app-host run remains required after the thin-host removal stage; these checkpoint results do not substitute for that final run.
