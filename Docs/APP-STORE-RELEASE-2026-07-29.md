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

The group has one active macOS build, `1.6.0 (9)`, and these three internal
testers:

- `nahid@sparktales.io`
- `andrew@sparktales.io`
- `andrew@ainvr.com`

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
