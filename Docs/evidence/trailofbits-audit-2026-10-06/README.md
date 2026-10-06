# Audit evidence — 2026-10-06

Parent report: [Locus Trail of Bits audit](../../TrailOfBitsAudit-2026-10-06.md).

All reproducers use synthetic fixtures and temporary profiles. They deliberately demonstrate failures in commit `5529004a`; a successful probe process is not a passing regression test.

## Runtime setup

From the repository root, prepare an isolated Python environment with the exact shipped dependencies:

```sh
python3 -m venv /tmp/locus-audit-pinned
/tmp/locus-audit-pinned/bin/python -m pip install --require-hashes -r agent/requirements-runtime.lock
/tmp/locus-audit-pinned/bin/python -m pip install pytest
```

Run the production disconnect reproduction and its negative control:

```sh
/tmp/locus-audit-pinned/bin/python Docs/evidence/trailofbits-audit-2026-10-06/plugin-disconnect-repro.py
/tmp/locus-audit-pinned/bin/python Docs/evidence/trailofbits-audit-2026-10-06/plugin-disconnect-repro.py --bare
```

Production records `published_after_disconnect: true` and `cancelled: false`; the bare endpoint records the inverse. The only publication is a temporary local marker. The probe starts a loopback-only Uvicorn server with a synthetic auth token and shuts it down afterward. It disables application lifespan because the injected minimal fixture service is already owned/cleaned up by the test fixture; production routes and middleware still run.

Run the conditional ownership recovery reproduction:

```sh
PYTHONPATH=agent /tmp/locus-audit-pinned/bin/python Docs/evidence/trailofbits-audit-2026-10-06/memory-ownership-repro.py
```

This backs up and restores only a newly created temporary profile. Its process-quiescence check is replaced because unrelated Locus processes do not own that profile; real migration leases remain active.

The native source probe imports the built Locus module with `@testable`. Its captured output is in `native-findings-result.txt`; compilation requires the Debug build products/frameworks and `Locus.debug.dylib`. The native component report describes its actual execution. No live provider is called: an ephemeral URLProtocol supplies a synthetic conversation.

The workspace-context probe is a nonblocking design observation, not one of the four counted findings. It imports repository test helpers and uses temporary project files.

## Records

- `plugin-review.md`, `native-review.md`, `memory-review.md`: component reviews and coverage limits.
- `plugin-disconnect-verification.md`: independent challenge of the highest-priority finding.
- `plugin-disconnect-result.json`, `plugin-disconnect-control.json`: exact-lock TCP results.
- `memory-ownership-result.txt`, `native-findings-result.txt`: reproduced memory/native behavior.
- `dependency-audit.json`: 51 named dependencies without reported advisories; direct-URL `locus-memory` skipped by scanner.
- `secret-scan.json`: empty findings from the primary commit range, with redaction enabled.

Some component reports retain original absolute `/tmp` paths as audit provenance. The parent report links the saved copies here. Whole-suite/build logs remain under `/tmp/locus-audit-*`; final counts and build status are captured in the parent report and validation record.
