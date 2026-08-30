import AppKit
import Foundation

/// Owns the workspace knowledge surface: the aggregate status, approved and
/// candidate memories, vault diagnostics, cross-chat context snapshots, skill
/// observations, and the file watcher that debounces reindexing. AppModel
/// wires it via configure(...) and bridges its publication; it never retains
/// AppModel.
@MainActor
final class WorkspaceKnowledgeModel: ObservableObject {
    @Published private(set) var knowledgeStatus: WorkspaceKnowledgeStatus?
    @Published private(set) var workspaceMemories: [WorkspaceMemory] = []
    @Published private(set) var memoryCandidates: [WorkspaceMemory] = []
    @Published private(set) var memoryVaultStatus: MemoryVaultStatus?
    @Published private(set) var memoryDiagnosticReport: MemoryDiagnosticReport?
    @Published private(set) var contextSnapshots: [ContextSnapshot] = []
    @Published private(set) var skillObservations: [SkillObservation] = []

    private let knowledgeWatcher = WorkspaceKnowledgeWatcher()
    private var knowledgeReindexTask: Task<Void, Never>?

    private var backend: BackendService?
    private var isUITesting = false
    private var workspacePathProvider: () -> String = { "" }
    private var sessionAttribution: () -> (sessionID: String, runID: String?) = { ("", nil) }
    private var ollamaHostProvider: () -> String = { "" }
    private var knowledgePageVisible: () -> Bool = { false }
    private var toastHandler: (String) -> Void = { _ in }

    func configure(
        backend: BackendService,
        isUITesting: Bool,
        workspacePathProvider: @escaping () -> String,
        sessionAttribution: @escaping () -> (sessionID: String, runID: String?),
        ollamaHostProvider: @escaping () -> String,
        knowledgePageVisible: @escaping () -> Bool,
        toastHandler: @escaping (String) -> Void
    ) {
        self.backend = backend
        self.isUITesting = isUITesting
        self.workspacePathProvider = workspacePathProvider
        self.sessionAttribution = sessionAttribution
        self.ollamaHostProvider = ollamaHostProvider
        self.knowledgePageVisible = knowledgePageVisible
        self.toastHandler = toastHandler
    }

    func cancelAll() {
        knowledgeReindexTask?.cancel()
        knowledgeReindexTask = nil
        knowledgeWatcher.stop()
    }

    func watchWorkspaceKnowledge(_ root: String) {
        guard !isUITesting, !root.isEmpty else { return }
        knowledgeWatcher.start(path: root) { [weak self] in
            Task { @MainActor in self?.scheduleWorkspaceKnowledgeReindex(root) }
        }
        scheduleWorkspaceKnowledgeReindex(root, immediately: true)
    }

