import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Inspector chrome: tab selection with its per-tab side effects, panel
/// and rail toggles, the automatic-open prompt, zoom, and pane widths.
extension AppModel {
    func selectInspectorTab(_ tab: InspectorTab, selecting runID: String? = nil) {
        // Manual checkpoints are a brief management task, not a surface that
        // needs to consume a persistent inspector tab. Keep the legacy enum
        // value so stored settings and ⌘6 remain compatible, but route it to
        // the existing focused manager.
        if tab == .checkpoints {
            checkpointPresented = true
            return
        }
        guard !justChatEnabled else { return }
        if !openInspectorTabs.contains(tab) {
            openInspectorTabs.append(tab)
        }
        inspectorTab = tab
        if inspectorCollapsed {
            inspectorCollapsed = false
        }
        if tab == .plan { planHasUnseenUpdate = false }
        if tab == .changes {
            gitWorkspace.changesHaveUnseenUpdate = false
            gitWorkspace.refreshStatus()
        }
        if tab == .files { workspaceFiles.refresh() }
        if tab == .terminal {
            terminal.configure(
                workspacePath: workspacePath,
                shell: settings.terminalShell,
                loginShell: settings.terminalLoginShell
            )
            DispatchQueue.main.async { [weak terminal] in
                terminal?.ensureStarted()
                terminal?.focus()
            }
        }
        if tab == .runs {
            runsNavigationRequest = runID.map(RunsNavigationRequest.init(runID:))
            Task { @MainActor [weak self] in
                await self?.refreshOrchestrationRuns(select: runID)
            }
        }
        if tab == .agents { refreshAgentInstructions() }
        settings.inspectorLastTab = tab.rawValue
        if tab.isWorkspaceTab {
            settings.inspectorLastWorkspaceTab = tab.rawValue
        }
    }

    /// Closes one dynamic inspector tab. The tab to the right occupies the
    /// vacated position; closing the rightmost tab falls back to its left.
    /// With no tabs left, the inspector returns to the rail while retaining
    /// the last selection as the destination a future command can reopen.
    func closeInspectorTab(_ tab: InspectorTab) {
        guard let closingIndex = openInspectorTabs.firstIndex(of: tab) else { return }
        let wasSelected = inspectorTab == tab
        lastClosedInspectorTab = tab
        openInspectorTabs.remove(at: closingIndex)

        guard !openInspectorTabs.isEmpty else {
            inspectorCollapsed = true
            return
        }
        guard wasSelected else { return }

        let fallbackIndex = min(closingIndex, openInspectorTabs.count - 1)
        selectInspectorTab(openInspectorTabs[fallbackIndex])
    }

    /// Ctrl-` mirrors the familiar integrated-terminal gesture: reveal the
    /// terminal if needed, otherwise return keyboard focus to its PTY.
    func openTerminal() {
        selectInspectorTab(.terminal)
    }

    func openTeamRun(_ runID: String) {
        selectInspectorTab(.runs, selecting: runID)
    }

    func refreshAnchoredRunsIfNeeded() {
        guard blocks.contains(where: { $0.runID != nil }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshOrchestrationRuns()
            let identifiers = Set(self.blocks.compactMap(\.runID))
            for runID in identifiers where self.runRecord(for: runID)?.jobCount ?? 0 > 0 {
                do {
                    let detail: OrchestrationRun = try await self.orchestrationBackend(
                        for: runID
                    ).get("/api/orchestrations/\(runID)", as: OrchestrationRun.self)
                    self.runDetailsByID[runID] = detail
                } catch {
                    continue
                }
            }
        }
    }

    func toggleInspector() {
        guard !justChatEnabled else { return }
        // The general inspector command owns the workspace inspector, never a
        // special-purpose Plan or Browser surface. From either of those it
        // returns to the last workspace tab; a second press there collapses it.
        if !inspectorCollapsed, inspectorTab.isWorkspaceTab {
            lastClosedInspectorTab = inspectorTab
            inspectorCollapsed = true
        } else {
            selectInspectorTab(settings.resolvedInspectorWorkspaceTab)
        }
    }

    /// The dedicated rail control closes the current panel and reopens the
    /// last selected destination. A fresh model starts on Overview, so the
    /// first use always has a useful destination even when no tab was closed.
    func toggleInspectorPanel() {
        guard !justChatEnabled else { return }
        if inspectorCollapsed {
            let destination = lastClosedInspectorTab
                ?? (openInspectorTabs.contains(inspectorTab) ? inspectorTab : .plan)
            selectInspectorTab(destination)
        } else {
            lastClosedInspectorTab = inspectorTab
            inspectorCollapsed = true
        }
    }

