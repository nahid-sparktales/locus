import AppKit
import Darwin
import Foundation
import SwiftTerm

/// A single, app-owned PTY session for the active workspace.
///
/// The terminal deliberately does not travel through the agent socket. It is
/// direct user input, remains alive while the local agent reconnects, and does
/// not enter the conversation transcript.
@MainActor
final class TerminalSession: NSObject, ObservableObject {
    struct Configuration: Equatable {
        let workspacePath: String
        let shell: String
        let loginShell: Bool
    }

    @Published private(set) var isRunning = false
    @Published private(set) var title = "Terminal"
    @Published private(set) var currentDirectory = ""
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsWorkspaceSwitchConfirmation = false

    private var terminalView: LocusLocalProcessTerminalView?
    private var configuration: Configuration?
    private var pendingConfiguration: Configuration?
    private var directoryTimer: Timer?

    static var isSandboxedBuild: Bool {
        #if LOCUS_APP_STORE
        true
        #else
        false
        #endif
    }

    var hostView: NSView {
        if let terminalView { return terminalView }
        let created = makeTerminalView()
        terminalView = created
        return created
    }

    var workspaceDisplayName: String {
        let path = currentDirectory.isEmpty ? configuration?.workspacePath ?? "" : currentDirectory
        guard !path.isEmpty else { return "Workspace" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Applies the app's active workspace. A foreground job is never killed
    /// silently; the new workspace waits until the user confirms the restart.
    func configure(workspacePath: String, shell: String, loginShell: Bool) {
        let canonical = URL(fileURLWithPath: workspacePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let next = Configuration(
            workspacePath: canonical,
            shell: shell.trimmingCharacters(in: .whitespacesAndNewlines),
            loginShell: loginShell
        )
        guard next != configuration else { return }
        if isRunning, hasForegroundJob {
            pendingConfiguration = next
            needsWorkspaceSwitchConfirmation = true
            return
        }
        apply(next, start: terminalView != nil)
    }

    func confirmWorkspaceSwitch() {
        guard let pendingConfiguration else { return }
        self.pendingConfiguration = nil
        needsWorkspaceSwitchConfirmation = false
        apply(pendingConfiguration, start: true)
    }

    func keepCurrentShell() {
        pendingConfiguration = nil
        needsWorkspaceSwitchConfirmation = false
    }

    /// Starts lazily when the terminal surface first appears.
    func ensureStarted() {
        guard !isRunning else { return }
        if configuration == nil {
            configure(
                workspacePath: FileManager.default.currentDirectoryPath,
                shell: "",
                loginShell: true
            )
        }
        startConfiguredShell()
    }

    func focus() {
        guard let terminalView else { return }
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    func restart() {
        terminate()
        terminalView?.terminal.resetToInitialState()
        lastExitCode = nil
        errorMessage = nil
        startConfiguredShell()
        focus()
    }

    func terminate() {
        guard let terminalView, terminalView.process.running else { return }
        stopDirectoryUpdates()
        let pid = terminalView.process.shellPid
        if pid > 0 {
            // forkpty makes the shell a process-group leader. Signal the group
            // first so a foreground TUI cannot outlive the terminal surface.
            _ = Darwin.kill(-pid, SIGTERM)
        }
        terminalView.terminate()
        isRunning = false
    }

    func clear() {
        guard let terminalView else { return }
        terminalView.clearScrollback()
        let formFeed: [UInt8] = [0x0c]
        terminalView.send(data: formFeed[...])
        focus()
    }

    func showFind() {
        guard let terminalView else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        terminalView.performTextFinderAction(item)
    }

    var hasForegroundJob: Bool {
        guard let terminalView, terminalView.process.running else { return false }
        let descriptor = terminalView.process.childfd
        guard descriptor >= 0 else { return false }
        var foregroundGroup: pid_t = 0
        guard ioctl(descriptor, TIOCGPGRP, &foregroundGroup) == 0 else { return false }
        return foregroundGroup > 0 && foregroundGroup != terminalView.process.shellPid
    }

    private func apply(_ next: Configuration, start: Bool) {
        if isRunning { terminate() }
        configuration = next
        currentDirectory = next.workspacePath
        title = "Terminal"
        lastExitCode = nil
        errorMessage = nil
        if start { startConfiguredShell() }
    }

    private func makeTerminalView() -> LocusLocalProcessTerminalView {
        let options = TerminalOptions(
            cols: 100,
            rows: 30,
            termName: "xterm-256color",
            scrollback: 10_000
        )
        let view = LocusLocalProcessTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            options: options
        )
        view.processDelegate = self
        view.nativeBackgroundColor = NSColor.textBackgroundColor
        view.nativeForegroundColor = NSColor.textColor
        view.allowMouseReporting = true
        view.linkReporting = .implicit
        view.linkHighlightMode = .hoverWithModifier
        view.optionAsMetaKey = true
        // NSViewRepresentable modifiers do not reliably bridge identifiers to
        // a hosted AppKit view. Put the terminal surface itself in the
        // accessibility tree so VoiceOver and UI automation can find it.
        view.setAccessibilityElement(true)
        view.setAccessibilityIdentifier("terminal.output")
        view.setAccessibilityLabel("Terminal output")
        return view
    }

    private func startConfiguredShell() {
        guard let configuration else { return }
        let view = terminalView ?? {
            let created = makeTerminalView()
            terminalView = created
            return created
        }()
        guard !view.process.running else {
            isRunning = true
            return
        }
        let shell = resolvedShell(configuration.shell)
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            errorMessage = "The configured shell is not executable: \(shell)"
            isRunning = false
            return
        }
        let arguments = configuration.loginShell ? ["-l"] : []
        title = URL(fileURLWithPath: shell).lastPathComponent
        view.startProcess(
            executable: shell,
            args: arguments,
            environment: childEnvironment(shell: shell),
            currentDirectory: configuration.workspacePath
        )
        isRunning = view.process.running
        if !isRunning {
            errorMessage = "The shell could not be started."
        } else {
            beginDirectoryUpdates()
        }
    }

    private func resolvedShell(_ configured: String) -> String {
        if !configured.isEmpty { return configured }
        let inherited = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if !inherited.isEmpty, FileManager.default.isExecutableFile(atPath: inherited) {
            return inherited
        }
        return FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh"
    }

    private func childEnvironment(shell: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("LOCUS_")
            || key == "PYTHONPATH"
            || key.hasPrefix("DYLD_")
            || key == "LD_PRELOAD"
        {
            environment.removeValue(forKey: key)
        }
        environment["SHELL"] = shell
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["LANG"]?.isEmpty ?? true { environment["LANG"] = "en_US.UTF-8" }
        let inheritedPath = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let standardPath = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "/bin", "/usr/sbin", "/sbin",
        ]
        environment["PATH"] = (inheritedPath + standardPath).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: ":")
        return environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
    }

