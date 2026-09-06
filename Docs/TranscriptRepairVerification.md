# Transcript visibility repair and CI verification

Engineering checkpoint, 2026-09-06. This focused repair does not activate wallet
authority, satisfy wallet GA evidence, or constitute a release approval.
The original `/Users/nahid/Documents/locus` checkout remains untouched.

## Changes

- Conversation identity and message snapshots commit together. Internal
  generation/revision/tail tokens bind rendering, native layout and deferred
  scrolling; owned load tokens reject stale conversation and metadata replies.
  Assigning a server identity to the same conversation preserves its rows and
  reading state. Draft admission waits for that conversation's owned metadata.
- History remains in one lazy stack with stable, conversation-scoped outer row
  identities. For a multi-row transcript, discovery first realizes the immediate
  predecessor, waits for its attached native measurement, and exposes its exact
  adjacent boundary; a changed estimate alone cannot trigger another proxy jump.
  The single-row path requests its terminal row directly. The real terminal
  content must then be realized before its measured end is
  aligned in the attached native viewport. Completion requires matching layout
  evidence. A main-queue callback or estimated lazy-stack end is not completion.
  Unchanged geometry is coalesced, not retried by a scrolling timer.
- Reader scrolling, selection, search and detach cancel pending following.
  Deferred session resets cannot override newer reader input. Ending selection
  does not silently resume following; Send and Jump to Latest can resume it.
  Native alignment reconsiders actual document growth after a constrained scroll.
  Native live-scroll intent is admitted synchronously. A selected native glyph
  preserves its measured viewport position across layout, bound to weak leaf
  ownership, content identity, attachment, conversation and reader intent. An
  unfinished layout cannot erase an otherwise valid anchor; stale text or newer
  input invalidates it. The ineffective macOS 15+ transaction experiment was
  removed, and its failed runs remain retained.
- Visibility helpers calibrate real glyph clipping and transcript-owned controls
  in the same frame. An inspector's Stop button cannot satisfy the transcript
  test. The six original follow-test bodies and three-second deadlines remain
  unchanged. Diagnostics are bounded and fixture-only, without message content.
- Compact sidebar hosting preserves the native observation/focus environment.
  The optional decorative diagnostic view no longer intercepts accessibility or
  pointer hits and is absent unless explicitly enabled in a fixture. Search and
  Clear identifiers belong to their actual controls, not the containing row.
- AppModel compatibility consumers are notified only after an orchestration-owned
  identity transition commits. Child/content publications do not propagate to
  AppModel. Existing architecture assertions remain intact, with five additional
  publication-count and coherent-state tests.

## Retained verification

All counts describe one identified execution, not a union of retries. Native
engineering runs use Debug/ad-hoc signing and backend bundle mode `skip` on
Apple Silicon, macOS 26.4.1 (25E253), Xcode 26.6 (17F113), SDK 26.5. They are not
distribution builds or proof of the full macOS 14/15/26 UI matrix.

