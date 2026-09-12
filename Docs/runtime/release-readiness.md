# Runtime package release readiness

This phase follows the four independent-agent stages merged into main. It builds
complete portable packages, verifies them through actual supervisor and worker
processes, and makes service updates recoverable. It does not change edition
availability or enable background execution for ordinary agents.

## Building a candidate

Build on the target OS and architecture from a clean committed checkout:

```sh
python3 Tools/PrepareRemoteRuntime.py \
  --target macos-arm64 --require-clean \
  --output build/runtime-packages/locus-runtime-macos-arm64.tar.gz
```

Supported targets are `linux-x86_64`, `linux-arm64` and `macos-arm64`. Linux needs
glibc 2.28 or newer and a working systemd user session. macOS needs version 14 or
newer, Apple Silicon and an active graphical login. The host needs Python 3.10+
only for setup; execution uses the bundled Python. Linux lingering is needed for
continuation after SSH logout. Mac work runs while the user is logged in and the
machine is awake. The installer reports these requirements without changing them.

`Tools/RemoteRuntimeArtifacts.json` pins Python 3.14.6 from the
[20260728 standalone release](https://github.com/astral-sh/python-build-standalone/releases/tag/20260728)
and the CLI and code-mode-host binaries from
[Codex 0.147.0](https://github.com/openai/codex/releases/tag/rust-v0.147.0).
Every download and cache reuse is checked against its reviewed SHA-256. The
builder installs binary wheels from `agent/requirements-runtime.lock`, requires
their hashes, and bounds wheel compatibility to the supported OS baseline.
It copies tracked backend source, prunes unused development/Tk/dbm files and
retains dependency license notices, including the pinned helper's LICENSE and
NOTICE from its verified source archive. No extra runtime dependencies are added.

The archive contains a file-hash manifest, dependency and artifact provenance,
source revision and dirty-checkout status. Account homes, controller state and
project files are separate. Tar metadata and gzip timestamps are deterministic;
packaging an unchanged prepared layout produces the same checksum regardless of
its output filename or file timestamps. This does not claim that arbitrary
dependency installations are byte-identical across different build environments.

The builder produces `.tar.gz`, `.tar.gz.sha256` and `.tar.gz.build.json` files.
Select the archive and checksum in Settings → Runtimes. SHA-256 verifies the
selected artifact's integrity; it is not a replacement for trusted distribution or
the separate signed desktop Service Management helper. The lower-level
`Tools/PackageRemoteRuntime.py` remains available for an already prepared layout.

## Update transaction and recovery

Pause and drain the runtime before updating. An exclusive installation lock also
serializes service controls. After checking the uploaded archive, helper version
and isolated imports, the installer writes a durable journal before stopping the
old service. Once stopped, it backs up every profile SQLite database using SQLite's
backup API. Candidate startup runs in maintenance mode: HTTP mutations, worker
creation, commands and automatic admission are blocked. Read-only authenticated
health requests still work.

The candidate service must report the expected protocol and package identity
before `current` advances. Existing installations remain paused until resumed
explicitly. The previous package and database backups remain available. The
service command references the immutable version directory directly, so changing
`current` cannot move an active process onto another package.

On failure, the installer stops the candidate, restores the old unit and package
references, restores backed-up databases and removes databases created during the
failed startup. It restarts the prior service if it was running and verifies its
identity. If recovery fails or the installer is interrupted, the journal remains
and new work stays blocked. Retrying installation recovers the pending transaction
before attempting the upload. Do not delete `installation.json` to bypass recovery.
Credentials are not placed in the journal or restored from project snapshots.

The packaged helper is the full Codex CLI. The service declares its `cli` entry
point explicitly so the manager invokes `app-server --listen stdio://` even though
the packaged filename is `codex-app-server`. Existing desktop basename handling
remains compatible.

Run-history connections now close at each transaction boundary. The actual macOS
service test exposed file-handle exhaustion because SQLite's default context
manager commits or rolls back without closing the connection. A process test with
garbage collection disabled and only 64 file handles verifies repeated history
queries, and transaction tests preserve commit/rollback behavior. Read-only
database URLs also encode special characters in profile paths correctly.

## Isolated package validation

The smoke runner uses a fresh random service name, separate profile, separate
account homes and a temporary project. It never uses the production runtime or
existing provider credentials. Its model responses come from a local deterministic
HTTP fixture. It starts the actual packaged ChatGPT helper in two signed-out
account homes to verify protocol initialization without login or billable calls.

```sh
python3 Tools/SmokeRemoteRuntime.py \
  --package build/runtime-packages/locus-runtime-macos-arm64.tar.gz \
  --sha256 REVIEWED_PACKAGE_SHA256 \
  --service-manager --exercise-rollback \
  --output build/runtime-packages/macos-arm64.smoke.json
```

The scenario verifies authenticated loopback access, a schedule after controller
detach, verified output and ledger usage, an explicitly requested and approved
correction check enforced on the next task, service restart without duplicate
runs or usage, and a deliberately broken update restoring the previous service
and results. It stops and removes only its own service and workspace in cleanup.
Omit `--service-manager --exercise-rollback` for a foreground process-only check.
An unsuccessful cleanup makes the report fail. A forcibly killed smoke runner may
leave its validation namespace behind; normal exit cleans it even after failure.

The **Runtime package candidates** workflow builds and runs these checks on
Linux x86-64, Linux ARM64 and macOS 14 ARM64. It retains build/smoke JSON evidence
and checksums separately, and uploads candidate archives only for passing targets.
It does not publish a production release or configure a user's SSH host.

## Validation and remaining release gates

Regression coverage includes archive traversal, pinned-download and installed-file
tampering, authentication before maintenance responses, concurrent installer
locking, successful and failed updates, interrupted recovery, and database cleanup
under a 64-file-handle limit. Each package run records its exact SHA-256, platform,
process/service mode and scenario outcomes in JSON evidence. Deterministic provider
fixtures and signed-out helper initialization do not establish real provider
billing, refresh or account expiration behavior.

Production release still requires signed direct-download SMAppService
registration, SSH deployment to disposable owned Linux and Mac hosts, host-key
change rejection, login/reboot lifecycle, real connector delivery, and bounded
API/Ollama/independent ChatGPT login, model-call and expiration/recovery checks.
The isolated user-service check exercises launchd/systemd directly; it does not
test the desktop SMAppService registration flow. No live SSH host or provider
account is required for the fixture build pipeline, and none is provisioned by it.
