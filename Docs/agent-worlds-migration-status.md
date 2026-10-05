# Agent Worlds migration status

Status: **in progress; no destructive cutover authorized by evidence yet**.

- Inspected Locus: `4cce6ebfaa31f76cd7790967ad8ce7d7e2338deb`, originally clean detached HEAD.
- Working branch: `codex/agent-worlds-extraction`.
- Audit gate committed before implementation: `d7f05e63`.
- Independent repository: `/Users/nahid/.codex/worktrees/72d5/agent-worlds` (local only).
- SDK/Core initial commit: `70cee8febacf85de4018093cced4476c1077acc5`.
- Versions: Agent Worlds 0.2.0; SDK 1; wire protocol 2; preference schema 2. Existing wire 1 is preserved during migration.

| Phase | Evidence / current gate |
| --- | --- |
| 1 audit | Complete: primary audit plus native/renderer/assets appendices. Baseline renderer 144/144, package verifier pass; native 116/116 via resource-correct disposable XCTest runner. Original LaunchServices failure retained in audit. Interactive screenshot parity not yet verified. |
| preservation | Complete: verified targeted archive, 1,239 files; all restored hashes match original commit; restored package verifier pass. See recovery document. |
| 2 contract | TypeScript strict validation, client session/correlation/timeout, disposable ordered projection, lifecycle and non-nautical test world implemented. 70 contract/core tests pass. Swift shared-fixture validation and real v2 WebKit roundtrip pending. |
| 3 separation | Pending contract gate; old renderer and canonical native services remain usable. |
| 4 active Outpost removal | Blocked on parity/contract integration gates. Recovery is ready. |
| 5 repository | Local Git repo with pinned Node toolchain, SDK/Core, fixtures/tests; package/assets scaffold in progress. No remote or published release. |
| 6 host cutover | Not performed; original source/package retained until actual built-artifact native checks and no-world regression pass. |
| 7 full validation | Not yet complete; T01–T40 report will distinguish implemented/tested/not run. |

No test or skip has been represented as native visual proof. No credentials, providers, backend, execution runtime or unrelated Locus history are copied into Agent Worlds. Canonical Locus records are not reset/migrated with world preferences.
