# Locus memory cutover and authorization audit

Reviewed `b332e455..5529004a` on 2026-10-06. Focused differential audit using Trail of Bits differential-review `SKILL.md`, `methodology.md`, and `adversarial.md`. Scope is wallet-free Locus memory integration, ownership/restore handling, model authorization and routes; this is not an audit of every module in the external memory package.

## Explicit baseline context

- Baseline `memory.py` directly implemented a single AES-GCM legacy SQLite vault, with scope targets derived from resolved workspace paths or agent IDs. `tools.py::_impl_propose_memory` fixed proposals to candidate status and host `ToolContext` scope/identity, while user REST routes could approve and edit. `server.py::_automatic_memory_context` recalled approved legacy records using the agent memory policy. Baseline source was read with `git show`; blame traces these behaviors to `2ee8bfe7d` and `ce453897a`.
- Current integration, introduced in `a55169ca7`, delegates those operations to `locus-memory`; `d6e629da` pins released 0.3.0. Exact installed dependency was inspected at `/tmp/locus-audit-venv-20261006/lib/python3.14/site-packages/locus_memory`, version 0.3.0. The release URL and SHA-256 are pinned in `agent/pyproject.toml:23`.
- `MemoryVault.__new__` selects canonical versus legacy storage from durable ownership (`memory.py:137-162`). Fresh profiles use atomic bootstrap; adapter services hold a shared process lease, offline migration/recovery an exclusive lease. Missing encryption keys for existing data fail closed (`memory.py:41-61,74-106`).
- `MemoryAdapter.access` constructs trusted USER read/CRUD, AGENT read/propose, and HOST ingest/maintenance contexts (`memory_adapter.py:62-68,180-205`). Ordinary model tools cannot choose actor, approval permission, identity, or disabled scopes (`tools.py:1169-1267`). Canonical package `_access` disallows widening an AGENT constructor identity.
- Recall packets are policy bounded and revalidated immediately before provider calls. Memory reference text is supplied only on the request copy (`core.py:3874-3898`), rather than persisted in the local transcript system message. Saved-agent inspection reloads current controller-owned profiles through `trusted_memory_agent`.
- REST routes are user control-plane APIs behind existing Origin/token middleware (`server.py:250-269`), not independent remote principals. Client-selected memory CRUD agent/workspace selectors are intentional user management access; model tools receive different grants.
- Guard identity and marker proofs derive from stable host custody. The native helper implements bounded requests, per-account locking, token checks, compare-and-swap and monotonic checkpoint advancement. Recovery requires a surviving authenticated generation and explicit history-loss acknowledgment; missing helpers for enrolled profiles stay unavailable.

## Finding: P2 — stale empty ownership metadata silently returns a migrated profile to legacy writes

**Confidence:** High for reproduced data-integrity/recovery behavior. This is not a remote exploit. It requires local restoration/corruption of ownership metadata; no normal-cutover failure was found.

**Location:** Host trust seam `agent/ollama_code/memory_ownership.py:11-13`; owner selection `agent/ollama_code/memory.py:147-162`. Root implementation in pinned dependency `locus_memory/migrations/ownership.py:32-36`: when the `ownership` table exists but has no row for the partition/family, it returns `legacy_authoritative`. The missing-file branch at lines 24-26 correctly rejects surviving partition data, but the missing-row branch does not distinguish a former package owner.

**Concrete recovery scenario:** A normal shadow adapter creates a valid control database with zero ownership rows. Back up that real database, then run the supported snapshot/validate/cutover sequence and create package-era records. If a partial restore puts that pre-cutover control database back beside the newer encrypted partition, the host silently picks legacy authority. Package-era records disappear from ordinary memory APIs and new writes are accepted into the legacy database, producing divergent history. Reinstalling the current control database reveals the original package-era record again, confirming preservation rather than deletion.

**Reproduction:** `/tmp/locus-memory-ownership-repro.py`, run from the repository with `PYTHONPATH=agent /tmp/locus-audit-venv-20261006/bin/python /tmp/locus-memory-ownership-repro.py`. It uses only a temporary profile and real migration/lease logic; it replaces the global running-process quiescence check because unrelated app instances on the host do not own its fresh temporary profile. No arbitrary row deletion is required in this reproduction.

Observed output:

```text
actual shadow ownership rows 0
cutover state package_authoritative
before restore visible True
missing file negative control LegacyVaultError
old control restored state legacy_authoritative
after restore visible False
legacy write accepted 2
package record preserved True
```

**Invariant:** `Docs/MemoryCutover.md` states ownership, rather than rollout flags, selects the canonical store; missing/corrupt ownership must fail closed when partition data exists. An old control file with a missing row currently avoids that protection. The docs discourage manual rollback by replacing SQLite files, so this should be reported as robustness of partial-restore handling, not a supported rollback flow failing under normal use.

**Blast radius:** Four direct host callers of the `ownership_state` wrapper (adapter startup, explicit-key vault selection, recovery, migration status), plus bootstrap delegation. `MemoryVault` has three direct production constructor callers: the two model tools and `memory_runtime.memory_vault`; the latter has 21 call sites across the memory/continuity and knowledge route modules. All operate on the selected owner. Existing tests cover an absent/corrupt *file*, but not a valid stale/empty-row file (`test_memory_migration.py:132,163`).

**Suggested direction:** Preserve authenticated evidence that the partition became canonical, and reject ambiguous control rollback/missing records before any legacy read/write. Preserve the legitimate pre-cutover shadow state: simply rejecting every empty ownership table with a partition would break existing shadow rollout. Add the old-control-backup regression above and a valid-shadow negative control, fix in the external package, then update the pinned release/hash.

**Limits and false-positive challenges:** The package record was not deleted. A separate canonical-forget probe confirmed legacy source deletion and did **not** resurrect a forgotten item, so no deletion-resurrection claim is made. The source environment used no native signed helper, and this probe does not establish a login-Keychain bypass. It also does not demonstrate an unprivileged remote attacker can modify control metadata.

## Validation and other reviewed boundaries

Executed the following isolated suites with the parent's temporary audit venv: memory guard, bootstrap, migration, canonical routes, inspector, learning, trusted-agent identity, embeddings. Result: **116 passed in 13.20s**. Native helper parser tests compile the real Swift parser, but replace its entry point; Keychain protocol tests use an in-memory stand-in. No live Keychain or live profile was accessed.

Manually inspected current adapter/guard/recovery/ownership/canonical facade, all new memory API modules, memory learning and local embedding transport, relevant core/server/chat-service/tools diffs, package canonical authorization, bootstrap and ownership/runtime dependencies, plus corresponding test coverage. Key negative paths covered include candidate exclusion, tool injection inability to approve or widen scopes, scoped feedback/deletion, saved-agent revocation, missing keys/control file, migration leases, local-only embeddings/redirect rejection, proof authentication, monotonic marker updates, recovery acknowledgments and policy revalidation.

No additional high-confidence actionable defect was confirmed in these inspected boundaries. Did not run Task Observer. Did not change production code. Full dependency package audit, actual signed-helper Keychain integration, provider network behavior and every concurrency schedule remain outside this focused result.
