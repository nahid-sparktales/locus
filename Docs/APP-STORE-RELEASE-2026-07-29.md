# Mac App Store release preparation — 2026-07-29

## Result

Locus has been prepared as a sandboxed macOS App Store application for the
SparkTales Apple developer team.

- App Store Connect name: **Locus AI Workspace**
- Apple ID: `6796076183`
- Bundle ID: `io.sparktales.locus`
- Marketing version: `1.6.0`
- Current replacement build: `9`
- Team ID: `4X4RJA7GMD`

The mistakenly created `com.nahid.locus` App Store record was removed. Build
8 was uploaded successfully but is superseded because its standalone Python
runtime still contained an unused GNU gdbm extension. Replacement Build 9
was validated and uploaded successfully on July 29, 2026:

- Delivery UUID: `19d4a3b3-ea0f-4b71-838c-3990fa1fa551`
- Uploaded package: `Locus.pkg` (`38,781,786` bytes transferred)
- App Store state at handoff: accepted for processing; not submitted for
  review

## App Store engineering changes

- Enabled App Sandbox and hardened runtime for Release builds.
- Added security-scoped bookmarks for persistent user-selected workspace
  access.
- Moved agent state into the application container when sandboxed.
- Added app and helper entitlements for workspace, network, and inherited
  sandbox access.
- Added `PrivacyInfo.xcprivacy` and declared no tracking or collected data.
- Set `ITSAppUsesNonExemptEncryption` to `NO`.
- Signed nested Python binaries and extension modules before signing the app.
- Added archive, export, validation, and upload automation using the shared
  SparkTales App Store Connect service key.
- Pinned the 24 runtime packages and all distribution hashes in
  `agent/requirements-runtime.lock`. A missing interpreter checksum or
  mismatched package hash now stops the release build.

## Distribution-rights audit

The uploaded application bundles CPython and 24 Python packages. Package
licenses are retained in their `.dist-info` directories. License texts for
the standalone Python runtime and its statically included libraries are
bundled under:

`Locus/Resources/ThirdPartyLicenses/python-build-standalone-20260728/`

`Locus/Resources/ThirdPartyNotices.md` provides the component inventory,
versions, licenses, and corresponding source locations.

The original runtime included `_dbm.so`, which identifies its linked library
as GNU gdbm and is governed by GPLv3. Locus does not use dbm. The release
pipeline now deletes `_dbm.so` and its pure-Python wrapper before signing.
It also removes the unused `_tkinter.so`, whose Tcl/Tk libraries are not part
of the slim runtime.

`Tools/AuditDistribution.sh` blocks archives that contain either extension,
contain the `GNU gdbm` marker, or omit required license files.

## Verification performed

- 104 Swift unit tests passed.
- 153 Python backend tests passed.
- Release archive compiled for arm64.
- Deep code-signature verification passed.
- The main app and Python helper carry the expected sandbox entitlements.
- The bundled backend launched successfully inside the sandbox.
- App Store package validation succeeded before upload.
- The exact bundled Python dependency set reported no known vulnerabilities
  using `pip-audit`.
- Build 9 passed the archive distribution audit, deep signature verification,
  entitlement inspection, and App Store package validation.
- The existing complete macOS icon set was compiled as `AppIcon.icns` and
  included in the uploaded build for App Store Connect.
- Build 9 uploaded successfully with no delivery errors.

## TestFlight

Build 9 completed processing and was added to the manual internal group
**Locus Internal Testers**. Automatic distribution is disabled so the
superseded Build 8 cannot be distributed accidentally.

The group has one active macOS build, `1.6.0 (9)`, and three internal testers
(two SparkTales accounts and one external collaborator). The addresses are in
App Store Connect rather than here — this repository is open source, and
publishing people's email addresses is not ours to do.

App Store Connect reports Build 9 as **Testing**, expiring in 90 days. Build 8
was not added to the group.

## Repository and ownership follow-up

The repository is private but currently owned by the personal GitHub user
`nahid-sparktales`, with Nahid as its only administrator. SparkTales should:

1. Confirm that Nahid's employment or contractor agreement assigns all Locus
   code, artwork, and documentation to SparkTales.
2. Transfer the repository to the SparkTales GitHub organization.
3. Protect `main` and require pull-request review.
4. Preserve this release record and third-party notices with future builds.

## App Store Connect work still required

- Product screenshots
- Description, keywords, and support URL
- App privacy and age-rating answers
- Pricing and availability
- App Review contact information and notes
- Selection of the processed replacement build

The version remains configured for manual release. No submission to App
Review or public release was performed.

## 1.7.0 (10) upload — 2026-07-29 evening

Marketing version 1.7.0, build 10, was uploaded to App Store Connect at
19:30 EDT on July 29, 2026 and processed to state **VALID**. The archive
that produced the uploaded package is kept at
`artifacts/appstore/uploaded-2026-07-29-1930/Locus-1.7.0-10.xcarchive`; a
same-source rebuild at `artifacts/appstore/Locus-1.7.0-10.xcarchive` passed
the distribution audit and deep code-signature verification
(`io.sparktales.locus`, team `4X4RJA7GMD`).

- 121 Swift unit tests and 153 Python backend tests passed before the
  archive.
- The release script's default ASC key path was corrected to
  `SparkTales_Master/api-keys`; the previous StoryBook2 location no longer
  exists, which is what interrupted the first export run.