| Source | Result |
| --- | --- |
| `6b71cc9` plus exact patch SHA-256 `09632eec3d118ad7ecd2772259c321defd2dd87ac12565626741af5bb7364022` | 93/93 focused native checks and a separate 6/6 sidebar UI run passed. These are dirty-patch engineering results, not clean-candidate evidence. Earlier failed attempts remain retained. |
| Clean `22ed1bb3db5db84e2e37a28c05e67eafe3c0deb5` | Full native inventory: 1,280 enumerated and executed once, 1,279 passed, one failed, zero disabled/skipped/missing/duplicated cases. Both original visibility failures and the new deferred-reset/constraint regressions passed. The unchanged AppModel observation-boundary assertion failed and prompted commit `38fcd39`; this full run remains failed. |
| Clean `22ed1bb3db5db84e2e37a28c05e67eafe3c0deb5` | Full Python suite: 1,059 passed in 90.27 seconds. Lint, design-system source audit, protocol manifest, shell syntax and exact Rust-fuzzer vendor provenance checks passed. |
| Clean `38fcd394748cad84b50db03af10ea17d304f93b9` | Full native inventory: 1,285 executed once, 1,283 passed, two failed, zero skipped or missing. The architecture gate and all five new observation tests passed. The new selection-preservation and rapid-replacement cases caught a 67-point layout shift and delayed native gesture cancellation. This full run remains failed. |
| Clean `03e164c41de54e963ace143cbb38fce6df61fda5` | Full Python suite: 1,063 passed in 91.55 seconds. Runtime dependencies were installed into a new isolated environment from the unchanged hash-verified lock; test tools are pytest 9.1.1 and Ruff 0.15.7. Lint, design-system and vendor-provenance checks passed. Gitleaks 8.30.1 scanned 408 commits / 23.36 MB with zero findings. |
| Clean `03e164c41de54e963ace143cbb38fce6df61fda5` | Full native inventory: 1,286 executed once, 1,285 passed, one failed, zero skipped/missing/duplicated cases. The immediate native-gesture regression and rapid-replacement case now pass. Selected-text viewport preservation still fails by 67 points. Before/after attachments prove the selected glyph remains attached at exactly the same document position and the drag pointer remains inside the viewport; only the viewport changes. This is not a passing full suite. |
| Clean `03e164c41de54e963ace143cbb38fce6df61fda5` | Real Rust `evm_ffi` replay and 60-second smoke passed with the pinned fuzz-only engine, ASan and leak detection enabled. Replay executed two inputs; the timed target executed 8,267 inputs and measured 60.949 target CPU-seconds. Run `b642b258-59de-43b2-9d3e-e5a21b2ca44f` retains exact source, binary, instrumentation, corpus and receipt identities. This covers one of five Rust targets, not a long campaign or canary gate. |
| Clean `148b3b9ef2f102d6bb9bef4f0e1c186076317d7f` | Full native inventory: 1,289 enumerated and executed once, all passed, zero disabled/skipped/missing/duplicated cases or repetitions. Both original visibility cases, the unchanged selected-text viewport check and three measured-anchor regressions passed. Source and generated artifact identities were unchanged before/after. |
| Clean `9c288bed13acd87a6a20f2ac2f4aa89f218863cd` | Full native inventory: 1,291 executed once, 1,290 passed and the selected-text viewport check failed, zero skipped/missing/duplicated cases. The two added pending-layout tests passed. The retained trace shows a transient 67-point movement followed by a successful measured correction about five milliseconds later; the original maximum-movement assertion correctly rejects that visible excursion. The preceding passing run never experienced the excursion. This run remains failed and demonstrates that deferred correction alone is insufficient. |
| Clean `9c288bed13acd87a6a20f2ac2f4aa89f218863cd` | Targeted UI inventory: 14 executed once, 12 passed and two failed, zero skips/missing/duplicates. All six sidebar cases, dispatcher controls, cross-message selection, Jump to Latest and resize passed. Team-plan actions and continuous scrolling across tool blocks failed and remain under investigation. This is not a passing UI suite. |
| Clean `cca7d0c0b345cb46a07798d5b10dae64edf234fd` | Full Python suite: 1,089 passed in 90.18 seconds, with clean lint. Run used a second isolated clean clone; its source remained unchanged afterward. Includes the expanded syntax and distribution-inspection regression coverage. |
| Clean `bcd7e1438d320e94f536824a1b1c066fc306159d` | Full native inventory: 1,292 enumerated and executed once, all passed, zero disabled/skipped/missing/duplicated cases or repetitions. Includes the new assertion that measured selection correction completes inside the native bounds notification, before it returns, with no synchronous observable-state publication. Both original visibility tests and the unchanged maximum-movement check pass. Source and exact generated test artifacts remained unchanged. |
| Clean `bcd7e1438d320e94f536824a1b1c066fc306159d` | The other four real Rust targets passed replay and 60-second smokes with ASan and leak detection enabled: Solana 6,512 iterations / 60.935 target CPU-seconds; Sui 6,012 / 60.948; authorization 2,375,036 / 60.761; calldata 2,984,933 / 60.808. Exact clean-source receipts are retained. Together with the earlier separately identified EVM result, these exercise all five targets; they are not one same-revision campaign or long-duration release evidence. |
| Clean `56cc97a6475a5e201e77b048105116d7647d48aa` | Full native inventory: 1,295 executed once, 1,293 passed and two failed. The new exact tall-plan fixture reproduces missing native text/controls before any accessibility query, confirming a realization dead end. The new selection-scope fixture also catches an invalid baseline accessibility lookup returning the scroll area rather than its child button/text. Existing tests remain unchanged; both failures are retained and require separate fixes. |
| Clean `56cc97a6475a5e201e77b048105116d7647d48aa` | Targeted UI inventory: 14 executed once, 12 passed and the same two team-plan/tool-scroll cases failed. Making the selection registration view noninteractive is a valid ownership correction, but did not resolve either actual UI failure. |
| Clean `eefc223cfad6a9e32abe013be963f0f5d6e00360` | Full Python suite: 1,090 passed in 87.63 seconds, with clean lint in the separate clean clone. |
| Clean `eefc223cfad6a9e32abe013be963f0f5d6e00360` | Focused native inventory: 76 enumerated/executed once, 75 passed and the tall-plan regression failed; zero skipped/missing/duplicated cases. The original six tests and corrected native-hit-based accessibility calibration pass. Requesting row visibility without a bottom anchor is not sufficient to resolve the tall plan. An earlier focused-run harness attempt failed before executing any tests because it incorrectly treated excluded classes as disabled required tests; that failed attempt is retained. |
| Clean `bb1d5bdf8f51aeccd7f9f1108373f15f92be80b6` | One unchanged tool-scroll UI test passed with a fixture-only native hit diagnostic. The diagnostic did not own hits, but its accessibility reads and native background can affect realization, so this single instrumented pass does not prove normal behavior repaired. The diagnostic now has a separate default-off switch for control verification. |
| Clean `eb4c3c2388e168d5509fe976b20889279bfa8867` | Focused native inventory: 79 enumerated/executed once, 78 passed and the tall-plan regression still failed. All three new real-coordinator registration-order tests pass. Row geometry shows only the tall request row appearing, then disappearing after the realization request; the reply and terminal row never appear. No offsets or periodic invalidation were added to mask this. |
| Clean `eb4c3c2388e168d5509fe976b20889279bfa8867` | The unchanged tool-scroll UI case fails with the new native diagnostic disabled, at the original not-hittable button assertion. This control run confirms the instrumented pass is not acceptance evidence. |
| Clean `73ba0c80440ca64faafa6c05fd4322fdb2e852bd` and separately clean `7f9a355b63a0658d167831d8592455a2d8c5d1f1` | One real tall-plan regression executed on each revision; both failed. Explicit scroll-target layout alone and then a target-position binding with exact container acknowledgments were insufficient. The position-binding experiment was removed, retaining both failed results. The latter trace proves the second realization request follows a fresh native layout acknowledgment. |
| Clean `546028addab6d2b2e85ee9d8b23c9b48c97d745e` | Focused native inventory: 82 executed once, 80 passed; tall-plan visibility and the new decorated-card fixture's legacy accessibility lookup failed. The two new exact-layout-acknowledgment tests pass, as do the original six. A separate unchanged, diagnostic-off tool UI run failed at the same not-hittable button. The decorative-border correction is not a demonstrated repair of that actual UI failure. |
| Clean `546028addab6d2b2e85ee9d8b23c9b48c97d745e` | Full Python suite: 1,108 passed and one activation-signing test failed. CI's exact lint scope passed. The failure exposed a real fractional-second rounding bug in the release review validator, not a loosened authority requirement. Deterministic actual-validator tests reproduced three failures before the fix; all failed evidence is retained. A separate broader non-CI lint invocation found five pre-existing findings in the unrelated robot-symbol generator; it is not reported as passing. |
| Clean `28bc6e707f78724ec0ca43753ba542799346bb8f` | One real tall-plan regression executed and failed. Moving the accessibility label/container responsibility to the native scroll area did not resolve that realization dead end. |
| Clean `6e9525ab252b72595a55ebbe471a87e99a020b35` | Full Python suite: 1,118 passed in 89.17 seconds; CI's exact lint scope (`agent` and `Tools/ReviewabilityReport.py`) passed. Clean source remained unchanged. Includes deterministic second-boundary acceptance and invalid-time/ownership/method rejection checks; the actual authority restrictions remain intact. |
| Clean `6e9525ab252b72595a55ebbe471a87e99a020b35` | The decorated-card native fixture passed once after switching to the existing proven public accessibility helper and initializing its own accessibility query. Its timeout, frame-center ownership, exact identity and role requirements were preserved. This fixture pass is not a passing tool-scroll UI result. |
| Clean `3d5ad34ee4dd20a437ceaf44805b70f772ab7c89` | Both the unchanged real tall-plan test and a separate plain-719-point-row diagnostic failed. The diagnostic retains real trailing content, exact unique identities and the same request pipeline; it changes no model state. This rules out the approval card's controls/focus subtree as a necessary cause of the blank transcript and retains the real card as the acceptance gate. |
| Clean `3d5ad34ee4dd20a437ceaf44805b70f772ab7c89` | The unchanged tool-scroll UI test passed once with native hit diagnostics disabled, after the explicit full-header label shape and native scroll accessibility ownership changes. A complete uninstrumented UI/native run is still required; this single-case result is not the full matrix. |
| Clean `76fb418f33334ff7a8386e93f6a81eb4d786e681` | Both real tall-plan and plain-row isolation tests still failed. Requesting the preceding row successfully realizes the short reply, but the next estimated terminal-row request immediately moves beyond it and evicts the visible content. In the plain diagnostic, a genuine predecessor measurement is available; the remaining proxy jump still strands the viewport. This is retained failure evidence, not acceptance of predecessor-first discovery. |
| Clean `6f60acbce64bd777d8b8681f07d73f392eb9e7cf` | Five new coordinator regressions executed once and passed, zero skipped/missing/duplicated cases. They verify predecessor-stage accounting and rejection of stale/conflicting render installs before callback or reader-state mutation, valid same-token callback refresh, newer generations and exact-token reattachment. This is not a passing tall-plan visibility result. |
| Clean `507df7a8e900908d7444a1c6a244e2c0fc805ca7` | Both tall-plan cases passed once: unchanged real approval card with actual reply and transcript-owned controls, and the separate plain-row diagnostic. The trace confirms actual predecessor layout, exact native boundary exposure and actual terminal-row realization. The normal-view run is still required after removing the diagnostic replacement hook; this is not a full-suite or hosted-CI pass. |
| Clean `a7cc3a2a2cc8faa318d964a437eca5c42ade6bf0` | Full normal-view native inventory: 1,307 enumerated/executed once, 1,306 passed and one streaming-growth visibility test failed; zero skipped/missing/duplicated cases. Original six, real tall approval card, 600-row lazy-history visibility and the new ownership/measurement tests passed. The streaming trace proves that bottom-anchored predecessor discovery itself overshoots before a native marker appears. All four actual glyph assertions fail while immutable-snapshot assertions pass. This full run remains failed. |
| Clean `a7cc3a2a2cc8faa318d964a437eca5c42ade6bf0` | Expanded normal-view UI inventory: 26 executed once, 24 passed and two failed, zero skipped/missing/duplicated cases. Both native hit diagnostics were disabled. Tool-card click and user-message double-click fail the unchanged not-hittable checks despite being visibly onscreen in retained recordings. Sidebar, team plan, dispatcher, copying, cross-row selection, visibility modes and live resizing pass. Earlier isolated tool-click passes do not override these normal-view failures. |
| Clean `c4cde0ecbf7c4b060d27182f720df6b4aff4c4cd` | All 88 focused follow/selection/relayout/streaming tests passed once, zero skipped/missing/duplicated cases. Includes actual streaming growth, unchanged original six, real tall card and 600-row lazy-history visibility after switching predecessor discovery to its leading edge. Separately, full Python and CI-scope lint passed: 1,118 tests in 88.73 seconds, zero skips; clean source unchanged before/after. Fresh full native and normal UI results remain required. |

