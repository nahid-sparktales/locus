import AppKit
import SwiftUI

struct RemoteRuntimeRecord: Decodable, Identifiable {
    let id: String
    let host: String
    let target: String
    let requirements: String
    let deployments: [RemoteDeploymentRecord]
    let lastConnectionAt: Double?
    enum CodingKeys: String, CodingKey {
        case id, host, target, requirements, deployments
        case lastConnectionAt = "last_connection_at"
    }
}
struct RemoteDeploymentRecord: Decodable, Identifiable {
    let id: String
    let sessionID: String
    let workspace: String
    let state: String?
    enum CodingKeys: String, CodingKey { case id, workspace, state, sessionID = "session_id" }
}
struct RuntimeFileReview: Decodable, Identifiable {
    let path: String
    let reason: String?
    var id: String { path }
}
struct RuntimeProjectReview: Decodable {
    let id: String
    let fingerprint: String
    let files: [RuntimeFileReview]
    let exclusions: [RuntimeFileReview]
}
struct RuntimeReturnedChange: Decodable, Identifiable {
    let path: String
    let state: String
    var id: String { path }
}
struct RuntimeReturnedResult: Decodable {
    let changes: [RuntimeReturnedChange]
    let runs: [OrchestrationRun]
    let accounting: UsageAccounting?
    let taskContracts: [ReturnedTaskContract]?
    enum CodingKeys: String, CodingKey { case changes, runs, accounting, taskContracts = "task_contracts" }
}
struct ReturnedTaskContract: Decodable, Identifiable {
    let id: String
    let request: String
    let verificationStatus: String
    let verificationReason: String
    let evidence: [[String: JSONValue]]
    enum CodingKeys: String, CodingKey { case id, request, evidence, verificationStatus = "verification_status", verificationReason = "verification_reason" }
}

