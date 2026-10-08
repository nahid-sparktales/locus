# Install and Restart verification

## Defect and correction

The pinned Sparkle 2.9.6 installer checks `updaterShouldRelaunchApplication`
twice: before postponing installation for application cleanup, and again
when the supplied install continuation resumes installation. Locus formerly
allowed only the lifecycle's `idle` state through that gate. Cleanup changed
the state to `relaunching`, so the second check refused the continuation and
Sparkle aborted installation without an error.

`ApplicationLifecycleCoordinator` now permits its prepared `relaunching`
state. It still refuses concurrent requests during cleanup or ordinary Quit.
An ended update cycle invalidates its retained continuation and cleanup ID,
so a stale completion cannot resume an aborted or newer installation.
`SparkleUpdateDriver` forwards cycle completion in both product editions.

The relevant upstream implementation is
[SPUInstallerDriver.m at the pinned revision](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Sparkle/SPUInstallerDriver.m).
The install continuation calls `installWithToolAndRelaunch` recursively;
`mayUpdateAndRestart` runs before the `_postponedOnce` check. Successful
installation hands off termination before installation completion; the live
trace below also confirms that `didFinishUpdateCycle` did not reset the
lifecycle between continuation and termination.

## Validation

A standalone reproduction using the actual lifecycle source returned:

```text
Before: initial=true continuation=false state=relaunching
After:  initial=true continuation=true  state=relaunching
```

Four native regression cases in `AppUpdateControllerTests` cover the second
gate, deferred cleanup resuming exactly once, stale cleanup after cancellation,
and the real Sparkle driver's cycle-finished delegate forwarding. Their
execution is recorded with the release's native test results; the live test
below is separate from those tests.

A real Sparkle 2.9.6 update ran successfully on October 8, 2026 with an
isolated fixture application under the current macOS login account. It used
the actual patched `ApplicationLifecycleCoordinator`, an asynchronous 150 ms
cleanup callback, and a custom Sparkle user driver that selected installation
without opening windows or activating the application.

- Bundle ID: `io.sparktales.updater-fixture.5481985759a24cdb95701aeb1d4bd8bb`.
- Both fixture versions and all embedded Sparkle helpers were signed with
  `Developer ID Application: SparkTales Inc. (4X4RJA7GMD)`.
- The archive was signed with a fresh, isolated Ed25519 key and served from
  `127.0.0.1:54455`. The private fixture key was deleted before launch.
- Archive SHA-256:
  `66dfe9ead34e1455607d8e4c2d2121dad2db3aaf61b64c90a8223ab3ead20a51`.
- The installed fixture's bundle version changed from `1` to `2`, and the
  updater automatically launched version 2 with a different PID.

The exact ordered event trace was:

```text
version 1 / PID 39218: launched
version 1 / PID 39218: checking
version 1 / PID 39218: update_found
version 1 / PID 39218: download
version 1 / PID 39218: extract
version 1 / PID 39218: ready
version 1 / PID 39218: relaunch_gate: true
version 1 / PID 39218: postpone
version 1 / PID 39218: continue_install
version 1 / PID 39218: relaunch_gate: true
version 1 / PID 39218: will_relaunch
version 1 / PID 39218: installing: false
version 1 / PID 39218: terminate: 1
version 2 / PID 39247: launched
version 2 / PID 39247: terminate: 1
```

`terminate: 1` is AppKit's `terminateNow`. Version 2 deliberately exited after
logging its launch. No fixture process remained after the test.

This verified actual download, extraction, signature validation, cleanup
handoff, termination, bundle replacement, and automatic relaunch. It did not
update the installed Locus app, touch Locus user data, or exercise full Locus
active-work shutdown. Cleanup ordering and cancellation are covered by the
native tests. The local fixture omitted secure timestamps and notarization;
the production packaging/signing/notarization gates remain separate.

Local evidence is retained at
`/tmp/locus-updater-live-2525f6d3e471/result.json` and `events.jsonl`.
The reusable fixture source, exact lifecycle snapshot, compiled harness,
and runner remain under `/tmp/locus-updater-regression/`:
`LiveFixture.swift`, `ApplicationLifecycleCoordinator.swift`,
`UpdaterFixture`, and `run-live.py`. Running
`python3 /tmp/locus-updater-regression/run-live.py` repeats the isolated test
with a fresh bundle ID, port, and signing key. It requires the cached Sparkle
framework/tools and the same local Developer ID signing identity.

## Upgrading an already affected installation

This fix runs only after the new binary has been installed. If an older
version's Install and Restart button does nothing, download the signed ZIP
from the new release, quit Locus, replace its application in Applications,
and open the replacement. Replacing the app bundle preserves Locus data
stored outside it.

Sparkle also documents that an already prepared installation remains staged
when dismissed and installs after normal termination, whereas Skip cancels
it. See the pinned
[SPUUserDriver.h](https://github.com/sparkle-project/Sparkle/blob/ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a/Sparkle/SPUUserDriver.h).
Manual replacement is the unambiguous recovery recommendation because the
affected app may already have aborted its prepared update.
