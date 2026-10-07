import SwiftUI

/// A read-only projection of saved evidence. Conversation prose is kept
/// explicitly separate from task verification and never authorizes a resume.
struct CompanionCatchUpCard: Equatable {
    let objective: String
    let decisions: [String]
    let progress: String
    let nextAction: String
    let evidence: String
    let canResume: Bool

    static func task(_ task: TaskDetailSnapshot, latestRequest: String? = nil) -> Self {
        let verified = task.verificationState == "passed"
        let status = task.state.replacingOccurrences(of: "_", with: " ")
        let progress = task.state == "planned"
            ? "Saved plan awaiting implementation."
            : "Task status: \(status). \(task.progress.count) recorded milestones."
        return .init(objective: task.goal?.objective ?? latestRequest?.nilIfEmpty ?? task.plan?.title ?? task.request,
                     decisions: Array((task.plan?.decisions ?? []).prefix(3)),
                     progress: progress,
                     nextAction: task.blocker.isEmpty
                        ? (task.allows("resume") ? "Resume the saved task when you are ready." : "Review the saved result or continue the conversation.")
                        : task.blocker,
                     evidence: verified ? "Verification passed for the saved task revision."
                        : "Verification: \(task.verificationState.replacingOccurrences(of: "_", with: " ")).",
                     canResume: task.allows("resume"))
    }

    static func conversation(_ detail: SessionDetailResponse) -> Self? {
        guard let request = detail.messages.last(where: { $0.role == "user" }) else { return nil }
        let lastReply = detail.messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty })
        return .init(objective: String(SessionSummary.cleanPreview(request.content).prefix(360)),
                     decisions: [],
                     progress: lastReply.map { "Last reply: " + String($0.content.prefix(480)) } ?? "No saved reply yet.",
                     nextAction: "Continue the conversation or share what changed.",
                     evidence: "Conversation excerpt · Progress has not been independently verified.",
                     canResume: false)
    }
}

@MainActor
final class CompanionCatchUpModel: ObservableObject {
    @Published private(set) var card: CompanionCatchUpCard?
    @Published private(set) var task: TaskDetailSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var revision = UUID()

    func clear() {
        revision = UUID()
        card = nil
        task = nil
        error = nil
        isLoading = false
    }

    func refresh(backend: BackendService, scope: CompanionConversationScope) async {
        clear()
        let requestedRevision = revision
        isLoading = true
        defer { if revision == requestedRevision { isLoading = false } }
        do {
            let conversation = try await backend.get("/api/sessions/\(scope.sessionID)", as: CompanionContinuityConversation.self)
            guard revision == requestedRevision, !Task.isCancelled else { return }
            guard conversation.identity.matches(sessionID: scope.sessionID, profileID: scope.profileID, workspace: scope.workspace),
                  conversation.detail.archived != true else {
                throw SavedAgentConversationError.conversationUnavailable("This Companion conversation is no longer available.")
            }
            do {
                let saved = try await backend.get("/api/sessions/\(scope.sessionID)/task", as: TaskDetailSnapshot.self)
                guard revision == requestedRevision, !Task.isCancelled else { return }
                task = saved
                let latestRequest = conversation.detail.messages.last(where: { $0.role == "user" })
                    .map { String(SessionSummary.cleanPreview($0.content).prefix(360)) }
                card = .task(saved, latestRequest: latestRequest)
            } catch {
                guard revision == requestedRevision, !Task.isCancelled else { return }
                // A chat without work has no task record. Other failures stay
                // visible; never substitute an apparently successful summary.
                guard (error as NSError).code == 404 else { throw error }
                card = .conversation(conversation.detail)
            }
        } catch {
            guard revision == requestedRevision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct CompanionContinuityConversation: Decodable {
    let detail: SessionDetailResponse
    let identity: AgentCrewChatSessionIdentity
    init(from decoder: Decoder) throws {
        detail = try SessionDetailResponse(from: decoder)
        identity = try AgentCrewChatSessionIdentity(from: decoder)
    }
}

struct CompanionCatchUpView: View {
    let backend: BackendService
    let scope: CompanionConversationScope
    var openConversation: () -> Void
    var reviewChanges: () -> Void
    var resume: (TaskDetailSnapshot) -> Void
    @StateObject private var model = CompanionCatchUpModel()
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Where we left off", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if model.isLoading { ProgressView("Reading saved progress…").controlSize(.small) }
                if let card = model.card {
                    Text(card.objective).font(.callout.weight(.medium)).textSelection(.enabled)
                    Text(card.progress).font(.caption).textSelection(.enabled)
                    ForEach(Array(card.decisions.enumerated()), id: \.offset) { _, decision in
                        Text("Decision: \(decision)").font(.caption)
                    }
                    Text(card.nextAction).font(.caption)
                    Text(card.evidence).font(.caption2).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { actions(card) }
                        VStack(alignment: .leading) { actions(card) }
                    }.font(.caption)
                } else if !model.isLoading, model.error == nil {
                    Text("Your saved progress will appear after you start a conversation.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                Button("Refresh") { Task { await model.refresh(backend: backend, scope: scope) } }
                    .font(.caption).disabled(model.isLoading)
            }.padding(.top, 6)
        }
        .font(.caption.weight(.medium))
        .accessibilityIdentifier("companion.catchup")
        .task(id: scope) { await model.refresh(backend: backend, scope: scope) }
    }

    @ViewBuilder private func actions(_ card: CompanionCatchUpCard) -> some View {
        if card.canResume, let task = model.task {
            Button("Resume") { resume(task) }.accessibilityIdentifier("companion.catchup.resume")
        }
        if model.task != nil { Button("Review changes", action: reviewChanges) }
        Button("Source conversation", action: openConversation)
    }
}