Generated test configurations, binary hashes, source/tree identities,
enumerated inventories, logs and result bundles are retained outside the
checkout. Native and UI app-host runs share the execution lock and run serially.
UI recordings remain private diagnostics; they may include desktop background
and must not be published raw as sanitized evidence.

The temporary plain-row substitution and its diagnostic-only test are removed
before normal-view verification. Their original source identities, failures and
passing isolation result remain retained. The real tall-plan regression and all
six original follow-test bodies/deadlines remain unchanged. The expanded focused
UI selection also includes copy, native word/user-message selection, code/table
collapse, reasoning visibility, alternate tool modes and permission usability;
it is still not the full cross-OS/profile matrix.

## CI repairs and remaining limits

- Swift fuzz coverage now requests edge mode, inline counters, PC tables and
  comparison tracing. Standalone compiler output demonstrates those mechanisms;
  it is not proof of a working production campaign. The separately unresolved
  Swift runtime-completion issue remains a blocker.
- The Rust-only fuzz engine is pinned to the exact `libfuzzer-sys` 0.4.13 archive,
  commit and single RSS-monitor lifetime patch, with an independently verified
  patched-tree digest and retained licenses. Production signer dependencies are
  unchanged. No sanitizer finding is suppressed or retrospectively waived;
  real-target replay/smoke results are recorded above. A complete same-candidate
  campaign and long-duration evidence are still required.
