import SwiftUI

struct ReusableCheckSource: Identifiable {
    let id = UUID()
    let correction: String
    let messageIndex: Int?
    let runID: String?
    var generateRequested = true
}

struct ReusableCheckRecord: Decodable, Identifiable {
    let id: String
    let version: Int
    let revision: Int
    let state: String
    let correction: String
    let workspaceRoot: String
    let check: [String: JSONValue]
    let scope: Scope
    let source: [String: JSONValue]
    let verificationLimits: String
    let lastTest: [String: JSONValue]?
    let accounting: UsageAccounting?
    let activeVersion: Int?
    struct Scope: Decodable { let agentID: String; let files: [String]; enum CodingKeys: String, CodingKey { case agentID = "agent_id", files } }
    enum CodingKeys: String, CodingKey {
        case id, version, revision, state, correction, check, scope, source, accounting
        case activeVersion = "active_version", workspaceRoot = "workspace_root", verificationLimits = "verification_limits", lastTest = "last_test"
    }
}

struct ReusableChecksView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: ReusableCheckSource
    @State private var record: ReusableCheckRecord?
    @State private var records: [ReusableCheckRecord] = []
    @State private var requirement = ""
    @State private var kind = "human_review"
    @State private var path = ""
    @State private var expected = ""
    @State private var pointer = ""
    @State private var command = ""
    @State private var files = ""
    @State private var scopeFiles = ""
    @State private var agentOnly = false
    @State private var limits = ""
    @State private var busy = false
    @State private var message = ""
    private let kinds = ["human_review", "file_exists", "file_contains", "json_value", "command"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Reusable project check").font(.title2); Spacer(); Button("Done") { dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Original correction").font(.headline)
                    Text(record?.correction ?? (source.generateRequested ? source.correction : "Select a saved check below. To propose a new check, use Make reusable check on a user message.")).textSelection(.enabled)
                    Text(record?.workspaceRoot ?? model.workspacePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let record {
                        Text("Version \(record.version) · \(record.state.capitalized)").font(.caption)
                        if let active = record.activeVersion, active != record.version { Text("Approved version \(active) remains active for future tasks while this proposal is reviewed.").font(.caption) }
                        Form {
                            TextField("Requirement", text: $requirement, axis: .vertical)
                            Picker("Check", selection: $kind) {
                                Text("Human review").tag("human_review")
                                Text("File exists").tag("file_exists")
                                Text("File contains text").tag("file_contains")
                                Text("JSON value").tag("json_value")
                                Text("Command succeeds").tag("command")
                            }
                            if kind.hasPrefix("file_") || kind == "json_value" { TextField("Project-relative file", text: $path) }
                            if kind == "file_contains" { TextField("Required text", text: $expected, axis: .vertical) }
                            if kind == "json_value" {
                                TextField("JSON pointer", text: $pointer)
                                TextField("Expected JSON value", text: $expected)
                            }
                            if kind == "command" {
                                TextField("Command", text: $command, axis: .vertical)
                                TextField("Relevant files, separated by commas", text: $files)
                                Text("Testing and future execution use the task’s existing command permissions.").font(.caption)
                            }
                            Toggle("Only this agent or chat", isOn: $agentOnly)
                            TextField("File scope, such as Sources/** (optional)", text: $scopeFiles)
                            Text("A file scope applies when matching files change or are named in the task. Empty scope applies across this project.").font(.caption)
                            TextField("Verification limits", text: $limits, axis: .vertical)
                        }.disabled(busy || ["dismissed", "disabled"].contains(record.state))
                        HStack {
                            if record.state == "proposed" || record.state == "approved" {
                                Button("Save edits") { perform { try await saveEdits() } }
                                Button("Test check") { perform {
                                    try await saveEdits()
                                    guard let current = self.record else { return }
                                    let result: [String: JSONValue] = try await model.conversationBackend.post("/api/reusable-checks/\(current.id)/test", body: ["expected_revision": current.revision], timeout: 660, as: [String: JSONValue].self)
                                    message = result["verification_status"]?.string?.capitalized ?? "Test finished"
                                    try await load(current.id)
                                } }
                            }
                            if record.state == "proposed" {
                                Button("Approve for future tasks") { perform { try await saveEdits(); try await review("approve") } }
                                Button("Dismiss") { perform { try await review("dismiss") } }
                            }
                            if record.state == "approved" {
                                if let runID = source.runID {
                                    Button("Apply to this task") { perform {
                                        let task: [String: JSONValue] = try await model.conversationBackend.get("/api/reusable-checks/contracts/\(runID)", as: [String: JSONValue].self)
                                        let _: [String: JSONValue] = try await model.conversationBackend.post("/api/reusable-checks/\(record.id)/apply", body: ["task_id": "run:" + runID, "expected_revision": task["revision"]?.integer ?? 0, "version": record.version], as: [String: JSONValue].self)
                                        let result: [String: JSONValue] = try await model.conversationBackend.post("/api/reusable-checks/contracts/\(runID)/verify", body: [:], timeout: 660, as: [String: JSONValue].self)
                                        message = "Task checks: " + (result["verification_status"]?.string ?? "pending")
                                    } }
                                }
                            }
                            if record.activeVersion != nil { Button("Disable for future tasks") { perform { try await review("disable") } } }
                        }.disabled(busy)
                        Text("Approval fixes this version into future task requirements. Editing an approved check creates a new proposal. Existing tasks keep their saved versions.").font(.caption).foregroundStyle(.secondary)
                        if let test = record.lastTest {
                            Text("Latest test: " + (test["verification_status"]?.string ?? "Unavailable")).font(.headline)
                            Text(test["verification_reason"]?.string ?? "").font(.caption).textSelection(.enabled)
                        }
                        if let accounting = record.accounting { UsageAccountingView(accounting: accounting) }
                    }
                    if model.hasPendingPermission {
                        Button("Review permission in the task") { dismiss() }
                        Text("The test is waiting for your existing task permission prompt.").font(.caption)
                    }
                    if busy { ProgressView(record == nil ? "Generating a proposal with the selected model…" : "Working…") }
                    if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
                    DisclosureGroup("Project checks") {
                        ForEach(records) { item in
                            Button { perform { try await load(item.id) } } label: {
                                HStack { Text(item.check["requirement"]?.string ?? "Check"); Spacer(); Text("v\(item.version) · \(item.state)") }
                            }.buttonStyle(.plain).padding(.vertical, 5)
                        }
                    }
                }
            }
        }.padding(20).frame(minWidth: 660, idealWidth: 760, minHeight: 620)
        .task { if source.generateRequested { await generate() } else { await refresh() } }
    }

    private func generate() async {
        busy = true
        defer { busy = false }
        do {
            var body: [String: Any] = ["correction": source.correction, "session_id": model.currentSessionID]
            if let index = source.messageIndex { body["message_index"] = index }
            let value: ReusableCheckRecord = try await model.conversationBackend.post("/api/reusable-checks/propose", body: body, timeout: 240, as: ReusableCheckRecord.self)
            try await load(value.id)
        } catch { message = error.localizedDescription }
        await refresh()
    }
    private func load(_ id: String) async throws {
        let value = try await model.conversationBackend.get("/api/reusable-checks/\(id)", as: ReusableCheckRecord.self)
        record = value
        requirement = value.check["requirement"]?.string ?? ""
        kind = value.check["kind"]?.string ?? "human_review"
        path = value.check["path"]?.string ?? ""
        pointer = value.check["pointer"]?.string ?? ""
        command = value.check["command"]?.string ?? ""
        if kind == "json_value", let json = value.check["value"], let data = try? JSONEncoder().encode(json) { expected = String(decoding: data, as: UTF8.self) }
        else { expected = value.check["value"]?.string ?? "" }
        if case .array(let values) = value.check["files"] { files = values.compactMap(\.string).joined(separator: ", ") } else { files = "" }
        scopeFiles = value.scope.files.joined(separator: ", ")
        agentOnly = !value.scope.agentID.isEmpty
        limits = value.verificationLimits
    }
    private func split(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func saveEdits() async throws {
        guard let record else { return }
        var check: [String: Any] = ["id": record.check["id"]?.string ?? "check", "kind": kind, "requirement": requirement, "files": split(files)]
        if kind.hasPrefix("file_") || kind == "json_value" { check["path"] = path }
        if kind == "file_contains" { check["value"] = expected }
        if kind == "json_value" { check["pointer"] = pointer; check["value"] = try JSONSerialization.jsonObject(with: Data(expected.utf8), options: .fragmentsAllowed) }
        if kind == "command" { check["command"] = command; check["timeout"] = record.check["timeout"]?.integer ?? 120 }
        let agentID = agentOnly ? (record.scope.agentID.isEmpty ? record.source["agent_id"]?.string ?? model.currentSessionID : record.scope.agentID) : ""
        let edited: [String: Any] = ["check": check, "scope": ["agent_id": agentID, "files": split(scopeFiles)], "verification_limits": limits]
        let originalCheck = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.check)) as? NSDictionary
        if originalCheck == check as NSDictionary && record.scope.agentID == agentID && record.scope.files == split(scopeFiles) && record.verificationLimits == limits { return }
        let result: ReusableCheckRecord = try await model.conversationBackend.patch("/api/reusable-checks/\(record.id)", body: ["action": "edit", "expected_revision": record.revision, "edits": edited], as: ReusableCheckRecord.self)
        try await load(result.id)
        await refresh()
    }
    private func review(_ action: String) async throws {
        guard let record else { return }
        let result: ReusableCheckRecord = try await model.conversationBackend.patch("/api/reusable-checks/\(record.id)", body: ["action": action, "expected_revision": record.revision], as: ReusableCheckRecord.self)
        try await load(result.id)
        await refresh()
    }
    private func refresh() async {
        struct Listing: Decodable { let checks: [ReusableCheckRecord] }
        if let value = try? await model.conversationBackend.get("/api/reusable-checks", as: Listing.self) { records = value.checks }
    }
    private func perform(_ operation: @escaping () async throws -> Void) {
        busy = true; message = ""
        Task { defer { busy = false }; do { try await operation() } catch { message = error.localizedDescription } }
    }
}
