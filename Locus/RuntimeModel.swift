import Foundation
import ServiceManagement

/// Installation identity is independent of individual application windows.
enum RuntimeInstallation {
    static var supported: Bool {
        #if LOCUS_DIRECT_DOWNLOAD && !LOCUS_WALLET
        true
        #else
        false
        #endif
    }
    static var enabled: Bool { supported && UserDefaults.standard.bool(forKey: "Locus.independentRuntime") }
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Locus/Runtime", directoryHint: .isDirectory)
    }
    static let plistName = "io.sparktales.locus.runtime.plist"
    static var endpoint: URL {
        if let data = try? Data(contentsOf: root.appending(path: "endpoint.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["url"] as? String, let url = URL(string: value),
           url.host == "127.0.0.1", url.scheme == "http" { return url }
        return URL(string: "http://127.0.0.1:8793")!
    }
    static var token: String? {
        guard let data = try? Data(contentsOf: root.appending(path: "runtime-secrets.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["controller_token"] as? String
    }
}

struct RuntimeWorkerRecord: Decodable, Identifiable {
    let sessionID: String
    let workspace: String
    let keepRunning: Bool
    let state: String
    var id: String { sessionID }
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", workspace, keepRunning = "keep_running", state
    }
}

struct RuntimeSnapshot: Decodable {
    let id: String
    let version: Int
    let workers: [RuntimeWorkerRecord]
}

struct RuntimeWorkerAttachment: Decodable {
    let active: Bool
    let sessionID: String
    let sessionInfo: SessionInfo?
    let pathPrefix: String
    let websocketPath: String
    enum CodingKeys: String, CodingKey {
        case active, sessionID = "session_id", sessionInfo = "session_info"
        case pathPrefix = "path_prefix", websocketPath = "websocket_path"
    }
}

@MainActor
final class RuntimeModel: ObservableObject {
    @Published private(set) var snapshot: RuntimeSnapshot?
    @Published private(set) var installationStatus = "Not enabled"
    @Published private(set) var error: String?
    @Published private(set) var isWorking = false
    private var backend: BackendService?
    private var reconnect: (() -> Void)?

    func configure(backend: BackendService, reconnect: @escaping () -> Void) {
        self.backend = backend
        self.reconnect = reconnect
    }

    func refresh() async {
        guard RuntimeInstallation.supported else { return }
        switch SMAppService.agent(plistName: RuntimeInstallation.plistName).status {
        case .enabled: installationStatus = "Enabled in macOS"
        case .requiresApproval: installationStatus = "Allow Locus in Login Items to start the runtime"
        case .notRegistered: installationStatus = "Not enabled"
        case .notFound: installationStatus = "Runtime helper is missing from this build"
        @unknown default: installationStatus = "Runtime status unavailable"
        }
        guard RuntimeInstallation.enabled, let backend else { return }
        do {
            snapshot = try await backend.get("/api/runtime", as: RuntimeSnapshot.self)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func enable(workspace: String) async {
        guard RuntimeInstallation.supported, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let manager = FileManager.default
            let root = RuntimeInstallation.root
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
            let bundled = resources.appending(path: "AgentRuntime")
            let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")
                + "-" + UUID().uuidString
            let installed = root.appending(path: "versions/" + version)
            try manager.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: bundled, to: installed)
            var pinnedCodex = ""
            if let helper = CodexComponent.helperPathForBackend(), !helper.isEmpty {
                let destination = installed.appending(path: "codex-app-server")
                try manager.copyItem(at: URL(fileURLWithPath: helper), to: destination)
                let codeHost = URL(fileURLWithPath: helper).deletingLastPathComponent().appending(path: "codex-code-mode-host")
                if manager.fileExists(atPath: codeHost.path) {
                    try manager.copyItem(at: codeHost, to: installed.appending(path: "codex-code-mode-host"))
                }
                pinnedCodex = destination.path
            }
            let configuration: [String: Any] = ["package": installed.path, "workspace": workspace, "port": 8793,
                                                "codex": pinnedCodex]
            let data = try JSONSerialization.data(withJSONObject: configuration)
            try data.write(to: root.appending(path: "launch.json"), options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appending(path: "launch.json").path)
            let service = SMAppService.agent(plistName: RuntimeInstallation.plistName)
            if service.status != .enabled { try service.register() }
            UserDefaults.standard.set(true, forKey: "Locus.independentRuntime")
            for _ in 0..<80 {
                if RuntimeInstallation.token != nil && BackendProcess.loopbackPortIsListening(at: RuntimeInstallation.endpoint) { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            reconnect?()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func setKeepRunning(sessionID: String, enabled: Bool) async {
        guard let backend else { return }
        do {
            let _: RuntimeWorkerRecord = try await backend.patch("/api/runtime/workers/\(sessionID)",
                body: ["keep_running": enabled], as: RuntimeWorkerRecord.self)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func control(sessionID: String, action: String) async {
        guard let backend else { return }
        do {
            let _: RuntimeWorkerRecord = try await backend.patch("/api/runtime/workers/\(sessionID)", body: ["action": action], as: RuntimeWorkerRecord.self)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func stopRuntime() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await SMAppService.agent(plistName: RuntimeInstallation.plistName).unregister()
            UserDefaults.standard.set(false, forKey: "Locus.independentRuntime")
            snapshot = nil
            reconnect?()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}
