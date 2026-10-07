# Your companion

The ten persistent-assistant features are implemented. After integration with
automatic memory and retrieval, the native build and **2,043 native tests passed
with two environment-related skips and zero failures**. The backend passed
**3,652 tests and 31 subtests**. All **12 Companion UI cases** passed before the
integration, and **three targeted UI cases** passed on the combined code.
Actual microphone capture, macOS Screen
Recording permission flows, and live provider calls were not exercised.
See [the implementation and validation record](CompanionImplementationPlan.md).

The verification totals below describe earlier Companion changes and do not
replace the current delivery record.

See [verification and changed-file inventory](YourCompanionVerification.md) for
the original launch checks, and [Companion panel verification](CompanionTabVerification.md)
for the right-panel correction, Scout, cursor reactions, and remaining manual checks.
The full run passed 1,966 native tests and seven companion UI cases, with one
explicit notch-related UI skip and zero failures. The subsequent
[combined extraction CI](https://github.com/nahid-sparktales/locus/actions/runs/37501986653)
passed all 432 Locus and LocusX UI tests, including actual menu-popover dismissal,
reopening, draft preservation, and opening the main window, with no skips or retries.
A later pointer guard's focused rerun had 13 passes
and one explicit hosted-window skip, with zero failures; the full-suite result
predates that guard change. The verification record includes fresh light/dark
captures of the latest local build using isolated fixture data.

Your companion is a saved Locus agent with a recognizable character. First-launch
Getting Started introduces it, offers six bundled animated characters, and asks
for its name. **Surprise me** locally selects one of those same six characters;
it does not generate new artwork or make a model request.
Fresh drafts start with **Pitou** as both character and editable name. Each new
character choice offers its own suggested name and starting communication style.
Untouched suggestions follow your choice; a name or personality you edit stays
yours, including after reopening setup. Existing drafts retain saved names when
their original authorship is unknown, and saved agents keep their name and appearance.
Setup and the profile's
**Characters** gallery offer only Pitou, Scout, Ninja, Clover, Shadow, and Pirate.
There is no Originals collection or accent/accessory control. Older procedural and
Gon appearances still load, and a saved custom picture stays selected until an
explicit change. The separate static portrait library, image import, and generation
remain available through the existing picture picker.
Names accept Unicode, trim surrounding whitespace,
and reject control characters and names longer than 64 characters without truncation.

| Companion | Starting personality | Traits |
| --- | --- | --- |
| Pitou | Thoughtful companion | Warm, curious, attentive |
| Scout | Curious explorer | Upbeat, observant, inquisitive |
| Ninja | Focused problem-solver | Precise, composed, methodical |
| Clover | Resourceful builder | Optimistic, inventive, persistent |
| Shadow | Calm strategist | Analytical, patient, deliberate |
| Pirate | Adventurous collaborator | Playful, bold, adaptable |

The **Personality** field on the naming step contains editable instructions that
are saved in the normal agent profile when you finish setup. These are starting
styles, not different models or tool permissions. Linking an existing agent or
changing a saved agent's picture leaves its instructions intact. Edit that saved
personality through the existing profile controls whenever you want to change it.

**Start with [Name]** saves the identity and opens the normal companion conversation
in the main composer when the runtime is available. Offline setup still saves the
identity and explains that a model must be connected before chatting. Existing model
connection controls remain available. **Explore Locus** continues the existing
Getting Started document, coding, and recurring-agent paths. Saving, previewing,
and naming do not send a message, start a task, grant permissions, activate
schedules, or call a model.

The left **Agent** and **Work** modes remain unchanged; there is no third segmented
Companion mode. The **Companion** row above **Manage Accounts** opens the saved
agent's one ongoing conversation in the **main composer**, with the character
horizontally centered at the top of the chat, including an empty conversation.
The main-chat character is 80 points and stays above existing messages. The same remembered chat
is used regardless of the selected project.
When none exists and the runtime is available, this explicit click creates one
empty canonical conversation. Normal switching rules protect active work and
approvals; a late creation cannot take over a newer chat, project, or profile.
Opening a conversation does not send a message.

The **Companion button in the right rail** opens the side-panel inspector alongside
the current workspace. Opening or closing that panel leaves the central conversation,
composer draft, active work, and pending approvals in place. Main-chat navigation
and side-panel presentation use the same saved identity and conversation.

The panel uses the same canonical saved-agent profile and normal folder-bound
conversation records. Sending and queueing a message use the existing background
worker and queued-chat path, with the companion's saved model, instructions,
permissions, and real task state. It does not introduce a second chat engine or
an autonomous controller. Opening the panel does not send a message; creating an
empty conversation and starting work remain explicit actions. The companion draft
is separate from the central draft and stays bound to its conversation and folder.
Switching the central project does not change the companion’s conversation or folder.
Late load or creation results retain their captured ownership. If the companion
conversation is also open in the central workspace, the panel presents it read-only
and points to the main composer, so two editors do not compete for one draft.
**Clear chat** starts a fresh companion conversation and archives the previous one;
active work and pending approvals must finish first. Older conversations remain
recoverable in saved-agent history. There is no companion conversation picker or
new-chat button. **Open full
conversation** is the explicit route to the existing advanced composer, attachments,
and approval controls; it intentionally selects that chat in the central workspace.
Interactive tool views and image editing also use that full conversation.

The panel shows an 80-point character, horizontally centered at the top above the
conversation, including when the chat is empty. Open the
existing profile and Overview controls through **Companion options → Profile and
activity**. The same shared avatar appears in the agent picker and profile. Rename and change its picture
through those existing profile controls. Disabling character animation affects only
presentation. Removing an agent remains the separate confirmed deletion action. Changing
appearance or model does not create a new identity, move conversations, or change
access settings. Runtime/model availability and errors remain explicit; opening an
offline panel does not imply a successful connection or fabricated reply.

## Chat from the menu bar

The Locus button in the macOS menu bar opens a native popover with **Chat** and
**Activity**. Chat presents the same companion panel, canonical conversation, and
session-bound draft as the right inspector. It uses the existing background worker
and queue when you explicitly send. Showing the popover does not create a
conversation, submit a message, or start a task. Close or Escape dismisses the
popover while keeping the draft. If the selected chat is already open centrally,
the same read-only rule prevents competing editors.

Activity presents the companion's requests and unread results from the existing
Activity Center, scoped to its saved identity and chosen folder. An unresolved
request remains actionable independently of read status. The popover does not
introduce another notification store or enable system notifications. Profile,
approval/recovery, and full-conversation actions reveal the main window and use
their existing surfaces. **Open Locus** only reveals that window; it does not
switch its conversation or discard either draft. Native activity/filtering tests
and earlier hosted CI checks for popover clicking, typing, Escape, Close, draft
preservation, and reopening after closing the main window passed. For that earlier
menu-bar change, local XCTest automation could not initialize on the development
host; its interaction evidence came from CI. The current feature pass has its own
validation record above.

## Your companion's folder

Unless you explicitly choose another folder, the companion uses its existing saved
agent home:

```text
~/Library/Application Support/Locus/AgentHomes/<profile-uuid>/Workspace
```

`<profile-uuid>` is the stable agent ID in lowercase, not the display name. LocusX
uses its separate `Application Support/LocusX` root. Renaming the companion,
changing its character or model, reopening Locus, or selecting another central
project does not select a different default folder. The home is created lazily by
the existing workspace preparation API when an explicit action needs it; merely
reading the preference does not create a folder or scan its contents.

The right panel displays the current conversation's folder. Edit the companion's
workspace preference through its profile to choose the folder used for its first
chat or after clearing. That preference does not switch to another conversation or
change the current chat's folder.

Folder selection affects subsequent companion chat creation. It does
not move or rewrite existing conversations, files, drafts, tasks, or queued requests.
Each keeps its original execution folder. A missing explicit folder produces an
error rather than a silent fallback. Existing home validation rejects redirected
home symlinks and another agent's private home. The companion's folder is a working
location, not an extra permission grant or a claim that its existing tools are
sandboxed to that folder. File links use the conversation's actual execution
folder, which may be a task folder within the chosen workspace. A file from a
different folder opens in the existing viewer without replacing the central Files
browser or adding it to the central chat's context. Document previews use their
own workspace; an explicit Show Files action can reveal the companion folder in
Finder while leaving the central project selected.

## Resume and upgrade behavior

The existing `OnboardingModel` owns this chapter and the Getting Started sheet.
There is no second onboarding coordinator. The automatic offer is remembered before
the sheet opens. **Not now**, Escape, sheet closure, and a quit during setup retain
the selected draft without creating an agent. Return through **Help → Getting
Started**, click the left **Companion** row when no companion is configured, or
open the right-rail Companion panel and choose **Set up your companion**. Existing
installations receive an opt-in entry; missing new presentation fields never force an upgrade wizard.
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
| Draft name, name-edit tracking, optional custom personality, reserved UUID, chosen appearance, temporary approved draft pixels, step and completion link | Existing `OnboardingModel.Progress`, `Locus.onboarding.v1`; the payload version is 2 with backward-compatible optional draft fields |
| Explicit companion folder choice | Existing `AgentProfile.workspacePreferences.defaultProjectPath`; absent means the stable edition-scoped Agent home |
| Panel selection, loading, error, and presentation mode | `CompanionPanelModel`; presentation only, with no profile or execution database |
| Companion drafts and loaded transcript blocks | Existing `paneDraft`/`setPaneDraft` and `splitPaneBlocks`, keyed by the normal session identity |
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

The standard workspace now uses neutral light and dark surfaces: near-white and
white in light appearance, charcoal and gray in dark appearance. Text uses neutral
ink tones; saved accents, character artwork, logos, and optional World/deck themes
keep their intentional colours. The companion follows the same native palette as
the rest of Locus. See [Colour palette](ColourPalette.md) for exact values,
source-derived contrast measurements and executed native theme checks. Current
light/dark fixture captures are in the [verification record](CompanionTabVerification.md#native-ui-inspection-and-screenshots).

The six offered animated characters use local sprite assets. Native SwiftUI Canvas
paths and gradients retain support for previously saved procedural appearances
and the internal visual fallback; they are no longer offered as new choices.
Both renderers support the existing macOS 14 deployment target and require no
download, provider, or Agent World installation.
See [artwork provenance and input limits](CompanionArtwork.md).
Reduce Motion, the animation preference, scene inactivity, and view disappearance
disable or stop the cancellable animation task. Static text/status equivalents remain.
Imported/generated pictures receive honest whole-image motion, never face rigging.
Idle bundled characters in the right tab react only while the pointer is inside
that tab. Main-chat, menu-bar, desktop, gallery and profile characters do not
track the pointer. The app-local listener also requires its own key window and
enabled, visible tracking; it does not separately require the whole app to be active.
Playback holds discrete poses on an eight-frame-per-second cadence: each source
frame lasts one or more 125 ms ticks, with quiet idle/waiting holds and brief
greetings and completion reactions. Legacy procedural appearances use held key poses too;
static art receives only snapped whole-image movement. There are no eased glides.
The existing painted character assets remain unchanged by this motion adjustment.
The renderer measures each atlas's visible bounds once and uses a shared scale and
baseline for every pose. All seven supported sprites, including saved Gon, have
a resting silhouette height of 78% of their square view while preserving the
whole animation inside its safety inset. This is 34.32 points in a 44-point view
and 140.4 points in a 180-point view. Native sizing/bounds tests passed; no artwork
was redrawn. See [artwork sizing](CompanionArtwork.md#consistent-displayed-size).
See [pointer reactions](CompanionPointerReactions.md) for motion, status-priority,
privacy, and lifecycle rules. Scout combines My Hero Academia and Hunter x Hunter
influences and replaces Gon in the new-selection gallery. Existing Gon appearances
remain loadable and receive the same corrected display scale as the other earlier
generated sprites; updating the gallery does not silently replace saved artwork.

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
The primary companion's summary follows its chosen folder, independently of the
central project. Other saved agents retain their existing foreground-project
summary scope. A known canonical session's owner and folder take precedence over
conflicting run metadata; only a run missing from the recent session catalog may
use its recorded profile and workspace as a fallback.
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
  `Locus/SavedAgentInspectorView.swift`: sprite and legacy fallback renderers, approved catalog and shared
  profile image handling.
- `Locus/CompanionPanelModel.swift`, `Locus/CompanionInspectorTab.swift`, and
  `Locus/AppModel+CompanionNavigation.swift`: right-panel presentation and project-bound
  conversation selection. `openCompanionMainConversation` handles the left shortcut
  through normal central session routing; the right rail selects the inspector.
  `selectCompanionWorkspace` saves an explicit choice through existing profile
  workspace preferences; `AppModel+SavedAgents.swift` owns home paths and validation.
  Existing `paneDraft`/`setPaneDraft` and `splitPaneBlocks`
  hold drafts and transcript blocks. Canonical saved-agent conversation creation and
  the native `sendAgentWorldTurn` worker/admission queue handle explicit work; that
  native path is independent of the optional Agent World plugin. Panel navigation
  does not replace the central transcript selection. `conversationWorkspacePath`
  supplies the actual execution folder for file/output rendering while the selected
  root remains the conversation-binding scope. Interactive MCP views and their
  foreground tool-result fetches are deferred to the full conversation.
- `Locus/CompanionSidebarEntry.swift`, `Locus/InspectorRail.swift`, and
  `Locus/CompanionActivitySummary.swift`: main-chat shortcut, separate inspector
  entry, and presentation of authoritative activity.
- `Locus/CompanionMenuBarView.swift` and `Locus/LocusApp.swift`: the native
  `MenuBarExtra` window-style popover and main window presenter. Quick chat reuses `CompanionInspectorTab` and
  `CompanionPanelModel`; menu activity reuses the existing Activity Center records
  and the shared canonical owner/folder predicate.
- `Locus/CompanionCustomCharacterPicker.swift`,
  `agent/ollama_code/api/portrait_preview.py`, and the existing
  `agent/ollama_code/image_generation.py`: explicit generation/import preview.
- `LocusTests/CompanionPersistenceTests.swift`, `CompanionAppearanceTests.swift`,
  `CompanionActivitySummaryTests.swift`, `CompanionIntegrationTests.swift`,
  `CompanionPanelTests.swift`, `CompanionInspectorNavigationTests.swift`,
  `CompanionMotionTests.swift`,
  `LocusTests/SavedAgentTests.swift`, `LocusUITests/CompanionOnboardingUITests.swift`,
  and `LibraryOnboardingUITests.swift`: recovery, boundary, rendering-input, status,
  project routing, draft/approval preservation, asynchronous selection, and UI coverage.
- `Locus/AppModel+UITestFixtures.swift` and the fixture transport selection in
  `Locus/AppModel.swift`: opt-in, in-process companion navigation fixture.

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

The separate companion-chat fixture is intended for inspecting the configured
profile and project-bound conversation without a provider:

```text
LOCUS_UI_TESTING=1
LOCUS_UI_TESTING_FIRST_LAUNCH=0
LOCUS_UI_TESTING_COMPANION_OFFLINE=0
LOCUS_UI_TESTING_COMPANION_CHAT=1
```

Its two empty conversations in `/tmp` are **Companion UI fixture** and **Work UI
fixture**, owned by the normal session/profile stores. Work remains in the central
workspace while Companion opens in the right inspector. Type different unsent
drafts in the two editors, close/reopen the panel, and verify each retains its own
text. The fixture deliberately rejects submitted work with a visible error; it does
not connect a provider or generate an AI reply. Runtime availability is simulated.
Remove the companion-chat flag before returning to other fixture scenarios.

The earlier completed full run passed **1,966 native tests** and **seven companion UI
cases**, with **one explicit UI skip**, zero failures, and `xcodebuild` exit 0.
It covers folder/output isolation, sizing, palette, gallery, activity, and menu
activity. The Python suite passed **3,083 tests plus 31 subtests**. Actual menu
interaction is the notch-related skip and remains unverified locally. A later
pointer guard is not covered by those full-suite totals; its focused rerun passed
13 cases and explicitly skipped hosted event delivery because the fixture could
not activate, with zero failures. That hosted case passed before the guard change.
Earlier isolated host/UI interruptions passed unchanged
on retry and are not outstanding acceptance failures.
See [the verification record](CompanionTabVerification.md) for final status, commands,
evidence, static-layout screenshots, and the remaining live-provider/manual limits.

Durable restoration and interrupted-commit tests use unique injected UserDefaults
suites in `CompanionPersistenceTests` and remove only those test domains afterward.
Live-provider conversation and generation, real permission/approval flows, physical
cursor interaction, VoiceOver use, signed distribution, and the latest LocusX build
remain unverified in this follow-up. Renderer tracking and observer teardown have
native test coverage; that is separate from manual resource profiling.


## Persistent assistant tools

Open **Companion tools** from the character or the right-tab options menu.
The tools share the current Companion conversation, including when it is open on
the desktop. The main-chat and right-tab characters are 80 points and stay
horizontally centered at the top, including when their conversation is empty.

- **Share**: choose pasted text/error, files, the current Locus browser page, the
  last active application, or a screenshot region. Review the captured contents,
  attach them, and send a message. Chips remain visible beside the composer and
  are removed only after accepted delivery. These snapshots grant no app control.
- **Catch up**: read the latest saved request, decisions, recorded task progress
  and verification. Conversation excerpts remain explicitly unverified. Resume
  uses the task's existing controls; source/review opens the saved conversation
  or task inspector.
- **Activity**: review grouped requests/results, choose event sources, snooze an
  update, and set local quiet hours. Snooze never approves a request or marks a
  result read.
- **Memory**: type “Remember that…” to prepare a memory, review its scope and
  confirm. Inspect sources and update times, edit, forget or approve candidates.
  Scope changes use existing create/forget APIs with rollback if forgetting
  fails; after an interrupted change, refresh and review both records.
- **Focus**: agree a deliverable, duration and checkpoints for focus or learning.
  Record evidence as you progress. Learning has explicit explanation, exercise,
  hint and answer steps. The timer offers a check-in; it never dispatches work.
  Finishing records user-reported progress, not independent verification.
- **Handoffs**: in Work mode, Companion can use the existing specialist runtime.
  Cards show recorded task input, tool declarations, status, results, evidence
  and uncertainties. “Explain results” asks Companion to synthesize these records.
  Stop work ends the Companion turn; supported team branches use existing branch
  cancellation. Historical input may be unavailable. Hosted previews identify the
  approved orchestrator input; they do not claim to expose internal worker prompts.
- **Guide**: follow actual highlighted controls for MCP setup, recurring agents
  or waiting work. You still choose what to save and permit. Errors stop
  highlighting; a status banner keeps the explanation and **Stop guidance** visible
  in MCP and schedule setup.
- **Character**: import a validated [animation pack](CompanionAnimationPacks.md),
  edit the profile, or show the desktop Companion.

The **desktop Companion** is a movable native window. Click the character to open
its compact chat, drag near an edge to snap, and use its options for size and
always-on-top. **Control–Option–Command–C** shows/hides it when that shortcut is
available. Desktop sizing starts at 80 points, offers 64/80/112/144-point presets,
and is independent of the main chat and right tab.
Hiding the window preserves the conversation and draft and never cancels work.

**Talk with companion** uses the configured voice engine. Push-to-talk makes
recording visible; interruption stops playback. Voice and approved context stay
bound to the Companion session even while a different central chat is selected.
Recognition/playback failures use the existing voice settings and error states.
Real microphone and Screen Recording access remain native macOS permissions.
