# Locus Runtime extraction implementation report

## Source, target and publication

Locus implementation baseline is `4319810bfb13d42be47d0e5278c3f55135a357c2`, not the historical revision in the brief. Work is on `codex/extract-locus-runtime` at `/Users/nahid/.codex/worktrees/b6b6/locus`, with origin `git@github.com:nahid-sparktales/locus.git`. The separate target is `/Users/nahid/.codex/worktrees/b6b6/locus-runtime`, branch `codex/extract-runtime`. It is a real Git repository outside Locus, with no remote configured. No repository was published, pushed, or assigned visibility. No production service/profile or unrelated checkout was modified.

Runtime implementation source is `db1955b106d747ff715885ff6d68c834e2d3129d`; subsequent target commits `4741818` and `59cd161` improve the cross-interpreter test harness and record Python-floor evidence without changing wheel code. The reviewed `locus_runtime-0.1.0-py3-none-any.whl` SHA-256 is `8c7cdbc0d623f9c1cde600c2dd49af8460f3b558bd26d4576f794a759b292c36`. The target branch HEAD is `59cd16167f22eadc7a4061563c6931ac56963347`. Its committed product pin is `agent/vendor/wheels/runtime-release.json`, including actual build-tool versions and source timestamp. Two clean source exports produced byte-identical wheels.

Review stages are separate commits: `a5050baa` ownership map; `d13e5ecc` characterized worker-descendant cleanup fix; `660d667f` unchanged baseline/companion audit; `77f6dcaa` host adapters and mechanic removal; `8996b526` compatibility/recovery documentation; `5673f68f` pinned package composition; `aeaea423` smoke-runner canonical package import; `425bda09` strict developer-bundle verification/failure propagation and Python 3.10 tooling fallback. Follow-up validation/build fixes are recorded in the final branch history and verification document.

## Implemented ownership

`locus_runtime` owns the canonical supervisor, child/owned model-process lifecycle, runtime SQLite tables/private state, command/event/decision and connector-receipt transport, strict SSH tunnels, reviewed snapshots/results, immutable installation/service/update/recovery mechanics and read-only doctor. The new repository contains tests, CI, standalone deterministic worker, license/NOTICE and architecture/security/migration/compatibility/verification documentation. No reasoning backend, memory engine or workflow engine was copied into it.

Locus's `runtime_host.py` provides `LocusWorkerDriver`, usage recovery, product event emission, continuation and connector adapters. Public routes, account selection and child environment policy, consent, task/run identity, canonical budgets/usage, verification, reasoning/tools, scheduling/goal/workflow semantics, native broker enforcement, Swift UI, signing and helper registration remain in Locus. Legacy runtime modules are compatibility imports or product policy adapters. Their removal condition is documented; no second active supervisor, SSH, persistence, snapshot or installer implementation remains in Locus.

Public package seams are `WorkerDriver`/`WorkerLaunchRequest`/`WorkerLaunch`, typed continuation/connector/provider/remote ports, `RuntimeSupervisor(root, store=..., private=..., driver=...)`, and `RuntimeStore(connect, sanitize=...)`. Locus supplies public `RunStore.runtime_connection`; core code does not receive FastAPI or a service/core context, access `RunStore._connect`, or hard-code a product worker. Missing connector authority fails closed; host routes and worker permission checks retain admission authority.

The runtime wheel exclusively owns the `locus-runtime` console script. Legacy flags dispatch through the fixed `locus_runtime.host/locus` registration owned by `ollama-code`; untrusted/duplicate registrations fail. `python -m ollama_code.runtime` preserves existing native-helper launches. Ordinary foreground execution and the opt-in independent service remain distinct. Doctor defaults to offline inspection; remote probes require explicit existing profile/database and one saved connection ID.

## Companion reconciliation

The evidence matrix is [companion ownership](companion-ownership.md). Native Locus consumes its own product backend; Browser actually bundles the separate `locus-platform` backend and shared protocol packages. Platform's ownership prose overstated current native consumption. Its inspected revisions do not contain these independent-service modules, so this extraction does not create a third product backend. Browser's published canary.6 artifact records platform canary.5, while its current CI selects canary.7; these are not equivalent evidence. Browser was not migrated or tested as a new runtime consumer. Git-tracked requirements CR-1 through CR-6 specify the separate integration path.

Locus Memory remains the existing hash-pinned 0.3.0 package. LangGraph remains the separate optional plugin; no corresponding product import migration was invented. Mobile continues through the paired Mac protocol. Companion repositories and their unrelated local changes were left untouched.

## State, recovery and deliberate fixes

Runtime tables, shared database location, column definitions and transaction boundaries are preserved; no production data migration or unrelated schema redesign is introduced. Product run/usage state remains canonical and shared-storage tests preserve consumed allowances across restart. Sent commands become uncertain rather than replayed; decisions retain fingerprints and native leased claims. Private command configuration now contributes a keyed fingerprint so a reused request ID cannot hide changed secrets behind redaction. Legacy admission can upgrade only when the original private payload proves equality; otherwise reconcile the original outcome before deliberate retry.