    /// Shells are not required to emit OSC 7 after `cd`. Polling the retained
    /// child process keeps the header truthful while still accepting OSC title
    /// and directory reports immediately when a shell or TUI provides them.
    private func beginDirectoryUpdates() {
        stopDirectoryUpdates()
        updateCurrentDirectoryFromProcess()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateCurrentDirectoryFromProcess()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        directoryTimer = timer
    }

    private func stopDirectoryUpdates() {
        directoryTimer?.invalidate()
        directoryTimer = nil
    }

    private func updateCurrentDirectoryFromProcess() {
        guard let terminalView, terminalView.process.running else {
            stopDirectoryUpdates()
            return
        }
        var information = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(
            terminalView.process.shellPid,
            PROC_PIDVNODEPATHINFO,
            0,
            &information,
            Int32(size)
        ) == Int32(size) else { return }
        let path = withUnsafePointer(to: &information.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        if !path.isEmpty { currentDirectory = path }
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Terminal"
            : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        currentDirectory = directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        stopDirectoryUpdates()
        lastExitCode = exitCode
        isRunning = false
    }
}

/// SwiftTerm's local-process view with a strict external-link allowlist.
final class LocusLocalProcessTerminalView: LocalProcessTerminalView {
    private let inputWriter = AtomicTerminalWriter()

    /// SwiftTerm dispatches every input chunk through a separate asynchronous
    /// write. Rapid key events and bracketed-paste markers can therefore race
    /// each other. Keep each logical input chunk ordered and indivisible from
    /// the next chunk all the way to the PTY.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        inputWriter.write(Data(data), to: process.childfd)
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme)
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Serializes complete terminal input chunks. A POSIX write can be short, so
/// one queued operation owns the descriptor until its entire chunk is sent;
/// later key and paste events cannot interleave with it.
final class AtomicTerminalWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.sparktales.locus.terminal-input")

    func write(_ data: Data, to descriptor: Int32) {
        guard descriptor >= 0, !data.isEmpty else { return }
        queue.async {
            data.withUnsafeBytes { rawBuffer in
                guard var pointer = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let count = Darwin.write(descriptor, pointer, remaining)
                    if count > 0 {
                        remaining -= count
                        pointer = pointer.advanced(by: count)
                    } else if count < 0, errno == EINTR {
                        continue
                    } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        var writable = pollfd(
                            fd: descriptor,
                            events: Int16(POLLOUT),
                            revents: 0
                        )
                        while Darwin.poll(&writable, 1, 1_000) < 0, errno == EINTR {}
                        guard writable.revents & Int16(POLLOUT) != 0 else { return }
                    } else {
                        return
                    }
                }
            }
        }
    }
}
