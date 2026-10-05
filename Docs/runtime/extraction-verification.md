# Runtime extraction verification

## Baseline identity and isolation

Baseline inspected on 2026-10-05 at Locus commit
`4319810bfb13d42be47d0e5278c3f55135a357c2`, in
`/Users/nahid/.codex/worktrees/b6b6/locus`. The initial worktree was clean.
The brief's `b332e4554e72956f949506207ffa034749360d79` is an inspection
reference, not the checkout used for these results.

Tests ran with Python 3.14.6 on macOS ARM64 in a newly created disposable venv:

```text
/var/folders/8s/h68vzwb10yg081d3vgblcx7c0000gn/T/locus-runtime-baseline-5b7cmyp5/venv
```

The venv was created with `/opt/homebrew/bin/python3 -m venv`. Existing installed
dependencies were copied from `/Users/nahid/Documents/locus/agent/.venv` without
changing that environment; editable import hooks were removed from the copy.
The exact `locus-memory` dependency declared by this checkout was then installed:

```sh
BASELINE_PY=/var/folders/8s/h68vzwb10yg081d3vgblcx7c0000gn/T/locus-runtime-baseline-5b7cmyp5/venv/bin/python
"$BASELINE_PY" -m pip install --no-deps --force-reinstall \
  'https://github.com/nahid-sparktales/locus-memory/releases/download/v0.3.0/locus_memory-0.3.0-py3-none-any.whl#sha256=aafdbdf72b04aa2e83589cf0b88f1f9c8493b6ab9e97b65b6deac6dd5802d4b6'
```

This copied-dependency setup is baseline test isolation, not a reproducible wheel
installation gate. The repository's test configuration loads the working
checkout under `agent/`; package independence must be verified separately.
`agent/tests/conftest.py` relocates product state before imports, assigns each
test a temporary profile, blocks writes to the real `~/.ollama-code`, and
disables background provider probes. Actual runtime process tests provide
separate runtime/profile/account roots and random loopback ports. Their provider
is a deterministic local HTTP fixture. No production service was stopped,
reinstalled, registered or updated, and no account login/model call occurred.

## Executed before movement

From the Locus repository root:

```sh
"$BASELINE_PY" -m pytest -q \
  agent/tests/test_runtime.py \
  agent/tests/test_runtime_remote.py \
  agent/tests/test_runtime_release.py \
  agent/tests/test_runtime_hardening.py \
  agent/tests/test_runtime_connectors.py \
  agent/tests/test_runtime_helper_signing.py \
  agent/tests/test_runtime_acceptance.py \
  agent/tests/test_app_factory.py \
  --junitxml=/var/folders/8s/h68vzwb10yg081d3vgblcx7c0000gn/T/locus-runtime-baseline-5b7cmyp5/baseline.xml
python3 Tools/ProtocolManifest.py
```

Result: **90 passed in 37.35 seconds**. No pre-existing failure was observed in
this focused baseline. Protocol manifest: **current, revision 2**. The manifest
is the companion wire-file integrity gate, not an independent runtime protocol
negotiation test.

| Suite | Cases | Evidence covered |
| --- | ---: | --- |
| `test_runtime.py` | 9 | Durable requests/cursors, decision fingerprint/single use, private state, opt-in continuation, actual supervisor/worker disconnect and reuse, connector receipt |
| `test_runtime_remote.py` | 9 | Reviewed snapshots/result conflicts, secrets/path escapes, strict SSH arguments and mocked host-key failure, package checks, separate account homes |
| `test_runtime_release.py` | 26 | Reproducible fixture archives, platform/artifact pins, traversal/tampering, maintenance admission, SQLite backup/update/rollback/recovery and exclusive install lock using mocked service manager |
| `test_runtime_hardening.py` | 22 | Chat limits, saved-agent admission, native claim uncertainty, pause/detach, durable HTTP operations, abandoned-request non-replay, native availability, private payloads |
| `test_runtime_connectors.py` | 7 | Connector HTTP error classification/receipt behavior with fixtures |
| `test_runtime_helper_signing.py` | 12 | Signing preflight fixtures plus actual temporary Mach-O ad-hoc signing rejected as a distribution signature |
| `test_runtime_acceptance.py` | 1 | Actual supervisor/worker, detached schedule, deterministic provider, correction/check approval, result verification, usage attribution and task restore/recovery |
| `test_app_factory.py` | 4 | App/service isolation, WebSocket isolation, public route snapshot |

The process checks are two cases within the suite above. They are not live SSH
checks, systemd/launchd tests, or signed SMAppService registration tests.

## Process ownership inspection and regression gaps

At baseline `RuntimeSupervisor.ensure_worker` launches the explicit product
worker, drains its merged output without publishing it, and records the owned
process handle. `stop_worker` terminates only that handle and escalates after
five seconds. Failed readiness calls the same cleanup path. There is no
`pkill`/process-name scan in these paths. `RuntimeProviders` retains handles only
for helpers it created; an already healthy external Ollama instance is not
added to its owned-process map and is not stopped by `close`.

The baseline worker launch does **not** create a separate process session/group.
Direct-process termination alone does not establish nested-child cleanup.
Existing tests do not directly prove nested-child cleanup, high-output pipe
backpressure, occupied-port failure, or repeated close/cancel across startup
states. Extraction must add deterministic characterization for these cases and
distinguish retained behavior from fixes. Do not signal any process discovered
only by a stale persisted PID; new tests must retain their own handles and
prove ownership of any process group before signaling it.

## Integration and release gates

Keep the following separate when reporting post-extraction results:

