import SwiftUI

/// The empty/connection state of the companion destination. A selected chat
/// uses WorkspaceView's normal transcript, composer, attachments and controls.
struct CompanionDestinationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var runtime: RuntimeStatusModel
    @Environment(\.locusViewColors) private var colors
    let sidebarVisible: Bool
    let showSidebar: () -> Void

    private var profile: AgentProfile? {
        agentTeams.agentProfiles.first { $0.id == agentTeams.primaryCompanionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !sidebarVisible {
                    Button(action: showSidebar) {
                        Image(systemName: "sidebar.left").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.locus())
                    .help("Show sidebar").accessibilityLabel("Show sidebar")
                    .accessibilityIdentifier("workspace.showSidebar")
                }
                Text("Your companion").font(.locus(size: 13, weight: .semibold))
                Spacer()
                if let profile {
                    Button("Profile") { model.selectSavedAgent(profile) }
                        .accessibilityIdentifier("companion.destination.profile")
                }
            }
            .padding(.horizontal, 20).frame(height: WorkspaceLayoutMetrics.toolbarHeight)
            .locusSurface(.toolbar)
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    if let profile {
                        AgentAvatarView(profileID: profile.id, name: profile.name, size: 112)
                        Text("Your space with \(profile.name)")
                            .font(.locus(size: 24, weight: .semibold))
                            .accessibilityIdentifier("companion.destination.name")
                        Text("A conversation for this project, with your companion’s saved model, instructions, and access settings.")
                            .foregroundStyle(colors.textSecondary)
                        Label(URL(fileURLWithPath: model.companionWorkspacePath).lastPathComponent,
                              systemImage: "folder")
                            .font(.locus(size: 12)).foregroundStyle(colors.textSecondary)
                            .help(model.companionWorkspacePath)

                        if !runtime.agentPhase.isOnline {
                            Text("Your companion is ready. Reconnect Locus, then connect a model to start chatting.")
                                .accessibilityIdentifier("companion.destination.unavailable")
                            Button("Reconnect Locus") { Task { await model.bootstrap() } }
                                .accessibilityIdentifier("companion.destination.reconnect")
                        } else if profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Your companion is ready. Connect a model to start chatting.")
                                .accessibilityIdentifier("companion.destination.unavailable")
                        }
                        HStack(spacing: 12) {
                            if !model.companionChats().isEmpty {
                                Button("Continue conversation") { model.openCompanionDestination() }
                                    .buttonStyle(.locus(.primary))
                                    .disabled(!runtime.agentPhase.isOnline || !model.canSwitchToCompanionChat)
                                    .accessibilityIdentifier("companion.destination.continue")
                            } else {
                                Button("Start conversation") { model.startCompanionConversation() }
                                    .buttonStyle(.locus(.primary))
                                    .disabled(!runtime.agentPhase.isOnline || !model.canSwitchToCompanionChat
                                              || model.creatingSavedAgentChatIDs.contains(profile.id))
                                    .accessibilityIdentifier("companion.destination.start")
                            }
                            Button("Choose model") { model.presentSavedAgentEditor(profile) }
                                .buttonStyle(.locus())
                                .accessibilityIdentifier("companion.destination.model")
                        }
                        Button("Models & Providers") { model.presentSettings(.accounts) }
                            .buttonStyle(.locus())
                        Text("Opening a conversation does not send a message or start a task.")
                            .font(.locus(size: 11)).foregroundStyle(colors.textSecondary)
                    } else {
                        Text("Meet your Locus companion")
                            .font(.locus(size: 24, weight: .semibold))
                        Text("Choose a character and name for the agent you’ll work with. You can set it up offline.")
                            .foregroundStyle(colors.textSecondary)
                        Button("Set up your companion") { model.presentCompanion() }
                            .buttonStyle(.locus(.primary))
                            .accessibilityIdentifier("companion.destination.setup")
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520).padding(32)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("companion.destination")
    }
}
