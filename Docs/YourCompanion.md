# Your companion

See [verification and changed-file inventory](YourCompanionVerification.md) for
executed checks and remaining manual acceptance work.

Your companion is a saved Locus agent with a recognizable character. First-launch
Getting Started introduces it, offers six bundled animated characters, lets you
choose an accent/accessory or local **Surprise me** variation, and asks for its name.
Fresh drafts start with **Pitou** as both character and editable name. Existing drafts
and agents retain their saved name and appearance. **Characters** contains Pitou, Gon,
Ninja, Clover, Shadow, and Pirate; **Originals** contains the six procedural characters
with accent/accessory controls. Bundled sprites have no unsupported recoloring controls.
Names accept Unicode, trim surrounding whitespace,
and reject control characters and names longer than 64 characters without truncation.

**Start with [Name]** saves the identity and opens the normal saved-agent entry;
when the runtime is available it continues or creates a normal profile-bound chat.
Without a usable model the identity still saves and the existing model connection
controls remain available. **Explore Locus** continues the existing Getting Started
document, coding, and recurring-agent paths. Saving, previewing, and naming do not
send a message, start a task, grant permissions, activate schedules, or call a model.

The sidebar entry opens the existing agent Overview. The same shared avatar appears
in the agent picker, profile, and conversation header. Rename and change its picture
through the existing profile controls. Disabling character animation affects only
presentation. Removing an agent remains the separate confirmed deletion action.
Conversations keep the existing global profile ID and project-scoped session binding;
changing appearance or model does not create a new identity.

## Resume and upgrade behavior

The existing `OnboardingModel` owns this chapter and the Getting Started sheet.
There is no second onboarding coordinator. The automatic offer is remembered before
the sheet opens. **Not now**, Escape, sheet closure, and a quit during setup retain
the selected draft without creating an agent. Return through **Help → Getting
Started** or **Set up your companion** in the sidebar. Existing installations receive
an opt-in entry; missing new presentation fields never force an upgrade wizard.
Existing agents are linked only by explicit selection, retaining their name, picture,
instructions, account, model, access, and conversation bindings.

The main window and optional Agent World window share the existing presentation-owner
mechanism. Main-actor offer claiming additionally checks persisted progress so two
model instances using the same defaults cannot automatically offer it twice.

## Ownership and persistence

| Data | Canonical owner and persistence |
| --- | --- |
| Stable identity, name, instructions, model, access, memory policies | Existing `AgentProfile` in `AgentTeamsModel`, saved by `AgentTeamStore` under `Locus.agentProfiles` |
| Primary companion binding, versioned appearance references, animation preference | `AgentTeamsModel` presentation record, `Locus.AgentProfiles.companionPresentation.v1` |
| Approved custom raster pixels | Existing `AgentTeamsModel.agentAvatarData`, `Locus.AgentProfiles.avatars.v1` |
| Draft name, reserved UUID, chosen appearance, temporary approved draft pixels, step and completion link | Existing `OnboardingModel.Progress`, `Locus.onboarding.v1`; the payload version is now 2 |
| Chats, runs, approvals, schedules, execution scope and permissions | Existing session/runtime stores and APIs; no character-owned execution state |

`Progress.companion` is optional when reading the former payload. Version-1 Getting
Started data retains its selected path, workspace, task receipt, failure and timings;
the new companion chapter migrates to deferred opt-in. The version-1 companion
progress distinguishes `notOffered`, `inProgress`, `deferred`, and `completed`.
An offered introduction is never a completed task or created agent.

The draft reserves a UUID before final confirmation. `commitCompanion` synchronously
records a short-lived creation intent in the presentation record, saves that exact
canonical profile and approved portrait, and finalizes the primary binding. Restart
replays any unfinished intent using the same UUID. A primary binding already committed
by another window wins. Onboarding reconciles that durable binding before it can
create another profile. The intent is removed after saving; approved draft pixels
are cleared from onboarding after completion. Recovery reloads durable profiles,
teams, consent, and portraits before saving, preserving other windows' changes.

Persistence uses the existing injected UserDefaults domain and single-value encoded
replacements. Locus and LocusX remain isolated through their app bundle domains.
Appearance is native presentation metadata, never an `AgentProfile` runtime grant or
system instruction. Unknown/missing artwork falls back visually without changing ID.