    func presentInspectorForSentRequest(isTeam: Bool, runID: String? = nil) {
        // Just Chat deliberately has no workspace inspector, so it should not
        // consume the first-run choice for a panel that cannot be shown.
        guard !justChatEnabled else { return }
        let prompt = AutomaticInspectorPrompt(tab: isTeam ? .runs : .plan, runID: runID)
        let presentation = isTeam
            ? settings.resolvedTeamRunsPresentation
            : settings.resolvedSoloPlanPresentation
        switch presentation {
        case .ask:
            automaticInspectorPrompt = prompt
        case .always:
            openAutomaticInspector(prompt)
        case .never:
            break
        }
    }

    func answerAutomaticInspectorPrompt(showEveryTime: Bool) {
        guard let prompt = automaticInspectorPrompt else { return }
        automaticInspectorPrompt = nil
        let choice = showEveryTime
            ? AutomaticInspectorPresentation.always.rawValue
            : AutomaticInspectorPresentation.never.rawValue
        if prompt.isTeamRun {
            settings.teamRunsPresentationRaw = choice
        } else {
            settings.soloPlanPresentationRaw = choice
        }
        if showEveryTime {
            openAutomaticInspector(prompt)
        }
    }

    private func openAutomaticInspector(_ prompt: AutomaticInspectorPrompt) {
        selectInspectorTab(prompt.tab, selecting: prompt.tab == .runs ? prompt.runID : nil)
    }

    /// Rail icon behavior: a click on the open panel's own tab closes the
    /// panel; anything else selects the tab (which opens the panel if needed).
    func toggleInspectorTab(_ tab: InspectorTab) {
        guard !justChatEnabled else { return }
        if !inspectorCollapsed, inspectorTab == tab {
            lastClosedInspectorTab = tab
            inspectorCollapsed = true
        } else {
            selectInspectorTab(tab)
        }
    }

    /// Expand the panel over the window, or hand the space back. Zooming
    /// opens a collapsed panel first, and borrows the session sidebar's
    /// room — remembering to give it back — so the panel gets real width
    /// without the window growing.
    func setInspectorZoomed(_ zoomed: Bool) {
        guard zoomed != inspectorZoomed else { return }
        if zoomed {
            guard !justChatEnabled else { return }
            if openInspectorTabs.isEmpty {
                selectInspectorTab(inspectorTab)
            } else if inspectorCollapsed {
                inspectorCollapsed = false
            }
            inspectorZoomed = true
            if !sidebarCollapsed {
                restoreSidebarAfterZoom = true
                let savedPreference = settings.sidebarCollapsed
                sidebarCollapsed = true
                // The borrow is zoom-owned, not a preference: its didSet write
                // must not survive a quit-while-zoomed, or relaunch — which
                // never restores zoom — would come back with the sidebar
                // silently gone.
                settings.sidebarCollapsed = savedPreference
            }
        } else {
            inspectorZoomed = false
            let shouldRestore = restoreSidebarAfterZoom
            restoreSidebarAfterZoom = false
            // Only reopen what zoom itself closed — if the user reopened the
            // sidebar while zoomed, their choice stands.
            if shouldRestore, sidebarCollapsed { sidebarCollapsed = false }
        }
    }

    func toggleInspectorZoom() {
        setInspectorZoomed(!inspectorZoomed)
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

    /// Live width during a drag. Persistence waits for release so the settings
    /// writer is not restarted on every pointer movement.
    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = CGFloat(AppSettings.clampSidebarWidth(Double(width)))
    }

    func commitSidebarWidth() {
        settings.sidebarWidth = Double(sidebarWidth)
    }

    func resetSidebarWidth() {
        setSidebarWidth(CGFloat(AppSettings.defaultSidebarWidth))
        commitSidebarWidth()
    }

    /// Live width during a drag. Deliberately does not persist — see
    /// `commitInspectorWidth()`.
    func setInspectorWidth(_ width: CGFloat) {
        inspectorWidth = CGFloat(AppSettings.clampInspectorWidth(Double(width)))
    }

    /// Called once when a drag ends. Writing on every frame would restart the
    /// debounced settings save 60 times a second.
    func commitInspectorWidth() {
        settings.inspectorWidth = Double(inspectorWidth)
    }

    /// Live width of the chat column during a zoomed-divider drag. Same
    /// commit-on-release contract as `setInspectorWidth`.
    func setZoomedChatWidth(_ width: CGFloat) {
        zoomedChatWidth = CGFloat(AppSettings.clampZoomedChatWidth(Double(width)))
    }

    func commitZoomedChatWidth() {
        settings.inspectorZoomedChatWidth = Double(zoomedChatWidth)
    }
}
