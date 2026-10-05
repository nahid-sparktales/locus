import Combine
import SwiftUI

/// A read-only invalidation bridge for visible avatars. It owns no task state,
/// timer, provider request, profile or execution controls.
@MainActor
final class CompanionActivityPresentation: ObservableObject {
    private weak var app: AppModel?
    private var observations: Set<AnyCancellable> = []

    init(app: AppModel) {
        self.app = app
        let publishers = [app.objectWillChange.eraseToAnyPublisher(), app.activity.objectWillChange.eraseToAnyPublisher(),
            app.runs.objectWillChange.eraseToAnyPublisher(), app.runtimeStatus.objectWillChange.eraseToAnyPublisher(),
            app.providerAccountsModel.objectWillChange.eraseToAnyPublisher(), app.sessionCatalog.objectWillChange.eraseToAnyPublisher(),
            app.agentTeamsModel.objectWillChange.eraseToAnyPublisher()]
        Publishers.MergeMany(publishers).receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &observations)
    }

    func summary(profileID: UUID) -> CompanionActivitySummary? { app?.companionActivitySummary(profileID: profileID) }
    func scopeID(profileID: UUID) -> String { app?.companionActivityWorkspacePath(profileID: profileID) ?? "" }
}

struct CompanionCompletionReactionGate {
    private var scopeID: String?
    private var consumed: Set<String> = []

    mutating func establishBaseline(scopeID: String, event: ActivityCompletionEvent?) {
        self.scopeID = scopeID
        if let event { consumed.insert(event.runID) }
    }

    mutating func receive(scopeID: String, event: ActivityCompletionEvent?, now: Date = Date()) -> Bool {
        guard self.scopeID == scopeID else {
            establishBaseline(scopeID: scopeID, event: event)
            return false
        }
        guard let event, consumed.insert(event.runID).inserted else { return false }
        let age = now.timeIntervalSince(event.occurredAt)
        return age >= 0 && age < 3
    }
}

private struct CompanionActivityEnvironmentKey: EnvironmentKey {
    static let defaultValue: CompanionActivityPresentation? = nil
}

extension EnvironmentValues {
    var companionActivityPresentation: CompanionActivityPresentation? {
        get { self[CompanionActivityEnvironmentKey.self] }
        set { self[CompanionActivityEnvironmentKey.self] = newValue }
    }
}

/// A visible mount establishes its own baseline. Only a new live event can
/// trigger a short reaction; rerendering or opening history cannot replay it.
struct CompanionActivityCharacterView: View {
    @ObservedObject var source: CompanionActivityPresentation
    let profileID: UUID
    let appearance: CompanionAppearance
    let size: CGFloat
    let animationsEnabled: Bool
    let customImageData: Data?
    @State private var reactionRunID: String?
    @State private var reactionTask: Task<Void, Never>?
    @State private var reactionGate = CompanionCompletionReactionGate()

    private struct ReactionInput: Equatable {
        let scopeID: String
        let event: ActivityCompletionEvent?
    }

    var body: some View {
        let summary = source.summary(profileID: profileID)
        let livePose = summary?.pose ?? .idle
        let input = ReactionInput(scopeID: "\(source.scopeID(profileID: profileID))|\(profileID.uuidString)", event: summary?.latestCompletion)
        // Pending approvals and errors retain visual priority over a success
        // from a different task, while unread/activity counts remain separate.
        let pose: CompanionCharacterPose = reactionRunID != nil && livePose == .idle ? .completed : livePose
        CompanionCharacterView(appearance: appearance, size: size, pose: pose,
            animationsEnabled: animationsEnabled, customImageData: customImageData)
            .id(reactionRunID)
            .help([summary?.statusText, summary?.activityText].compactMap { $0?.nilIfEmpty }.joined(separator: " · "))
            .onAppear { reactionGate.establishBaseline(scopeID: input.scopeID, event: input.event) }
            .onChange(of: input) { _, input in
                guard reactionGate.receive(scopeID: input.scopeID, event: input.event) else { return }
                reactionTask?.cancel()
                reactionRunID = input.event?.runID
                reactionTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1_600))
                    guard !Task.isCancelled else { return }
                    reactionRunID = nil
                }
            }
            .onDisappear {
                reactionTask?.cancel(); reactionTask = nil; reactionRunID = nil
            }
    }
}
