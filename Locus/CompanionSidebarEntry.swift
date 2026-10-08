import SwiftUI

/// The overview shortcut and the dedicated ongoing-chat entry have distinct destinations.
struct CompanionSidebarEntry: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var activity: ActivityCenterModel
    @Environment(\.locusViewColors) private var colors
    var featured = false

    private var profile: AgentProfile? {
        agentTeams.agentProfiles.first { $0.id == agentTeams.primaryCompanionID }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if featured { model.openCompanionMainConversation() }
                else { model.openCompanionOverview() }
            } label: {
                HStack(spacing: 8) {
                    if let profile {
                        AgentAvatarView(profileID: profile.id, name: profile.name, size: featured ? 34 : 24)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.locus(size: 12, weight: .medium)).frame(width: 24)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(featured ? profile?.name ?? "Set up your companion" : "Companion")
                            .font(.locus(size: 10, weight: .semibold)).lineLimit(1)
                        if featured {
                            Text(model.companionHasUnread ? "Unread conversation" : "Your ongoing chat")
                                .font(.locus(size: 8)).foregroundStyle(colors.textSecondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if featured, model.companionHasUnread {
                        Circle().fill(colors.accentAction).frame(width: 6, height: 6)
                            .accessibilityLabel("Unread companion conversation")
                            .accessibilityIdentifier("sidebar.companion.unread")
                    }
                }
                .foregroundStyle(colors.inkSoft)
                .padding(.horizontal, 8).frame(height: featured ? 48 : 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.locus())
            .help(featured ? "Open your companion in the main conversation" : "Open your companion’s overview")
            .accessibilityLabel("Companion")
            .accessibilityValue(model.companionHasUnread ? "Unread" : "Read")
            .accessibilityIdentifier(featured ? "sidebar.companion" : "sidebar.companion.overview")
            if featured, profile != nil {
                Menu { actions } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 32)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Companion options")
                .accessibilityIdentifier("sidebar.companion.options")
            }
        }
        .background(featured && model.currentCompanionConversationProfile != nil
            ? colors.accentAction.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        if model.companionConversation != nil {
            Button(model.companionHasUnread ? "Mark as read" : "Mark as unread") {
                model.markCompanionRead(model.companionHasUnread)
            }
            .accessibilityIdentifier("companion.markReadState")
        }
        if let profile {
            Button("Companion profile") { model.selectSavedAgent(profile) }
        }
    }
}

extension AppModel {
    private var companionReadRuns: [OrchestrationRun] {
        guard let id = companionConversation?.id else { return [] }
        return Array(Dictionary((activity.visibleActivityRuns + runs.orchestrationRuns
            + Array(runs.runDetailsByID.values)).filter { $0.sessionID == id }.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                let existingFinished = TeamRunState(rawValue: existing.state)?.isTerminal == true
                let candidateFinished = TeamRunState(rawValue: candidate.state)?.isTerminal == true
                if existingFinished != candidateFinished { return existingFinished ? existing : candidate }
                return (existing.lastSequence, existing.updatedAt, existing.state)
                    >= (candidate.lastSequence, candidate.updatedAt, candidate.state) ? existing : candidate
            }).values)
    }

    var companionHasUnread: Bool {
        guard let id = companionConversation?.id else { return false }
        return activity.companionConversationIsUnread(sessionID: id, runs: companionReadRuns)
    }

    /// Manual unread survives while a chat stays visible. Opening the chat or
    /// receiving a new completed reply advances this observation identity.
    var companionReadRevision: String {
        (companionConversation?.id ?? "") + "|" + companionReadRuns
            .filter { TeamRunState(rawValue: $0.state)?.isTerminal == true }
            .sorted { $0.id < $1.id }.map { "\($0.id):\($0.updatedAt)" }.joined(separator: "|")
    }

    func markCompanionRead(_ read: Bool = true) {
        guard let id = companionConversation?.id else { return }
        activity.markCompanionConversation(sessionID: id, read: read, runs: companionReadRuns)
    }
}

struct CompanionSidebarStatus: View {
    @ObservedObject var source: CompanionActivityPresentation
    let profileID: UUID
    @Environment(\.locusViewColors) private var colors

    var body: some View {
        let summary = source.summary(profileID: profileID)
        VStack(spacing: 2) {
            Text(summary?.statusText ?? "Your companion")
                .lineLimit(2)
                .foregroundStyle((summary?.approvalCount ?? 0) > 0 ? colors.warning : colors.textSecondary)
            if let text = summary?.activityText, !text.isEmpty {
                Text(text).foregroundStyle(colors.textSecondary).lineLimit(2)
            }
            if let summary, !summary.availability.isAvailable, summary.execution != .idle {
                Text(summary.availability.detail).foregroundStyle(colors.textSecondary).lineLimit(1)
            }
        }
        .font(.locus(size: 11))
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("companion.activitySummary")
    }
}
