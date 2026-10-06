# Post-Patch Validation

All supplied checks passed. Human review is still required.

Declared evidence level: runtime (execution of the reported behavior and its safety assertions).

Assessment: complete. Human review is required.

## Findings

No supported failures in the supplied checks.

## Validation gaps

All required checks produced usable evidence.

## Evidence

Finding: F4: Restoring a real zero-row shadow control after cutover silently returns to legacy authority despite surviving canonical partition data.

Base commit: `5529004a47235943991f192464001dbc92685c9f`

Patch SHA-256: `88db3fb83c6ca66f63719729f3f3cba49e6c90f78f324da77246ced42d5cb0c7`

Submodules: none

Forwarded environment: none

The table records whether each run matched its expected result. For exploits and
variants, a matched baseline means the safety assertion failed as expected.
Observations require the controls and comparisons described in the findings and gaps.

| Check | Kind | Base expectation | Patched expectation | Output comparison |
|---|---|---|---|---|
| `01-shadow-control` | control | matched | matched | not compared |
| `02-stale-control-vault` | exploit | matched | matched | not compared |
| `03-retained-legacy-writer` | variant | matched | matched | not compared |
| `04-explicit-rollback` | behavior | matched | matched | same |
| `05-existing-migration` | regression | matched | matched | not compared |
| `06-scope-and-key-security` | security | matched | matched | not compared |
| `07-ownership-suite` | suite | not run | matched | not compared |

## Next steps

Review the saved assertions and omitted paths before accepting the patch. A complete
assessment means the supplied checks produced usable evidence.
It does not establish that coverage is exhaustive.
