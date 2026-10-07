import SwiftUI

extension AppModel {
    var companionScope: CompanionConversationScope? {
        guard let session = companionConversation, let profile = primaryCompanionProfile else { return nil }
        return .init(sessionID: session.id, workspace: companionWorkspacePath, profileID: profile.id)
    }

    func configureCompanionContext() {
        companionContext.configure(browserSnapshot: { [weak self] in
            guard let self else { throw CancellationError() }
            let source = self.currentSessionID
            return try await self.browser.companionPageSnapshot(sessionID: source)
        }, applicationSnapshot: { [weak self] in
            guard let self, let target = self.applicationContext.lastExternalApplication else {
                throw SavedAgentConversationError.unavailable("Open the application you want to share, then return to Companion.")
            }
            return try await self.applicationContext.captureSnapshot(of: target)
        })
    }

    func openCompanionMemorySource(_ id: String) {
        guard let session = sessionCatalog.snapshot.sessionsByID[id], canSwitchToCompanionChat else {
            showToast("The source conversation is unavailable, or the current task needs attention.")
            return
        }
        resume(session)
    }

    func sendCompanionPrompt(_ text: String, scope: CompanionConversationScope) async throws {
        guard scope == companionScope else {
            throw SavedAgentConversationError.unavailable("The Companion conversation changed. Reopen this tool.")
        }
        try await sendSavedAgentTurn(sessionID: scope.sessionID, workspace: scope.workspace,
            profileID: scope.profileID, text: text, mode: .ask, preservingForeground: true)
    }

    func resumeCompanionTask(_ displayed: TaskDetailSnapshot, scope: CompanionConversationScope) {
        Task { @MainActor [weak self] in
            guard let self, self.companionScope == scope else { return }
            do {
                let latest = try await backend.get("/api/sessions/\(scope.sessionID)/task", as: TaskDetailSnapshot.self)
                guard companionScope == scope, latest.id == displayed.id,
                      latest.revision == displayed.revision, latest.allows("resume") else {
                    throw SavedAgentConversationError.unavailable("Saved progress changed. Refresh the catch-up card before resuming.")
                }
                if latest.owner_kind == "goal" {
                    _ = await goals.resume(sessionID: scope.sessionID)
                } else {
                    // Capsule/run resumption needs the existing task inspector's
                    // full routing and approval controls, scoped to this record.
                    showTaskDetail(sessionID: scope.sessionID)
                }
            } catch { showToast(error.localizedDescription) }
        }
    }
}

struct CompanionToolsButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label("Companion tools", systemImage: "square.grid.2x2") }
            .font(.caption).accessibilityIdentifier("companion.tools.open")
            .sheet(isPresented: $presented) { CompanionToolsView() }
    }
}

enum CompanionTool: String, CaseIterable, Identifiable {
    case context = "Share", continuity = "Catch up", activity = "Activity", memory = "Memory"
    case focus = "Focus", handoffs = "Handoffs", guidance = "Guide", appearance = "Character"
    var id: Self { self }
}

struct CompanionToolsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: CompanionTool

    init(initialTool: CompanionTool = .context) { _selected = State(initialValue: initialTool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Companion tools").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Tool", selection: $selected) {
                ForEach(CompanionTool.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if let scope = model.companionScope {
                content(scope).id(scope).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("Start your Companion chat", systemImage: "bubble.left",
                    description: Text("These tools use the same ongoing conversation."))
                Button("Start conversation") { model.companionPanel.createConversation() }
            }
        }
        .padding(20).frame(width: 680, height: 570)
        .task(id: model.companionScope) { model.companionContext.activate(model.companionScope) }
    }

    @ViewBuilder private func content(_ scope: CompanionConversationScope) -> some View {
        switch selected {
        case .context:
            VStack(alignment: .leading, spacing: 16) {
                Text("Share a specific part of your work").font(.headline)
                CompanionContextSharingView(model: model.companionContext)
                Text("Review the contents, attach them, then send your Companion a message.")
                    .foregroundStyle(.secondary).font(.callout)
                CompanionVoiceControls()
            }
        case .continuity:
            CompanionCatchUpView(backend: model.backend, scope: scope,
                openConversation: { dismiss(); model.openCompanionMainConversation() },
                reviewChanges: { dismiss(); model.showTaskDetail(sessionID: scope.sessionID) },
                resume: { saved in
                    if saved.goal?.isCompanionSession == true { selected = .focus }
                    else { model.resumeCompanionTask(saved, scope: scope) }
                })
        case .activity: CompanionActivityCardsView()
        case .memory:
            CompanionMemoryNotebookView(backend: model.backend, scope: scope,
                openSource: { id in dismiss(); model.openCompanionMemorySource(id) })
        case .focus:
            CompanionFocusView(sessionID: scope.sessionID, sendPrompt: { try await model.sendCompanionPrompt($0, scope: scope) })
        case .handoffs: CompanionHandoffsView(sessionID: scope.sessionID, sendPrompt: { try await model.sendCompanionPrompt($0, scope: scope) })
        case .guidance: CompanionGuidanceView()
        case .appearance:
            VStack(alignment: .leading, spacing: 16) {
                Text("Your character").font(.headline)
                CompanionAnimationPackButton(profileID: scope.profileID)
                Button("Show desktop companion") { model.companionDesktop.show() }
                Text("Move the desktop window to a screen edge to snap it. Its options control character size and whether it stays on top. Summon or hide it with Control–Option–Command–C.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Edit name and personality") {
                    dismiss()
                    if let profile = model.primaryCompanionProfile { model.presentSavedAgentEditor(profile) }
                }
            }
        }
    }
}
