import SwiftUI

/// A persistent shortcut to the companion's full conversation, beside accounts.
struct CompanionSidebarEntry: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @Environment(\.locusViewColors) private var colors

    private var profile: AgentProfile? {
        agentTeams.agentProfiles.first { $0.id == agentTeams.primaryCompanionID }
    }

    var body: some View {
        Button { model.openCompanionMainConversation() } label: {
            HStack(spacing: 8) {
                if let profile {
                    AgentAvatarView(profileID: profile.id, name: profile.name, size: 24)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.locus(size: 12, weight: .medium)).frame(width: 24)
                }
                Text("Companion").font(.locus(size: 10, weight: .semibold))
                Spacer(minLength: 4)
            }
            .foregroundStyle(colors.inkSoft)
            .padding(.horizontal, 8).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .help("Open your companion in the main conversation")
        .accessibilityLabel("Companion")
        .accessibilityIdentifier("sidebar.companion")
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
