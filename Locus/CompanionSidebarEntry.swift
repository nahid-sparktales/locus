import SwiftUI

/// One stable navigation entry, also the unobtrusive opt-in for upgraded installs.
struct CompanionSidebarEntry: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agentTeams: AgentTeamsModel
    @EnvironmentObject private var onboarding: OnboardingModel
    @Environment(\.locusViewColors) private var colors
    @Environment(\.companionActivityPresentation) private var activitySource

    private var profile: AgentProfile? {
        agentTeams.agentProfiles.first { $0.id == agentTeams.primaryCompanionID }
    }

    var body: some View {
        Button {
            if let profile { model.selectSavedAgent(profile) }
            else { onboarding.beginCompanionSetup() }
        } label: {
            Group {
                if let profile {
                    VStack(spacing: -5) {
                        AgentAvatarView(profileID: profile.id, name: profile.name, size: 84)
                            .zIndex(1)
                        VStack(spacing: 3) {
                            Text(profile.name)
                                .font(.locus(size: 15, weight: .semibold)).lineLimit(1)
                            if let activitySource {
                                CompanionSidebarStatus(source: activitySource, profileID: profile.id)
                            } else {
                                Text("Your companion").font(.locus(size: 11))
                                    .foregroundStyle(colors.textSecondary)
                            }
                        }
                        .frame(minWidth: 106, maxWidth: 168)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(colors.panel, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(colors.line, lineWidth: 1))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 10) {
                    CompanionCharacterView(appearance: onboarding.companion.draft.appearance,
                        size: 32, animationsEnabled: false,
                        customImageData: onboarding.companion.draft.avatarData)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set up your companion")
                            .font(.locus(size: 12, weight: .semibold)).lineLimit(1)
                        Text("A familiar face for your work")
                            .font(.locus(size: 10)).foregroundStyle(colors.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .help(profile.map { "Open \($0.name)’s profile, conversations, and activity" }
              ?? "Personalize an agent without connecting a model")
        .accessibilityIdentifier("sidebar.companion")
    }
}

private struct CompanionSidebarStatus: View {
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
