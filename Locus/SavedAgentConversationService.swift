import Combine
import Foundation

/// Canonical native saved-agent identity and queued native conversation work.
/// Exists independently of installed worlds and survives closing their windows.
@MainActor
final class SavedAgentConversationService: ObservableObject {
    private struct QueuedTurn { let text: String; let mode: WorkMode }
    private var bindings: [String: String] = [:]
    private var profileHistory: [String: String] = [:]
    private var creationTasks: [String: Task<String, Error>] = [:]
    private var queues: [String: [QueuedTurn]] = [:]
    private var runners: [String: Task<Void, Never>] = [:]
    private var runnerTokens: [String: UUID] = [:]
    private var queueErrors: [String: String] = [:]
    private var defaults: UserDefaults?
    private var create: (String, AgentProfile) async throws -> String = { _, _ in throw SavedAgentConversationError.unavailable("Connect the agent first.") }
    private var state: (String) -> SavedAgentConversationState = { _ in .init() }
    private var dispatch: (String, String, UUID, String, WorkMode) async throws -> Void = { _, _, _, _, _ in }
    var queueFailed: ((String, UUID, String, String) -> Void)?

    func configure(defaults: UserDefaults?, state: @escaping (String) -> SavedAgentConversationState,
                   create: @escaping (String, AgentProfile) async throws -> String,
                   dispatch: @escaping (String, String, UUID, String, WorkMode) async throws -> Void) {
        self.defaults = defaults; self.state = state; self.create = create; self.dispatch = dispatch
        // Retain the historical persistence keys: these are canonical ownership
        // records and must never be migrated/reset with disposable world settings.
        if let data = defaults?.data(forKey: "Locus.AgentWorld.conversations.v1"),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) { bindings = saved }
        if let data = defaults?.data(forKey: "Locus.AgentWorld.profileHistory.v1"),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            profileHistory = saved.filter { UUID(uuidString: $0.value) != nil }
        }
        for (key, sessionID) in bindings where profileHistory[sessionID] == nil {
            if let profileID = UUID(uuidString: String(key.split(separator: "\n").last ?? "")) { profileHistory[sessionID] = profileID.uuidString }
        }
        persist()
    }

    static func bindingKey(workspace: String, profileID: String) -> String {
        SessionSummary.canonicalWorkspacePath(workspace) + "\n" + profileID.lowercased()
    }
    func boundProfileID(for sessionID: String) -> UUID? { profileHistory[sessionID].flatMap(UUID.init(uuidString:)) }
    func currentSessionID(for key: String) -> String? { bindings[key] }
    func pendingCount(for key: String) -> Int { queues[key]?.count ?? 0 }
    func queueError(for key: String) -> String? { queueErrors[key] }
    func hasPendingWork(profileID: UUID) -> Bool {
        let suffix = "\n" + profileID.uuidString.lowercased()
        return creationTasks.keys.contains { $0.hasSuffix(suffix) } || runners.keys.contains { $0.hasSuffix(suffix) }
            || queues.contains { $0.key.hasSuffix(suffix) && !$0.value.isEmpty }
    }
    func bind(_ sessionID: String, workspace: String, profileID: UUID) {
        guard boundProfileID(for: sessionID).map({ $0 == profileID }) ?? true else { return }
        profileHistory[sessionID] = profileID.uuidString
        bindings[Self.bindingKey(workspace: workspace, profileID: profileID.uuidString)] = sessionID
        persist(); objectWillChange.send()
    }
    private func persist() {
        // Identity must survive interruption before changing the current selection.
        if let data = try? JSONEncoder().encode(profileHistory) { defaults?.set(data, forKey: "Locus.AgentWorld.profileHistory.v1") }
        if let data = try? JSONEncoder().encode(bindings) { defaults?.set(data, forKey: "Locus.AgentWorld.conversations.v1") }
    }
    func conversation(workspace: String, profile: AgentProfile) async throws -> String {
        let key = Self.bindingKey(workspace: workspace, profileID: profile.id.uuidString)
        if let id = bindings[key] {
            guard boundProfileID(for: id).map({ $0 == profile.id }) ?? true else {
                throw SavedAgentConversationError.unavailable("This stored chat belongs to another agent. Start a new chat for \(profile.name).")
            }
            return id
        }
        if let task = creationTasks[key] { return try await task.value }
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let id = try await create(workspace, profile)
            if let existing = boundProfileID(for: id), existing != profile.id {
                throw SavedAgentConversationError.unavailable("This saved conversation belongs to another agent profile.")
            }
            profileHistory[id] = profile.id.uuidString; bindings[key] = id; persist()
            return id
        }
        creationTasks[key] = task
        defer { creationTasks[key] = nil; objectWillChange.send() }
        return try await task.value
    }
    func clearMissingBinding(sessionID: String, workspace: String, profileID: UUID) {
        let key = Self.bindingKey(workspace: workspace, profileID: profileID.uuidString)
        if bindings[key] == sessionID { bindings[key] = nil; persist(); objectWillChange.send() }
    }
    @discardableResult
    func resetCurrentConversation(workspace: String, profileID: UUID) -> Bool {
        let key = Self.bindingKey(workspace: workspace, profileID: profileID.uuidString)
        guard creationTasks[key] == nil, runners[key] == nil, bindings[key].map({ state($0).busy }) != true else { return false }
        bindings[key] = nil; persist(); objectWillChange.send(); return true
    }
    /// Unaccepted local drafts from a revoked presentation are discarded. Runs
    /// already admitted to the application's worker lifecycle remain authoritative.
    func discardQueuedDrafts(workspace: String) {
        let prefix = SessionSummary.canonicalWorkspacePath(workspace) + "\n"
        for key in Array(queues.keys) where key.hasPrefix(prefix) { queues[key] = [] }
        objectWillChange.send()
    }
    func enqueue(text: String, mode: WorkMode, sessionID: String, workspace: String, profileID: UUID) throws {
        let key = Self.bindingKey(workspace: workspace, profileID: profileID.uuidString)
        guard (queues[key]?.count ?? 0) < 20 else { throw SavedAgentConversationError.unavailable("This agent already has 20 queued messages.") }
        guard boundProfileID(for: sessionID).map({ $0 == profileID }) ?? true else { throw SavedAgentConversationError.unavailable("This chat does not belong to the selected agent.") }
        queueErrors[key] = nil; queues[key, default: []].append(.init(text: text, mode: mode)); objectWillChange.send()
        guard runners[key] == nil else { return }
        let token = UUID(); runnerTokens[key] = token
        runners[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if runnerTokens[key] == token { runners[key] = nil; runnerTokens[key] = nil }
                objectWillChange.send()
            }
            while !Task.isCancelled, let next = queues[key]?.first {
                while state(sessionID).busy && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled, runnerTokens[key] == token, queues[key]?.isEmpty == false else { return }
                do {
                    try await dispatch(sessionID, workspace, profileID, next.text, next.mode)
                    if runnerTokens[key] == token, queues[key]?.isEmpty == false { queues[key]?.removeFirst() }
                } catch {
                    guard runnerTokens[key] == token, !Task.isCancelled else { return }
                    queueErrors[key] = error.localizedDescription
                    queueFailed?(workspace, profileID, next.text, error.localizedDescription)
                    queues[key] = []; return
                }
                objectWillChange.send()
            }
        }
    }
}

/// Native-only types shared by ordinary saved-agent chats, Crew Chat and runs.
enum SavedAgentConversationError: LocalizedError {
    case unavailable(String)
    case conversationUnavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let message), .conversationUnavailable(let message): message } }
}
struct SavedAgentConversationState {
    var status = "idle"
    var detail: String?
    var busy = false
    var blocks: [ChatBlock] = []
}
