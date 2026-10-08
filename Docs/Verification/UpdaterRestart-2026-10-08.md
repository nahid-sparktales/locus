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

## Follow-up: installed-app timeline and full model cleanup

The subsequent report that Install and Restart still failed was investigated
against the installed application's read-only unified logs. The update was
handled by PID `34158`, previously observed running Locus 4.2.0. The narrowly
relevant October 8 timeline is:

| Local time | Observation |
| --- | --- |
| 02:32:56.923 | PID 34158 verified the new appcast signature. |
| 02:33:07.432–433 | Sparkle verified and extracted the downloaded update. |
| 02:33:21.156 | The installer's connection from PID 34158 closed. |
| 02:33:25.540–810 | PID 34158 received a Quit AppleEvent, returned `NSTerminateNow`, and exited normally. |
| 02:33:26 | The Sparkle installation directory was updated; the installer exited. |
| 02:33:27 | The new installed Locus process, PID 80194, started. |

The installed bundle was then confirmed as **4.2.1 (39)**. No later Sparkle
update attempt by PID 80194 appeared in the inspected logs. This places the
reported update attempt in the older process, before the restart fix was
installed. The logs do not establish whether the later Quit AppleEvent was a
manual recovery action, so that detail is not inferred.

Two additional native tests exercise `ApplicationLifecycleCoordinator`
connected to a real `AppModel`: idle cleanup resumes installation immediately,
and a busy model whose worker never sends a completion still resumes after the
existing bounded shutdown wait. They use an inert backend and do not launch
provider work or touch the installed app. Both passed in the focused native
verification run for 4.2.2.

A second Developer ID signed Sparkle rehearsal also exercised the actual
compiled app components. The source fixture linked the built
`Locus.debug.dylib` and used the real `AppModel`,
`ApplicationLifecycleCoordinator`, and `LocusApplicationDelegate`. Its busy
flag was deliberately left set, and a real temporary Markdown output was
queued for capture immediately before installation. There was no fake cleanup
callback. The target was a complete Locus app executable and UI; a tiny fixture
launcher set `LOCUS_UI_TESTING=1` before executing that unchanged binary, so
the relaunched app used temporary/in-memory fixture storage.

Observed results:

- Source PID `87229` passed the first restart gate and postponed installation.
- Actual app cleanup completed after **3.151 seconds**, saved **one output**,
  and resumed despite the deliberately stale busy flag.
- The second restart gate passed; the real application delegate returned
  `terminateNow` and the source process exited.
- Sparkle replaced fixture bundle version `1` with `2` and automatically
  launched the complete Locus executable as PID `87303`.
- PID-bound Accessibility and Window Server inspection confirmed launch had
  finished, the app was not hidden, and its **1100 × 760 main window was
  visible on screen**.

The fixture identity was
`io.sparktales.full-updater-fixture.33216a303cf74c03b3e8a7bc72729c13`.
Both versions and their embedded code were Developer ID signed, the local
archive/feed used a fresh Ed25519 key, and the private key was removed before
launch. The linked production-code dylib SHA-256 was
`f7936e0132bde33e549bec07db697c8a366746b4ec6da3b87dd50122886de889`.
This was an isolated identity and temporary data under the current macOS login,
not a separate OS account. No installed Locus process was running when this
rehearsal launched. Only the verified fixture PID was terminated afterward,
and the copied app was unregistered from Launch Services.

Limits: no live provider task or real foreground terminal job was interrupted.
The archive was not notarized. A concurrent UI test runner held focus during
the final observation, so foreground activation is **not** claimed. The
runner's initial process monitor compared `/tmp` and `/private/tmp` literally
and missed the successfully relaunched process; separate exact-PID checks
verified the replacement and visible window before cleanup. The retained
runner now canonicalizes those paths, but was not rerun after that monitor
repair.

Evidence is retained in
`/tmp/locus-422-full-update-e52d8936e0/result.json`, `events.jsonl`, and
`relaunch-ax.json`; fixture source and runners are under
`/tmp/locus-422-full-updater/`. This verification did not reproduce another
production updater defect, so no speculative updater behavior change was
added for 4.2.2.
