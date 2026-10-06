# Runtime extraction map

Inspection baseline: Locus `4319810bfb13d42be47d0e5278c3f55135a357c2`, clean detached checkout on 2026-10-05; implementation branch `codex/extract-locus-runtime`. The brief's `b332e455` is a historical reference only. Target: sibling `../locus-runtime`, Python `locus_runtime`, initial version 0.1.0, no remote publication authorized. See `Docs/runtime/companion-ownership.md` for the companion consumer audit and `Docs/runtime/extraction-verification.md` for baseline and verification evidence.

## Dependency and migration decision

Locus product → explicit Locus adapters → installed `locus_runtime`. Preserve protocol 1, runtime tables in the existing RunStore database, profile paths, worker permission checks, optional foreground/independent/SSH modes. Keep the existing Locus product and wire contracts; this extraction creates no new product schema. No production service, profile, installed package, credentials, or remote host is a test target.

Move existing mechanics rather than replacing them. Package methods receive explicit storage, private configuration, launch and product callbacks. Locus compatibility modules delegate to the package. Product route/automation/connector behavior stays in Locus. Distribution assembly continues in Locus and bundles an immutable hash-pinned runtime wheel; it is different from a standalone runtime release. The sole console script owner becomes locus-runtime; a trusted installed Locus host entry point preserves legacy CLI arguments, and `python -m ollama_code.runtime` remains a compatibility bootstrap.

## Candidate ownership and effects

| Area/current owner | Actual callers | Side effects / persistence / secrets | Proposed owner and adapter | Characterization gates |
|---|---|---|---|---|
| `runtime.py` supervisor, Locus | `server.py`, runtime/deploy/evaluation routes, automation, helper CLI, runtime tests | worker subprocesses, loopback HTTP/WS, runtime DB state, controller tokens/configuration | Package supervisor; typed worker driver, event policy, continuation and connector ports supplied by Locus composition | runtime, hardening, acceptance, process, agent-profile continuation tests |
| `runtime_store.py`, Locus | RunStore schema init, supervisor, API, remote/automation | runtime_workers/events/commands/decisions/automations/deployments, private atomic JSON credentials | Package RuntimeStore explicit connection factory and required sanitizer; public RunStore connection adapter. Keep shared DB schema and transactions. | runtime dedupe/restart/decision races, runstore transaction/file-handle checks |
| `runtime_remote.py`, Locus | runtime_deploy routes, supervisor controller relay | strict OpenSSH, owned tunnel children, remote install/control, persisted deployments/private remote token | Package remote mechanics with explicit store/private/root ports. Provider-specific login selection stays in Locus; generic callback forwarding in package. | runtime_remote, SSH args, snapshot/retry/remove/identity tests |
| `runtime_install.py`, Locus | remote SSH bootstrap, package smoke runner, installer tests | user service commands, exclusive install lock, immutable archives, private profile, SQLite backups/journal | Package dependency-free installer. Preserve product-distribution validation/service contract during first migration; no new artifact manifest. | remote package/install/recovery/tamper tests |
| `runtime_snapshots.py`, Locus | runtime_deploy routes, remote transfer | reviewed file archive, exclusions, conflict-checked local writes | Package snapshot mechanics; host authorization and selection remain routes/native UI | runtime_remote snapshot safety and post-review changes |
| `runtime_providers.py`, Locus | provider routes, supervisor | owns only newly launched Ollama child, no provider credential selection | Package process owner and loopback validation; Locus supplies sanitized child environment | externally running service remains unowned; failure/cleanup tests |
| `runtime_automation.py`, Locus | supervisor coordinate tick, runtime routes | schedule/goal/workflow admission and product usage ledger | Retain product continuation adapter; package invokes tick/close, stores transport state only | schedules/goals/workflows/usage/agent-profile suites |
| `runtime_connectors.py`, Locus | supervisor connector dispatch, automation poll, routes | connector-specific APIs, product connection records and scoped private credentials | Retain connector adapter; package owns durable intent/receipt/replay handling | connector admission, uncertain receipts, permission tests |
| `api/runtime.py`, `api/runtime_deploy.py`, Locus | public FastAPI router/native | consent, account choice, snapshot import, task/run identities, native claims | Retain public routes and adapters, eliminate private runtime DB access where touched | server route fixture, native runtime protocol fixtures |
| RuntimeHelper, RuntimeModel, project.yml | signed native app/optional service | SMAppService, entitlements, bundle execution paths | Retain Locus; legacy module forwards to composed runtime | native build, helper audit, protocol checks; signed live registration unverified |
| Prepare/Package/SmokeRemoteRuntime, requirements, BundleBackend | CI and release scripts | package downloads, hashes, build resources/provenance | Retain product composition; install pinned vendored runtime wheel, validate runtime imports/version and source identity | clean checkout/wheel, artifact composition, process smoke; target/service gates separate |
| memory/workflow/backend contracts | product adapters and companion consumers | canonical product state/reasoning | Retain existing owners; no duplicate memory/workflow package | companion manifest/import audit and neighbor tests |

## Existing behavior to preserve

- Workers are explicitly bound to one workspace; request-ID changes fail; sent work becomes uncertain on restart.
- Decisions fingerprint payloads and bind response type/request identity; native claims become uncertain on broker disconnect.
- Ordinary controller-detached work pauses, while explicitly allowed continuation remains eligible.
- Credentials stay in user-only private storage; runtime events use the product sanitizer; raw child output is drained without export.
- SSH uses existing authentication and strict host verification; no remote failure falls back to local execution. Connection removal retains remote files.
- Installers pause/drain and keep a recovery journal, SQLite-consistent backups and immutable package paths. No schema redesign or production migration is planned.

## Review stages

A: map, companion audit and unchanged baseline. B: characterization/seams and demonstrated blockers. C: independent package/provenance/tests. D: host adapters/pinned distribution. E/F: verification, obsolete implementation removal and migration/runbook docs. Commits distinguish independently reviewable changes; all known unavailable live gates stay explicitly unverified.
