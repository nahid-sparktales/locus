import Darwin
import Foundation

enum BackendLaunchResult: Equatable {
    case running(URL)
    case failed(String)
}

final class BackendProcess {
    private var process: Process?
    private var outputPipe: Pipe?
    private var runningPort: Int?
    private var stopping = false
    private let logLock = NSLock()
    private var logBuffer = Data()

    var onUnexpectedExit: ((Int32, String) -> Void)?

    var isRunning: Bool { process?.isRunning == true }

    /// Last portion of the child's combined stdout/stderr, for diagnostics.
    var recentOutput: String {
        logLock.lock()
        defer { logLock.unlock() }
        return String(data: logBuffer, encoding: .utf8) ?? ""
    }

    @discardableResult
    func start(root: String, port preferredPort: Int, cwd: String) -> BackendLaunchResult {
        if isRunning, let runningPort,
           let url = URL(string: "http://127.0.0.1:\(runningPort)")
        {
            return .running(url)
        }

        let launch = bundledRuntime() ?? externalRuntime(root: root)
        guard let launch else {
            return .failed("Could not find the bundled agent runtime or a development runtime at \(root).")
        }
        guard let port = Self.resolvedLaunchPort(preferred: preferredPort),
              let endpoint = URL(string: "http://127.0.0.1:\(port)")
        else {
            return .failed("Could not reserve a local port for the agent.")
        }

        let process = Process()
        let pipe = Pipe()
        logLock.lock()
        logBuffer.removeAll(keepingCapacity: true)
        logLock.unlock()
        // Launching the venv's symlinked interpreter directly from a Finder app
        // can stall while Python resolves its embedded runtime. `env` preserves
        // the venv path as argv[0] and behaves consistently from Xcode or Finder.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = launch.source
        process.arguments = [
            launch.python.path,
            "-m", "ollama_code.server",
            "--port", String(port),
            "--cwd", cwd,
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        // The pipe must be drained continuously: once its 64 KB kernel buffer
        // fills, an undrained child blocks on write and the server deadlocks.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.appendLog(data)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["LOCUS_AGENT_TOKEN"] = BackendSecurity.launchToken
        environment["LOCUS_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // The bundled runtime lives inside the signed, sealed .app. A .pyc
        // written there at import time would invalidate the code signature,
        // so byte-code writing must stay off no matter where we run from.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        if WorkspaceAccess.isSandboxed,
           let support = FileManager.default.urls(
               for: .applicationSupportDirectory,
               in: .userDomainMask
           ).first
        {
            let agentHome = support
                .appending(path: "Locus", directoryHint: .isDirectory)
                .appending(path: "Agent", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(
                at: agentHome,
                withIntermediateDirectories: true
            )
            environment["OLLAMA_CODE_HOME"] = agentHome.path
        }
        if let packages = launch.packages {
            environment["PYTHONPATH"] = [
                launch.source.path,
                packages.path,
            ].joined(separator: ":")
        }
        process.environment = environment
        process.terminationHandler = { [weak self, weak process] terminated in
            guard let self, let process, process === terminated else { return }
            let output = self.recentOutput
            DispatchQueue.main.async { [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                let expected = self.stopping
                self.process = nil
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.runningPort = nil
                self.stopping = false
                if !expected {
                    self.onUnexpectedExit?(terminated.terminationStatus, output)
                }
            }
        }

        do {
            try process.run()
            stopping = false
            self.process = process
            outputPipe = pipe
            runningPort = port
            return .running(endpoint)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            outputPipe = nil
            runningPort = nil
            return .failed("Could not launch the local agent: \(error.localizedDescription)")
        }
    }

    static func resolvedLaunchPort(preferred: Int) -> Int? {
        if preferred > 0, portIsAvailable(preferred) { return preferred }
        return availableLoopbackPort()
    }

    static func portIsAvailable(_ port: Int) -> Bool {
        boundLoopbackPort(requested: port) != nil
    }

    private static func availableLoopbackPort() -> Int? {
        boundLoopbackPort(requested: 0)
    }

    /// Binds briefly to loopback to ask the kernel for an unused port. The
    /// socket is closed before Python starts; the remaining race is tiny, and
    /// an immediate bind failure is still caught by process-exit recovery.
    private static func boundLoopbackPort(requested port: Int) -> Int? {
        guard (0...Int(UInt16.max)).contains(port) else { return nil }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didRead = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard didRead == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func appendLog(_ data: Data) {
        logLock.lock()
        defer { logLock.unlock() }
        logBuffer.append(data)
        if logBuffer.count > 32_768 {
            logBuffer.removeFirst(logBuffer.count - 32_768)
        }
    }

    private func bundledRuntime() -> RuntimeLaunch? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let runtime = resources.appending(path: "AgentRuntime", directoryHint: .isDirectory)
        let source = runtime.appending(path: "source", directoryHint: .isDirectory)
        let packages = runtime.appending(path: "site-packages", directoryHint: .isDirectory)
        guard let python = Self.pythonBinary(in: runtime.appending(path: "python/bin")),
              FileManager.default.fileExists(atPath: source.appending(path: "ollama_code/server.py").path),
              FileManager.default.fileExists(atPath: packages.path)
        else {
            return nil
        }
        return RuntimeLaunch(python: python, source: source, packages: packages)
    }

    private func externalRuntime(root: String) -> RuntimeLaunch? {
        let source = URL(fileURLWithPath: root).standardizedFileURL
        let python = source.appending(path: ".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: source.appending(path: "ollama_code/server.py").path)
        else {
            return nil
        }
        return RuntimeLaunch(python: python, source: source, packages: nil)
    }

    /// Finds the interpreter without pinning a version, so the bundle keeps
    /// working as the Python toolchain moves forward.
    private static func pythonBinary(in directory: URL) -> URL? {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        let versioned = names
            .filter { $0.hasPrefix("python3.") }
            .sorted { lhs, rhs in
                let lhsMinor = Int(lhs.dropFirst("python3.".count)) ?? 0
                let rhsMinor = Int(rhs.dropFirst("python3.".count)) ?? 0
                return lhsMinor > rhsMinor
            }
        for name in versioned + ["python3"] {
            let candidate = directory.appending(path: name)
            if manager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Asks the child to exit and returns immediately.
    private func terminate() -> Process? {
        stopping = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        guard let process, process.isRunning else {
            self.process = nil
            runningPort = nil
            stopping = false
            return nil
        }
        process.terminate()
        return process
    }

    /// Waits — off the calling thread — for the child to actually exit. A
    /// backend still shutting down keeps the port bound, and a relaunch then
    /// fails to bind and leaves the app with no agent at all. Use this before
    /// starting a replacement; it never blocks the main thread.
    func stopAndWait() async {
        guard let process = terminate() else { return }
        self.process = nil
        runningPort = nil
        await Task.detached(priority: .userInitiated) {
            if !Self.waitForExit(process, timeout: 3) {
                kill(process.processIdentifier, SIGKILL)
                _ = Self.waitForExit(process, timeout: 1)
            }
        }.value
    }

    /// Bounded, synchronous stop for app exit, where a multi-second wait
    /// would beachball the quit. After SIGKILL there is nothing to wait for:
    /// at termination the only requirement is that the child not outlive us.
    func stop(maxWait: TimeInterval = 0.5) {
        guard let process = terminate() else { return }
        self.process = nil
        runningPort = nil
        if !Self.waitForExit(process, timeout: maxWait) {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    deinit {
        stop()
    }
}

private struct RuntimeLaunch {
    let python: URL
    let source: URL
    let packages: URL?
}