## Artwork, custom images and activity

Bundled animated characters use local sprite assets; the six procedural originals use
native SwiftUI Canvas paths and gradients on the existing macOS 14 deployment target.
They require no download, provider, or Agent
World installation. See [artwork provenance and input limits](CompanionArtwork.md).
Reduce Motion, the animation preference, scene inactivity, and view disappearance
disable or stop the cancellable animation task. Static text/status equivalents remain.
Imported/generated pictures receive honest whole-image motion, never face rigging.

**Create your own** uses the configured image-generation account and existing provider
handoff. The picker names the receiving account and discloses usage/possible charges
before **Generate**. It does not assume an ordinary chat account supplies an image API
and does not switch providers on failure. Generation has a cancellable request with
a bounded timeout; retry is explicit. Cancelling can leave provider-side charges for
work already begun. Errors and cancellation retain the previous chosen character.
Only **Use this character** adopts the preview. Import is always available offline;
approved raster data is validated and re-encoded locally before using the portrait
store. Prompts and provider URLs do not become appearance references.

`CompanionActivitySummary` derives execution, outstanding approvals/failures, unread
results, and connection availability from the normal session/run/activity catalogs.
Decorative movement does not claim work is running. Completion reactions consume
unique live completion events; restored history does not replay celebrations. Runtime
and work controls remain in the existing Overview and Activity surfaces. Local
scheduled work continues to require Locus and the Mac to be available unless the user
has separately selected and configured a supported remote environment.

Agent World is optional. The existing native profile bridge continues to use the same
stable ID and conversation binding; a native portrait does not imply a matching 3D
world model. No new world plugin protocol, renderer dependency, editable profile,
remote-access service, or mobile-pairing feature is introduced by this setup.

## Source map and development verification

- `Locus/CompanionSetupView.swift`, `Locus/OnboardingView.swift`, and
  `Locus/AppModel+Onboarding.swift`: coordinated surface and normal saved-agent routing.
- `Locus/CompanionOnboarding.swift`, `Locus/OnboardingModel.swift`, and
  `Locus/AgentTeamsModel.swift`: versioned draft, canonical commit and recovery.
- `Locus/CompanionAppearance.swift`, `Locus/CompanionCharacterView.swift`,
  `Locus/CompanionSpriteView.swift`, `Locus/AgentPicturePicker.swift`, and
  `Locus/SavedAgentInspectorView.swift`: original renderer, approved catalog and shared
  profile image handling.
- `Locus/CompanionSidebarEntry.swift` and `Locus/CompanionActivitySummary.swift`:
  persistent entry and presentation of authoritative activity.
- `Locus/CompanionCustomCharacterPicker.swift`,
  `agent/ollama_code/api/portrait_preview.py`, and the existing
  `agent/ollama_code/image_generation.py`: explicit generation/import preview.
- `LocusTests/CompanionPersistenceTests.swift`, `CompanionAppearanceTests.swift`,
  `CompanionActivitySummaryTests.swift`, `CompanionIntegrationTests.swift`, and
  `LocusUITests/CompanionOnboardingUITests.swift` and `LibraryOnboardingUITests.swift`: focused recovery, boundary,
  rendering-input, status, routing, and UI coverage.

To inspect a fresh first-launch surface without touching real user defaults, set these
environment variables on the Xcode **Locus** Debug scheme's Run action:

```text
LOCUS_UI_TESTING=1
LOCUS_UI_TESTING_FIRST_LAUNCH=1
LOCUS_UI_TESTING_COMPANION_OFFLINE=1
```

This uses the app's in-memory UI fixture mode. Launch a separate development build;
do not delete the real app's defaults or Application Support. The fixture is suitable
for offline appearance/name/skip UI checks and resets its in-memory data on relaunch.
Durable restoration and interrupted-commit tests use unique injected UserDefaults
suites in `CompanionPersistenceTests` and remove only those test domains afterward.
Provider calls, real-model chat routing, signed distribution, VoiceOver interaction,
and resource cleanup should be validated separately against the relevant environment;
the presence of test source alone is not evidence that those checks have run.