| Layer | Gate / command | Baseline status |
| --- | --- | --- |
| Runtime unit/contract | Focused pytest command above | Passed |
| Product HTTP contracts | `test_app_factory.py::test_public_route_contract_matches_snapshot` | Passed, fixture unchanged |
| Companion contract | `python3 Tools/ProtocolManifest.py` | Passed revision 2 |
| Actual foreground processes | Runtime disconnect/reuse and detached schedule tests above | Passed |
| Native runtime fixtures | `LocusTests/IndependentRuntimeProtocolTests.swift` via isolated Xcode test build | Not run in baseline |
| Clean independent wheel | Build/install `locus-runtime` in fresh venv outside Locus; import without side effects; deterministic worker and forbidden imports | New package gate, pending |
| Product dependency composition | Fresh checkout native backend bundle and remote package contain exact pinned wheel/provenance | Pending |
| Portable package/process | `Tools/PrepareRemoteRuntime.py` then `Tools/SmokeRemoteRuntime.py` without service flags | Not run in baseline |
| Disposable OS service/recovery | Smoke with `--service-manager --exercise-rollback` | Not run in baseline; requires separately authorized service installation |
| Signed desktop helper | Developer ID build/sign, SMAppService registration | Unverified; signing/registration gate remains |
| Real remote target | Explicitly selected owned host, SSH/host-key/tunnel/service/provider/reconnect/cancel/result checks | Unverified; no host selected |

Relevant affected-neighbor suites include `test_runstore.py`,
`test_runstore_connections.py`, `test_usage_ledger.py`, `test_schedules.py`,
`test_goals.py`, `test_goal_runtime.py`, `test_automation_workflows.py`,
`test_memory_adapter.py`, `test_chatgpt_broker_accounts.py` and collaboration
tests. Preserve canonical usage, decisions, worker-side permissions and product
scheduling behavior; do not regenerate route/protocol fixtures to hide drift.

The native CI invocation uses a separate derived-data directory and
`LOCUS_BUNDLE_MODE=skip` for tests. For example:

```sh
LOCUS_BUNDLE_MODE=skip xcodebuild test \
  -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/locus-runtime-extraction-native-tests \
  -only-testing:LocusTests/IndependentRuntimeProtocolTests \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements
```

A passing skip-bundle native test does not prove a standalone packaged app. The
portable package target matrix in `.github/workflows/runtime-packages.yml` is
Linux x86-64, Linux ARM64 and macOS ARM64; do not claim execution on an untested
target from a synthetic fixture.

The existing package runbook is `Docs/runtime/release-readiness.md`:

```sh
python3 Tools/PrepareRemoteRuntime.py --target macos-arm64 --require-clean \
  --output build/runtime-packages/locus-runtime-macos-arm64.tar.gz
python3 Tools/SmokeRemoteRuntime.py \
  --package build/runtime-packages/locus-runtime-macos-arm64.tar.gz \
  --sha256 REVIEWED_PACKAGE_SHA256 \
  --output build/runtime-packages/macos-arm64.process-smoke.json
```

Service installation, reboots, provider credentials/billable calls and live host
selection require explicit authorization. When authorized, add
`--service-manager --exercise-rollback` for a random disposable service name;
this still does not verify signed SMAppService registration. Run only with
separate profiles/accounts/workspaces, retain the report/checksum, and require
successful cleanup. Preserve journals after interrupted updates.

## Native compilation and test-runner results

The isolated `xcodebuild test` invocation above compiled the application and
`LocusTests`, linked the test bundle, and completed ad-hoc signing with the
backend bundle deliberately skipped. It then failed **before executing any
test cases** because LaunchServices could not launch `LocusTests`
(`IDELaunchErrorDomain`, code 20). Retrying with `test-without-building` against
the same derived-data directory produced the same launch failure.

The separate build-only gate subsequently **passed** (`TEST BUILD SUCCEEDED`,
exit 0):

```sh
LOCUS_BUNDLE_MODE=skip xcodebuild build-for-testing \
  -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/locus-runtime-extraction-native-tests \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements
```

No Swift runtime protocol fixture is claimed passed, and this is not a clean
packaged application gate or a signed SMAppService gate.

`LocusX` also **passed** a separate unsigned build-for-testing gate with backend
bundling skipped. The first ad-hoc invocation stopped because the wallet signer
service's production entitlements require a development certificate. Retrying
with signing disabled verified compilation/linking without changing any
entitlement files or launching the application:

```sh
LOCUS_BUNDLE_MODE=skip xcodebuild build-for-testing \
  -project Locus.xcodeproj -scheme LocusX -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/locus-runtime-extraction-nativex-tests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements
```

Result: `TEST BUILD SUCCEEDED`, exit 0. No LocusX test execution or signed wallet
service behavior is claimed from this compile gate.

Evidence retained outside the source tree:

```text
/tmp/locus-runtime-extraction-native-tests.log
/tmp/locus-runtime-extraction-native-retry.log
/tmp/locus-runtime-extraction-native-build.log
/tmp/locus-runtime-extraction-nativex-build.log
/tmp/locus-runtime-extraction-nativex-unsigned-build.log
/tmp/locus-runtime-extraction-native-tests/Logs/Test/Test-Locus-2026.10.05_15-16-21--0400.xcresult
/tmp/locus-runtime-extraction-native-tests/Logs/Test/Test-Locus-2026.10.05_15-19-27--0400.xcresult
```

To finish this gate, use a macOS session in which Xcode's test runner can launch
the isolated app and rerun the command above. A separate Developer ID signing
environment and explicit registration authorization are still required for
the signed helper gate. The task did not modify or stop the production runtime
to try to repair the test runner.
