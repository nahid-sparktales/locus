# Your companion — implementation and verification

This work extends the existing Getting Started sheet, saved `AgentProfile` owner,
portrait storage, profile-bound conversations, activity catalogs and connection UI.
It does not add a chat engine, scheduler, permissions store, memory store or Agent
World dependency. The later v4 release request also includes the existing memory and runtime
changes; their package and release validation is tracked separately.

## Delivered source

- Presentation and identity: `Locus/CompanionAppearance.swift`,
  `CompanionOnboarding.swift`, `CompanionCharacterView.swift`,
  `CompanionSpriteView.swift`, `CompanionSetupView.swift`,
  `CompanionSidebarEntry.swift`, `CompanionCustomCharacterPicker.swift`,
  `CompanionActivitySummary.swift`, and `CompanionActivityPresentation.swift`.
- Existing integration surfaces: `Locus/OnboardingModel.swift`,
  `OnboardingView.swift`, `AppModel+Onboarding.swift`, `AppModel.swift`,
  `AppModel+UITestFixtures.swift`, `AgentTeamsModel.swift`,
  `AgentTeamsSettingsView.swift`, `AgentPicturePicker.swift`,
  `SavedAgentInspectorView.swift`, `AgentManagementPresentation.swift`,
  `ActivityCenterModel.swift`, `AppFeatureEnvironment.swift`, `LocusApp.swift`,
  `LocusSharedPresentations.swift`, `SessionSidebarView.swift`, `WorkspaceView.swift`,
  and `AgentWorldView.swift`.
- Generation endpoint: `agent/ollama_code/api/portrait_preview.py`, existing
  `api/providers.py`, `image_generation.py`, and `agent/tests/fixtures/server-routes.txt`.
- Artwork: `Locus/Resources/Companions/{Pitou,Gon,Ninja,Clover,Shadow,Pirate}.png`;
  deterministic atlas preparation: `Tools/PrepareCompanionAtlases.py`.
- Tests: `LocusTests/Companion{Appearance,Persistence,Integration,ActivitySummary,Visibility,Sprite}Tests.swift`,
  `LocusUITests/CompanionOnboardingUITests.swift`, updated
  `LocusUITests/LibraryOnboardingUITests.swift`, and `agent/tests/test_portrait_preview.py`.
- Guides: `Docs/YourCompanion.md`, `CompanionArtwork.md`,
  `CompanionGenerationPrompts.md`, this report, and `LibraryAndGettingStarted.md`.
- `Locus.xcodeproj/project.pbxproj` is regenerated from the existing `project.yml`
  source/resource globs. No new SDK or deployment-target requirement is introduced.

## Test environment and commands

Verified on macOS with Xcode 26.6 and Swift 6.3.3. The application continues to
target macOS 14 in Swift 5.10 mode. Test artifacts are in
`/tmp/locus-companion-verification` on the development machine.

```sh
xcodegen generate
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/locus-companion-build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= LOCUS_BUNDLE_MODE=skip build-for-testing
```

Native test selection covers the six new companion suites plus existing
`OnboardingModelTests`, `SavedAgentTests`, `AgentOverviewTests`,
`ActivityCenterModelTests`, `ImageGenerationSettingsTests`, and `AgentWorldTests`.
It uses the same xcodebuild arguments with `test` and one
`-only-testing:LocusTests/<Suite>` argument per suite.

The final asset-inclusive native regression run passed **235 tests with zero
failures**. All seven sprite tests and 21 persistence tests passed. Evidence:
`pitou-unit.log` and `pitou-unit.xcresult`. Earlier broad and focused runs also
passed, but are not counted again in this total.

After the visual thumbnail/label adjustments, **68 focused companion/onboarding
tests passed** (`pitou-final-focused.log`). Final Locus `build-for-testing` and
unsigned LocusX `build` also passed after provider-disclosure text wrapping was
corrected (`pitou-final-build.log`, `pitou-final-locusx-build.log`).

The last UI-test assertion was adjusted for macOS combining adjacent static text
into one accessibility element. The final test file passed a separate type check:

```sh
xcrun swiftc -typecheck \
  -I /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib \
  -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
  LocusUITests/CompanionOnboardingUITests.swift
```

Two redundant build attempts after that test-only edit stalled at Swift Package
Manager's `Resolve Package Graph` and were stopped. The application source had
already passed the final builds above; the test-file type check passed with the
XCTest Swift overlay search path supplied.

