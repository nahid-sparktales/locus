# Agent Worlds acceptance ledger

Status: **in progress, destructive Locus cutover not accepted**. This ledger distinguishes executed logic/security/installer checks from actual native visual acceptance. A passing row at one layer is not evidence for another layer.

Baseline: Locus `4cce6ebfaa31f76cd7790967ad8ce7d7e2338deb`, clean detached checkout. Audit `d7f05e63` was committed before implementation. Candidate source: independent `agent-worlds` `68a60d4492cae2414ba765202b71248d038e41e6`; local artifact0.2.0 uses SDK1, wire2 and preference schema2. No remote or publication exists.

## Executed aggregate checks

- Original renderer: typecheck/build and144 tests passed. Candidate retains128 applicable baseline tests, adds8 World-wrapper tests;16 Outpost-only tests are archived with their implementation.
- Independent clean clone: `npm ci --ignore-scripts --no-audit --no-fund`, `npm run check`, repeated fresh `npm run package`, ZIP CRC and full inventory verification passed. Candidate222 tests, zero failed/skipped. Node25.5.0/npm11.8.0, macOS arm64. See [artifact evidence](agent-worlds-artifact-acceptance.md).
- Swift shared contract:57 canonical fixture vectors and17 session/version/idempotency checks passed (74 total). Actual WK hello→welcome→scoped snapshot and resource fetch/XHR tests passed; private provider/model text is absent from DTOs.
- Native baseline116 tests passed; additive canonical-service/generic-metadata checkpoint126 tests passed. Later failure/queue/artifact tests and full suite results are recorded separately when complete.
- Python full suite before the local installer addition:3130 tests and31 subtests passed in435.37s. Local installer suite13 tests passed, affected existing extension suite93 passed. Current final full run is pending.
- Browser asset loading, empty/500-agent rosters, capabilities, scope reset/reconnect, native intention logging and paused-clock commands passed. Original and extracted screenshots are retained. Their viewport/clock differences are documented; they are not pixel-golden tests.

## Required scenarios

`PASS` identifies executed automated or observed evidence named in the row. `PARTIAL` identifies required remaining native/end-to-end evidence. `BLOCKED` identifies an unmet extraction gate. Native failure results will be appended rather than inferred from mocks.