struct RemoteRuntimesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var records: [RemoteRuntimeRecord] = []
    @State private var host = ""
    @State private var validation = ""
    @State private var package = ""
    @State private var checksum = ""
    @State private var message = ""
    @State private var busy = false
    @State private var deployTarget: RemoteRuntimeRecord?
    @State private var statusTarget: RemoteRuntimeRecord?
    @State private var result: RuntimeReturnedResult?
    @State private var returnedTarget: (String, String)?
    @State private var selectedChanges: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deploy to a machine you own. Remote agents continue when this Mac disconnects.").foregroundStyle(.secondary)
            ForEach(records) { runtime in
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(runtime.host, value: runtime.target)
                    Text(runtime.requirements).font(.caption).foregroundStyle(.secondary)
                    if let latest = runtime.lastConnectionAt {
                        Text("Last connected \(Date(timeIntervalSince1970: latest).formatted())").font(.caption)
                    }
                    HStack {
                        Button("Deploy agent") { deployTarget = runtime }
                        Button("Health and approvals") { statusTarget = runtime }
                        Button("Pause runtime") { perform { let _: [String: JSONValue] = try await model.backend.post("/api/runtime/remotes/\(runtime.id)/request", body: ["method": "POST", "path": "/api/runtime/pause", "body": [:]], as: [String: JSONValue].self); message = "Remote agents are pausing." } }
                        Button("Resume scheduling") { perform { let _: [String: JSONValue] = try await model.backend.post("/api/runtime/remotes/\(runtime.id)/request", body: ["method": "POST", "path": "/api/runtime/resume", "body": [:]], as: [String: JSONValue].self) } }
                        Button("Stop service") { perform { let _: [String: Bool] = try await model.backend.post("/api/runtime/remotes/\(runtime.id)/control", body: ["action": "stop"], timeout: 60, as: [String: Bool].self); message = "Remote service stopped. Saved work remains on the host." } }
                        Button("Start service") { perform { let _: [String: Bool] = try await model.backend.post("/api/runtime/remotes/\(runtime.id)/control", body: ["action": "start"], timeout: 60, as: [String: Bool].self); await refresh() } }
                        Button("Remove connection") { perform { let _: [String: Bool] = try await model.backend.delete("/api/runtime/remotes/\(runtime.id)", as: [String: Bool].self); await refresh() } }
                    }
                    ForEach(runtime.deployments) { deployment in
                        HStack {
                            Text("Agent \(deployment.sessionID)").lineLimit(1)
                            Spacer()
                            if deployment.state == "uncertain" || deployment.state == "uploading" {
                                Button("Recover deployment") { perform { let _: RemoteDeploymentRecord = try await model.backend.post("/api/runtime/remotes/\(runtime.id)/deployments/\(deployment.id)/retry", body: [:], timeout: 180, as: RemoteDeploymentRecord.self); await refresh() } }
                            }
                            Button("Retrieve result") { perform {
                                result = try await model.backend.post("/api/runtime/remotes/\(runtime.id)/deployments/\(deployment.id)/retrieve", body: [:], timeout: 120, as: RuntimeReturnedResult.self)
                                returnedTarget = (runtime.id, deployment.id)
                                selectedChanges = []
                            } }
                        }
                    }
                }.padding(.vertical, 6)
            }
            if let result, let target = returnedTarget {
                Divider()
                Text("Returned changes").font(.headline)
                ForEach(result.changes) { change in
                    Toggle("\(change.state.capitalized): \(change.path)", isOn: Binding(get: { selectedChanges.contains(change.path) }, set: { if $0 { selectedChanges.insert(change.path) } else { selectedChanges.remove(change.path) } }))
                }
                if let accounting = result.accounting { UsageAccountingView(accounting: accounting) }
                ForEach(result.runs) { run in Text("\(run.id) · \(run.state)").font(.caption).textSelection(.enabled) }
                ForEach(result.taskContracts ?? []) { contract in
                    DisclosureGroup(contract.request + " · " + contract.verificationStatus.replacingOccurrences(of: "_", with: " ")) {
                        Text(contract.verificationReason).textSelection(.enabled)
                        ForEach(Array(contract.evidence.enumerated()), id: \.offset) { _, evidence in
                            Text((evidence["requirement"]?.string ?? "Check") + ": " + (evidence["state"]?.string ?? "Unavailable"))
                            Text(evidence["detail"]?.string ?? "").font(.caption).textSelection(.enabled)
                        }
                    }
                }
                Text("\(result.runs.count) saved runs. Local edits are checked before applying selected changes.").font(.caption)
                Button("Apply selected changes") { perform {
                    let _: [String: JSONValue] = try await model.backend.post("/api/runtime/remotes/\(target.0)/deployments/\(target.1)/apply", body: ["selected_files": Array(selectedChanges)], as: [String: JSONValue].self)
                    message = "Selected changes applied."
                    self.result = nil
                } }.disabled(selectedChanges.isEmpty)
            }
            Divider()
            Text("Add or update a runtime").font(.headline)
            TextField("SSH host", text: $host).onChange(of: host) { _, _ in validation = "" }
            Button("Validate host") { perform {
                let value: [String: JSONValue] = try await model.backend.post("/api/runtime/remotes/validate", body: ["host": host], timeout: 45, as: [String: JSONValue].self)
                validation = (value["target"]?.string ?? "") + ": " + (value["requirements"]?.string ?? "")
            } }.disabled(host.isEmpty)
            if !validation.isEmpty {
                Text(validation).font(.caption)
                HStack {
                    TextField("Verified runtime package", text: $package)
                    Button("Choose…") { let panel = NSOpenPanel(); panel.canChooseDirectories = false; if panel.runModal() == .OK, let url = panel.url { package = url.path; checksum = (try? String(contentsOf: url.appendingPathExtension("sha256"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "" } }
                }
                TextField("Release SHA-256", text: $checksum)
                Button("Install runtime") { perform {
                    let _: RemoteRuntimeRecord = try await model.backend.post("/api/runtime/remotes/install", body: ["host": host, "package": package, "sha256": checksum], timeout: 360, as: RemoteRuntimeRecord.self)
                    message = "Runtime installed and ready."
                    await refresh()
                } }.disabled(package.isEmpty || checksum.count != 64)
            }
            if !message.isEmpty { Text(message).textSelection(.enabled).font(.caption) }
        }
        .disabled(busy)
        .task { await refresh() }
        .sheet(item: $statusTarget) { target in RemoteRuntimeStatusView(runtime: target).environmentObject(model) }
        .sheet(item: $deployTarget) { target in DeployAgentView(target: target, completed: { Task { await refresh() } }).environmentObject(model) }
    }

    private func refresh() async {
        struct Listing: Decodable { let runtimes: [RemoteRuntimeRecord] }
        do { records = try await model.backend.get("/api/runtime/remotes", as: Listing.self).runtimes }
        catch { message = error.localizedDescription }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await operation() } catch { message = error.localizedDescription } }
    }
}

