import AppKit
import Foundation
import Security

enum WalletRecoveryPresentationState: String, Equatable, Sendable {
    case idle
    case launching
    case presented
}

enum WalletRecoveryViewError: LocalizedError, Equatable {
    case unavailable
    case alreadyActive
    case launchFailed(String)
    case presentationTimedOut
    case invalidMessage
    case helperExited

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The signed recovery helper is missing or invalid in this build."
        case .alreadyActive:
            "Another recovery window is already active."
        case let .launchFailed(message):
            "The recovery helper could not launch: \(message)"
        case .presentationTimedOut:
            "The recovery window did not appear within 10 seconds."
        case .invalidMessage:
            "The recovery helper sent an invalid status message."
        case .helperExited:
            "The recovery helper closed before recovery finished."
        }
    }
}

/// Pure protocol lifecycle used by the process client. Keeping duplicate,
/// timeout, cancellation, and exit precedence in one small state machine makes
/// races deterministic and independently testable.
struct WalletRecoveryProcessLifecycle {
    enum Event {
        case presented
        case terminal(WalletRecoveryCeremonyResult)
    }

    let invocationID: String
    private(set) var presentationState = WalletRecoveryPresentationState.launching
    private(set) var terminalReceived = false
    private(set) var cancellationRequested = false
    private(set) var pendingFailure: WalletRecoveryViewError?

    mutating func receive(_ message: WalletRecoveryProcessMessage) throws -> Event {
        guard message.invocationID == invocationID, !terminalReceived else {
            throw WalletRecoveryViewError.invalidMessage
        }
        switch message.kind {
        case .presented:
            guard presentationState == .launching else {
                throw WalletRecoveryViewError.invalidMessage
            }
            presentationState = .presented
            return .presented
        case .terminal:
            guard let result = message.result,
                  result.outcome != .completed || presentationState == .presented else {
                throw WalletRecoveryViewError.invalidMessage
            }
            terminalReceived = true
            return .terminal(result)
        case .start, .cancel:
            throw WalletRecoveryViewError.invalidMessage
        }
    }

    mutating func requestCancellation() -> Bool {
        guard !cancellationRequested, !terminalReceived else { return false }
        cancellationRequested = true
        return true
    }

    mutating func presentationTimedOut() -> Bool {
        guard presentationState == .launching, !terminalReceived,
              !cancellationRequested else { return false }
        pendingFailure = .presentationTimedOut
        return requestCancellation()
    }

    func terminalResolution(
        _ result: WalletRecoveryCeremonyResult
    ) -> Result<WalletRecoveryCeremonyResult, WalletRecoveryViewError> {
        if let pendingFailure { return .failure(pendingFailure) }
        return .success(result)
    }

    func terminationResolution()
        -> Result<WalletRecoveryCeremonyResult, WalletRecoveryViewError> {
        if let pendingFailure { return .failure(pendingFailure) }
        if cancellationRequested {
            return .success(WalletRecoveryCeremonyResult(
                ceremonyID: invocationID,
                outcome: .canceled,
                signerStatus: nil,
                error: nil
            ))
        }
        return .failure(.helperExited)
    }
}

@MainActor
protocol WalletRecoveryViewClient: AnyObject {
    var isAvailable: Bool { get }
    var presentationState: WalletRecoveryPresentationState { get }
    var presentationStateHandler: ((WalletRecoveryPresentationState) -> Void)? { get set }
    var invalidationHandler: (() -> Void)? { get set }
    func present(mode: WalletRecoveryCeremonyMode) async throws -> WalletRecoveryCeremonyResult
    func bringToFront()
    func cancel()
}

@MainActor
final class UnavailableWalletRecoveryViewClient: WalletRecoveryViewClient {
    let isAvailable = false
    let presentationState = WalletRecoveryPresentationState.idle
    var presentationStateHandler: ((WalletRecoveryPresentationState) -> Void)?
    var invalidationHandler: (() -> Void)?

    func present(mode: WalletRecoveryCeremonyMode) async throws
        -> WalletRecoveryCeremonyResult {
        throw WalletRecoveryViewError.unavailable
    }

    func bringToFront() {}
    func cancel() {}
}

@MainActor
enum WalletRecoveryViewClientFactory {
    static func make() -> WalletRecoveryViewClient {
        #if LOCUS_DIRECT_DOWNLOAD
        let client = ProcessWalletRecoveryViewClient()
        return client.isAvailable ? client : UnavailableWalletRecoveryViewClient()
        #else
        return UnavailableWalletRecoveryViewClient()
        #endif
    }
}

#if LOCUS_DIRECT_DOWNLOAD
@MainActor
final class ProcessWalletRecoveryViewClient: WalletRecoveryViewClient {
    let isAvailable: Bool
    private(set) var presentationState = WalletRecoveryPresentationState.idle {
        didSet { presentationStateHandler?(presentationState) }
    }
    var presentationStateHandler: ((WalletRecoveryPresentationState) -> Void)?
    var invalidationHandler: (() -> Void)?

    private let helperExecutableURL: URL
    private let environment: [String: String]
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var frameDecoder = WalletRecoveryProcessFrameDecoder()
    private var invocationID: String?
    private var lifecycle: WalletRecoveryProcessLifecycle?
    private var continuation: CheckedContinuation<WalletRecoveryCeremonyResult, Error>?
    private var presentationTimeoutTask: Task<Void, Never>?
    private var forcedTerminationTask: Task<Void, Never>?

