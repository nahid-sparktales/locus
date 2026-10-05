# Agent Worlds migration status

Status: **local extraction complete: thin-host cutover, final native/Python suites, isolated package and native visual checks passed**. Publication is blocked on artwork redistribution rights.

- Inspected Locus: `4cce6ebfaa31f76cd7790967ad8ce7d7e2338deb`, originally clean detached HEAD.
- Branch: `codex/agent-worlds-extraction`; audit committed before implementation as `d7f05e63`.
- Independent repository: `/Users/nahid/Documents/agent-worlds`, local `main`; tested implementation `ec94166`.
- Versions: release/World 0.2.0, SDK 1, wire 2, preferences 2. Legacy web wire 1 is explicitly rejected; native Social Studio remains a separate version 1 surface.
- Final standalone ZIP SHA256: `4a4ca458bd1e0391e2ead1b52a58977329e85c30280218e605e992808f99eff8` (reproduced by two clean no-sibling builds).

| Phase | Actual gate state |
| --- | --- |
| 1 audit | Complete before implementation: dependency/ownership/persistence maps, native/renderer/assets appendices. Baseline 144 renderer and 116 native tests passed. Browser baseline captured with stated deterministic/viewport limitations. |
| preservation | Complete: 1239-file archive restored and every hash verified; restored package verifier passed. Outside active inputs and retained. |
| 2 contract | Implemented: canonical strict v2/SDK 1 schemas, shared fixtures, Swift adapter, scoped request/idempotency/grant checks. 57 shared vectors+17 Swift session checks passed; real WK roundtrip passed. |
| 3 separation | Implemented: native SavedAgentConversationService owns canonical chat/queue independently; Local Line implements World; CounterWorld proves non-nautical Core. Additive 126 native regression checkpoint passed. Lifecycle/isolation checkpoint passed in the real app host, including actual exception/hang/load-failure recovery. |
| 4 Outpost | Removed from independent repo/runtime/package; verified archive retained. Original Locus renderer/package/source backdrops and generation inputs removed after verified recovery and native gates. |
| 5 repository | Complete standalone candidate: no-sibling clean clone, 222 tests/typecheck/build/repeated deterministic package passed. 113 files / 221,540,432 installed bytes; source provenance/licenses preserved. |
| 6 cutover | Complete: actual installer upgrade/rollback/disable/uninstall passed, pinned local install+dev snapshot CLI shipped. Strict visible packaged WK and actual native UI tour passed before cutover. Generic metadata-based native chrome replaces world constants; final post-cutover focused fault/transport/metadata/board checks passed; final native UI, focused and full aggregate checks passed. |
| 7 full validation | Complete: final Python 3,138 tests +31 subtests passed; final native `LocusTests` 1,989 tests passed with zero failures/skips, including all 16 bridge and 36 native host tests. Independent 222 tests/typecheck/reproducible package and native CUA checks passed. Earlier failed/skipped diagnostic runs remain in the native report; NOT RUN limits remain explicit in the T01–T40 ledger. |

[Acceptance ledger](agent-worlds-acceptance.md), [host ownership and rollout](agent-worlds-host-integration.md), [local installation](agent-worlds-local-install.md), [artifact verification](agent-worlds-artifact-acceptance.md), [browser evidence](agent-worlds-browser-verification.md), [recovery](agent-worlds-recovery.md).

No remote, push, public release, paid asset generation, real provider call or user plugin installation occurred. Publication is additionally blocked on unresolved derivative artwork rights. Unit/browser/installer passes are not represented as native visual proof.
