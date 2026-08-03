import AppKit
import Foundation

enum RuntimePhase: Equatable {
    case starting(String)
    case online
    case recovering(String)
    case unavailable(String)

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .starting(let message), .recovering(let message), .unavailable(let message):
            message
        case .online:
            nil
        }
    }
}

enum OllamaEnsureResult: Equatable {
    case online(String)
    case unavailable(String)
}

/// Starts the shared Ollama application when it is installed and falls back to
/// an app-owned `ollama serve` process for command-line-only installations.
/// Repeated callers share one in-flight launch attempt, so health polling can
/// never produce a row of duplicate servers.
@MainActor
final class OllamaRuntime {
    private var cliProcess: Process?
    private var outputPipe: Pipe?
    private var ensureTask: Task<OllamaEnsureResult, Never>?
    private let logLock = NSLock()
    private var logBuffer = Data()

    var ownsRunningCLI: Bool { cliProcess?.isRunning == true }

    func ensureRunning(at host: URL) async -> OllamaEnsureResult {
        guard Self.isLoopback(host) else {
            return .unavailable("Locus only starts Ollama automatically for a local address.")
        }
        if await Self.isHealthy(at: host) {
            return .online("Ollama is already running.")
        }
        if let ensureTask {
            return await ensureTask.value
        }

        let task = Task<OllamaEnsureResult, Never> { [weak self] in
            guard let self else {
                return OllamaEnsureResult.unavailable("Ollama startup was cancelled.")
            }
            return await self.performEnsure(at: host)
        }
        ensureTask = task
        let result = await task.value
        ensureTask = nil
        return result
    }

    func stopOwnedCLI(maxWait: TimeInterval = 0.5) {
        ensureTask?.cancel()
        ensureTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        guard let process = cliProcess, process.isRunning else {
            cliProcess = nil
            return
        }
        process.terminate()
        let deadline = Date().addingTimeInterval(maxWait)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        cliProcess = nil
    }

    nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        return host.hasPrefix("127.")
    }

    nonisolated static func firstExecutable(in paths: [String]) -> URL? {
        paths.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func performEnsure(at host: URL) async -> OllamaEnsureResult {
        if cliProcess?.isRunning == true {
            if await waitUntilHealthy(host, process: cliProcess) {
                return .online("Started Ollama from the command line.")
            }
            return .unavailable(cliFailureMessage(prefix: "The Ollama process did not become ready."))
        }

        let workspace = NSWorkspace.shared
        if let applicationURL = workspace.urlForApplication(withBundleIdentifier: "com.electron.ollama") {
            let launchError = await openApplication(applicationURL, workspace: workspace)
            if launchError == nil {
                if await waitUntilHealthy(host) {
                    return .online("Started Ollama.app.")
                }
                return .unavailable(
                    "Ollama.app opened but its local service did not become ready at \(host.absoluteString)."
                )
            }
            // An installed application that cannot be opened may still carry
            // a working CLI, so continue through the explicit executable list.
        }

        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        guard let executable = Self.firstExecutable(in: candidates) else {
            return .unavailable("Ollama is not installed. Install Ollama, then choose Retry Now.")
        }
        guard startCLI(executable: executable, host: host) else {
            return .unavailable(cliFailureMessage(prefix: "Locus could not start ollama serve."))
        }
        if await waitUntilHealthy(host, process: cliProcess) {
            return .online("Started Ollama from the command line.")
        }
        return .unavailable(cliFailureMessage(prefix: "ollama serve did not become ready."))
    }

    private func openApplication(_ url: URL, workspace: NSWorkspace) async -> Error? {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            workspace.openApplication(at: url, configuration: configuration) { _, error in
                continuation.resume(returning: error)
            }
        }
    }

    private func startCLI(executable: URL, host: URL) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.appendLog(data)
            }
        }
        var environment = ProcessInfo.processInfo.environment
        if let hostname = host.host, let port = host.port {
            let renderedHost = hostname.contains(":") ? "[\(hostname)]:\(port)" : "\(hostname):\(port)"
            environment["OLLAMA_HOST"] = renderedHost
        }
        process.environment = environment

        do {
            try process.run()
            cliProcess = process
            outputPipe = pipe
            return true
        } catch {
            appendLog(Data(error.localizedDescription.utf8))
            pipe.fileHandleForReading.readabilityHandler = nil
            return false
        }
    }

    private func waitUntilHealthy(_ host: URL, process: Process? = nil) async -> Bool {
        for _ in 0..<80 {
            if Task.isCancelled { return false }
            if await Self.isHealthy(at: host) { return true }
            if let process, !process.isRunning { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await Self.isHealthy(at: host)
    }

    nonisolated static func isHealthy(at host: URL) async -> Bool {
        guard var components = URLComponents(url: host, resolvingAgainstBaseURL: false) else {
            return false
        }
        components.path = "/api/tags"
        components.query = nil
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1)
        } catch {
            return false
        }
    }

    private func appendLog(_ data: Data) {
        logLock.lock()
        defer { logLock.unlock() }
        logBuffer.append(data)
        if logBuffer.count > 16_384 {
            logBuffer.removeFirst(logBuffer.count - 16_384)
        }
    }

    private func cliFailureMessage(prefix: String) -> String {
        logLock.lock()
        let output = String(data: logBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        logLock.unlock()
        guard !output.isEmpty else { return prefix }
        return "\(prefix) \(String(output.suffix(600)))"
    }
}