```sh
cd agent
.venv/bin/python -m pytest tests/test_portrait_preview.py \
  tests/test_image_generation.py tests/test_app_factory.py -q
```

The backend run passed **72 tests**, with no live provider requests.
`git diff --check` passed during implementation.

Locus Debug native test build and LocusX Debug unsigned `build` both passed with
the final sprite additions. LocusX evidence: `pitou-locusx-build.log`; source compilation used
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`. An ad-hoc signed LocusX build
was blocked by existing wallet entitlements requiring a development certificate;
this is not signed-distribution verification.

## Boundaries of the evidence

XCTest UI execution was attempted, but the runner could not enable macOS automation:
`Timed out while enabling automation mode`; testmanagerd reported that authentication
was required. **No XCTest UI test was executed.** Security/automation settings were
not changed. The test sources compile with the native test target.

Native visual inspection uses a separately identified in-memory fixture build,
with `LOCUS_UI_TESTING`, `LOCUS_UI_TESTING_FIRST_LAUNCH`, and
`LOCUS_UI_TESTING_COMPANION_OFFLINE` set to `1`. It neither accesses real saved
profiles nor represents a live model/provider integration. See the feature guide
for safe fresh-install inspection; never delete production defaults to test setup.

Native computer-use inspection verified the Pitou welcome, all six animated gallery
choices and their crossover descriptions, immediate character selection, unavailable
generation with import still available, cancellation retaining Ninja, Unicode draft
`Pitou ピトー` retained across Escape/resume, and offline Start opening Pitou’s
normal agent Overview. The overview showed exactly one agent, zero chats, no
automations, read-only access, matching sidebar/profile/picker artwork, and the
connect-model notice. These are fixture observations, not a live chat result.
Changing the profile artwork to Clover retained the same stable agent ID and
read-only/no-chat/no-automation state; Pitou was restored afterward. Final native
inspection also confirmed the larger crossover thumbnails and fully wrapped
offline account/generation disclosures.
The existing procedural-character UI was also inspected earlier. Atlas review
covers all selected animation frames on white and dark backgrounds.

Saved artwork previews: [light/dark](Assets/YourCompanion/companions-light-dark-160.png)
and [animation](Assets/YourCompanion/companions-all-motion.gif). These are character
contact sheets, not app screenshots; native app screenshots were captured inline
during computer-use verification.

Live image-provider cancellation/rate limits and real configured-model conversation
round trips remain unverified. Automated tests cover routing boundaries, error
paths and state derivation, but they are not live provider evidence. Full VoiceOver
interaction, signed distribution and prolonged multi-window performance remain
manual acceptance work. Native visibility lifecycle tests exercise observer cleanup.

Pitou preserves the supplied sprite bytes. Generated variants retain their nine
standard animation rows; unverified generated look-direction rows are excluded.
The app does not implement a draggable desktop pet or cursor-following look poses,
and does not claim undocumented ChatGPT timing or screen parity.

## v4 release preflight

The combined source was exercised with the complete `LocusTests` target on
2026-10-05: 1,893 tests passed, one source-observation boundary test failed,
and one transcript selection test exited on SIGTERM. The observation accesses
were moved to the observed feature owner and the existing AppModel action
boundary. The six companion suites, observation-boundary suite, and complete
transcript relayout suite were then rerun: **85 passed, zero failures**, including
both previously failing tests (`/tmp/locus-v4-verification/native-rerun.xcresult`).

The release preflight also passes the design-system audit without changing its
baseline, the transport-security audit, protocol manifest verification, shared
iOS wire-type compilation, shell-script syntax checks, Agent World package
verification, Python Ruff, and staged secret scanning. Historical source patches
retain exact context whitespace and provenance hashes. The new memory guard is
explicitly Developer ID signed and timestamped by the release packager before
the enclosing app is sealed.

The publication build uses version 4.0.0 (36), the existing standard `Locus`
Release scheme, the full bundled runtime, and the existing notarization and
signed Sparkle feed process. Compile-only builds with `LOCUS_BUNDLE_MODE=skip`
are not installable release evidence. Packaging logs and release artifacts are
kept outside the source tree in `/tmp/locus-v4-verification` and
`/tmp/locus-v4-release`.
