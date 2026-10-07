import SwiftUI

/// A view onto the existing memory vault. It has no independent persistence,
/// and every request carries the selected Companion's captured attribution.
@MainActor
final class CompanionMemoryNotebookModel: ObservableObject {
    @Published private(set) var memories: [WorkspaceMemory] = []
    @Published private(set) var scope: CompanionConversationScope?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isAvailable = false
    @Published private(set) var error: String?
    private var revision = UUID()

    func refresh(backend: BackendService, scope requested: CompanionConversationScope) async {
        let token = UUID()
        revision = token
        scope = requested
        memories = []
        error = nil
        isAvailable = false
        isLoading = true
        defer { if revision == token { isLoading = false } }
        do {
            let conversation = try await backend.get("/api/sessions/\(requested.sessionID)", as: CompanionMemoryConversation.self)
            guard conversation.identity.matches(sessionID: requested.sessionID, profileID: requested.profileID, workspace: requested.workspace),
                  conversation.detail.archived != true else {
                throw SavedAgentConversationError.conversationUnavailable("This Companion conversation is no longer available.")
            }
            let query = Self.query(requested)
            let status = try await backend.get("/api/memory/status", query: query, as: MemoryVaultStatus.self)
            guard status.memoryAvailable != false else {
                throw SavedAgentConversationError.unavailable(status.restoreProtection?.message ?? "Memory is unavailable. Review memory recovery in Settings.")
            }
            let response = try await backend.get("/api/memory", query: query, as: WorkspaceMemoriesResponse.self)
            guard revision == token, !Task.isCancelled else { return }
            memories = response.memories.sorted { $0.updatedAt > $1.updatedAt }
            isAvailable = true
        } catch {
            guard revision == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    static func query(_ scope: CompanionConversationScope) -> [URLQueryItem] {
        [URLQueryItem(name: "workspace", value: scope.workspace),
         URLQueryItem(name: "agent_id", value: scope.profileID.uuidString)]
    }

    /// Preserve the user's wording; removing the request prefix is the only
    /// interpretation before they review and confirm the proposed memory.
    static func proposedMemory(from request: String) -> String {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["please remember that ", "please remember ", "remember that ", "remember "] {
            if text.lowercased().hasPrefix(prefix) {
                return String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    static func memoryBody(scope: CompanionConversationScope, title: String, content: String,
                           memoryScope: AgentMemoryScope, existing: WorkspaceMemory? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "workspace": scope.workspace, "agent_id": scope.profileID.uuidString,
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "content": content.trimmingCharacters(in: .whitespacesAndNewlines),
            "scope": memoryScope.rawValue, "kind": existing?.kind ?? "preference",
            "tags": existing?.tags ?? [], "status": existing?.status ?? "approved",
        ]
        // Editing a record preserves its source; only the user-confirmed
        // creation is attributed to the active Companion conversation.
        if existing == nil { body["source_session_id"] = scope.sessionID }
        if let existing {
            body["revision"] = existing.revision
            body["pinned"] = existing.pinned
            body["confidence"] = existing.confidence
            body["valid_from"] = existing.validFrom
            body["valid_until"] = existing.validUntil
        }
        return body
    }

    func save(backend: BackendService, title: String, content: String, memoryScope: AgentMemoryScope,
              existing: WorkspaceMemory?, expectedScope: CompanionConversationScope?) async -> Bool {
        guard let scope, scope == expectedScope, isAvailable, !isSaving, !isLoading,
              existing == nil || memories.contains(where: { $0.id == existing?.id }) else { return false }
        let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 16_000 else {
            error = "Enter a memory of up to 16 KB."; return false
        }
        let token = revision
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            var body = Self.memoryBody(scope: scope, title: title.isEmpty ? String(clean.prefix(80)) : title,
                                      content: clean, memoryScope: memoryScope, existing: existing)
            if let existing, existing.resolvedScope != memoryScope {
                // The canonical vault intentionally forbids in-place scope
                // widening. Copy the reviewed value, then forget the old one.
                // A failed forget rolls the new copy back and leaves the
                // original source of truth intact.
                body.removeValue(forKey: "revision")
                body["source_session_id"] = existing.sourceSessionID ?? scope.sessionID
                body["source_run_id"] = existing.sourceRunID
                let replacement = try await backend.post("/api/memory", body: body, as: WorkspaceMemoryResponse.self)
                do {
                    let _: SimpleActionResponse = try await backend.delete("/api/memory/\(existing.id)",
                        query: Self.query(scope), as: SimpleActionResponse.self)
                } catch {
                    let originalError = error
                    do {
                        let _: SimpleActionResponse = try await backend.delete("/api/memory/\(replacement.memory.id)",
                            query: Self.query(scope), as: SimpleActionResponse.self)
                    } catch {
                        throw SavedAgentConversationError.unavailable("The scope change could not finish or roll back. Both memories may remain; refresh and review them before relying on the restriction.")
                    }
                    throw SavedAgentConversationError.unavailable("The original memory was kept because its scope could not be changed: \(originalError.localizedDescription)")
                }
            } else if let existing {
                _ = try await backend.put("/api/memory/\(existing.id)", body: body, as: WorkspaceMemoryResponse.self)
            } else {
                _ = try await backend.post("/api/memory", body: body, as: WorkspaceMemoryResponse.self)
            }
            guard revision == token else { return false }
            await refresh(backend: backend, scope: scope)
            return error == nil
        } catch {
            if revision == token { self.error = error.localizedDescription }
            return false
        }
    }

    func forget(_ memory: WorkspaceMemory, backend: BackendService) async {
        guard let scope, isAvailable, !isSaving else { return }
        let token = revision
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let _: SimpleActionResponse = try await backend.delete("/api/memory/\(memory.id)",
                query: Self.query(scope) + [URLQueryItem(name: "outcome", value: memory.isCandidate ? "reject" : "delete")],
                as: SimpleActionResponse.self)
            guard revision == token else { return }
            memories.removeAll { $0.id == memory.id }
        } catch { if revision == token { self.error = error.localizedDescription } }
    }

    func approve(_ memory: WorkspaceMemory, backend: BackendService) async {
        guard let scope, isAvailable, !isSaving else { return }
        let token = revision
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let _: WorkspaceMemoryResponse = try await backend.post("/api/memory/\(memory.id)/approve",
                body: ["workspace": scope.workspace, "agent_id": scope.profileID.uuidString, "resolution": "keep_both"],
                as: WorkspaceMemoryResponse.self)
            guard revision == token else { return }
            await refresh(backend: backend, scope: scope)
        } catch { if revision == token { self.error = error.localizedDescription } }
    }
}

private struct CompanionMemoryConversation: Decodable {
    let detail: SessionDetailResponse
    let identity: AgentCrewChatSessionIdentity
    init(from decoder: Decoder) throws {
        detail = try SessionDetailResponse(from: decoder)
        identity = try AgentCrewChatSessionIdentity(from: decoder)
    }
}

struct CompanionMemoryNotebookView: View {
    let backend: BackendService
    let scope: CompanionConversationScope
    var openSource: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = CompanionMemoryNotebookModel()
    @State private var editorPresented = false
    @State private var editing: WorkspaceMemory?
    @State private var query = ""
    @State private var memoryRequest = ""
    @State private var proposedContent = ""