- Bounded test-process supervision retains exact invoked Swift configurations
  and immutable failed timeout records. Timeout/interruption never earns CPU
  credit. Only invocation-owned process groups may be cleaned up.
- Sui's separate fixture dependency graph is fetched using its exact lock before
  the unchanged offline build. This is not a production network bypass or a
  completed stateful local-chain matrix.
- The MAS forbidden-content audit reads complete inspection output before
  matching. A producer SIGPIPE can no longer turn a forbidden match into a false
  success; inspection failures remain blocking. Distribution and CI updater
  inspection now follow the same rule. The shell-syntax gate parses every quoted
  script separately; additional synthetic checks cover a malformed late-listed
  script, large first/last matches, failed producers and invalid match patterns.
  The 55 focused tooling checks pass; that is not an actual distribution audit.
- Hosted native/local-chain jobs now retain their generated test-result bundles
  on success or failure, without uploading full build caches or changing test
  outcomes. Exact result-directory coverage has a separate regression.
- The UI matrix runner retains failed summary/tree extraction independently and
  the exact invoked test configuration, its digest and original relative-path
  base. Process failure, missing results, configuration drift and early preflight
  failure remain blocking; observed failure counts are not accepted coverage.
  The 56 targeted synthetic evidence/lock checks pass, and the full clean Python
  result above includes the new evidence checks.
- The release tool anchors only its synthetic non-activating review projection
  to a canonical whole second. It still compares actual review/expiry dates with
  the original clock. This avoids formatter rounding falsely rejecting valid
  identities at a second boundary without changing any signed scope or lease.

PR #70 is held for fresh hosted results. GitHub currently configures no required
checks for `main`, but that does not relax the user's all-CI-green merge gate.
Skipped downstream jobs, zero-credit fuzz attempts and missing cross-OS or
external wallet evidence are not passes. Notarization, canary activation, funded
interoperability and the required soak remain separate release gates.
