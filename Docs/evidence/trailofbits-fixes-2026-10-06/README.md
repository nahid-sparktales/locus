# Post-fix evidence

- `disconnect-report.md`, `ownership-report.md`: complete assessments from the Trail of Bits runner.
- `disconnect-summary.json`, `ownership-summary.json`: compact per-check exit codes, reachability markers and outcomes extracted from original results.
- `disconnect-check.py`, `ownership-check.py`: independently authored runtime helpers, using `PPV_CHECKOUT` for source and private temporary profiles. They require the repository's locked runtime dependencies.
- `native-fixed-probe.swift`, `native-fixed-result.txt`: the original native probe inputs against the rebuilt Debug module, with safety assertions replacing the original bug assertions. This supplemental native check is separate from isolated Python validation.
- `native-probe-command.sh`: the exact native probe compilation command.
- `validation.json`: final check totals and runtime-validation patch pins; `source-sha256.json` records the reviewed production/test file contents.
- `archive-sha256.txt`: integrity hash of the complete local validation archive at `/tmp/locus-post-patch-validation-20261006.tar.gz`. The archive contains both original runner evidence trees and all plans/helpers/patches. The compact files here are summaries, not replacements for its integrity manifests.

Original vulnerable results remain in `../trailofbits-audit-2026-10-06/`. No original evidence was overwritten.
