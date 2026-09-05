# Wallet verification checkpoint

Observed 2026-09-04/05 on macOS 26.4.1 (25E253), Apple Silicon, Xcode 26.6
(17F113), SDK 26.5. This is an engineering progress report, not a release
approval or an independent penetration test.

## Outcome

The implementation is committed and pushed on `codex/wallet-integration-ga` in
[draft PR #70](https://github.com/nahid-sparktales/locus/pull/70). It is **not ready
to merge, sign for distribution, activate a canary, or promote to GA**. The
original checkout was not changed. A recovery reference retains the initial
checkpoint at `codex/wallet-verification-checkpoint-20260904`; the implementation
was checked against `origin/main` revision `ebb8ed619ddfa5dc611b6ad709641f6c37e9095b`.

Production capability/review inputs remain empty/default-deny. No release
activation, invitation, real-wallet transaction, notarization, publication, or
canary soak was performed. Task Observer stays removed; bundled skills remain
manual-only.

## Measured engineering results

Unless separately identified, these results bind clean implementation revision
`7f2ae0a44cf82335c6d56a1596dd9e24bb54a9f3`. Verification-only follow-ups must be
rechecked on their own revision; passing results are not silently relabeled.

| Check | Result and limitation |
| --- | --- |
| Python suite | **1,027 passed**, 83.93 seconds, on clean `79b0270`; no skips or failures. The earlier `8c4fd66` run passed 1,025 tests and `7f2ae0a` passed 1,017. |
| Python lint | Passed on `79b0270`. An earlier import-order failure was fixed without suppressions. |
| Rust signer | **29 passed**; formatting and strict all-target Clippy passed. This is not a long fuzz campaign. |
| Complete native suite | **1,194 passed**, 106.55 seconds, on clean `3dbca50`. This includes the knowledge fixture correction, composer geometry and resize sampler regressions. The prior `7f2ae0a` run failed one transcript inspector-drag pixel comparison (1.143% against its unchanged 1% ceiling). Additional failure-image/geometry diagnostics were added; the mismatch did not recur in either new full run (`8c4fd66` / `3dbca50`), but its cause has not been proven fixed. No tolerance or retry waiver was introduced. |
| New scroll regressions | Clean `3f60ca4`: **1,195 passed, 3 failed**, zero skips, 1,198 native tests. The following clean `79b0270` run completed after the Keychain pause: **1,194 passed, 5 failed**, zero skips, 1,199 tests. Three tests retain dispatcher visibility, follow-after-send, and append/session-replacement failures; two additional tests were interrupted by a normal-code runner exit and earn no pass credit. `5fa3554` fixes an independently confirmed cancellation bug but does not resolve this gate. |
| Complete UI suite | **111 passed, 30 failed**, zero skips, all 141 tests requested, macOS 26 / compact-light-standard at `7f2ae0a`. Failed result bundles are retained. Subsequent targeted fixes are not a replacement for rerunning the complete 48-profile matrix. |
| Focused UI regressions | On clean `3dbca50`, **24 passed, 6 failed**, zero skips, all 30 prior failures selected once. Wallet Hub navigation, narrow composer/team-plan flow, inspector resizing and resize sampling pass in this subset. Remaining failures cover Appearance settings visibility, three sidebar interactions, Startup help contrast, and a blank dispatcher transcript. Counts from different runs are not combined into a full-profile pass. |
| Follow-up UI startup | The 15-case `3f60ca4` focused attempt times out enabling macOS automation before executing any test. All 15 remain missing; it earns no coverage. The failed result bundle and request are retained. |
| Latest hosted UI suite | **132 passed, 9 failed**, zero skips, all 141 tests requested, macOS 15.7.9 / compact-light-native with Xcode 16.4. PR head `1dbc3c3` was tested as merge `f2a879443f7202b1ac847295b06018802ad3956a`. Five sidebar hit/interaction failures, two composer-bottom assertions, the Review and Land heading, and user-bubble width remain. This is one failed profile, not a complete cross-OS matrix. |
| Focused clean-checkout verification | **5 passed, 0 failed, 0 skipped** on clean `05525f3ee3dcfe620fe15840f889a2548dfa82a6`: two orchestration request/cursor cases and three compact-sidebar focus cases. Build and test processes both exit zero; source is clean before and after, and the exact generated test artifact is recorded. This excludes the discarded transcript experiments and is not a full-suite or release pass. |
| Compact sidebar follow-up | `63d1045` adds a compact-only native hosting boundary and three focus regressions, verified in the clean five-case run above. The separate eight-case UI attempt builds but times out enabling macOS automation before executing any requested case; no actual sidebar AX/click coverage is credited. |
| UI measurement follow-up | `05525f3` corrects composer/bubble measurements and Review & Land viewport navigation from retained hosted AX/video evidence. Full UI-file typechecking and the design-system source audit pass. No new full-profile execution is claimed. |
| Solana local-validator smoke | **5 passed, 0 failed, 0 skipped** on clean `79b0270`, with Agave 4.1.2 (`182084b8`). The native-transfer case finalized and passed exact wire/signature/slot, fee and transaction-specific balance checks in 15.94 seconds. The validator executable SHA-256 is `aa0fd7ccc9300a29e5bea0a4bc65b9de5a103b111bc09c654983494040e8eaf8`; the downloaded archive was independently checked against the pinned CI digest. This is unsigned Debug smoke verification, not the full token/collectible, production reconciler, crash/restart or real-connector matrix. |
| Debug build | Passed with local ad-hoc signing, not Developer ID signing. |
| Direct Release and ReleaseMAS | Both full standalone-backend builds passed in separate DerivedData directories. Distribution signing was disabled. |
| Linked bundle boundary | Passed: **22 Direct and 14 MAS Mach-O files** inspected. No forbidden signer exports outside signer executables, or forbidden wallet connector/activation resources, configuration, or code in MAS. |
| Distribution audit | Not complete. After correcting the packaged attribution notice, the unsigned Direct product stops at the required connector-session access-group check. Only a properly profiled protected-Mac export can satisfy distribution entitlement/signature checks; there is no ad-hoc re-signing fallback. |
| Two clean checkouts | Connector bundle, both SBOMs, and seven resource/license files match byte-for-byte. This is two materialized checkouts on one Mac, not two-machine binary reproducibility. |
| License inventory | Signer SBOM covers 351 locked components; connector SBOM covers Reown and 292 npm entries, with zero unresolved npm license declarations. Vendor service/beta terms still need counsel. |
| npm advisory audit | Zero reported advisories, including development dependencies, on the audited unchanged lock. |
| Rust advisory audit | Zero reported vulnerabilities, but `derivative 2.2.0` / `RUSTSEC-2024-0388` and `paste 1.0.15` / `RUSTSEC-2024-0436` are unmaintained. Strict local `--deny warnings` exits 1; neither finding was waived in this report. Hosted CI permits these warnings, so its success is not a strict-audit pass. RustSec revision: `5a0ebedfe8bdd2e295b171f4162f8c977bcad9a5`. |
| Hosted Rust fuzz replay | All five targets failed seed replay with LeakSanitizer reporting 56 bytes in two allocations in fuzz-driver/libc++ thread setup. This recurred for `1dbc3c3`, tested as merge `f2a8794`, after the earlier `a35aad5` / `3ce39c7` attempt. Stacks suggest a driver-lifetime issue, not a proven signer leak; the finding remains blocking. No timed mutation phase or clean CPU hours are credited. |
| Hosted Swift fuzz replay | All eight latest hosted jobs failed. The downloaded Solana replay at `f2a8794` confirms the earlier pre-XCTest-bootstrap failure: LLVM 21 libFuzzer rejects `trace-pc-guard` instrumentation. Its receipt correctly records zero executed units, coverage and CPU credit. The separate normal-runtime-exit completion defect also remains; compiling the harness is not a working fuzz campaign. |
| Installed-code identity | App/signer API and command-line 40-character CDHashes agreed on actual ad-hoc signed `7997de9` Debug executables. This is not notarization or release identity approval. |
| Secret scan | A full-history redacted scan passed for **396 commits / 23.02 MB** through the `1dbc3c3` engineering checkpoint. Follow-ups require their own scan. No private release credentials were used. |

Complete local logs and dependency reports are retained outside the checkout at
`/Users/nahid/Documents/locus-wallet-evidence-20260904.EbK9iQ`. Native/UI result
bundles also retain failed attempts; they are not replaced with successful
receipts. The dependency report records exact commands, compiler/package
identities, archive/report hashes, and limitations.
UI recordings can include unrelated desktop background and must not be
published raw. They remain private local diagnostic artifacts, not sanitized
release receipts or externally attributable wallet evidence.

## Implementation changes and their verification limits

- External EVM settlement now binds the reviewed sender, transaction fields,
  fee ceiling, and exact transaction-scoped effects. Swap code checks select
  only the decoded adjacent pools/protocol/fee tiers, not unrelated manifest
  pools. Missing or ambiguous selected identities still reject.
- Release metadata uses the schema-v2 transition shape. Real signing-tool
  fixtures begin from the shipped template; blank identities and zero revision
  remain unusable.
- Sparkle uses its current update-check delegate selector. Candidate updates
  stay channel/archive-bound; a separately confirmed manual safety update does
  not inherit the old candidate's wallet authority or soak.
- The UI runner no longer asks Xcode for the unsupported repetition count of
  one. Missing, repeated, skipped, or failed results still fail the profile.
- Compact UI fixture sizing accounts for whole-window rather than content
  height. Normal user window minimums and exact UI geometry assertions remain
  unchanged.
- Packaged connector notices now preserve the exact Reown attribution line
  and describe the verified license evidence instead of stale unresolved-license
  text. No SDK, dependency lock, or vendored source update was made.
- Hosted connector inputs now pin verified Node 24.20.0 and npm 11.8.0. Fresh
  hosted inputs pass the deterministic bundle, resolved-license SBOM and npm
  advisory checks without changing the dependency lock or vendor bundle.
- Superseded PR checks now cancel within their own workflow/PR group; nightly,
  protected-branch/tag and explicit campaign runs remain distinct and are not
  preempted. Cancelled or incomplete attempts never earn evidence credit.
- UI preflight failures now retain an immutable unexecuted/blocked receipt.
  Hosted CI requests a compact window because the runner cannot fit the regular
  profile; this does not claim regular-window coverage.
- Compact navigation tests open the real sidebar overlay and scroll identified
  settings controls into view. Their existing assertions remain in force.
- The inspector divider now captures its rendered width instead of its larger
  saved preference, eliminating the initial compact-window drag dead zone.
  This applies the Apple design guidance's current-presentation-value rule.
- Settings concurrency guidance is larger and higher-contrast after its rendered
  text measured approximately 4.45:1. The accessibility audit is not waived.
  The subsequent audit reached the Startup explanation and found the same
  small-text contrast problem; that paragraph also uses the larger, stronger
  secondary-text style in `e69a64f`, pending execution.
- Wallet section navigation reserves a separate scrollbar band. The regression
  requires no scrollbar overlap, actual tab selection, and destination content.
- Resize work sampling includes tracking passes that never sleep, using a
  monotonic clock and deterministic non-overlapping sample tests. These are
  observed run-loop intervals, not rendered-frame or GPU timing.
- The knowledge fan-out error fixture now supplies valid early responses and
  fails the last awaited endpoint. This preserves every request assertion while
  avoiding scheduler-dependent cancellation of sibling requests.
- `65d97ab` replaces a total-request-count wait with an event-driven observation
  of the exact orchestration list, detail and incremental-events endpoints.
  Registration snapshots existing requests atomically and observes subsequent
  requests; unrelated metadata traffic cannot satisfy the wait. The original
  one-second deadline, exact request counts and cursor assertions remain.
  Both focused methods pass. An initial predicate-polling attempt timed out at
  that same deadline and was replaced, not accepted as a pass.
- Composer actions now wrap within narrow chat panes, preserving the same
  permission/mode/team controls and keeping Voice/Send/Stop together. Pure
  geometry tests cover compact widths, long labels, RTL, and non-finite probes;
  real UI verification is still required.
- Metadata-only transcript geometry diagnostics are opt-in, UI-fixture-only and
  compiled out of Release. They do not alter bottom-follow behavior or log text,
  addresses, session identifiers, or provider payloads.
- `3f60ca4` changes bottom-follow requests to the existing logical SwiftUI target
  while retaining display-refresh coalescing, selection/manual-scroll guards,
  and cancellation across session replacement or bridge removal. Native lazy
  document height is no longer treated as the exact scroll target. This follows
  [Apple's lazy-stack scrolling guidance](https://developer.apple.com/videos/play/wwdc2026/321/).
  Four native regressions check actual visible content, cancellation and input
  ownership. The first full run exposed three failing tests; the follow-up
  `5fa3554` cancellation correction adds a deterministic queued-update regression.
  Neither source inspection nor static typechecking proves the remaining visual
  behavior is fixed.
- Transcript wheel routing checks the native frontmost hit, so an overlapping
  sidebar or panel can own its gesture. Sidebar hit diagnostics are separately
  opt-in, DEBUG-only, capped at 32 metadata records and never consume events.
  The three failing sidebar clicks retain their original assertions; no
  coordinate-click workaround or accessibility exception was added.
- The latest hosted AX log independently proves a visible compact sidebar row
  resolves to the underlying conversation during accessibility hit-testing.
  `63d1045` places only that overlay in its own clipped native hosting subtree,
  preserving its environment and leaving the conversation non-modal. Dismissal
  restores the original control only while the sidebar still owns focus. It
  remembers a shared field editor's owning control rather than the reusable
  editor, preserves drafts, refuses removed-window controls, and does not steal
  focus that the user moved elsewhere. The Apple design guidance informed this
  visible-layer/input-ownership relationship. Native focus tests pass; the actual
  sidebar click/AX improvement still requires UI execution.
- `05525f3` measures the final composer action after wrapping, with the same
  8–28-point bottom bounds and containment checks, and measures the user bubble
  against the actual transcript reading column with the unchanged 0.84 ceiling.
  Review & Land navigation now requires the destination and its fields to be
  visible/hittable in the form's own viewport before interaction. None of these
  changes waives a geometry limit or substitutes coordinate clicks.
- Isolated lazy-scroll experiments did not fix dispatcher visibility and were
  not applied to the implementation branch. The native document-height estimate
  can disagree with the actual logical footer by 55 points even when that footer
  is aligned; separately, the dispatcher really has no realized final text.
  These are distinct remaining issues, not a reason to relax visibility tests.
- The Solana native smoke now uses a monotonic acceptance deadline with bounded
  idle/total-resource timeouts, and rejects a successful response arriving too
  late. Its finalized receipt must match submitted wire bytes, signature, slot,
  reconstructed message, fee/ceiling, and exact checked transaction-specific
  sender/recipient effects. Three pure adversarial methods accompany the two
  live methods. This test-only checker does not stand in for the production
  submitted-transaction reconciler or the full asset/action matrix.

## Open implementation and execution gates

1. **Local chains:** the fail-closed fixture verifier reports 25 readiness
   blockers, including 17 missing scenario groups. Stateful V2/V3/Universal
   Router/Permit2 settlement, SPL/Token-2022/ATA/Core, Sui Coin/object fixtures,
   pinned compiler/database artifacts, process termination/restart, and dual
   provider fault injection are not a complete runnable matrix. Catalog/source
   hashes are not execution proof. Production Sui's allowlist remains unchanged.
2. **Fuzzing:** hosted Swift replay currently stops before XCTest bootstrap
   because the selected runtime rejects the chosen coverage instrumentation.
   Separately, the app-hosted harness expects libFuzzer to return before
   recording completion metrics, while its pinned runtime exits the host on
   normal completion. This design must be corrected and instrumented execution
   demonstrated. An unexpected host exit cannot count as success. Distinct
   successful decoder branches, instrumentation self-tests, and supported leak
   checks remain incomplete. No 312-CPU-hour candidate campaign is credited.
3. **UI/accessibility:** macOS 14/15/26 × 16 profiles is not complete. Earlier
   setup failures and the 30 actual full-suite failures were retained. The compact
   dispatcher/team-plan fixtures showed a blank transcript and overflowing composer;
   the team-plan flow now passes, but dispatcher content still disappears. Its
   diagnostic snapshot retains three items and an attached native scroll view,
   while the lazy transcript has no visible rows after an absolute bottom jump.
   A logical scroll-target correction requires execution, followed by fresh
   complete profiles. Keyboard-only,
   VoiceOver, QR/privacy, real connector approval/restart, and complete swap
   correction flows remain separate unfulfilled gates.
4. **CI:** the first PR run failed because npm 10.9.8 interpreted the lock
   differently from the tested npm 11.8.0, and the hosted Mac's native
   accessibility settings differed from the requested standard profile. The
   resolver fix passed remotely; the next UI attempt stopped before execution
   because the hosted display was too small for the regular window. Hosted native
   tests also exposed the knowledge error-fixture cancellation race (1,185 passed,
   1 failed). Tool pinning, explicit compact-profile selection, and deterministic
   fixtures do not skip required profiles or waive failures. On the subsequent
   hosted `ec7cc12` attempt, native tests, deterministic smoke checks and basic
   Anvil integration pass; the two-case Solana run passes identity rejection but
   fails native-transfer finalization. After approximately 45 seconds its status
   is `confirmed` with 18 confirmations, not `finalized`. Sui and release builds
   are consequently skipped. This is retained as a failed local-chain attempt,
   not a successful settled transfer. A separate local `eafcc1b` attempt built
   successfully but failed LaunchServices startup before test execution; its
   result bundle is retained with zero executed test credit. Fresh complete CI
   is required.
   The following `79b0270` native run paused in `MCPCredentialStore.set` /
   `SecItemAdd`; a one-second stack sample also showed browser-key reads waiting
   inside Keychain. It subsequently completed with the five failures recorded
   above. No permission was auto-approved or credential printed/exported; the
   two premature host exits remain unexplained, not waived. Test storage still
   needs deliberate isolation from the user's Keychain.
   Hosted run `33947113589` at merge `f2a8794` passed Python, mobile and signer
   jobs, but failed native and UI verification. Native failures include the
   dispatcher/append/replacement regressions and a test that counted unrelated
   background requests before its required incremental-events fetch. The chain,
   Swift smoke and release build steps were skipped after the native failure.
   The separate local five-case Solana pass does not convert those skipped
   hosted steps into successful evidence.
5. **Release operations:** cold-start history currently has a 64-transition
   bound; longer-lineage paging is not implemented. Admission signing validates
   individual finite allocations, but does not supply the independently
   witnessed issuance/serial/cohort-allocation ledger or publication service.
   These are not automatically completed by a signed local fixture.

## External gates remain real

The second protected signing Mac, Developer ID profiles/credentials, independent
clean-Mac verification, funded real-wallet accounts, provider contracts/load
results, independent signer and application audits, derivation reproduction,
counsel/disclosures, release ledger/hosting approvals, finite admission
allocations, invited testers, incident drill, reward/support/security ownership,
and continuous canary observations have not been supplied as release evidence.

The soak begins only when the exact notarized archive, valid all-chain
activation, and admitted cohort are simultaneously available. The required
30 continuous days, 25 external testers, 100 finalized/reconciled transactions
per chain, exact enabled-path coverage, and zero defined security-loss events
cannot be inferred from repository tests. GA must retain the exact canary
archive bytes and permanent restrictions. Missing evidence keeps the gates shut.
