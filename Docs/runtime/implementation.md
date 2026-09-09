# Independent agent runtime

Branch: `codex/independent-agent-runtime`, isolated from revision `4b49373`.

## Delivery gates

1. Local service and durable controller protocol.
2. SSH deployment, reviewed workspace snapshots, account isolation, retrieval.
3. Unified invocation accounting and immutable evaluation comparisons.
4. Explicit correction proposals and versioned acceptance checks.

The runtime is opt-in in direct-download, wallet-free Locus. A signed bundled
SMAppService launch agent starts the Python supervisor. Its versioned package,
private credentials, and controller token are stored in the user's Locus Runtime
directory. macOS registration approval, login and awake requirements are shown in
Settings. App Store and LocusX do not install this helper.

A worker belongs to the supervisor, not a window. Controller websocket connections
subscribe to durable events; reconnect uses a cursor and pending decision snapshot.
Decisions require their current fingerprint. The supervisor owns the only worker
socket and connector executor, and records external action intent before execution.
A crash leaves sent commands and external actions uncertain instead of resending
those actions. Existing recovery controls remain responsible for deliberate retry.
The runtime pauses ordinary work on controller disconnect; opted-in work continues.

The service coordinates schedules, event delivery, workflow steps and goal claims.
Automation continuation is inherited from the owning agent's explicit setting.
The application remains the interactive sign-in and native operation broker.
Browser, computer and other native requests remain pending while disconnected;
explicit interruption cancels their wait. Model and tool permission checks remain
inside the existing worker. Credentials are stored separately from event records.

## Validation log

Stage 1: native Debug build (ad hoc, bundled assets skipped) and 37 backend tests
passed. Includes a real supervisor/worker process, controller detach/reattach,
request deduplication, interrupted command handling, approval version checks and
external action receipt deduplication. These are fixture/process results, not live
provider validation. Signed SMAppService registration, login/reboot lifecycle and
real provider/connector smoke tests remain release gates.

No changes from the original dirty checkout have been copied. Overlapping recovery,
evaluation and run-store work must be reviewed and reconciled before integration.

Stage 2 implements strict OpenSSH host validation, loopback tunnels, systemd user
and macOS launch-agent installation, hash-checked versioned packages, independent
ChatGPT device login with an SSH browser callback fallback, and remote controls.
Deployment snapshots include current selected edits and show ignored/secret/cache
exclusions. Uploads have stable deployment IDs; retry reconciles the same remote
workspace. Retrieved changes require selection and an unchanged local baseline.
Removing a connection preserves remote files. Updates refuse active work; Stop
first checkpoints and drains workers. Previous packages and migration backups are
retained. Selected API and connector credentials travel through authenticated
tunnels and remain outside project snapshots and public deployment records.

Stage 2 validation: 92 backend tests passed, including tampered/incompatible
packages, host-key failure, snapshot path escape, post-review edits, explicit apply,
local conflicts, independent device login and account homes. Native Debug build
passed. No disposable SSH host was supplied; service-manager installation and
remote live-provider/login/reboot tests remain release gates.

## Build and install a remote package

Run `Tools/PackageRemoteRuntime.py` with `--runtime` pointing to a portable runtime
layout (`python/bin/python3`, `site-packages`, and `source/ollama_code`), the pinned
0.147.0 helper and its `codex-code-mode-host` sibling, `--target` (`linux-x86_64`,
`linux-arm64`, or `macos-arm64`) and `--output`. Use the hashed
`agent/requirements-runtime.lock` when building dependencies for each architecture.
The macOS runtime preparation scripts pin Python and helper source/dependency hashes.
Linux release packages must be built and smoke-tested on their target architecture;
this change does not claim that macOS executables can be deployed to Linux.
The generated package and SHA-256 are selected in Settings → Runtimes. Installation
requires Python 3 for the bootstrap and a working systemd user session on Linux, or
an active GUI login on macOS. The installed service uses its own bundled Python.

Do not release a package before checking its helper version, architecture, runtime
imports, isolated account login and a model call on the target host. Signed macOS
background-helper registration must also be checked from a signed direct-download
build; ad hoc compile checks do not establish OS registration behavior.