    private var visibleMemories: [WorkspaceMemory] {
        model.memories.filter { query.isEmpty || ($0.title + " " + $0.content).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("What you know about me").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Review your existing memories, correct them, or choose where a new preference belongs. Proposed memories are used only after approval.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Remember that I prefer examples before explanations…", text: $memoryRequest)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("companion.memory.request")
                Button("Review memory") {
                    proposedContent = CompanionMemoryNotebookModel.proposedMemory(from: memoryRequest)
                    editing = nil
                    editorPresented = true
                }.disabled(!model.isAvailable || model.isSaving || memoryRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField("Search memories", text: $query).textFieldStyle(.roundedBorder)
            if model.isLoading { ProgressView("Opening memory notebook…") }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleMemories) { memory in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(memory.title).font(.headline)
                                Spacer()
                                Text(memory.isCandidate ? "Awaiting approval" : memory.resolvedScope.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(memory.content).textSelection(.enabled)
                            Text("Updated \(Date(timeIntervalSince1970: memory.updatedAt).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if memory.stale { Text("This memory needs review.").font(.caption).foregroundStyle(.secondary) }
                            if memory.hasConflicts { Text("Conflicting memories are retained until you review them.").font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                if memory.isCandidate {
                                    Button("Approve") { Task { await model.approve(memory, backend: backend) } }
                                }
                                Button("Edit") { editing = memory; proposedContent = ""; editorPresented = true }
                                Button(memory.isCandidate ? "Reject" : "Forget") { Task { await model.forget(memory, backend: backend) } }
                                Spacer()
                                if let source = memory.sourceSessionID, !source.isEmpty {
                                    if let openSource { Button("Source conversation") { openSource(source) } }
                                    else { Text("Source: \(source)").lineLimit(1).truncationMode(.middle) }
                                }
                            }.font(.caption).disabled(model.isSaving)
                        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if visibleMemories.isEmpty, model.isAvailable, !model.isLoading {
                        Text(query.isEmpty ? "No memories yet. Tell your Companion what you want it to remember, then review the proposed memory here." : "No matching memories.")
                            .foregroundStyle(.secondary).padding(.vertical)
                    }
                }
            }
            Button("Refresh") { Task { await model.refresh(backend: backend, scope: scope) } }
                .disabled(model.isLoading || model.isSaving)
        }
        .padding(20).frame(minWidth: 480, idealWidth: 560, minHeight: 430, idealHeight: 620)
        .task(id: scope) { await model.refresh(backend: backend, scope: scope) }
        .onChange(of: scope) { _, _ in editorPresented = false; editing = nil }
        .sheet(isPresented: $editorPresented) {
            CompanionMemoryEditor(existing: editing, proposedContent: proposedContent, model: model, backend: backend)
        }
        .accessibilityIdentifier("companion.memory.notebook")
    }
}

private struct CompanionMemoryEditor: View {
    let existing: WorkspaceMemory?
    let capturedScope: CompanionConversationScope?
    @ObservedObject var model: CompanionMemoryNotebookModel
    let backend: BackendService
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var memoryScope: AgentMemoryScope

