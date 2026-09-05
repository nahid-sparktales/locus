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

The Swift runner is **not yet a working campaign gate**. The current app-hosted
XCTest harness expects `LLVMFuzzerRunDriver` to return before writing completion
metrics, but the pinned runtime exits the host on normal campaign completion.
An unexpected host exit or absent metrics must remain a failed/incomplete run;
neither is credited as successful fuzzing. A supported execution/completion
design, actual instrumentation self-tests, successful deterministic decoder
fixtures, and platform-supported leak checks remain implementation/verification
blockers. No Swift campaign or 312-CPU-hour candidate result is claimed here.

Both fuzz runners require clean source by default. `LOCUS_FUZZ_ALLOW_DIRTY=1`
permits development smoke checks, but their receipts are ineligible for campaigns.
`LOCUS_FUZZ_SECONDS` is a **wall-clock budget**, not credited CPU time. Each new
invocation creates a unique run ID, plus distinct replay/fuzz completion records
for each target. Build/replay time never counts toward the canary CPU requirement.
Swift's intended receipt measures CPU inside the hosted target process; Rust
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
python3 Tools/RunLocusUIMatrix.py --os-major 15 \
  --profile regular-light-standard \
  --derived-data /outside/repository/locus-ui-derived \
  --output /outside/repository/locus-ui-evidence
```

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
source-discovered UI test ID (minimum 140) is explicitly requested, and the raw
result bundle, summary, test tree, counts, logs, source and binary identities are
retained. A missing, skipped, duplicate, failed or retried case fails the profile.
The CI job runs one full-suite macOS 15 native profile; it does **not** claim the other 47
OS/profile combinations. Native VoiceOver review, live connector paths, complete
swap/allowance flows, and QR privacy/recovery checks remain separately attributable
work until corresponding fixtures and real-device evidence exist.
