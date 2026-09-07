import SwiftUI

struct SoloHelperControlsView: View {
    @ObservedObject var helpers: SoloCollaborationModel
    let sessionID: String
    let runID: String
    let isParentRunning: Bool

    private var agents: [SoloHelper] {
        helpers.visibleHelpers(sessionID: sessionID, runID: runID, isParentRunning: isParentRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(agents) { helper in
                helperRow(helper)
            }
        }
    }

    private func helperRow(_ helper: SoloHelper) -> some View {
        let key = SoloCollaborationModel.key(sessionID, helper.id)
        let draft = helpers.drafts[key] ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(helper.label).font(.locus(size: 11, weight: .semibold))
                Spacer()
                Text(helper.state.capitalized).font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft)
            }
            if helper.runID != runID {
                Text("Earlier turn")
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.inkSoft)
                    .accessibilityIdentifier("soloHelper.earlierTurn.\(helper.id)")
            }
            Text(helper.goal).font(.locus(size: 10)).lineLimit(3)
            if let reason = helper.reason, !reason.isEmpty {
                Text(reason).font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft)
            }
            if isParentRunning {
                TextField("Instruction for this helper", text: Binding(
                    get: { helpers.drafts[key] ?? "" },
                    set: { helpers.drafts[key] = $0 }
                ), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.locus(size: 11))
                .accessibilityIdentifier("soloHelper.instruction.\(helper.id)")
                HStack {
                    Button(helper.isRunning ? "Send message" : "Follow up") {
                        helpers.act(helper.isRunning ? "message" : "followup", agentID: helper.id,
                                    sessionID: sessionID, text: draft)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("soloHelper.message.\(helper.id)")
                    if helper.isRunning {
                        Button("Interrupt") {
                            helpers.act("interrupt", agentID: helper.id, sessionID: sessionID)
                        }
                        .disabled(helper.state == "stopping")
                        .accessibilityIdentifier("soloHelper.interrupt.\(helper.id)")
                    } else if ["paused", "interrupted", "failed"].contains(helper.state) {
                        Button("Resume") {
                            helpers.act("resume", agentID: helper.id, sessionID: sessionID,
                                        text: draft.isEmpty ? "Continue the assigned task from the saved state." : draft)
                        }
                        .accessibilityIdentifier("soloHelper.resume.\(helper.id)")
                    }
                }
                .controlSize(.mini)
                .disabled(helpers.pending.contains(key))
            } else {
                Text("Continue the parent task to work with this helper again.")
                    .font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft)
            }
            if let error = helpers.errors[key] {
                Text(error).font(.locus(size: 10)).foregroundStyle(LocusTheme.warningForeground)
            } else if let receipt = helpers.receipts[key] {
                Text(receipt).font(.locus(size: 10)).foregroundStyle(LocusTheme.inkSoft)
            }
        }
        .padding(8)
        .locusCard(radius: 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("soloHelper.card.\(helper.id)")
    }
}
