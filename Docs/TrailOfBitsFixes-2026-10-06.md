# Fixes for the October 6 Locus audit

All four reproduced findings from [the audit](TrailOfBitsAudit-2026-10-06.md) have fixes and regression coverage. They were originally validated on `codex/fix-audit-findings-20261006`, based on `5529004a47235943991f192464001dbc92685c9f`, and are included in the 4.1.0 release branch on top of merged runtime and Agent Worlds extraction commit `6e8afb0aa486955188ef29dbfc2cb46f950f84f7`.

The combined extraction source also passed 243 focused Python tests and all 22
CompanionPanelTests with these fixes applied. Integration required only renaming
two regression-test calls to the extracted host's `savedAgentProfileDispatch`;
the production patches were unchanged. The baseline comparisons below retain
their original inputs and scope.

| Finding | Fix | Regression coverage |
| --- | --- | --- |
| F1 — Disconnect does not cancel plugin work | A blocking ASGI receive watcher sets the existing cooperative stop event after body parsing. Plugin panels and portrait previews use it; the production middleware and request guards remain in place. Worker cleanup is registered before awaiting watcher disposal. | Real TCP and production `create_app` disconnect, gated deferred writes, normal completion exactly once, handler cancellation, token/Origin/body-limit/maintenance checks, portrait cancellation and timeout. |
| F2 — Git subfolder companion chats disappear | Companion listing and catalog refresh use the existing `belongsToWorkspace` predicate. | Creation, selection, catalog refresh, main shortcut reuse, sibling rejection and preservation of execution paths and the center draft. |
| F3 — Chat model override blocked by default account | Availability checks use the selected conversation's effective profile, matching dispatch. | A healthy override works with an unavailable default; an unavailable override cannot fall back to a healthy default. |
| F4 — Stale control restores legacy memory authority | The host rejects a missing ownership row when surviving ownership history or partition cutover metadata establishes a prior transition. Bootstrap, constructors, cached legacy write guards, adapters and offline migration enforce the check. | Actual shadow-control backup/restore after cutover, nine host entrypoints, CLI actions, missing rows with/without history, fresh canonical records, valid shadow writes, rollback and re-cutover. |

The memory change is contained in the Locus host. The external `locus-memory` package pin remains at 0.3.0; no new package release was published.

## Validation

Applied the installed Trail of Bits [post-patch-validation skill](/Users/nahid/.codex/skills/post-patch-validation/SKILL.md). Two independently authored runtime plans were run against isolated, pinned baseline and patched checkouts with the exact runtime dependency lock. Both completed with no reported failures or evidence gaps. Each includes control, exploit, root-cause variant, behavior-preservation, regression, adjacent-security and project-suite checks.

| Check | Baseline | Patched |
| --- | --- | --- |
| F1: plugin TCP disconnect before deferred publication | Safety assertion fails; publication occurs | Pass; publication prevented |
| F1 variant: portrait TCP disconnect | Safety assertion fails; worker continues | Pass; worker stops |
| F4: restore real empty shadow control after cutover | Safety assertion fails; legacy vault opens | Pass; ownership ambiguity rejected |
| F4 variant: retain a pre-cutover legacy writer | Safety assertion fails; divergent write accepted | Pass; write rejected |

All four checks emitted `PPV_REACHED` immediately before the safety assertion on both revisions. Benign output comparisons were identical. Healthy shadow behavior, explicit rollback, request authorization, scope restrictions and key continuity passed on both revisions. These checks establish the tested behaviors, not exhaustive security coverage.

- Full native suite: **1,959 passed, zero failures** (Debug app build, runtime bundling skipped).
- Full Python suite: **3,118 passed, 31 subtests passed** in 394.23 seconds, using the exact runtime dependency lock (`/tmp/locus-audit-pinned-20261006/bin/python -m pytest -q`).
- Focused memory suite: **210 passed**; focused plugin/portrait and request-guard suites: **118 passed**.
- Ruff, transport-security audit, protocol manifest and whitespace checks: passed.
- The original native probe's inputs also passed against the rebuilt app module: `companionChats=1 selected=isolated-chat`; healthy override `canSend=true error=nil`.

## Evidence and reproduction

Compact evidence is in [the evidence directory](evidence/trailofbits-fixes-2026-10-06/README.md), including both runner reports, check summaries, independent check sources and the native probe. The complete [validation archive](/tmp/locus-post-patch-validation-20261006.tar.gz) retains pinned patches, plans, original result JSON, stdout/stderr, hashed helpers, synthetic scratch profiles and integrity manifests. Its hash is recorded with the compact evidence. The archive is local temporary storage; preserve it elsewhere if long-term retention is needed.

The runtime plans use `/tmp/locus-audit-pinned-20261006/bin/python`, installed from `agent/requirements-runtime.lock` plus pytest. Helpers resolve application code from `PPV_CHECKOUT`, so validation does not accidentally import an editable installation from the working tree. All reproduction records, tokens, providers and plugin side effects are synthetic.

Full native command:

```sh
LOCUS_BUNDLE_MODE=skip LOCUS_CARGO_BIN=/usr/bin/false xcodebuild test \
  -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/locus-audit-native-20261006 \
  -only-testing:LocusTests CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements
```

## Limits

Cancellation remains cooperative and cannot undo an operation already committed remotely. The fix prevents the demonstrated deferred side effect after disconnect.

The memory guard handles the demonstrated missing-row restore. It does not authenticate a stale **nonempty** ownership row, detect every mixed restore across repeated migration cycles, or change arbitrary direct consumers of the external package. Valid rollback uses the existing offline protocol; see [MemoryCutover.md](MemoryCutover.md). Release packaging and live provider/publishing operations were not exercised for these fixes.