Characterization exposed missing nested-child cleanup and incomplete failed-model-startup cleanup. The implementation now bounds termination/draining, handles descendants that close output, guards against reused leader PIDs, closes callback/tunnel resources and prevents a late heartbeat thread reopening a closed manager. Private profile symlinks and unsafe credential symlinks/FIFOs/modes fail safely. Raw child output never enters public events. A transient extraction cleanup reference and obsolete smoke import were caught and fixed before final artifact verification.

The installer retains its exclusive lock, pause/drain requirement, immutable versions, archive/hash/helper checks, journal, maintenance gate and SQLite-consistent backups. Mocked recovery tests verify restoration of prior unit/package and consumed state, removal of candidate-created databases, recovery-before-retry, concurrent install exclusion, and retention of journals on failed recovery. This is deterministic recovery evidence, not a live launchd/systemd or reboot test. Never delete a pending journal or switch a symlink alone to bypass recovery.

## Development and reproducible composition

From the Locus root:

```sh
python3 Tools/RuntimePackage.py verify --agent agent
python3 -m pip install --find-links agent/vendor/wheels -e './agent[dev]'
python3 -m pip install pip-tools
python3 -m piptools compile --find-links=agent/vendor/wheels --generate-hashes \
  --no-emit-find-links --output-file=agent/requirements-runtime.lock agent/requirements-runtime.in
python3 Tools/PrepareRemoteRuntime.py --target macos-arm64 --require-clean \
  --output build/runtime-packages/locus-runtime-macos-arm64.tar.gz
python3 -m pip install --no-deps agent/vendor/wheels/locus_runtime-0.1.0-py3-none-any.whl
python3 Tools/SmokeRemoteRuntime.py \
  --package build/runtime-packages/locus-runtime-macos-arm64.tar.gz \
  --sha256 REVIEWED_ARCHIVE_SHA256 --output build/runtime-packages/process-smoke.json
```

`Tools/PrepareAgentRuntime.sh` and `Tools/BundleBackend.sh` install the hash-pinned wheel at build time, validate actual installed package bytes, stage trusted host metadata and record both source identities. No sibling checkout, system pip or first-launch source download is required by the resulting backend. `project.yml` remains the native source of truth; no native project/resource declaration changed because existing assembly copies the selected backend and locked site-packages.

Runtime source build/install commands are in the target repository's migration document. Local editable sibling installation is optional developer work only. CI/releases use the immutable wheel; no mutable branch dependency or developer absolute path is a release input. The product dependency lock was regenerated with existing tooling without changing neighboring versions.

## Results and open release gates

[Verification evidence](extraction-verification.md) contains exact commands/results and artifact report locations. Package tests passed **90/90** on Python 3.14.6 and **90/90** on Python 3.10.22, including a fresh empty-venv wheel install outside both repositories, forbidden-import/side-effect checks, sole console ownership, authenticated deterministic worker and cleanup. Product runtime/HTTP/process/package contracts passed **108/108** at `425bda09`; affected-neighbor suites passed **306/306**. Focused reruns are subsets, not additional unique coverage. Existing route fixtures and protocol revision 2 stayed unchanged.

Locus native build-for-testing passed with ad-hoc signing; LocusX compiled unsigned. Native runtime XCTest execution remains **unverified**: LaunchServices could not launch the test runner on two attempts before any cases executed. LocusX signing needs a suitable development certificate. These compile gates skipped bundled resources and are separate from the clean-checkout backend/artifact checks.

Clean product checkout `425bda09e0c876ecd4ccfb68a39d5d293fca7726` also passed an integrated Locus `xcodebuild build` with `LOCUS_BUNDLE_MODE=standalone`, the complete pinned backend, both provider helpers and ad-hoc signing. **The packaged Locus build works without the runtime repository checkout**, system pip or a first-launch runtime-source download. This is build/backend process evidence, not a claim that the native UI or signed SMAppService registration was exercised. [Packaging evidence](extraction-packaging.md) records complete commands, archive hashes and retained artifacts.

The clean macOS portable distribution at `aeaea423` passed all seven deterministic process-smoke checks (3 runs, 84 fixture tokens, successful cleanup); SHA-256 `a12ce6adf643afbb4fa64c91a0e94cb0cdf1722cfced38cc0dd047b2c0a69ce4`. A package made from the native backend resource layout at `5673f68f` passed the same checks; SHA-256 `bd3f2b6f4ab5378ad2ed6b7cfc44d335189d58c5768618a3886096380e0eb60e`. The subsequent tool-only build fixes were separately validated by **38 packaging tests** and positive native assembly; runtime implementation and pinned wheel stayed unchanged.

Actual live OS-service installation/rollback, signed SMAppService registration, real SSH/Tailscale hosts, Linux x86-64/ARM64 process packages, provider login/refresh/billable calls and reboot recovery remain **unverified**. Prerequisites are an explicitly selected disposable owned host, reviewed exact archive/hash, relevant signing identities and separately authorized service/provider operations. The exact isolated service/host runbook is in release-readiness and target verification docs. No migration is declared production-ready on mocks or compilation alone.