struct DeployAgentView: View {
    let target: RemoteRuntimeRecord
    let completed: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providerAccounts: ProviderAccountsModel
    @Environment(\.dismiss) private var dismiss
    @State private var review: RuntimeProjectReview?
    @State private var selectedFiles: Set<String> = []
    @State private var accountID = ""
    @State private var modelName = ""
    @State private var prompt = ""
    @State private var keepRunning = false
    @State private var scheduled = false
    @State private var permissionMode = "ask"
    @State private var selectedConnectors: Set<String> = []
    @State private var approvedChecks: [ReusableCheckRecord] = []
    @State private var selectedChecks: Set<String> = []
    @State private var sourceAgentID = ""
    @State private var busy = false
    @State private var message = ""
    @State private var loginURL: URL?
    @State private var loginCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deploy agent to \(target.host)").font(.title2)
            Form {
                Section("Project snapshot") {
                    Text(model.workspacePath).font(.caption).textSelection(.enabled)
                    if let review {
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(review.files) { file in
                                    Toggle(file.path, isOn: Binding(get: { selectedFiles.contains(file.path) }, set: { if $0 { selectedFiles.insert(file.path) } else { selectedFiles.remove(file.path) } }))
                                }
                            }
                        }.frame(maxHeight: 140)
                        DisclosureGroup("\(review.exclusions.count) excluded files") {
                            ForEach(review.exclusions) { file in Text("\(file.path): \(file.reason ?? "excluded")").font(.caption) }
                        }
                        Text("Current edits are included. Returned files are reviewed before you apply them.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !approvedChecks.isEmpty {
                    Section("Approved project checks") {
                        ForEach(approvedChecks) { check in
                            Toggle((check.check["requirement"]?.string ?? "Check") + " · v\(check.version)", isOn: Binding(get: { selectedChecks.contains(check.id) }, set: { if $0 { selectedChecks.insert(check.id) } else { selectedChecks.remove(check.id) } }))
                            Text(check.correction).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Account and permissions") {
                    Picker("Account", selection: $accountID) {
                        Text("Ollama on remote host").tag("")
                        ForEach(providerAccounts.providerAccounts) { account in Text(account.displayName).tag(account.id.uuidString) }
                    }
                    TextField("Model", text: $modelName)
                    Picker("Permissions", selection: $permissionMode) {
                        Text("Ask before actions").tag("ask")
                        Text("Allow file edits").tag("accept_edits")
                        Text("Allow all tools").tag("bypass")
                    }
                    Text("Only this account is provisioned. Remote tools ask for permission. ChatGPT accounts sign in independently on this host.").font(.caption).foregroundStyle(.secondary)
                    if selectedAccountIsChatGPT {
                        Button("Sign in on remote runtime") { perform { await startLogin() } }
                        Button("Use browser login through SSH") { perform { await startLogin(method: "browser") } }
                        if !loginCode.isEmpty { Text("Enter code: \(loginCode)").textSelection(.enabled) }
                        if let loginURL { Link("Open account sign-in", destination: loginURL) }
                    }
                }
                Section("Selected connectors") {
                    ForEach(model.eventAutomations.connections) { connection in
                        Toggle(connection.displayName, isOn: Binding(get: { selectedConnectors.contains(connection.id) }, set: { if $0 { selectedConnectors.insert(connection.id) } else { selectedConnectors.remove(connection.id) } }))
                    }
                    Text("Only selected connector credentials are provisioned. Sign-in stays in Locus.").font(.caption)
                }
                Section("Work") {
                    TextField("What should this agent do?", text: $prompt, axis: .vertical).lineLimit(3...6)
                    Toggle("Keep running when Locus closes", isOn: $keepRunning)
                    Toggle("Repeat every hour", isOn: $scheduled)
                }
            }.formStyle(.grouped)
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Deploy and verify readiness") { perform { try await deploy() } }
                    .disabled(review == nil || prompt.isEmpty || modelName.isEmpty || selectedFiles.isEmpty)
            }
        }.padding(24).frame(width: 650, height: 740).disabled(busy)
        .task {
            modelName = model.activeAccount?.preferredModel ?? ""
            accountID = model.activeAccount?.id.uuidString ?? ""
            perform {
                struct CheckListing: Decodable { let active_checks: [ReusableCheckRecord]; let agent_id: String }
                let listing: CheckListing = try await model.conversationBackend.get("/api/reusable-checks", as: CheckListing.self)
                sourceAgentID = listing.agent_id
                approvedChecks = listing.active_checks.filter { $0.state == "approved" && ($0.scope.agentID.isEmpty || $0.scope.agentID == sourceAgentID) }
                let value: RuntimeProjectReview = try await model.backend.post("/api/runtime/snapshots/preview", body: ["workspace": model.workspacePath], timeout: 60, as: RuntimeProjectReview.self)
                review = value; selectedFiles = Set(value.files.map(\.path))
            }
        }
    }
    private var selectedAccountIsChatGPT: Bool { providerAccounts.providerAccounts.first(where: { $0.id.uuidString == accountID })?.kind == .chatGPT }
    private var provider: [String: Any] {
        if let account = providerAccounts.providerAccounts.first(where: { $0.id.uuidString == accountID }) {
            return model.scheduledProviderRequestBody(provider: account.kind == .chatGPT ? "chatgpt" : "remote", accountID: accountID, model: modelName) ?? [:]
        }
        return ["provider": "ollama", "model": modelName]
    }
    private func startLogin(method: String = "device_code") async {
        do {
            let home = provider["codex_home_id"] as? String ?? accountID
            let value: [String: JSONValue] = try await model.backend.post("/api/runtime/remotes/\(target.id)/login", body: ["account_id": home, "method": method], timeout: 60, as: [String: JSONValue].self)
            loginCode = value["user_code"]?.string ?? ""
            loginURL = URL(string: value["auth_url"]?.string ?? "")
        } catch { message = error.localizedDescription }
    }
    private func deploy() async throws {
        guard let reviewed = review else { return }
        let value: RuntimeProjectReview = try await model.backend.post("/api/runtime/snapshots/preview", body: ["workspace": model.workspacePath, "selected_files": Array(selectedFiles)], timeout: 60, as: RuntimeProjectReview.self)
        if value.fingerprint != reviewed.fingerprint {
            review = value; message = "Project files changed. Review the updated snapshot and deploy again."; return
        }
        var configuration: [String: Any] = ["provider": provider, "permissions": ["mode": permissionMode], "keep_running": keepRunning, "agent_id": sourceAgentID]
        configuration["connectors"] = model.eventAutomations.selectedRuntimeConnectors(selectedConnectors)
        if scheduled {
            configuration["schedule"] = ["name": "Remote agent", "prompt": prompt, "mode": "work", "runner": "solo", "provider": provider["provider"] ?? "ollama", "provider_account_id": accountID, "model": modelName, "timezone": TimeZone.current.identifier, "rule": ["kind": "interval", "every": 1, "unit": "hours", "anchor": Date().timeIntervalSince1970 + 3600]] as [String: Any]
            configuration["accounts"] = [["id": accountID.isEmpty ? "ollama" : accountID, "configuration": provider]]
        } else { configuration["prompt"] = prompt }
        let _: RemoteDeploymentRecord = try await model.backend.post("/api/runtime/remotes/\(target.id)/deploy", body: ["review_id": value.id, "fingerprint": value.fingerprint, "configuration": configuration, "selected_checks": approvedChecks.filter { selectedChecks.contains($0.id) }.map { ["id": $0.id, "version": $0.version] as [String: Any] }], timeout: 180, as: RemoteDeploymentRecord.self)
        completed(); dismiss()
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await operation() } catch { message = error.localizedDescription } }
    }
}