    init(existing: WorkspaceMemory?, proposedContent: String, model: CompanionMemoryNotebookModel, backend: BackendService) {
        self.existing = existing
        capturedScope = model.scope
        self.model = model
        self.backend = backend
        _title = State(initialValue: existing?.title ?? "")
        _content = State(initialValue: existing?.content ?? proposedContent)
        _memoryScope = State(initialValue: existing?.resolvedScope ?? .agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Remember this" : "Correct this memory").font(.headline)
            TextField("Title (optional)", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $content).frame(minHeight: 120)
                .accessibilityLabel("What should your Companion remember?")
            Picker("Remember for", selection: $memoryScope) {
                Text("This companion").tag(AgentMemoryScope.agent)
                Text("This project").tag(AgentMemoryScope.workspace)
                Text("Across projects").tag(AgentMemoryScope.personal)
            }.disabled(existing?.resolvedKind == .procedure)
            if existing?.resolvedKind == .procedure {
                Text("A learned procedure keeps its reviewed scope. Use procedure review to change its access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(memoryScope == .workspace ? "Project: \(model.scope?.workspace ?? "")" : memoryScope == .personal
                 ? "Personal memory can be recalled across projects when their memory policy allows it."
                 : "This memory belongs to your Companion's saved profile.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(model.isSaving)
                Spacer()
                Button(model.isSaving ? "Saving…" : existing == nil ? "Confirm memory" : "Save correction") {
                    Task {
                        if await model.save(backend: backend, title: title, content: content,
                                            memoryScope: memoryScope, existing: existing, expectedScope: capturedScope) { dismiss() }
                    }
                }.disabled(model.isSaving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 460)
    }
}
