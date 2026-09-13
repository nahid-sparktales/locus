import SwiftUI

/// Both native surfaces present the same editors and task controls. Ownership
/// follows the key window so dismissing one host cannot clear another's state.
struct LocusSharedPresentations: ViewModifier {
    enum Surface { case main, agentWorld }
    let surface: Surface
    let updates: AppUpdateController?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                LocusPresentationAnchor(surface: surface, updates: updates, availableSize: proxy.size)
                    .frame(width: 0, height: 0)
            }
        }
    }
}

private struct LocusPresentationAnchor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: WorkspaceLibraryModel
    @EnvironmentObject private var onboarding: OnboardingModel
    @EnvironmentObject private var landingFlow: LandingFlowModel
    @EnvironmentObject private var extensionsModel: ExtensionsModel
    @EnvironmentObject private var schedule: ScheduleModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    let surface: LocusSharedPresentations.Surface
    let updates: AppUpdateController?
    let availableSize: CGSize

    private var ownsPresentations: Bool {
        model.agentWorldOwnsPresentations == (surface == .agentWorld)
    }
    private var presentationSize: CGSize {
        availableSize == .zero ? CGSize(width: 1100, height: 800) : availableSize
    }
    private func owned(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { ownsPresentations && binding.wrappedValue },
                set: { if ownsPresentations { binding.wrappedValue = $0 } })
    }
    private func owned<Value>(_ binding: Binding<Value?>) -> Binding<Value?> {
        Binding(get: { ownsPresentations ? binding.wrappedValue : nil },
                set: { if ownsPresentations { binding.wrappedValue = $0 } })
    }

    var body: some View {
        Color.clear
        .modifier(IdentityVaultPresentation(vault: model.identityVault, enabled: ownsPresentations))
        .modifier(TaskCapsulePresentation(capsules: model.taskCapsules, enabled: ownsPresentations, openTask: { model.showTaskDetail(runID: $0) }, onDismiss: { if ownsPresentations { model.completeCapsuleTaskDismissal() } }))
        .sheet(isPresented: owned($library.isPresented)) {
            if model.isUITesting, ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_LIBRARY_CONTENT"] == "1" {
                LibraryUITestFixtureView().appFeatureEnvironment(from: model)
            } else {
                LibraryWorkspaceView().appFeatureEnvironment(from: model)
            }
        }
        .sheet(isPresented: owned($onboarding.isPresented), onDismiss: {
            guard ownsPresentations else { return }
            onboarding.dismiss()
            // Wait for the setup sheet to close before presenting its sibling.
            if let run = onboarding.takeOutputRequest() {
                model.openOutputsLibrary(workspace: run.workspace, sessionID: run.sessionID, runID: run.runID)
            }
            if onboarding.takeAgentSetupRequest() {
                model.configureAgentPendingCreation = true
                model.presentConfigureAgent(draftText: "")
            }
        }) {
            OnboardingView().appFeatureEnvironment(from: model)
        }
        .sheet(isPresented: owned($model.commandPalettePresented)) {
            CommandPaletteView()
                .environmentObject(model)
        }
        .sheet(isPresented: owned($model.checkpointPresented)) {
            CheckpointSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: owned($model.taskDetailPresented), onDismiss: { if ownsPresentations { model.completeTaskDetailDismissal() } }) {
            TaskDetailView(sessionID: model.taskDetailSessionID).environmentObject(model)
        }
        .sheet(isPresented: owned($model.notebookPresented)) {
            NotebookSheet(notebook: model.notebook, availableSize: presentationSize)
                .onAppear {
                    model.notebook.refresh(
                        workspaces: model.workspaceProfiles,
                        sessions: model.sessions
                    )
                }
        }
        .sheet(item: owned($model.fileViewerRequest)) { request in
            WorkspaceFileViewerSheet(request: request)
                .environmentObject(model)
        }
        .sheet(isPresented: owned(Binding(
            get: { landingFlow.reviewAndLandPresented },
            set: { landingFlow.reviewAndLandPresented = $0 }
        ))) {
            ReviewAndLandView()
                .environmentObject(model)
        }
        .sheet(isPresented: owned(Binding(
            get: { model.rememberConfirmationText != nil },
            set: { if !$0 { model.rememberConfirmationText = nil } }
        ))) {
            if let text = model.rememberConfirmationText {
                RememberConfirmationView(initialText: text)
                    .environmentObject(model)
            }
        }
        .sheet(isPresented: owned($model.settingsPresented), onDismiss: {
            if ownsPresentations { model.completeSettingsDismissal() }
        }) {
            if let updates {
                SettingsView(presentationContext: .sheet, availableSize: presentationSize)
                    .environmentObject(model)
                    .environmentObject(updates)
            }
        }
        .sheet(isPresented: owned($model.usageDashboardPresented)) {
            UsageDashboardView()
                .environmentObject(model)
        }
        .sheet(isPresented: owned($model.modelLibraryPresented)) {
            ModelLibraryView()
                .environmentObject(model)
        }
        .sheet(isPresented: owned($model.shortcutsPresented)) {
            ShortcutsSheet()
        }
        .sheet(item: owned($model.savedAgentEditor)) { profile in
            AgentProfileEditor(profile: profile,
                isNew: !agentTeams.agentProfiles.contains(where: { $0.id == profile.id }),
                existingProfiles: agentTeams.agentProfiles,
                onSave: model.saveSidebarAgent)
                .environmentObject(model)
                .environmentObject(providerAccounts)
        }
        .sheet(isPresented: owned($model.configureAgentPresented), onDismiss: {
            if ownsPresentations { model.dismissConfigureAgent() }
        }) {
            ConfigureAgentView(
                automation: model.eventAutomations,
                schedule: schedule
            )
            .environmentObject(model)
        }
        .sheet(item: owned(Binding(
            get: { extensionsModel.mcpInputRequest },
            set: { value in
                if value == nil, extensionsModel.mcpInputRequest != nil {
                    extensionsModel.answerMCPInput(action: "cancel")
                }
            }
        ))) { request in
            MCPInputRequestView(request: request)
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .alert(model.automaticInspectorPrompt?.title ?? "Open request details automatically?", isPresented: owned(Binding(
            get: { model.automaticInspectorPrompt != nil },
            set: { presented in
                if !presented, model.automaticInspectorPrompt != nil {
                    model.answerAutomaticInspectorPrompt(showEveryTime: false)
                }
            }
        ))) {
            Button("Not Automatically", role: .cancel) {
                model.answerAutomaticInspectorPrompt(showEveryTime: false)
            }
            .accessibilityIdentifier("inspector.automatic.never")
            Button(model.automaticInspectorPrompt?.confirmationTitle ?? "Open Every Time") {
                model.answerAutomaticInspectorPrompt(showEveryTime: true)
            }
            .accessibilityIdentifier("inspector.automatic.always")
        } message: {
            Text(model.automaticInspectorPrompt?.message ?? "")
        }
        .alert("Clear this chat?", isPresented: owned($model.clearChatConfirmationPresented)) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Chat") { model.clearChatConfirmed() }
                .accessibilityIdentifier("clearChat.confirm")
        } message: {
            Text("The current conversation will remain available in Sessions. Locus will start a fresh chat with the same workspace, model, mode, context, and browser home.")
        }
        .alert("Clear saved sessions?", isPresented: owned($model.clearSessionsConfirmationPresented)) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Saved Sessions", role: .destructive) {
                model.clearSavedSessionsConfirmed()
            }
            .accessibilityIdentifier("clearSessions.confirm")
        } message: {
            Text("Previous sessions will move to a recovery folder. The active session, current chat, connection, and any running job will remain untouched.")
        }
        .alert("New Chat Folder", isPresented: owned($model.globalNewFolderPresented)) {
            TextField("Folder name", text: $model.globalNewFolderName)
                .accessibilityIdentifier("chatFolder.global.name")
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                model.createChatFolder(
                    in: model.activeWorkspaceID,
                    name: model.globalNewFolderName,
                    parentID: nil
                )
            }
            .disabled(model.globalNewFolderName
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("chatFolder.global.create")
        } message: {
            Text("Folders organize chats without changing where they run.")
        }
    }
}
