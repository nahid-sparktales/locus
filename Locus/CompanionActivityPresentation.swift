import Combine
import SwiftUI

/// A read-only invalidation bridge for visible avatars. It owns no task state,
/// timer, provider request, profile or execution controls.
@MainActor
final class CompanionActivityPresentation: ObservableObject {
    private struct Presentation: Equatable {
        let summary: CompanionActivitySummary?
        let voicePose: CompanionCharacterPose?
        let scopeID: String
    }

    private struct CachedPresentation {
        let revision: UInt64
        let value: Presentation
    }

    private weak var app: AppModel?
    private var observations: Set<AnyCancellable> = []
    private var revision: UInt64 = 0
    private var refreshScheduled = false
    private var cached: [UUID: CachedPresentation] = [:]
    private var published: [UUID: Presentation] = [:]
#if DEBUG
    private(set) var presentationBuildCountForTesting = 0
#endif

    init(app: AppModel) {
        self.app = app
        let publishers = [app.objectWillChange.eraseToAnyPublisher(), app.activity.objectWillChange.eraseToAnyPublisher(),
            app.runs.objectWillChange.eraseToAnyPublisher(), app.runtimeStatus.objectWillChange.eraseToAnyPublisher(),
            app.providerAccountsModel.objectWillChange.eraseToAnyPublisher(), app.sessionCatalog.objectWillChange.eraseToAnyPublisher(),
            app.agentTeamsModel.objectWillChange.eraseToAnyPublisher(), app.voiceControl.objectWillChange.eraseToAnyPublisher()]
        // These owners publish on the main actor. Invalidate synchronously so
        // callers immediately see a changed owner, but let its whole mutation
        // finish before recomputing the shared presentation and notifying views.
        Publishers.MergeMany(publishers).sink { [weak self] _ in
            self?.sourceWillChange()
        }.store(in: &observations)
    }

    func summary(profileID: UUID) -> CompanionActivitySummary? { presentation(profileID: profileID).summary }
    func voicePose(profileID: UUID) -> CompanionCharacterPose? { presentation(profileID: profileID).voicePose }
    func scopeID(profileID: UUID) -> String { presentation(profileID: profileID).scopeID }

    private func presentation(profileID: UUID) -> Presentation {
        // During objectWillChange delivery the owner may not have assigned its
        // new value yet. Do not reuse an intermediate read until the deferred
        // refresh has observed the completed mutation.
        if !refreshScheduled, let entry = cached[profileID], entry.revision == revision { return entry.value }
#if DEBUG
        presentationBuildCountForTesting += 1
#endif
        let voicePose: CompanionCharacterPose?
        if let app, profileID == app.primaryCompanionProfile?.id,
           app.voiceControl.activeConversationSessionID == app.companionConversation?.id,
           app.voiceControl.isVoiceModeActive {
            voicePose = app.voiceControl.isListening ? .listening : app.voiceControl.isSpeaking ? .speaking : nil
        } else {
            voicePose = nil
        }
        let value = Presentation(summary: app?.companionActivitySummary(profileID: profileID),
            voicePose: voicePose, scopeID: app?.companionActivityWorkspacePath(profileID: profileID) ?? "")
        cached[profileID] = CachedPresentation(revision: revision, value: value)
        if published[profileID] == nil { published[profileID] = value }
        return value
    }

    private func sourceWillChange() {
        revision &+= 1
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
    }

    private func refreshPresentation() {
        refreshScheduled = false
        // objectWillChange precedes the mutation. A synchronous observer may
        // have read the old value since invalidation; discard that intermediate
        // cache before deriving the settled state.
        revision &+= 1
        var changed = false
        for profileID in Array(published.keys) {
            let value = presentation(profileID: profileID)
            if published[profileID] != value { changed = true; published[profileID] = value }
        }
        // Composer edits, transcript tokens and panel geometry do not change
        // companion activity. Avoid repainting every avatar for those events.
        if changed { objectWillChange.send() }
    }

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
        let livePose = source.voicePose(profileID: profileID) ?? summary?.pose ?? .idle
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
