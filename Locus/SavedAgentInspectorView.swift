import SwiftUI

struct SavedAgentInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessionCatalog: SessionCatalogModel
    let profile: AgentProfile
    var workspace: String? = nil
    var newChat: (() -> Void)? = nil
    var openChat: ((SessionSummary) -> Void)? = nil
    var newChatDisabled: Bool? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.locus(size: 20, weight: .bold))
                    Text("\(profile.role.title) · \(profile.model)")
                        .font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
                }
                HStack {
                    Button("New chat") { if let newChat { newChat() } else { model.newSavedAgentChat(profile) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(newChatDisabled ?? (model.chatNavigationDisabled || model.creatingSavedAgentChatIDs.contains(profile.id)))
                        .accessibilityIdentifier("savedAgent.newChat")
                    Button("Manage Agent…") { model.manageSavedAgent(profile) }
                        .accessibilityIdentifier("savedAgent.manage")
                }
                Divider()
                Text("Instructions").font(.locus(size: 12, weight: .semibold))
                Text(profile.instructions.isEmpty ? "No additional instructions." : profile.instructions)
                    .font(.locus(size: 11)).textSelection(.enabled)
                Button("Edit Agent…") { model.presentSavedAgentEditor(profile) }
                    .accessibilityIdentifier("savedAgent.edit")
                Divider()
                Text("Chats").font(.locus(size: 12, weight: .semibold))
                ForEach(sessionCatalog.snapshot.sessions.filter {
                    model.savedAgentProfileID(for: $0.id) == profile.id && !$0.isArchived
                        && (workspace == nil || $0.workspacePath.map(SessionSummary.canonicalWorkspacePath) == workspace)
                }.sorted { $0.mtime > $1.mtime }) { session in
                    Button { if let openChat { openChat(session) } else { model.resume(session) } } label: {
                        Label(session.displayTitle, systemImage: session.isAgentEventChat ? "bolt" : "bubble.left")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.locus())
                }
                Text("Manage Agent lets you add schedules, incoming events, and price alerts.")
                    .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("savedAgent.overview")
    }
}
