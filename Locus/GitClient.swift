import Foundation

struct GitCommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum GitClientError: LocalizedError {
    case launchFailed(String)
    case timedOut(String)
    case failed(command: String, stderr: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            "Could not run git: \(reason)"
        case .timedOut(let command):
            "git \(command) timed out"
        case .failed(let command, let stderr):
            stderr.isEmpty ? "git \(command) failed" : stderr
        }
    }
}

/// One-shot, silent `git` execution in a workspace. Deliberately not
/// BackendProcess: that manages a long-lived server; this runs one command,
/// captures its output, and exits.
struct GitClient: Sendable {
    let workspaceRoot: String

    /// Runs `git <args>`, throwing on non-zero exit with stderr as the message.
    /// `stdin` feeds the process and closes — how a synthesized patch reaches
    /// `git apply`, mirroring the agent's own patch-over-stdin path.
    @discardableResult
    func run(
        _ args: [String],
        stdin: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> GitCommandResult {
        let result = try await launch(args, stdin: stdin, timeout: timeout)
        guard result.exitCode == 0 else {
            throw GitClientError.failed(
                command: args.first ?? "",
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    private func launch(
        _ args: [String],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> GitCommandResult {
        let process = Process()
        // `env` for the same reason BackendProcess uses it; --literal-pathspecs
        // and quotepath keep filenames byte-exact both directions.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--literal-pathspecs", "-c", "core.quotepath=false"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let stdinPipe { process.standardInput = stdinPipe }

        // Both pipes are drained continuously — a command with more than the
        // pipe's 64 KB of output would otherwise block and never terminate.
        let collector = PipeCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            guard collector.beginRead() else { return }
            defer { collector.endRead() }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.append(data, to: \.stdout) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            guard collector.beginRead() else { return }
            defer { collector.endRead() }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.append(data, to: \.stderr) }
        }

        let command = args.first ?? ""
        return try await withCheckedThrowingContinuation { continuation in
            let watchdog = Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                collector.markTimedOut()
                process.terminate()
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            process.terminationHandler = { process in
                watchdog.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // A readability callback may already have consumed bytes but
                // not appended them yet. Wait for those callbacks before the
                // final synchronous drain and snapshot, so command completion
                // cannot publish a partial stdout/stderr result.
                collector.stopAndWaitForReaders()
                if let remainder = try? stdoutPipe.fileHandleForReading.readToEnd() {
                    collector.append(remainder, to: \.stdout)
                }
                if let remainder = try? stderrPipe.fileHandleForReading.readToEnd() {
                    collector.append(remainder, to: \.stderr)
                }
                let snapshot = collector.snapshot()
                if snapshot.timedOut {
                    continuation.resume(throwing: GitClientError.timedOut(command))
                } else {
                    continuation.resume(returning: GitCommandResult(
                        exitCode: process.terminationStatus,
                        stdout: snapshot.stdout,
                        stderr: snapshot.stderr
                    ))
                }
            }
            do {
                try process.run()
                if let stdin, let stdinPipe {
                    // Written off the caller's thread: a patch larger than the
                    // pipe buffer would otherwise deadlock against a git that
                    // has not started reading yet. The throwing write, not the
                    // legacy one — a git that exits without reading (a fast
                    // `apply` refusal) closes the pipe, and EPIPE must surface
                    // as the command's own exit status, not an uncaught
                    // exception.
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }
            } catch {
                watchdog.cancel()
                process.terminationHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                collector.stopAndWaitForReaders()
                continuation.resume(throwing: GitClientError.launchFailed(error.localizedDescription))
            }
        }
    }
}

/// Lock-guarded accumulation for the two pipes; readability handlers arrive
/// on arbitrary dispatch threads.
private final class PipeCollector: @unchecked Sendable {
    struct Buffers {
        var stdout = Data()
        var stderr = Data()
    }

    private let condition = NSCondition()
    private var buffers = Buffers()
    private var timedOut = false
    private var acceptsReads = true
    private var activeReaders = 0

    func beginRead() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard acceptsReads else { return false }
        activeReaders += 1
        return true
    }

    func endRead() {
        condition.lock()
        activeReaders -= 1
        if activeReaders == 0 { condition.broadcast() }
        condition.unlock()
    }

    func stopAndWaitForReaders() {
        condition.lock()
        acceptsReads = false
        while activeReaders > 0 { condition.wait() }
        condition.unlock()
    }

    func append(_ data: Data, to keyPath: WritableKeyPath<Buffers, Data>) {
        condition.lock()
        defer { condition.unlock() }
        buffers[keyPath: keyPath].append(data)
    }

    func markTimedOut() {
        condition.lock()
        defer { condition.unlock() }
        timedOut = true
    }

    func snapshot() -> (stdout: String, stderr: String, timedOut: Bool) {
        condition.lock()
        defer { condition.unlock() }
        return (
            String(decoding: buffers.stdout, as: UTF8.self),
            String(decoding: buffers.stderr, as: UTF8.self),
            timedOut
        )
    }
}

/// Builds commit messages for the Changes tab: an on-device draft via the
/// local Ollama model when one is available, a deterministic summary
/// otherwise. Never routes through the chat pipeline — a draft must not
/// pollute the transcript or the session file.
enum CommitMessageDrafter {
    static func draft(host: String, model: String, stat: String, diff: String) async -> String? {
        guard let url = URL(string: host.trimmingCharacters(in: .whitespacesAndNewlines) + "/api/generate")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let prompt = """
        Write a git commit message for the staged changes below.
        Reply with the message only — no code fences, no commentary.
        The first line is imperative and at most 72 characters; optionally \
        follow with a blank line and a short body.

        \(stat)

        \(diff)
        """
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "stream": false,
        ])
        guard let (data, response) = try? await ProxyRuntime.shared.urlSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["response"] as? String
        else { return nil }
        return sanitize(text)
    }

    /// Strips reasoning tags, fences and wrapping quotes; caps the subject.
    static func sanitize(_ raw: String) -> String? {
        let visible = AssistantSegment.parse(raw).compactMap { segment -> String? in
            if case .visible(let text) = segment { return text }
            return nil
        }.joined(separator: "\n")
        var text = visible
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, let last = text.last,
              first == last, "\"'`".contains(first), text.count > 1
        {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.count > 72 {
            lines[0] = String(first.prefix(72))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Deterministic fallback when no local model can draft.
    static func template(for staged: [GitChange]) -> String {
        guard !staged.isEmpty else { return "" }
        if staged.count == 1, let only = staged.first {
            return "Update \(only.name)"
        }
        let additions = staged.compactMap(\.additions).reduce(0, +)
        let deletions = staged.compactMap(\.deletions).reduce(0, +)
        var message = "Update \(staged.count) files (+\(additions) −\(deletions))"
        let listed = staged.prefix(6).map { "- \($0.path)" }
        message += "\n\n" + listed.joined(separator: "\n")
        if staged.count > 6 {
            message += "\n- and \(staged.count - 6) more"
        }
        return message
    }
}
