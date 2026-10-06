# Locus native companion differential audit — 2026-10-06

## Executive summary

Reviewed native companion navigation, side-panel ownership, background dispatch integration, file opening, and menu-bar presentation against `b332e455..HEAD`. The new native companion implementation is from `4cce6ebfa` (2026-10-05, “Bring Companion chat to the sidebar, inspector, and menu bar (#133)”).

| Severity | Count |
|---|---:|
| Critical / High | 0 |
| Medium / P2 functional regression | 2 |
| Low | 0 |

Recommendation: fix both P2 regressions and add their missing integration cases. No confirmed cross-project disclosure or wrong-session dispatch in the reviewed new code. This is a focused component report; the parent audit covers build, packaging, removals, runtime, and dependencies.

## Baseline context and invariants

- Saved-agent conversations are ordinary durable sessions associated with an agent UUID. A primary companion adds a profile pointer and presentation; it does not introduce another session store.
- `createSavedAgentConversation` creates a detached session, records the binding, then refreshes the catalog. New companion callers request `preservingForeground: true`, which replaces only the remote session catalog and does not reconcile the center's active transcript/provider/workspace.
- The side panel owns selection/loading state, while `splitPaneBlocks`, `splitPaneDrafts`, `taskWorkers`, and `pendingChatTurns` remain AppModel's canonical stores.
- Read and send preflight must validate the actual session UUID, profile UUID, canonical workspace identity, and archive state. `AgentCrewChatSessionIdentity.matches` supplies this check at `CompanionPanelModel.swift:151-153,223-225`.
- A repository subfolder is a valid logical workspace. Automatic worktree creation may record repository root as `workspace_root`, the checkout as `execution_path`, and selected subfolder as `environment.source_workspace`. The canonical predicate is `SessionSummary.belongsToWorkspace`, which accepts only the exact root or a validated descendant source alias (`Models/SessionModels.swift:161-175`). Baseline commit `4631b3c9b` explicitly added this invariant on 2026-09-14.
- Ordinary saved-agent chats may select a model/account distinct from the owner's defaults. `agentChatProfile(_:sessionID:)` applies that persisted override; actual dispatch resolves it through `agentWorldProfileDispatch`.
- Transcript file links are untrusted. The opening boundary must revalidate path containment and URL equality in the conversation's execution folder.

## Finding N1 — [P2] Companion conversations disappear when their folder is a Git subdirectory

**Primary location:** `Locus/AppModel+CompanionNavigation.swift:48-50`.
**Related location requiring the same fix:** `Locus/CompanionPanelModel.swift:264-265`.
**Introduced:** `4cce6ebfa` (both locations verified by blame).
**Confidence:** High; backend subfolder behavior and actual compiled native selection failure both executed.

`companionChats` requires `session.workspacePath == root`. That bypasses the existing workspace predicate and rejects a valid managed-worktree conversation associated with the user's selected repository subfolder. The panel's incoming catalog validator repeats the same strict equality, so fixing only the history filter still loses selection on catalog refresh.

Concrete scenario:

1. Select an existing Git subfolder, such as `/tmp/project/subproject`, in the companion folder menu (`CompanionInspectorTab.swift:103-116`).
2. Click Start conversation or New companion conversation. `createSavedAgentConversation` requests `execution_environment: automatic` (`AppModel+SavedAgents.swift:392-398`).
3. The backend creates a managed checkout. `agent/ollama_code/agent_workspaces.py:89-97` sets `workspace_root` to `/tmp/project` and records `source_workspace: /tmp/project/subproject`.
4. The backend catalog returns that valid new chat. `companionChats` returns no candidates because `/tmp/project != /tmp/project/subproject`.
5. `CompanionPanelModel.createConversation` calls `select(session)`, whose `chats.contains` guard rejects it (`:130-133,192-196`). The panel returns to the empty conversation state without selecting the chat or reporting an error. Repeated clicks create more durable chats/worktrees that cannot be reached through that companion folder's history.
6. The main Companion shortcut also fails: its post-create membership guard at `AppModel+CompanionNavigation.swift:128` returns without resuming. It may create another hidden chat on the next click.

Representative real backend fixture shape (asserted by the executed test):

```json
{
  "id": "<created-session>",
  "agent_profile_id": "<primary-companion-uuid>",
  "workspace_root": "/tmp/project",
  "execution_path": "<managed-checkout>",
  "environment": {
    "type": "worktree",
    "source_workspace": "/tmp/project/subproject"
  }
}
```

Expected: `belongsToWorkspace("/tmp/project/subproject") == true` and the created session is selectable.
Actual: history uses `workspacePath == requestedRoot`, which is false; `select` exits.

Security/impact characterization: ordinary authorized use triggers this; no attacker or elevated privilege is necessary. It is a usability/resource accumulation regression, not a demonstrated access-control bypass. Existing chats remain durable and can be accessed elsewhere.

**Verification performed:**

```text
/tmp/locus-audit-venv-20261006/bin/python -m pytest \
  agent/tests/test_detached_workspaces.py::test_git_subfolder_keeps_map_source_and_uses_repository_execution -q
1 passed in 2.31s
```

That test creates a real temporary Git repository, chooses its subfolder, allocates an automatic checkout, and checks root/source identity before and after resume (`agent/tests/test_detached_workspaces.py:123-141`). Existing native `AgentWorldTests.testIsolatedProjectIdentityKeepsSelectedSubfolderWithoutChangingExecutionContext` (`:29-57`) covers the established predicate and queue execution root, but companion tests never combine this fixture with the new history filter.

**Fix scope:** use `$0.belongsToWorkspace(root)` in `companionChats` and `session.belongsToWorkspace(workspace)` in `catalogDidChange`, retaining owner/archive/automation/crew exclusions. Add create/select/catalog-refresh/main-shortcut tests for a selected Git subfolder, plus a sibling-subfolder negative control. Preserve execution root/path; do not rewrite the session to the source alias.

**Related checks:** `CompanionActivitySummary.includes` correctly uses `session.belongsToWorkspace(root)` (`:106-111`), and `CompanionMenuBarActivity` uses it for standalone session attention (`CompanionMenuBarView.swift:45-48`). Thus activity may correctly show this chat's work while the Chat history omits it. `rememberSidebarSession` stores the canonical session root in its companion key (`AppModel+SessionLifecycle.swift:62-65`); audit selected-alias restoration when fixing N1, although its fallback to candidate ordering makes this secondary and it is not a separate finding.

## Finding N2 — [P2] Panel blocks a valid conversation override when the owner's default account is unavailable

**Location:** `Locus/CompanionPanelModel.swift:76-86`, especially `:81`.
**Introduced:** `4cce6ebfa` (verified by blame).
**Confidence:** High; reproduced against the actual compiled Locus module and dynamic library, with only a synthetic URLProtocol session response.

`availabilityIssue` validates `app.agentProfileProvider(profile)` against the primary companion's default model/account. `canSend` requires that check to pass. Actual saved-chat dispatch uses `agentChatProfile(savedProfile, sessionID:)`, so it can legitimately use a different, healthy route.

Concrete scenario:

1. A companion profile defaults to provider account A.
2. In a normal companion conversation, choose local model B or a different healthy account using the existing model picker. This persists `settings.agentChatModelSelections[sessionID]` (`AppModel+AgentChats.swift:135-148`).
3. Disconnect/remove default account A. The conversation's independently selected B remains available.
4. Open another task in the center and select the B-routed companion chat in the inspector/menu bar. Its transcript loads and draft remains usable.
5. `availabilityIssue` validates A, produces “The selected account is unavailable…”, and `canSend` remains false; Send is disabled (`CompanionInspectorTab.swift:304`). The actual route B would pass `agentWorldProfileDispatch`, and the same chat can continue from the normal conversation.

Control-flow evidence:

- `AppModel+AgentChats.swift:18-25`: copies the owner's profile and applies the matching session's model/account override.
- `AppModel+AgentWorld.swift:84,103`: resolves that effective profile, then validates its provider for actual dispatch.
- `AppModel+AgentWorld.swift:162`: `sendAgentWorldTurn` passes the session ID into that route resolution.
- `AppModel+TaskCapsules.swift:180-187`: default account absence makes the panel's current provider check throw.
- `CompanionPanelModel.swift:81,86,205`: failure disables sending before the correct route resolver can run.

No untrusted actor is required; it is an availability regression for authorized per-conversation routing. The inverse case (valid default but broken selected override) is safely rejected by dispatch, so this does not establish wrong-account execution.

**Fix scope:** validate the effective selected-session profile (or the same route resolver used for dispatch) in availability. Preserve the owner's defaults for creating new conversations. Add a panel test with a missing default account and a healthy local override, plus a negative test where the override itself is unavailable.

**Existing coverage:** `TaskCapsuleRoutingTests.testAgentChatSelectionChangesTheWorkerProviderAndKeepsAgentIdentity`, `testAgentChatLocalSelectionSurvivesSettingsRestoreAndSwitchingChats`, and `testAgentChatRouteNeverFallsBackAfterSelectedAccountIsRemoved` (`:331-452`) prove the intended independent chat-route model. `CompanionPanelTests.testNoModelOrOfflineSendNeverDispatchesOrClearsDraft` tests only the base profile and lacks the override/default distinction.

## Other reviewed paths and evidence

- Main shortcut: checks center ownership token, original center workspace/destination/overview/agent, current companion identity/workspace, cancellation, and membership after asynchronous creation (`AppModel+CompanionNavigation.swift:108-135`). Existing tests cover repeated clicks, late navigation/scope changes, retry, busy foreground work, approval/draft preservation, and no setup identity.
- Side read/send: `selectionRevision`, `scopeIsCurrent`, durable identity, and archive checks prevent stale scope callbacks from displaying another selection or dispatching its draft. The submitted draft clears only after accepted dispatch and only if unchanged (`CompanionPanelModel.swift:147-165,204-236`).
- Background work: new `preservingForeground` parameter only changes post-acceptance catalog refresh. Existing queue/worker admission, captured model route, cancellation handler, acceptance recovery, and run cancellation remain unchanged (`AppModel+AgentWorld.swift:147-257`). No new bypass of route/owner/workspace checks found.
- Stop: side stop targets the selected session's sending task and existing `stopGoalTurn(sessionID:)`; a foreground conversation is read-only in the panel. Existing tests cover stopping another selection and preserve central draft/approval.
- Side tool results: `allowsForegroundToolResults = false` prevents mounting MCP launcher and tool-image loader against the unrelated center transport (`CompanionInspectorTab.swift:239-244`, `MCPAppHost.swift:66-79`, `WorkspaceView.swift:7212-7230`). Native tool-isolation tests mount real SwiftUI rows and check no foreground media requests.
- File opening: explicit conversation execution folder is passed to `openWorkspaceReference`; containment and URL equality are rechecked at click time (`AppModel+OverviewActions.swift:92-105`). Different-root text artifacts use read-only file viewer instead of retargeting center inspector. `WorkspaceFileViewerRequest.belongsToWorkspace` gates Add to Context against the current center (`WorkspaceFileModel.swift:15-20`, `WorkspaceFileViewerSheet.swift:106-109`).
- Menu bar: existing AppModel/panel stores are reused, and the captured menu window is hidden explicitly before main navigation; it does not use `NSApp.keyWindow`. Opening activity does not acknowledge unread results. Owned runs and attention are scoped by profile/workspace. Dedupe treats terminal samples as final.

## Blast radius

Counts are production call expressions found under `Locus/`, excluding definitions and tests; overload/function-value UI references are described separately, not presented as call counts.

| Function / value | Direct callers / references | Scope |
|---|---:|---|
| `companionChats` | 3 calls | Panel history/selection plus main shortcut candidate/post-create checks; transitive use across inspector and menu bar |
| `openCompanionMainConversation` | 3 calls | Sidebar plus 2 onboarding entry points |
| `createSavedAgentConversation` | 7 calls | Existing world/plugin/automation/saved-agent paths plus 2 companion callers |
| `sendAgentWorldTurn` | 6 calls | Crew/world/plugin/saved work and companion; only companion passes new flag |
| `refreshCompanionConversationCatalog` | 2 calls | Detached creation and accepted dispatch |
| `rememberCompanionPanelSession` | 1 call | Successful identity-validated panel load |
| `availabilityIssue` | 2 production reads | `canSend` gate and visible composer notice |

`companionChats` is low direct-call blast radius but affects both main and side Companion entry points. `createSavedAgentConversation` and `sendAgentWorldTurn` have medium blast radius; defaults preserve previous behavior for their existing callers.

## Test coverage and limitations

Read CompanionPanel, CompanionIntegration, CompanionInspectorNavigation, CompanionToolIsolation, CompanionMenuBar, relevant SavedAgent, TaskCapsuleRouting, ResponseOutput, WorkspaceFileViewer, and AgentWorld coverage. No percentage/line-coverage claim is made. The root agent completed the native build/test suite: 1,954 passed, zero failures; this worker did not run a competing xcodebuild. The backend Git-subfolder fixture and the compiled native findings probe described below were executed here. No production code was edited.

Missing targeted cases: Git subfolder selected scope through companion creation/history/catalog refresh; valid selected-chat route with invalid default route. Existing panel dispatch tests generally inject a dispatch closure, so they test selection/capture/draft invariants rather than a real provider end-to-end turn. No live model/provider interaction, native menu-bar UI automation, or live network attack was performed.

Methodology: read Trail of Bits differential-review SKILL.md, methodology.md, adversarial.md, and reporting.md; built baseline invariants; compared changed functions and one-hop consumers; used git blame/log for regression provenance; checked tests and counted callers; performed a concrete backend fixture. Surgical scope within a large repository. Task Observer was not used.

## Independent challenge of plugin handoff candidate (not a confirmed finding)

At the parent agent's request, independently inspected `PluginPanel.swift:437-481,495-553`, `agent/PROTOCOL.md:1744-1757`, native handoff tests, and `agent/ollama_code/agent_profile_runtime.py:113-155`. The plugin can display a read-only-looking step list, receive a run+agent grant, and later submit a write-marked job for that run; only agent UUIDs are retained and dispatch uses `.work`. This behavior predates the main diff (`59c89cf957`, 2026-09-24).

However, the explicit protocol and code contract grant run/agent handoffs, not individual immutable steps. The button is “Allow for This Run”, RunStep has no stable step ID, and the description says work follows normal Locus permissions. A saved read-only agent remains constrained by `bounded_profile_configuration` and `solo_profile_boundary`; this path does not widen its access ceiling or bypass normal tool permissions. With a writable profile and auto-edit permission, actual writes are possible, but those are existing run/profile permissions. No stronger statement that the preview itself creates a read-only execution boundary was found.

Conclusion: do not present this as a confirmed permission bypass in the audit. Capturing an approved maximum edit level and making the run-level breadth clearer are defensible hardening options, but the evidence currently establishes a UI/contract ambiguity rather than a violated implemented/documented authorization boundary. No live plugin exploit or provider invocation was executed.

## Compiled native reproduction added during independent verification

Both N1 and N2 were subsequently reproduced using `@testable import Locus` linked directly against the parent build's `/tmp/locus-audit-native-20261006/Build/Products/Debug/Locus.app/Contents/MacOS/Locus.debug.dylib`. No implementation was copied or modified. Probe source is `/tmp/locus-native-findings-probe.swift`, executable `/tmp/locus-native-findings-probe`, output `/tmp/locus-native-findings-probe.log`. Exit status: 0; all preconditions asserting the defects passed.

```text
N1 belongsToWorkspace=true companionChats=0 selected=nil
N2 route=ollama/healthy-local selected=override-chat canSend=false error=The selected account is unavailable. Reconnect it or explicitly choose another profile.
```

The probe constructs `AppModel(startImmediately: false)`, which disables persistence and selects in-memory credentials, uses an ephemeral URLProtocol fixture for the session detail response, and performs no provider dispatch or live network operation. N1 constructs the exact repository-root/source-subfolder identity supported by the independently executed backend fixture. N2 successfully resolves `agentWorldProfileDispatch` to the healthy per-chat local route, while the loaded side panel disables Send due to the missing default account. This directly distinguishes correct underlying routing from the defective UI availability gate.