    init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let helperURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("WalletRecovery.app", isDirectory: true)
        helperExecutableURL = helperURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("WalletRecovery", isDirectory: false)
        self.environment = Self.sanitizedEnvironment(from: environment)
        isAvailable = Self.validateHelper(at: helperURL, executable: helperExecutableURL)
    }

    func present(mode: WalletRecoveryCeremonyMode) async throws
        -> WalletRecoveryCeremonyResult {
        guard isAvailable else { throw WalletRecoveryViewError.unavailable }
        guard process == nil, continuation == nil else {
            throw WalletRecoveryViewError.alreadyActive
        }

        let invocationID = UUID().uuidString.lowercased()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helperExecutableURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = environment
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processDidTerminate() }
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        // Recovery errors are returned as categorical protocol results. Drain
        // stderr without retaining or surfacing process output.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.invocationID = invocationID
        lifecycle = WalletRecoveryProcessLifecycle(invocationID: invocationID)
        frameDecoder = WalletRecoveryProcessFrameDecoder()
        presentationState = .launching

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                try process.run()
                try write(WalletRecoveryProcessMessage(
                    invocationID: invocationID,
                    kind: .start,
                    mode: mode,
                    allowPresentationOverExistingVaultForUITesting:
                        environment["LOCUS_UI_TESTING"] == "1"
                ))
                presentationTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.presentationTimedOut() }
                }
            } catch {
                finish(
                    throwing: WalletRecoveryViewError.launchFailed(
                        error.localizedDescription
                    ),
                    notifyInvalidation: false
                )
            }
        }
    }

    func bringToFront() {
        guard let process, process.isRunning,
              let application = NSRunningApplication(
                  processIdentifier: process.processIdentifier
              ) else { return }
        application.activate(options: [.activateAllWindows])
    }

    func cancel() {
        guard let invocationID, process != nil, var lifecycle,
              lifecycle.requestCancellation() else { return }
        self.lifecycle = lifecycle
        presentationTimeoutTask?.cancel()
        sendCancellation(invocationID: invocationID)
    }

    private func sendCancellation(invocationID: String) {
        try? write(WalletRecoveryProcessMessage(invocationID: invocationID, kind: .cancel))
        forcedTerminationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.process?.isRunning == true else { return }
                self.process?.terminate()
            }
        }
    }

    private func receive(_ data: Data) {
        do {
            for message in try frameDecoder.append(data) {
                try receive(message)
            }
        } catch {
            finish(throwing: WalletRecoveryViewError.invalidMessage, notifyInvalidation: true)
        }
    }

    private func receive(_ message: WalletRecoveryProcessMessage) throws {
        guard var lifecycle else { throw WalletRecoveryViewError.invalidMessage }
        let event = try lifecycle.receive(message)
        self.lifecycle = lifecycle
        switch event {
        case .presented:
            presentationTimeoutTask?.cancel()
            presentationState = .presented
        case let .terminal(result):
            switch lifecycle.terminalResolution(result) {
            case let .success(result): finish(returning: result)
            case let .failure(error):
                finish(throwing: error, notifyInvalidation: false)
            }
        }
    }

    private func presentationTimedOut() {
        guard continuation != nil, let invocationID, var lifecycle,
              lifecycle.presentationTimedOut() else { return }
        self.lifecycle = lifecycle
        sendCancellation(invocationID: invocationID)
    }

    private func processDidTerminate() {
        guard continuation != nil, let lifecycle, !lifecycle.terminalReceived else { return }
        switch lifecycle.terminationResolution() {
        case let .success(result): finish(returning: result)
        case let .failure(error):
            finish(
                throwing: error,
                notifyInvalidation: error == .helperExited
            )
        }
    }

    private func write(_ message: WalletRecoveryProcessMessage) throws {
        guard let inputPipe else { throw WalletRecoveryViewError.helperExited }
        try inputPipe.fileHandleForWriting.write(contentsOf:
            WalletRecoveryProcessFrameDecoder.encode(message)
        )
    }

    private func finish(returning result: WalletRecoveryCeremonyResult) {
        guard let continuation else { return }
        self.continuation = nil
        cleanupProcess(terminate: false)
        continuation.resume(returning: result)
    }

    private func finish(throwing error: Error, notifyInvalidation: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        cleanupProcess(terminate: true)
        continuation.resume(throwing: error)
        if notifyInvalidation { invalidationHandler?() }
    }

    private func cleanupProcess(terminate: Bool) {
        presentationTimeoutTask?.cancel()
        forcedTerminationTask?.cancel()
        presentationTimeoutTask = nil
        forcedTerminationTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe?.fileHandleForWriting.closeFile()
        process?.terminationHandler = nil
        if terminate, process?.isRunning == true { process?.terminate() }
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        invocationID = nil
        lifecycle = nil
        presentationState = .idle
    }

    private static func sanitizedEnvironment(
        from source: [String: String]
    ) -> [String: String] {
        let allowedKeys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_CTYPE"]
        var result = source.filter { allowedKeys.contains($0.key) }
        #if DEBUG
        if source["LOCUS_UI_TESTING"] == "1" {
            result["LOCUS_UI_TESTING"] = "1"
        }
        #endif
        return result
    }

    private static func validateHelper(at appURL: URL, executable: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var requirement: SecRequirement?
        let requirementText = WalletXPCCodeSigningRequirement.recoveryApplication as CFString
        guard SecRequirementCreateWithString(requirementText, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }
}
#endif
