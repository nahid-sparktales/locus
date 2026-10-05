# Agent Worlds migration status

Status: **in progress; native visible-scene gate unresolved, no destructive cutover**.

- Inspected Locus: `4cce6ebfaa31f76cd7790967ad8ce7d7e2338deb`, originally clean detached HEAD.
- Branch: `codex/agent-worlds-extraction`; audit committed before implementation as `d7f05e63`.
- Independent repository: `/Users/nahid/.codex/worktrees/72d5/agent-worlds`, local `main`; tested implementation `68a60d4492cae2414ba765202b71248d038e41e6`.
- Versions: release/World0.2.0, SDK1, wire2, preferences2. Old wire1 stays explicit during transition.
- Final standalone ZIP SHA256: `090c697ed4c4c16f7bb0a4c284fe1cfead62cb7e7b335862c6e5da483c5c3421`.

| Phase | Actual gate state |
| --- | --- |
| 1 audit | Complete before implementation: dependency/ownership/persistence maps, native/renderer/assets appendices. Baseline144 renderer and116 native tests passed. Browser baseline captured with stated deterministic/viewport limitations. |
| preservation | Complete:1239-file archive restored and every hash verified; restored package verifier passed. Outside active inputs and retained. |
| 2 contract | Implemented: canonical strict v2/SDK1 schemas, shared fixtures, Swift adapter, scoped request/idempotency/grant checks.57 shared vectors+17 Swift session checks passed; real WK roundtrip passed. |
| 3 separation | Implemented: native SavedAgentConversationService owns canonical chat/queue independently; Local Line implements World; CounterWorld proves non-nautical Core. Additive126 native regression checkpoint passed. Later lifecycle/isolation tests in progress. |
| 4 Outpost | Removed from independent repo/runtime/package; verified archive retained. Original Locus source remains pending native gate. |
| 5 repository | Complete standalone candidate: no-sibling clean clone,222 tests/typecheck/build/repeated deterministic package passed.113files/221540158installedbytes; source provenance/licenses preserved. |
| 6 cutover | In progress: actual installer upgrade/rollback/disable/uninstall passed, pinned local install+dev snapshot CLI shipped. Native packaged asset/transport checks implemented; actual visible-scene check unresolved. Original Locus implementation not deleted. |
| 7 full validation | Python baseline3130+31subtests passed, final full run in progress. Native full run/visible UI and failure checks in progress. See T01–T40 ledger for partial/not-run criteria. |

[Acceptance ledger](agent-worlds-acceptance.md), [host ownership and rollout](agent-worlds-host-integration.md), [local installation](agent-worlds-local-install.md), [artifact verification](agent-worlds-artifact-acceptance.md), [browser evidence](agent-worlds-browser-verification.md), [recovery](agent-worlds-recovery.md).

No remote, push, public release, paid asset generation, real provider call or user plugin installation occurred. Publication is additionally blocked on unresolved derivative artwork rights. Unit/browser/installer passes are not represented as native visual proof.
