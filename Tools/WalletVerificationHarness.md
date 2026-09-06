# Wallet verification execution and evidence

These tools record engineering checks. They do not sign a release activation,
complete an external audit, or substitute local fixtures for live interoperability.

## Shared execution lock

Wrap a complete app-host or local-chain session in:

```sh
python3 Tools/WalletTestExecution.py --lock-timeout 600 -- command arguments
```

The advisory lock is shared per macOS user at `/tmp/locus-test-execution-UID.lock`.
It serializes cooperating runners, not arbitrary commands launched elsewhere.
Nested runners inherit a validated descriptor; `--assert-held` verifies it.
Python runners use `execution_lock()` and `run_locked()` from the same module.
Never delete the lock to bypass a running session. Cancellation targets only the
wrapper's own process group; it never kills every Locus process by bundle ID.

## Fuzz chunks

The Swift runner builds the Debug-only `WalletFuzzHost` and launches a fresh
process directly for each replay and timed phase. It does not start XCTest or
the normal application. The unchanged pinned runtime owns process completion;
ordinary exit cleanup writes provisional observations, never a pass verdict.
The parent and evidence verifier independently require the actual exit/PID,
matching invocation identities, complete engine statistics and retained seed
observations. The former XCTest-host exits remain failed evidence, not passes.

Before phases, the runner checks production decoder coverage objects, exercises
ordinary exit, missing metrics, crash, hang and ASan negative controls, and
requires deterministic successful Solana/Sui decoder fixtures. Failure controls
are separately labelled and never earn campaign credit. The host contains no
signer/recovery embedding, production configuration, backend or connector web
resources. Production/MAS audits reject fuzz-host code and resources. Actual
successful receipts are required; the implementation alone proves no campaign.
Platform-supported leak checks remain an unmet gate where unavailable. No
312-CPU-hour candidate result or external release approval is claimed here.

Both fuzz runners require clean source by default. `LOCUS_FUZZ_ALLOW_DIRTY=1`
permits development smoke checks, but their receipts are ineligible for campaigns.
`LOCUS_FUZZ_SECONDS` is a **wall-clock budget**, not credited CPU time. Each new
invocation creates a unique run ID, plus distinct replay/fuzz completion records
for each target. Build/replay time never counts toward the canary CPU requirement.
Swift measures CPU inside the dedicated target process starting just before the
engine, excluding build and fixture self-tests; Rust
measures only the direct fuzzer child after building it. LLVM coverage must be
observed in a successful fuzz phase. Swift builds request ASan with applicable
C/C++ boundary UBSan; Rust uses ASan and checked arithmetic,
not a falsely claimed Rust UBSan mode.

The receipt binds source revision, actual tracked/untracked tree identity,
dependency locks, before/after binary digests, compiler/runtime identities,
instrumentation flags, seed/final corpus, target metrics, logs and crash inputs.
Receipts use exclusive creation and never replace previous runs. Any finding,
missing completion, stale callback, source change or binary change fails the chunk.

Keep the entire `runs` directory; DerivedData and Cargo build caches are not
evidence uploads. Multiple downloaded workflow artifacts must be extracted under
separate roots with their UUID directories under a `runs` directory. Validate all
roots, including failed attempts—do not select only passing receipt files:

```sh
python3 Tools/WalletFuzzEvidence.py --revision EXACT_CANDIDATE_COMMIT \
  --output /outside/repository/campaign.json \
  /outside/repository/swift-evidence /outside/repository/rust-evidence
```

Default aggregation requires 86,400 measured CPU seconds for **each of 13 targets**
(312 CPU-hours total), every successful replay, consistent target binary/toolchain/
corpus identities, a single clean source+lock set, and no duplicate, overlapping,
stale, failed, incomplete or tampered chunks. Reviewers must independently attribute
CI provenance; these local JSON receipts are not cryptographic release approvals.
Any compiler, lock, corpus, source, or binary change starts a new campaign identity.
Archive evidence beyond the workflow's 90-day retention period when needed.

New PR revisions cancel superseded PR runs of the same workflow. Cancelled or
incomplete runs earn no campaign credit; existing failure artifacts remain
failures. Nightly and manually dispatched campaign chunks use distinct run IDs
and are not preempted by PR updates. The per-workflow group and event-scoped
cancellation follow [GitHub's concurrency rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

## UI matrix

`Config/LocusUITestMatrix.json` defines macOS 14, 15 and 26, each with 16 profiles:
compact/regular × light/dark × standard/contrast-only/motion-only/both. A profile
sets the initial launch for every test. Tests explicitly exercising resizing or
appearance changes retain those scenario-specific overrides.

```sh
python3 Tools/RunLocusUIMatrix.py --os-major 15 --edition locus \
  --profile regular-light-standard \
  --derived-data /outside/repository/locus-ui-derived \
  --output /outside/repository/locus-ui-evidence
```

The `locus` and `locusx` editions run separate full suites: shared tests run in
both, while wallet and wallet-absence tests run only where they compile. Use
`--edition locusx` with a separate DerivedData directory for the wallet edition.
CI runs both editions and preserves their evidence separately. The runner keeps
the original combined inventory floor as well as each edition’s own floor.

The runner checks the actual native OS, available display, and accessibility
preferences before building or launching. It refuses a mismatched profile and
does not change user preferences to force a pass. Close running Locus applications
first; the runner does not terminate an unrelated installed app. `--preflight-only`
checks readiness without starting an app or build. `--allow-dirty` is smoke-only.
For a hosted CI runner whose accessibility defaults are not controlled, use
`--native-profile compact-light` instead of `--profile`. The hosted display is
too small for the regular window; regular profiles remain a dedicated-Mac gate.
This option selects and records
the one exact contrast/motion profile matching the actual native preferences;
it does not change those preferences or claim the other profiles were tested.
An explicit `--profile` still rejects any mismatch, and both options together
are invalid. The receipt always contains the resolved full profile name.
An environment mismatch retains an immutable `executed: false` preflight
receipt, including the measured display and native settings. It cannot count as
executed coverage, even when the source is clean.

One serialized, ad-hoc signed Debug build produces one exact xctestrun. Every
active-edition UI test ID is explicitly requested (137 Locus / 153 LocusX, with
the original combined minimum of 140 retained), and the raw
result bundle, summary, test tree, counts, logs, source and binary identities are
retained. A missing, skipped, duplicate, failed or retried case fails the profile.
Each edition’s CI job runs one full-suite macOS 15 native profile; it does **not** claim the other 47
OS/profile combinations. Native VoiceOver review, live connector paths, complete
swap/allowance flows, and QR privacy/recovery checks remain separately attributable
work until corresponding fixtures and real-device evidence exist.