- Build 10 is not yet assigned to the **Locus Internal Testers** TestFlight
  group and has not been submitted for review.

## 1.8.0 (11) upload — 2026-07-31

Marketing version 1.8.0, build 11, was uploaded to App Store Connect at
09:05 PDT on July 31, 2026 and processed to state **VALID**. Built from clean
source revision `f5e57fd`; the archive is at
`artifacts/appstore/Locus-1.8.0-11.xcarchive`.

- 160 Swift unit tests and 202 Python backend tests passed before the archive.
- Build 11 is attached to App Store version 1.8.0, which closes the "selection
  of the processed replacement build" item listed above.
- The export emits `Upload Symbols Failed` warnings for the bundled Python
  runtime's prebuilt binaries (`python3.14`, `libpython3.14.dylib`, and the C
  extension modules), which ship without dSYMs. These affect crash
  symbolication for those components only and do not fail the upload.
- Version 1.8.0 remains in `PREPARE_FOR_SUBMISSION` with `releaseType: MANUAL`.
  It has **not** been submitted for review: description, keywords, screenshots,
  and the age-rating declaration are all still empty.

## Developer ID notarization — resolved 2026-08-03

**Outcome: all submissions were Accepted.** The delay below was Apple-side queue
latency, not a defect in the build, the signing, or the account. Nothing was
changed to fix it and no support case was filed; the queue drained on its own
after roughly three days, and the three submissions that had appeared stuck all
completed as `Accepted`. A fourth submission made the same afternoon
(`2cd1fce1-0da7-4465-b00f-3a9fa199321f`, 1.9.0 build 13) was accepted in about
two minutes, stapled, and verified: `spctl --assess` reports `accepted` with
`source=Notarized Developer ID`, and `stapler validate` passes on a fresh
extraction. That is the project's first publishable notarized release.

Keep the record below: a submission sitting `In Progress` for days with no log
is not evidence of a broken build, and the reflex to resubmit or escalate was
the wrong one.

### What the delay looked like

The direct-download channel had not completed a notarization. Three
submissions sat `In Progress` with no submission log produced:

| Submission | Created (UTC) | Source |
|---|---|---|
| `3cc83fa3-972a-4301-842c-1d3c223d85ec` | 2026-07-30 20:11 | 1.8.0 |
| `303ceda7-a0e8-4bd2-8124-14cbdfcb5d0c` | 2026-07-31 16:00 | 1.8.0 (`f5e57fd`) |
| `5970d664-8a42-4c9c-9673-bbf456346e9e` | 2026-08-03 04:10 | 1.8.0 (`8e91939`) |

The third was submitted deliberately as a control: a different source revision,
independently signed, with a changed bundled-dependency set and a different
SHA-256. It stalled identically, which correctly ruled out the binary — the
control was sound, but the conclusion drawn from it (that something was wrong
with the account) was not. All three were simply queued.

Apple's system status page reported Developer ID Notary Service as operational
throughout, which in hindsight was accurate.

Two things to carry forward:

1. `PackageRelease.sh` exits 1 on the `notarytool --wait` timeout **before**
   stapling, so a timed-out run leaves a signed, seal-verified zip with no
   ticket in `artifacts/direct/`. That is not a public release. Re-running the
   script resubmits from scratch; `xcrun notarytool info <id>` on the existing
   submission is the cheaper check.
2. The Gatekeeper assessment in that script had hardcoded `/usr/bin/spctl`,
   which does not exist — `spctl` is in `/usr/sbin`. It reported the missing
   binary as "Gatekeeper rejected the packaged app". The bug had been
   unreachable because no submission had ever been accepted, and it fired on
   the first one that was. Fixed.

## 1.9.0 (12) — 2026-08-03

`project.yml` was bumped to marketing version 1.9.0, build 12, and the
CHANGELOG's `Unreleased` section rolled into a `1.9.0` entry covering local
runtime supervision, the compact launch size, and the permission-panel
background, alongside the context-meter fixes. LangGraph runtime work that was
merged and then reverted on main is deliberately absent from the release notes.

- 176 Swift unit tests and 222 Python backend tests passed before the build.

## 1.9.0 (13) — 2026-08-03

Build 13 carries the fixes from the audit of `8262018` (commit `d68062d`) and
supersedes build 12, which was already `VALID` on App Store Connect and so
could not be reused.

- Uploaded 12:24 PDT 2026-08-03, processed to **VALID**. Archive at
  `artifacts/appstore/Locus-1.9.0-13.xcarchive`.
- Built from clean source `0c052bb`; 227 Python and 175 Swift tests passed.
- **Notarized and stapled** as submission
  `2cd1fce1-0da7-4465-b00f-3a9fa199321f`. `artifacts/direct/Locus-1.9.0.zip`
  passes `codesign --verify --deep --strict`, `spctl --assess --type execute`
  (`accepted`, `source=Notarized Developer ID`), and `stapler validate` on a
  fresh extraction. This is the first archive that satisfies the README's
  public-release rule.
- The App Store version record is 1.9.0 in `PREPARE_FOR_SUBMISSION`,
  `releaseType: MANUAL`. Description, keywords, screenshots and the age-rating
  declaration are still empty, so it cannot be submitted for review yet.