    func scheduleWorkspaceKnowledgeReindex(
        _ root: String,
        immediately: Bool = false
    ) {
        guard let backend else { return }
        knowledgeReindexTask?.cancel()
        knowledgeReindexTask = Task { @MainActor [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(650)) }
            guard !Task.isCancelled, let self, self.workspacePathProvider() == root else { return }
            do {
                let _: WorkspaceKnowledgeStatus = try await backend.post(
                    "/api/knowledge/reindex",
                    body: ["workspace": root],
                    as: WorkspaceKnowledgeStatus.self
                )
                if self.knowledgePageVisible() {
                    await self.refreshWorkspaceKnowledge()
                }
            } catch {
                // Search triggers a lazy first index too. Watcher failures must
                // never interrupt chat or workspace switching.
            }
        }
    }

    func refreshWorkspaceKnowledge(agentID: String = "primary") async {
        guard let backend else { return }
        let workspacePath = workspacePathProvider()
        do {
            let memoryQuery = [
                URLQueryItem(name: "workspace", value: workspacePath),
                URLQueryItem(name: "agent_id", value: agentID),
            ]
            async let status: WorkspaceKnowledgeStatus = backend.get(
                "/api/knowledge/status",
                query: [URLQueryItem(name: "workspace", value: workspacePath)],
                as: WorkspaceKnowledgeStatus.self
            )
            async let memories: WorkspaceMemoriesResponse = backend.get(
                "/api/memory",
                query: memoryQuery + [URLQueryItem(name: "status", value: "approved")],
                as: WorkspaceMemoriesResponse.self
            )
            async let candidates: WorkspaceMemoriesResponse = backend.get(
                "/api/memory",
                query: memoryQuery + [URLQueryItem(name: "status", value: "candidate")],
                as: WorkspaceMemoriesResponse.self
            )
            async let vaultStatus: MemoryVaultStatus = backend.get(
                "/api/memory/status", query: memoryQuery, as: MemoryVaultStatus.self
            )
            async let diagnostics: MemoryDiagnosticReport = backend.get(
                "/api/memory/diagnostics", query: memoryQuery,
                as: MemoryDiagnosticReport.self
            )
            async let snapshots: ContextSnapshotsResponse = backend.get(
                "/api/context-snapshots",
                query: [URLQueryItem(name: "workspace", value: workspacePath)],
                as: ContextSnapshotsResponse.self
            )
            async let observations: SkillObservationsResponse = backend.get(
                "/api/skill-observations",
                query: [URLQueryItem(name: "workspace", value: workspacePath)],
                as: SkillObservationsResponse.self
            )
            knowledgeStatus = try await status
            workspaceMemories = try await memories.memories
            memoryCandidates = try await candidates.memories
            memoryVaultStatus = try await vaultStatus
            memoryDiagnosticReport = try await diagnostics
            contextSnapshots = try await snapshots.snapshots
            skillObservations = try await observations.observations
        } catch {
            toastHandler("Could not load workspace knowledge: \(error.localizedDescription)")
        }
    }

    func setContextSnapshotPinned(_ snapshot: ContextSnapshot, pinned: Bool) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: ContextSnapshotResponse = try await backend.put(
                    "/api/context-snapshots/\(snapshot.id)",
                    body: ["workspace": self.workspacePathProvider(), "pinned": pinned],
                    as: ContextSnapshotResponse.self
                )
                if let index = contextSnapshots.firstIndex(where: { $0.id == snapshot.id }) {
                    contextSnapshots[index] = response.snapshot
                }
            } catch {
                toastHandler("Could not update session context: \(error.localizedDescription)")
            }
        }
    }

    func deleteContextSnapshot(_ snapshot: ContextSnapshot) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/context-snapshots/\(snapshot.id)",
                    query: [URLQueryItem(name: "workspace", value: self.workspacePathProvider())],
                    as: SimpleActionResponse.self
                )
                contextSnapshots.removeAll { $0.id == snapshot.id }
            } catch {
                toastHandler("Could not delete session context: \(error.localizedDescription)")
            }
        }
    }

    func clearContextSnapshots() {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/context-snapshots",
                    query: [URLQueryItem(name: "workspace", value: self.workspacePathProvider())],
                    as: SimpleActionResponse.self
                )
                contextSnapshots = []
                toastHandler("Cleared cross-chat session context")
            } catch {
                toastHandler("Could not clear session context: \(error.localizedDescription)")
            }
        }
    }

    func setSkillObservationStatus(_ observation: SkillObservation, status: String) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: SkillObservationResponse = try await backend.put(
                    "/api/skill-observations/\(observation.id)",
                    body: ["workspace": self.workspacePathProvider(), "status": status],
                    as: SkillObservationResponse.self
                )
                if let index = skillObservations.firstIndex(where: { $0.id == observation.id }) {
                    skillObservations[index] = response.observation
                }
            } catch {
                toastHandler("Could not update observation: \(error.localizedDescription)")
            }
        }
    }

    func deleteSkillObservation(_ observation: SkillObservation) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/skill-observations/\(observation.id)",
                    query: [URLQueryItem(name: "workspace", value: self.workspacePathProvider())],
                    as: SimpleActionResponse.self
                )
                skillObservations.removeAll { $0.id == observation.id }
            } catch {
                toastHandler("Could not delete observation: \(error.localizedDescription)")
            }
        }
    }

    func exportSkillObservations() {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let document: SkillObservationsExport = try await backend.get(
                    "/api/skill-observations/export",
                    query: [URLQueryItem(name: "workspace", value: self.workspacePathProvider())],
                    as: SkillObservationsExport.self
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "Locus Skill Observations.json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                toastHandler("Skill observations exported")
            } catch {
                toastHandler("Could not export observations: \(error.localizedDescription)")
            }
        }
    }

    func configureWorkspaceKnowledge(
        enabled: Bool,
        embeddingModel: String,
        exclusions: [String] = []
    ) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                knowledgeStatus = try await backend.post(
                    "/api/knowledge/settings",
                    body: [
                        "workspace": self.workspacePathProvider(),
                        "enabled": enabled,
                        "embedding_model": embeddingModel,
                        "ollama_host": self.ollamaHostProvider(),
                        "exclusions": exclusions,
                    ],
                    as: WorkspaceKnowledgeStatus.self
                )
                toastHandler("Knowledge settings saved")
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func rebuildWorkspaceKnowledge() {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                knowledgeStatus = try await backend.post(
                    "/api/knowledge/reindex",
                    body: ["workspace": self.workspacePathProvider()],
                    timeout: 600,
                    as: WorkspaceKnowledgeStatus.self
                )
                await refreshWorkspaceKnowledge()
                toastHandler("Workspace knowledge rebuilt")
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func rememberWorkspaceFact(
        title: String,
        content: String,
        tags: [String],
        scope: AgentMemoryScope = .workspace,
        kind: MemoryKind = .fact,
        confidence: Double = 1,
        validUntil: Double? = nil,
        agentID: String = "primary"
    ) {
        guard let backend else { return }
        let attribution = sessionAttribution()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var body: [String: Any] = [
                    "workspace": self.workspacePathProvider(),
                    "agent_id": agentID,
                    "scope": scope.rawValue,
                    "status": "approved",
                    "title": title,
                    "content": content,
                    "tags": tags,
                    "kind": kind.rawValue,
                    "confidence": confidence,
                    "source_session_id": attribution.sessionID,
                    "source_run_id": attribution.runID ?? "",
                ]
                if let validUntil { body["valid_until"] = validUntil }
                let response: WorkspaceMemoryResponse = try await backend.post(
                    "/api/memory",
                    body: body,
                    as: WorkspaceMemoryResponse.self
                )
                workspaceMemories.removeAll { $0.id == response.memory.id }
                workspaceMemories.insert(response.memory, at: 0)
                await refreshWorkspaceKnowledge(agentID: agentID)
                toastHandler("Remembered in \(scope.title.lowercased()) memory")
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func deleteWorkspaceMemory(
        _ memory: WorkspaceMemory,
        agentID: String = "primary"
    ) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/memory/\(memory.id)",
                    query: [
                        URLQueryItem(name: "workspace", value: self.workspacePathProvider()),
                        URLQueryItem(name: "agent_id", value: agentID),
                        URLQueryItem(
                            name: "outcome",
                            value: memory.status == "candidate" ? "reject" : "delete"
                        ),
                    ],
                    as: SimpleActionResponse.self
                )
                workspaceMemories.removeAll { $0.id == memory.id }
                memoryCandidates.removeAll { $0.id == memory.id }
                await refreshWorkspaceKnowledge(agentID: agentID)
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func updateWorkspaceMemory(_ memory: WorkspaceMemory, agentID: String = "primary") {
        guard let backend else { return }
        guard let body = encodedJSONObject(memory) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var updateBody = [
                    "workspace": self.workspacePathProvider(),
                    "agent_id": agentID,
                ].merging(body) { _, new in new }
                // An omitted optional field means "leave unchanged" to the
                // vault. Send explicit null when the editor removes expiry.
                updateBody["valid_until"] = memory.validUntil ?? NSNull()
                let response: WorkspaceMemoryResponse = try await backend.put(
                    "/api/memory/\(memory.id)",
                    body: updateBody,
                    as: WorkspaceMemoryResponse.self
                )
                if let index = workspaceMemories.firstIndex(where: { $0.id == memory.id }) {
                    workspaceMemories[index] = response.memory
                }
                if let index = memoryCandidates.firstIndex(where: { $0.id == memory.id }) {
                    memoryCandidates[index] = response.memory
                }
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func approveMemoryCandidate(
        _ memory: WorkspaceMemory,
        agentID: String = "primary",
        replacingConflicts: Bool = false
    ) {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: WorkspaceMemoryResponse = try await backend.post(
                    "/api/memory/\(memory.id)/approve",
                    body: [
                        "workspace": self.workspacePathProvider(),
                        "agent_id": agentID,
                        "resolution": replacingConflicts ? "replace" : "keep_both",
                    ],
                    as: WorkspaceMemoryResponse.self
                )
                memoryCandidates.removeAll { $0.id == memory.id }
                workspaceMemories.removeAll { $0.id == memory.id }
                workspaceMemories.insert(response.memory, at: 0)
                await refreshWorkspaceKnowledge(agentID: agentID)
                toastHandler("Memory approved")
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func reviewMemoryHealth(agentID: String = "primary") {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: MemoryMaintenanceResponse = try await backend.post(
                    "/api/memory/maintenance/run",
                    body: ["workspace": self.workspacePathProvider(), "agent_id": agentID],
                    as: MemoryMaintenanceResponse.self
                )
                await refreshWorkspaceKnowledge(agentID: agentID)
                toastHandler(
                    "Memory review: \(response.expiredMarkedStale) expired, "
                        + "\(response.conflictCount) conflicts"
                )
            } catch {
                toastHandler("Could not review memory: \(error.localizedDescription)")
            }
        }
    }

    func reprocessCurrentChatMemory(agentID: String = "primary") {
        guard let backend else { return }
        let sessionID = sessionAttribution().sessionID
        guard !sessionID.isEmpty else {
            toastHandler("Open a saved chat before analyzing it")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response: MemoryReprocessResponse = try await backend.post(
                    "/api/memory/reprocess",
                    body: [
                        "workspace": self.workspacePathProvider(),
                        "agent_id": agentID,
                        "session_id": sessionID,
                    ],
                    timeout: 120,
                    as: MemoryReprocessResponse.self
                )
                await refreshWorkspaceKnowledge(agentID: agentID)
                if response.candidateCount == 0 {
                    toastHandler("Analysis completed — no durable memories found")
                } else {
                    let suffix = response.candidateCount == 1 ? "" : "s"
                    toastHandler("Added \(response.candidateCount) suggestion\(suffix) to the Inbox")
                }
            } catch {
                toastHandler("Could not analyze this chat: \(error.localizedDescription)")
            }
        }
    }

    func exportMemory(agentID: String = "primary") {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let document: MemoryExportDocument = try await backend.get(
                    "/api/memory/export",
                    query: [
                        URLQueryItem(name: "workspace", value: self.workspacePathProvider()),
                        URLQueryItem(name: "agent_id", value: agentID),
                    ],
                    as: MemoryExportDocument.self
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(document)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "Locus Memory.json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                toastHandler("Memory exported — the chosen JSON file is readable text")
            } catch {
                toastHandler("Could not export memory: \(error.localizedDescription)")
            }
        }
    }

    func importMemory(agentID: String = "primary") {
        guard let backend else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: url)
                let document = try JSONDecoder().decode(MemoryExportDocument.self, from: data)
                guard let value = encodedJSONObject(document) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let response: MemoryImportResponse = try await backend.post(
                    "/api/memory/import",
                    body: [
                        "workspace": self.workspacePathProvider(),
                        "agent_id": agentID,
                        "document": value,
                    ],
                    as: MemoryImportResponse.self
                )
                await refreshWorkspaceKnowledge(agentID: agentID)
                toastHandler("Imported \(response.imported) memories")
            } catch {
                toastHandler("Could not import memory: \(error.localizedDescription)")
            }
        }
    }

    func deleteAllWorkspaceKnowledge(agentID: String = "primary") {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/knowledge",
                    query: [URLQueryItem(name: "workspace", value: self.workspacePathProvider())],
                    as: SimpleActionResponse.self
                )
                knowledgeStatus = nil
                workspaceMemories = []
                await refreshWorkspaceKnowledge(agentID: agentID)
                toastHandler("Deleted workspace knowledge")
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }

    func deleteAllMemory(agentID: String = "primary") {
        guard let backend else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: SimpleActionResponse = try await backend.delete(
                    "/api/memory",
                    query: [
                        URLQueryItem(name: "workspace", value: self.workspacePathProvider()),
                        URLQueryItem(name: "agent_id", value: agentID),
                    ],
                    as: SimpleActionResponse.self
                )
                workspaceMemories = []
                memoryCandidates = []
                await refreshWorkspaceKnowledge(agentID: agentID)
                toastHandler("Deleted personal, workspace, and primary-agent memory")
            } catch {
                toastHandler(error.localizedDescription)
            }
        }
    }
}
