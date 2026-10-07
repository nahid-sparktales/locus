import SwiftUI

@MainActor
final class CompanionGuidanceModel: ObservableObject {
    enum Topic: String, CaseIterable, Identifiable {
        case mcp = "Connect an MCP server", recurring = "Create a recurring agent", waiting = "Explain waiting work"
        var id: String { rawValue }
    }
    @Published var topic: Topic?
    @Published var target: String?
    @Published var instruction = ""
    @Published var stopped = false
    @Published var error: String?
    func stop() { topic = nil; target = nil; instruction = ""; stopped = true; error = nil }
    func point(to target: String?, instruction: String) {
        guard !stopped else { return }
        self.target = target; self.instruction = instruction
    }
}

/// Remains visible when an error removes the highlight, so the user can
/// understand the interruption and always end the walkthrough.
struct CompanionGuidanceStatus: View {
    @ObservedObject var guide: CompanionGuidanceModel
    let topic: CompanionGuidanceModel.Topic

    var body: some View {
        if guide.topic == topic && !guide.stopped {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: guide.error == nil ? "sparkle" : "exclamationmark.triangle")
                    .foregroundStyle(guide.error == nil ? Color.accentColor : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.rawValue).font(.caption.bold())
                    Text(guide.instruction).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = guide.error?.nilIfEmpty {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(3).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 4)
                Button("Stop guidance") { guide.stop() }
                    .font(.caption)
                    .accessibilityIdentifier("companion.guidance.stop")
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 14).padding(.bottom, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion.guidance.status")
        }
    }
}

private struct CompanionGuideAnchor: ViewModifier {
    let id: String
    @ObservedObject var guide: CompanionGuidanceModel
    func body(content: Content) -> some View {
        content.overlay {
            if guide.target == id && !guide.stopped {
                RoundedRectangle(cornerRadius: 7).stroke(.orange, lineWidth: 3).padding(-3).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if guide.target == id && !guide.stopped {
                VStack(alignment: .leading, spacing: 5) {
                    Text(guide.instruction).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if guide.topic == .waiting {
                        Button("Stop guidance") { guide.stop() }.font(.caption)
                    }
                }
                .padding(10).frame(maxWidth: 300, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .offset(y: 58).zIndex(100)
            }
        }
        .accessibilityHint(guide.target == id ? guide.instruction : "")
    }
}
extension View {
    func companionGuideAnchor(_ id: String, guide: CompanionGuidanceModel) -> some View {
        modifier(CompanionGuideAnchor(id: id, guide: guide))
    }
}

struct CompanionGuidanceView: View {
    @EnvironmentObject private var app: AppModel
    var body: some View { CompanionGuidanceContent(app: app, guide: app.companionGuidance) }
}

private struct CompanionGuidanceContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject var guide: CompanionGuidanceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show me how").font(.headline)
            Text("Choose a guide. Follow the highlighted controls; you decide what to save or permit.").font(.caption).foregroundStyle(.secondary)
            ForEach(CompanionGuidanceModel.Topic.allCases) { topic in
                Button(topic.rawValue) {
                    guide.stopped = false; guide.topic = topic; guide.error = nil
                    switch topic {
                    case .mcp:
                        guide.point(to: "extensions.tabs", instruction: "Choose MCP Servers to inspect or add a connection.")
                        app.presentSettings(.extensions)
                    case .recurring:
                        guide.point(to: "schedule.prompt", instruction: "Describe the work, choose its repeat timing, then review permissions before creating the agent.")
                        app.presentScheduleEditor()
                    case .waiting:
                        let snapshot = CompanionMenuBarActivity(profileID: app.primaryCompanionProfile?.id,
                            workspace: app.companionWorkspacePath, sessionsByID: app.sessionCatalog.snapshot.sessionsByID,
                            runs: app.activity.visibleActivityRuns, attentionItems: app.activity.attentionItems,
                            unreadRunIDs: [])
                        if let request = snapshot.attentionItems.first {
                            guide.point(to: "activity.waiting", instruction: request.title + ": " + request.detail)
                            app.activity.openActivityCenter(focus: request.runID.map(ActivityCenterModel.Focus.run))
                        } else {
                            guide.point(to: "activity.waiting", instruction: "No outstanding Companion request is recorded. Open Activity to inspect current work or refresh its state.")
                            app.activity.openActivityCenter()
                        }
                    }
                    dismiss()
                }.buttonStyle(.bordered)
            }
            if !guide.instruction.isEmpty { Text(guide.instruction).font(.caption) }
            if let error = guide.error { Text(error).font(.caption).foregroundStyle(.red) }
            if guide.topic != nil { Button("Stop guidance") { guide.stop() } }
        }.padding(18).frame(width: 370)
    }
}