private struct RemoteDecision: Decodable, Identifiable {
    let id: String
    let fingerprint: String
    let event: [String: JSONValue]
    var fields: [String: Any] {
        guard let data = try? JSONEncoder().encode(event), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}
private struct RuntimeAccountReadiness: Decodable, Identifiable { let id: String; let provider: String; let model: String; let readiness: String }
private struct RemoteStatus: Decodable {
    let version: Int
    let workers: [RuntimeWorkerRecord]
    let pendingApprovals: [RemoteDecision]
    let accounts: [RuntimeAccountReadiness]?
    let packageID: String?
    enum CodingKeys: String, CodingKey { case version, workers, accounts, packageID = "package_id", pendingApprovals = "pending_approvals" }
}
struct RemoteRuntimeStatusView: View {
    let runtime: RemoteRuntimeRecord
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var status: RemoteStatus?
    @State private var message = ""
    @State private var answers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(runtime.host).font(.title2)
            Form {
                if let status {
                    LabeledContent("Runtime version", value: String(status.version))
                    if let package = status.packageID { Text("Package: " + package).font(.caption).textSelection(.enabled) }
                    ForEach(status.accounts ?? []) { account in
                        LabeledContent(account.model.isEmpty ? account.provider : account.model, value: account.readiness)
                    }
                    ForEach(status.workers) { worker in
                        LabeledContent(worker.sessionID, value: worker.state.replacingOccurrences(of: "_", with: " "))
                            if let reason = worker.waitingReason, !reason.isEmpty { Text(reason).font(.caption).textSelection(.enabled) }
                        if let interrupted = worker.interruptedCommands, !interrupted.isEmpty {
                            DisclosureGroup("Review interrupted requests") {
                                Text("Inspect saved files and activity. These uncertain requests will not be replayed.").font(.caption)
                                ForEach(interrupted) { item in Text(item.command["text"]?.string ?? item.command["path"]?.string ?? item.id).font(.caption).textSelection(.enabled) }
                                Button("Keep saved work and allow new tasks") { action("PATCH", "/api/runtime/workers/\(worker.id)", ["action": "acknowledge_interruption", "reviewed_command_ids": interrupted.map(\.id)]) }
                            }
                        }
                        HStack {
                            Button("Pause agent") { action("PATCH", "/api/runtime/workers/\(worker.id)", ["action": "pause"]) }
                            Button("Resume agent") { action("PATCH", "/api/runtime/workers/\(worker.id)", ["action": "resume"]) }
                            Button("Stop agent") { action("PATCH", "/api/runtime/workers/\(worker.id)", ["action": "stop"]) }
                        }
                    }
                    ForEach(status.pendingApprovals) { decision in
                        Section("Needs your decision") {
                            Text(decision.event["preview"]?.string ?? decision.event["tool"]?.string ?? "Agent needs input").textSelection(.enabled)
                            if decision.event["type"]?.string == "question_required" {
                                ForEach((decision.fields["questions"] as? [[String: Any]] ?? []).compactMap { item -> AgentQuestion? in
                                    guard let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                                    return try? JSONDecoder().decode(AgentQuestion.self, from: data)
                                }) { question in
                                    Text(question.question)
                                    TextField("Answer", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                                }
                                Button("Send answers") { respond(decision, approved: true) }
                            } else if decision.event["type"]?.string == "permission_request" {
                                Button("Allow once") { respond(decision, approved: true) }
                            } else {
                                Text("This step requires Locus's native broker or its specialized review controls.").font(.caption)
                            }
                            Button("Decline") { respond(decision, approved: false) }
                        }
                    }
                }
            }.formStyle(.grouped)
            if !message.isEmpty { Text(message).font(.caption) }
            HStack { Button("Refresh") { Task { await refresh() } }; Spacer(); Button("Done") { dismiss() } }
        }.padding(24).frame(width: 650, height: 580).task { await refresh() }
    }
    private func refresh() async {
        do { status = try await model.backend.get("/api/runtime/remotes/\(runtime.id)", timeout: 30, as: RemoteStatus.self) }
        catch { message = error.localizedDescription }
    }
    private func action(_ method: String, _ path: String, _ body: [String: Any]) {
        Task {
            do { let _: [String: JSONValue] = try await model.backend.post("/api/runtime/remotes/\(runtime.id)/request", body: ["method": method, "path": path, "body": body], timeout: 45, as: [String: JSONValue].self); await refresh() }
            catch { message = error.localizedDescription }
        }
    }
    private func respond(_ decision: RemoteDecision, approved: Bool) {
        var response: [String: Any] = ["request_id": decision.event["request_id"]?.string ?? ""]
        let type = decision.event["type"]?.string ?? ""
        if type == "permission_request" {
            response["type"] = "permission_decision"; response["decision"] = approved ? "once" : "deny"
        } else if type == "question_required" {
            response["type"] = "question_response"; response["action"] = approved ? "answer" : "cancel"
            response["answers"] = answers.map { ["id": $0.key, "text": $0.value, "selected": []] as [String: Any] }
        } else if type == "dispatch_plan_ready" {
            response = ["type": "dispatch_decision", "run_id": decision.event["run_id"]?.string ?? "", "action": "cancel"]
        } else if type == "mcp_input_request" {
            response["type"] = "mcp_input_response"; response["action"] = "decline"
        } else {
            response["type"] = type.replacingOccurrences(of: "request", with: "result")
            response["result"] = ["error": "Declined by the user"]
        }
        action("POST", "/api/runtime/decisions/respond", ["id": decision.id, "fingerprint": decision.fingerprint, "response": response])
    }
}