| ID | Evidence and actual disposition |
| --- | --- |
| T01 | PASS: shared protocol/client tests; native `testActualWebKitV2HandshakePublishesOnlyTheScopedProjection` negotiates before data. |
| T02 | PASS:57 shared vectors, strict NSNumber boolean rejection, screen1/2 and Social Studio separation, runtime0.2.x/SDK1/session checks. |
| T03 | PASS at contract/browser layers: full/read-only/missing-optional/missing-required cases, forged denied calls rejected by native session and mock host; browser disabled controls have reasons. |
| T04 | PASS at projection/browser layers: empty roster stays empty, authoritative IDs retained. Actual packaged WK display assertions exist; visible native scene gate pending. |
| T05 | PASS: projection/mock add, harbor stable-addition and real renderer roster browser inspection; no canonical creation from rendering. |
| T06 | PASS: empty/removal projection, harbor reservations, identity caches, scope/lifecycle disposal tests. Native reset/removal service tests preserve unrelated data. |
| T07 | PASS: stable assignments, reorder/rename/status tests, browser search/selection, current labels and selected profile identity. |
| T08 | PASS: residentMotion/grandLine/harbor/islandWorkSignals tests derive work visuals solely from supplied status; command surface contains no execution API. |
| T09 | PASS: completion release/reconcile and snapshot transfer-history seeding prevent repeated work/effects. |
| T10 | PASS at logic/display layers: failed/waiting status tests, bounded display schema, native attention navigation; full visible native recovery interaction pending. |
| T11 | PASS: client resnapshot after gap, authoritative replacement, stale scope rejection, deduplicated courier/encounter effects; browser reconnect tour. |
| T12 | PASS: fifteen calibrated styles, identity-stable roster additions/reordering, full roster caches,500-agent browser roster. |
| T13 | PASS: deterministic residentMotion, route/full-hull clearance, sailing-area and shipAlignment tests preserve movement. |
| T14 | PASS: islandBerths/harborAssignments broadside docking, busy occupancy and native-status immutability tests. |
| T15 | PASS: distinct reservations, reorder/wait survival, completion/removal release and work/attention interruption tests. |
| T16 | PASS: projection/client lifecycle tests cover early events, gaps, duplicates, stale scope, unknown stream invalidation, replaced cancellation and disposed callbacks. |
| T17 | PASS at native contract/service layers: installed digest/workspace/grant identity checked on every invocation, foreign entity rejection, scoped bindings and workspace invalidation; cosmetic A/B isolation test added. |
| T18 | PASS at native contract/service layers: revoke/uninstall prevents old calls, attention opens the existing native flow; visual proof of full approval UI remains pending. No auto-approval command exists. |
| T19 | PARTIAL: commands route to existing native create/chat/activity/board/calendar surfaces; profile, portrait and board regression tests retained. Complete native interactive tour pending; rendering cannot submit a task. |
| T20 | PASS: timeout/cancel clears pending requests without replay; same request identity caches one native intent, changed payload reuse fails. |
| T21 | PARTIAL: canonical native surfaces retained, generic backdrop/palette descriptor validated and installed images decoded; packaged visible quarters/island/chat/tool parity pending. |
| T22 | PASS at native service/regression layer: three world-absent service tests plus saved-agent/Crew Chat/provider/permission/queue/calendar/board/plugin-panel suites. Full current native suite pending. |
| T23 | PARTIAL: queued native work survives disable/digest/workspace revoke tests; injected renderer failures keep canonical binding. Actual visible running-work UI survival remains to be recorded; no live provider calls were made. |
| T24 | PASS at namespace/service layer: reset only empties scoped cosmetic storage; profile/chat bindings and legacy defaults retained, mock roster unchanged. Current native workspace-isolation regression pending run. |
| T25 | PASS at initial native migration layer: legacy Outpost/Local Line map safely, native bindings untouched; new tests cover corruption, idempotence and A/B scope. Legacy bytes retained for downgrade. |
| T26 | PASS at installer/security layer: checksum, missing/invalid manifest/entrypoint, corrupt state, stale trust, half-state-write and incompatible version failures preserve active record. Native startup/visible unavailable gate pending. |
| T27 | PARTIAL: handshake timeout and bounded retry implemented; actual WK missing-file, uncaught script exception and infinite-loop watchdog tests added, process-termination callback tested. Full final run and visible native responsiveness evidence pending; callback is not an OS process kill. |
| T28 | PASS: strict payload/vector/byte limits; real resource fetch/XHR and traversal/symlink tests; installed archive confinement and manifest quotas. Existing main-frame messaging/navigation/local-resource policy retained. |
| T29 | PASS: repeated non-nautical World cycles, Local Line abort/dispose late initialization, resource pool cleanup and browser reconnect cycles. Native packaged disposal assertion exists; visible run pending. |
| T30 | PASS: production artifact without bridge shows unavailable/Retry and zero fake agents; no mock import in actual production graph/archive; lost sessions clear projection. |
| T31 | PASS: fresh `git clone --no-local` at68a60d4, no Locus sibling, dependencies/build/test/package succeeded. |
| T32 | PASS for standalone candidate:114 source assets pinned,113 shipped files,1170 actual graph inputs, no Outpost/dev/tests/archive/external imports. Locus active duplicate cleanup remains gated. |
| T33 | PASS: executable architecture checks enforce SDK/Core dependency direction and reject renderer/native/browser/nautical imports and constants. |
| T34 | PASS: test-only CounterWorld executes same lifecycle and snapshots without Babylon, ships, islands or production registration. |
| T35 | PARTIAL: zero/500 roster browser, paging/camera/label/reduced-motion logic tests passed. OS reduced-motion/browser media emulation and equivalent native visual/response measurements not yet verified. |
| T36 | PASS: Swift and TS validate the same57 reviewed vectors; actual WK transport roundtrip verifies scoped data and no provider details. |
| T37 | PARTIAL: packaged WK loads under actual scheme/CSP, manifest presentation/style images decode; visible native scene acceptance is blocked by disposable runner reporting document.hidden. A separate actual app launch is being investigated. |
| T38 | PASS at real installer/namespace layers: install/upgrade/stale-review rejection/rollback/reinstall/disable/uninstall preserve identity/scope;13 local CLI boundary tests incl failed commit/tampered rollback/dev snapshot. |
| T39 | BLOCKED: ordinary native service tests work without an installed world, but old renderer/package/backdrops still exist in Locus active source. Delete only after native cutover gates pass and rerun build/resource inspection. |
| T40 | PASS:1239-file external recovery archive fully restored, every hash matched source commit, restored legacy package verification passed. No future Outpost world implemented or packaged. |

## Gate and performance limits

The independent repository is implemented and tested. Locus still carries transitional v1/native world constants and the original bundled source/assets. This is intentional preservation while a required native gate is unresolved; it is not a completed thin-host extraction. No script is permitted to erase those inputs merely because unit tests pass.

Measured legacy package261824234bytes versus candidate221540158installedbytes; candidate ZIP221559158bytes. The baseline contained40256337bytes of Outpost and210975332bytes of Local Line. Source and build inventories measure sizes, not runtime memory. No equivalent CPU/frame-time/GPU/memory comparison was available through browser CUA; none is fabricated. Native visibility/graphics limitations are reported separately from asset decoding.

Outpost recovery SHA256 `d6694fb2258e5de2e85d8b0d4cf0a2865680d4dc9af9169c5554cc3bcb9297a3`, archive333170467bytes outside both repos. See [restore instructions](agent-worlds-recovery.md). Asset rights in the candidate NOTICE remain unresolved for publication. Remote creation, push, tag, signing and release publication were not performed. CI definitions are supplied; remote CI runs have not occurred.
