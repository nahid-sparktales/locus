import Foundation

struct AgentWorkSource: Identifiable, Hashable {
    let kind: String
    let sourceID: String
    let workspace: String
    let title: String
    let prompt: String
    var agentIDs: [UUID] = []
    var suggestedDate: Date?
    var id: String { kind + ":" + sourceID + ":" + workspace }
}

struct AgentWorkRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let sourceID: String
    let kind: String
    let workspace: String
    let title: String
    let profileID: UUID
    var createdAt = Date()
    var sessionID: String?
    var runID: String?
    var scheduleID: String?
    var scheduledAt: Date?
    var state = "preparing"
    var error: String?
    var reviewed = false

    var canStartAgain: Bool { ["completed", "failed", "cancelled"].contains(state) }
    var source: AgentWorkSource {
        .init(kind: kind, sourceID: sourceID, workspace: workspace, title: title, prompt: title, agentIDs: [profileID])
    }
    var status: String {
        if reviewed { return "Reviewed" }
        switch state {
        case "preparing": return "Preparing work"
        case "scheduled": return "Scheduled"
        case "queued": return "Queued"
        case "completed": return "Ready to review"
        case "failed": return "Failed"
        case "cancelled": return "Cancelled"
        case "paused": return "Paused"
        case "uncertain": return "Check Activity Center"
        default: return state.contains("waiting") ? "Needs attention" : "Working"
        }
    }
}

/// Links explicit user assignments to durable runs. Restoring this file never
/// dispatches work; the existing run queue and scheduler remain the owners.
@MainActor
final class AgentWorkLedger: ObservableObject {
    static let shared = AgentWorkLedger()
    @Published private(set) var records: [AgentWorkRecord] = []
    @Published private(set) var error: String?
    private let file: URL
    private var loadFailed = false
    private let boardProvider: @MainActor (String) -> BoardStore

    init(root: URL = NotesStore.applicationSupportDirectory, boardProvider: @escaping @MainActor (String) -> BoardStore = { BoardStore.shared(workspacePath: $0) }) {
        self.boardProvider = boardProvider
        file = root.appendingPathComponent(AppEdition.current.displayName).appendingPathComponent("Agent Work/assignments.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= 8 * 1024 * 1024 else { throw AgentWorldError.unavailable("The assignment file is too large.") }
            records = try JSONDecoder().decode([AgentWorkRecord].self, from: data)
        }
        catch { loadFailed = true; self.error = "Saved assignments could not be loaded. \(error.localizedDescription)" }
    }

    func latest(for source: AgentWorkSource) -> AgentWorkRecord? {
        records.last { $0.sourceID == source.sourceID && $0.kind == source.kind
            && $0.workspace == BoardStore.canonicalWorkspace(source.workspace) }
    }

    func save(_ record: AgentWorkRecord) throws {
        guard !loadFailed else { throw AgentWorldError.unavailable(error ?? "Saved assignments are unavailable.") }
        var next = records
        if let index = next.firstIndex(where: { $0.id == record.id }) { next[index] = record }
        else { next.append(record) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        guard data.count <= 8 * 1024 * 1024 else { throw AgentWorldError.unavailable("Saved assignments have reached their storage limit.") }
        try data.write(to: file, options: .atomic)
        records = next; error = nil
    }

    func reconcile(runs: [OrchestrationRun], schedules: [ScheduledTask]) {
        for var record in records {
            if let scheduleID = record.scheduleID, let task = schedules.first(where: { $0.id == scheduleID }) {
                if let id = task.lastRunID, id != record.runID { record.runID = id; record.reviewed = false }
                if record.runID == nil { record.state = task.enabled ? "scheduled" : "paused" }
                record.error = task.lastError
            }
            let candidates = runs.filter { $0.workspaceRoot.map(BoardStore.canonicalWorkspace) == record.workspace }
            let exact = candidates.first { $0.id == record.runID }
            let scheduled = record.runID == nil && record.scheduleID != nil
                ? candidates.filter { $0.scheduleID == record.scheduleID }.max { $0.createdAt < $1.createdAt } : nil
            if let run = exact ?? scheduled {
                record.runID = run.id; record.sessionID = run.sessionID; record.state = run.state
                if !["failed", "cancelled"].contains(run.state) { record.error = nil }
            }
            do {
                if record != records.first(where: { $0.id == record.id }) { try save(record) }
                try updateBoard(record)
            } catch { self.error = "Couldn’t update an assignment: \(error.localizedDescription)" }
        }
    }

    func markReviewed(runID: String) throws {
        guard var record = records.last(where: { $0.runID == runID }) else { return }
        record.reviewed = true
        try save(record)
        try updateBoard(record)
    }

    private func updateBoard(_ record: AgentWorkRecord) throws {
        guard latest(for: record.source)?.id == record.id, record.kind == "board", let id = UUID(uuidString: record.sourceID) else { return }
        let board = boardProvider(record.workspace)
        guard let card = board.cards.first(where: { $0.id == id }) else { return }
        let target = record.reviewed ? "done" : record.state == "completed" ? "review"
            : ["queued", "running", "working"].contains(record.state) ? "in-progress" : nil
        guard let target, card.columnID != target, card.columnID != "done",
              board.columns.contains(where: { $0.id == target }) else { return }
        try board.moveCard(id, toColumn: target)
    }
}