## Invocation accounting and evaluations (stage 3)

Schema 16 adds one persistent invocation ledger, immutable price provenance,
central task limits, concurrent spend reservations and durable native usage
cursors. Worker, planning, review, retry and compaction calls enter the ledger
before execution. Unknown prices, interrupted usage, local execution and plan
subscriptions remain distinct. API estimates use exclusive cache/output token
categories; reasoning is part of output. Anthropic cache writes retain 5-minute,
1-hour and unknown durations. Unknown durations retain only a partial known
subtotal. Reported USD tool charges are retained with their invocation; unpriced
server-tool activity makes coverage partial. Replayed cumulative native usage is
deduplicated across worker recreation. Task limits cannot reset consumed usage.

The dashboard's invocation totals, run records, goal/capsule detail, evaluation
results and remote exports derive from this ledger. Historical aggregate records
remain separately readable. Exact direct-endpoint standard prices were checked
against OpenAI and Anthropic's official pricing pages on 2026-09-09. Unsupported
models, routes, tiers and large requests remain unpriced. These controls are
estimates, not a guarantee about a provider invoice. Native helpers expose their
internal calls after execution; their token/call interruption occurs at the next
reported boundary. No per-task subscription dollar billing is inferred.

Evaluations now enter the run store before the result foreign key is created.
The overlapping admission fix in the original checkout was inspected and
reimplemented here without modifying or copying its unfinished recovery system.
Immutable fingerprints include route/model, team, prompts, tools, budgets, checks
and baseline. Repetitions replay the saved baseline. Required missing judges,
budget exhaustion, interruption and runtime failures cannot pass. Summaries count
incomplete results and expose completion, rubric coverage, outcome, latency and
cost coverage. Historical configurations are never silently grouped together.

Stage 3 validation: 265 backend regression checks passed; after correcting the
new fixture's explicit concurrency budget, all 24 accounting/evaluation checks
passed, including three real supervisor/worker/API scenarios (pass, missing judge,
exhausted budget), identical-baseline repetitions, cache normalization, concurrent
reservations and native cumulative replay. Native Debug build passed. All provider
responses in these tests are deterministic fixtures. Real provider prices/charges,
account expiration, signed installation and disposable remote hosts remain live
release gates. No integration into the original checkout has occurred.


## Explicit reusable checks (stage 4)

Make reusable check appears only on saved user messages. The selected model
creates a visible proposal, with its generation invocation attributed to the
source task. Invalid or unsupported proposals become human review. There is no
observer or automatic correction collection. Settings → Agents & Teams → Manage
reusable checks opens the library without generating a proposal.

Proposals preserve the correction, requirement, project, file/agent scope and
verification limits. Editing, testing, approving, dismissing and disabling use
revision checks; command tests retain the normal permission boundary. Approved
versions are frozen into future chat, team, goal and capsule contracts. Applicable
checks run through TaskVerifier and its existing evidence invalidation and repair
allowances. Explicit Apply to this task invalidates a chat's prior evidence;
goals/capsules retain their own requirement-edit controls. Disabling a check affects
future admissions, never silently changes an existing contract. Evaluations freeze
check definitions once for identical repetitions and include them in fingerprints.

Remote snapshots include only explicitly selected approved versions with their
provenance. Returned results expose current verification evidence and the same
invocation accounting used locally. Long-running controller check requests retain
workspace admission after an HTTP disconnect; uncertain worker outcomes are not
replayed.

Stage 4 validation: 332 combined backend checks passed, including a real local
supervisor and worker process with a deterministic HTTP provider fixture. The
acceptance test imports a reviewed deployment, disconnects the controller, runs a
schedule, retrieves verified output and usage, approves an explicitly requested
correction check and enforces its exact version on the next task. It does not use
SSH or claim a real remote installation. The native app and protocol test targets
compile. XCTest execution failed before connection: a process sample shows the
host blocked in dyld's file-open path before application code. This remains a
native execution gate; no unit test pass is inferred from compilation.
