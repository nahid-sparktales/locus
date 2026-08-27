import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum SimulatorDeviceState: String, Codable, Hashable, Sendable {
    case booted = "Booted"
    case shutdown = "Shutdown"
    case unknown

    init(simctlValue: String) {
        self = Self(rawValue: simctlValue) ?? .unknown
    }
}

struct SimulatorDevice: Identifiable, Codable, Hashable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let deviceTypeIdentifier: String
    let state: SimulatorDeviceState
    let isAvailable: Bool

    var id: String { udid }
    var isIPad: Bool { name.localizedCaseInsensitiveContains("ipad") }
    var family: String { isIPad ? "iPad" : "iPhone" }
    var subtitle: String { "\(runtime) · \(state.rawValue)" }
}

struct SimulatorTarget: Identifiable, Codable, Hashable, Sendable {
    let sessionID: String
    let device: SimulatorDevice
    let attachedAt: Date

    var id: String { sessionID }
    var udid: String { device.udid }
}

enum SimulatorStreamEncoding: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case png
    case jpeg

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Auto"
        case .png: "PNG"
        case .jpeg: "JPEG"
        }
    }
}

struct SimulatorStreamSettings: Equatable, Sendable {
    var framesPerSecond = 30
    var resolutionScale = 1.0
    var encoding = SimulatorStreamEncoding.automatic
}

struct SimulatorHelperHealth: Equatable, Sendable {
    var xcodePath: String?
    var touchHelperPresent: Bool
    var treeHelperPresent: Bool
    var compatibilityReady: Bool
    var message: String

    var ready: Bool {
        xcodePath != nil && touchHelperPresent && treeHelperPresent && compatibilityReady
    }
}

enum SimulatorControlError: LocalizedError {
    case unavailable(String)
    case command(String)
    case deviceNotFound
    case deviceLeased(String)
    case noAttachedDevice
    case busy
    case staleElement
    case invalidArguments(String)
    case build(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail), .command(let detail), .invalidArguments(let detail),
             .build(let detail):
            detail
        case .deviceNotFound:
            "The selected simulator is no longer available."
        case .deviceLeased(let owner):
            "That simulator is attached to another task (\(owner)). Detach or hand it off first."
        case .noAttachedDevice:
            "Attach an iOS Simulator from the composer before using simulator tools."
        case .busy:
            "That simulator is already processing another action."
        case .staleElement:
            "The simulator element id is stale. Call simulator_get_state again."
        }
    }
}

private struct SimulatorScreenInfo: Sendable {
    let pointWidth: Int
    let pointHeight: Int
    let nativePointWidth: Int
    let nativePointHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Int
    /// Clockwise quarter turns from the native framebuffer orientation.
    let rotationQuarterTurns: Int

    func logicalPoint(fromAccessibilityPoint point: CGPoint) -> CGPoint {
        SimulatorControlService.mapAccessibilityPoint(
            point,
            displaySize: CGSize(width: pointWidth, height: pointHeight),
            clockwiseQuarterTurns: rotationQuarterTurns
        )
    }

    func logicalRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        let corners = [
            rect.origin,
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ].map(logicalPoint(fromAccessibilityPoint:))
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }

    func accessibilityPoint(fromLogicalPoint point: CGPoint) -> CGPoint {
        switch rotationQuarterTurns {
        case 1:
            CGPoint(x: point.y, y: CGFloat(pointWidth) - point.x)
        case 2:
            CGPoint(x: CGFloat(nativePointWidth) - point.x,
                    y: CGFloat(nativePointHeight) - point.y)
        case 3:
            CGPoint(x: CGFloat(pointHeight) - point.y, y: point.x)
        default:
            point
        }
    }
}

private struct SimulatorElementDescriptor {
    let center: CGPoint
}

private struct SimulatorSnapshot {
    let token: String
    let elements: [String: SimulatorElementDescriptor]
}

private struct SimulatorCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

private enum SimulatorProcessRunner {
    static func run(
        _ executable: URL,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval = 60
    ) async throws -> SimulatorCommandResult {
        let worker = Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let directory = manager.temporaryDirectory
                .appendingPathComponent("locus-simulator-command-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: directory) }
            let outputURL = directory.appendingPathComponent("stdout")
            let errorURL = directory.appendingPathComponent("stderr")
            manager.createFile(atPath: outputURL.path, contents: nil)
            manager.createFile(atPath: errorURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                    _, new in new
                }
            }
            var inputPipe: Pipe?
            if input != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                inputPipe = pipe
            }
            try process.run()
            if let input, let inputPipe {
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }

            let deadline = Date().addingTimeInterval(max(timeout, 1))
            while process.isRunning, Date() < deadline, !Task.isCancelled {
                usleep(40_000)
            }
            if process.isRunning {
                process.terminate()
                usleep(100_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            let stdout = (try? Data(contentsOf: outputURL)) ?? Data()
            let stderr = (try? Data(contentsOf: errorURL)) ?? Data()
            if Task.isCancelled { throw CancellationError() }
            if Date() >= deadline {
                throw SimulatorControlError.command("Simulator action timed out.")
            }
            return SimulatorCommandResult(
                stdout: stdout,
                stderr: stderr,
                status: process.terminationStatus
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Direct-download-only iOS Simulator broker. Every action is tied to one
/// task-owned UDID and every mutation retires the current element snapshot.
@MainActor
final class SimulatorControlService: ObservableObject {
    static var isSupportedBuild: Bool {
        #if LOCUS_APP_STORE
        false
        #else
        !WorkspaceAccess.isSandboxed
        #endif
    }

    nonisolated static func mapAccessibilityPoint(
        _ point: CGPoint,
        displaySize: CGSize,
        clockwiseQuarterTurns: Int
    ) -> CGPoint {
        switch ((clockwiseQuarterTurns % 4) + 4) % 4 {
        case 1:
            CGPoint(x: displaySize.width - point.y, y: point.x)
        case 2:
            CGPoint(x: displaySize.width - point.x, y: displaySize.height - point.y)
        case 3:
            CGPoint(x: point.y, y: displaySize.height - point.x)
        default:
            point
        }
    }

    private static func makeUITestFrame(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor(srgbRed: 0.955, green: 0.945, blue: 0.91, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

        let ink = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.07, alpha: 1)
        let muted = NSColor(srgbRed: 0.38, green: 0.39, blue: 0.34, alpha: 1)
        let accent = NSColor(srgbRed: 0.79, green: 0.96, blue: 0.29, alpha: 1)
        let card = NSColor(srgbRed: 1, green: 0.995, blue: 0.975, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: ink,
        ]
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: muted,
        ]

        "Good morning".draw(at: CGPoint(x: 24, y: 750), withAttributes: attributes)
        "A calm plan for a focused day".draw(
            at: CGPoint(x: 25, y: 724),
            withAttributes: captionAttributes
        )

        card.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: 20, y: 505, width: 350, height: 180),
            xRadius: 24,
            yRadius: 24
        ).fill()
        accent.setFill()
        NSBezierPath(
            roundedRect: CGRect(x: 40, y: 625, width: 88, height: 26),
            xRadius: 13,
            yRadius: 13
        ).fill()
        "IN PROGRESS".draw(
            at: CGPoint(x: 51, y: 631),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: ink,
            ]
        )
        "Refine onboarding".draw(
            at: CGPoint(x: 40, y: 580),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: ink,
            ]
        )
        "Review the welcome flow and ship the final polish.".draw(
            in: CGRect(x: 40, y: 532, width: 295, height: 38),
            withAttributes: captionAttributes
        )

        for (index, label) in ["Check empty state", "Tighten type scale", "Verify dark mode"].enumerated() {
            let y = 438 - CGFloat(index * 62)
            card.setFill()
            NSBezierPath(
                roundedRect: CGRect(x: 20, y: y, width: 350, height: 50),
                xRadius: 16,
                yRadius: 16
            ).fill()
            ink.setStroke()
            let circle = NSBezierPath(ovalIn: CGRect(x: 38, y: y + 16, width: 18, height: 18))
            circle.lineWidth = 1.5
            circle.stroke()
            label.draw(
                at: CGPoint(x: 70, y: y + 17),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: ink,
                ]
            )
        }

        return image
    }

    @Published private(set) var devices: [SimulatorDevice] = []
    @Published private(set) var targets: [String: SimulatorTarget] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var latestFrame: NSImage?
    @Published private(set) var previewStatus = "Attach a simulator to begin."
    @Published private(set) var previewIsLive = false
    @Published private(set) var recordingSessionID: String?
    @Published var streamSettings = SimulatorStreamSettings()
    var capabilityDidChange: (() -> Void)?

    private var leases: [String: String] = [:]
    private var snapshots: [String: SimulatorSnapshot] = [:]
    private var screenInfo: [String: SimulatorScreenInfo] = [:]
    private var displayRotations: [String: Int] = [:]
    private var busyDevices: Set<String> = []
    private var previewCapture: SimulatorStreamCapture?
    private var previewSessionID: String?
    private var recordingProcess: Process?
    private var recordingURL: URL?
    private var compatibilityFailure: String?
    private var uiTestingPointSize: CGSize?

    private let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    private let openURL = URL(fileURLWithPath: "/usr/bin/open")
    private let osascriptURL = URL(fileURLWithPath: "/usr/bin/osascript")

    var helperHealth: SimulatorHelperHealth {
        guard Self.isSupportedBuild else {
            return SimulatorHelperHealth(
                xcodePath: nil,
                touchHelperPresent: false,
                treeHelperPresent: false,
                compatibilityReady: false,
                message: "Unavailable in the Mac App Store build"
            )
        }
        let developer = selectedDeveloperDirectory()
        let touch = FileManager.default.isExecutableFile(atPath: touchHelperURL.path)
        let tree = FileManager.default.isExecutableFile(atPath: treeHelperURL.path)
        let message: String
        if developer == nil {
            message = "Select a full Xcode installation with xcode-select."
        } else if !touch || !tree {
            message = "The signed simulator bridge helpers are missing from this build."
        } else if let compatibilityFailure {
            message = compatibilityFailure
        } else {
            message = "Ready"
        }
        return SimulatorHelperHealth(
            xcodePath: developer,
            touchHelperPresent: touch,
            treeHelperPresent: tree,
            compatibilityReady: compatibilityFailure == nil,
            message: message
        )
    }

    var nativeAvailable: Bool { helperHealth.ready && compatibilityFailure == nil }

    func target(for sessionID: String) -> SimulatorTarget? { targets[sessionID] }

    /// Stable, process-local simulator state for UI coverage. It never runs
    /// outside the UI-test harness and avoids coupling layout verification to
    /// whatever devices happen to be installed on the host Mac.
    func installUITestFixture(sessionID: String, attached: Bool) {
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else { return }
        let device = SimulatorDevice(
            udid: "00000000-0000-0000-0000-00000000F17E",
            name: "iPhone 17 Pro",
            runtime: "iOS 26.0",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            state: .booted,
            isAvailable: true
        )
        devices = [device]
        guard attached else { return }

        let size = CGSize(width: 390, height: 844)
        let target = SimulatorTarget(sessionID: sessionID, device: device, attachedAt: Date())
        targets[sessionID] = target
        leases[device.udid] = sessionID
        uiTestingPointSize = size
        latestFrame = Self.makeUITestFrame(size: size)
        previewSessionID = sessionID
        previewIsLive = true
        previewStatus = "Live"
    }

    func refreshDevices() async {
        guard Self.isSupportedBuild else {
            devices = []
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if targets.isEmpty, compatibilityFailure != nil {
            compatibilityFailure = nil
            capabilityDidChange?()
        }
        do {
            let result = try await simctl(["list", "devices", "available", "-j"], timeout: 20)
            guard result.status == 0 else {
                throw SimulatorControlError.command(result.stderrText.nilIfEmpty ?? "simctl list failed")
            }
            devices = try Self.parseDevices(result.stdout)
        } catch {
            devices = []
            previewStatus = error.localizedDescription
        }
    }

    func attach(sessionID: String, udid: String) async throws -> SimulatorTarget {
        guard nativeAvailable else { throw SimulatorControlError.unavailable(helperHealth.message) }
        if let owner = leases[udid], owner != sessionID {
            throw SimulatorControlError.deviceLeased(owner)
        }
        if devices.isEmpty { await refreshDevices() }
        guard var device = devices.first(where: { $0.udid == udid && $0.isAvailable }) else {
            throw SimulatorControlError.deviceNotFound
        }
        if let existing = targets[sessionID], existing.udid != udid {
            detach(sessionID: sessionID)
        }
        leases[udid] = sessionID
        do {
            if device.state != .booted {
                let boot = try await simctl(["boot", udid], timeout: 30)
                if boot.status != 0,
                   !boot.stderrText.localizedCaseInsensitiveContains("current state: Booted") {
                    throw SimulatorControlError.command(
                        boot.stderrText.nilIfEmpty ?? "The simulator could not be booted."
                    )
                }
            }
            _ = try await SimulatorProcessRunner.run(
                openURL,
                arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid],
                timeout: 15
            )
            let status = try await simctl(["bootstatus", udid, "-b"], timeout: 90)
            guard status.status == 0 else {
                throw SimulatorControlError.command(
                    status.stderrText.nilIfEmpty ?? "The simulator did not finish booting."
                )
            }
            let compatibility = try await helper(
                treeHelperURL,
                arguments: ["--udid", udid],
                timeout: 30
            )
            guard compatibility.status == 0,
                  let compatibilityElements = try? JSONSerialization.jsonObject(
                    with: compatibility.stdout
                  ) as? [[String: Any]]
            else {
                throw SimulatorControlError.unavailable(
                    compatibility.stderrText.nilIfEmpty
                        ?? "The simulator helper is not compatible with this Xcode runtime."
                )
            }
            _ = try await screenInformation(
                for: udid,
                accessibilityElements: compatibilityElements
            )
            device = SimulatorDevice(
                udid: device.udid,
                name: device.name,
                runtime: device.runtime,
                deviceTypeIdentifier: device.deviceTypeIdentifier,
                state: .booted,
                isAvailable: device.isAvailable
            )
            let target = SimulatorTarget(sessionID: sessionID, device: device, attachedAt: Date())
            targets[sessionID] = target
            snapshots.removeValue(forKey: sessionID)
            return target
        } catch {
            if targets[sessionID]?.udid != udid { leases.removeValue(forKey: udid) }
            throw error
        }
    }

    func detach(sessionID: String) {
        guard let target = targets.removeValue(forKey: sessionID) else { return }
        if leases[target.udid] == sessionID { leases.removeValue(forKey: target.udid) }
        snapshots.removeValue(forKey: sessionID)
        screenInfo.removeValue(forKey: target.udid)
        displayRotations.removeValue(forKey: target.udid)
        if previewSessionID == sessionID { stopPreview() }
        if recordingSessionID == sessionID { cancelRecording() }
    }

    func detachAll() {
        for sessionID in Array(targets.keys) { detach(sessionID: sessionID) }
    }

    func cancelPendingActions(sessionID: String? = nil) {
        if let sessionID, let udid = targets[sessionID]?.udid {
            busyDevices.remove(udid)
        } else {
            busyDevices.removeAll()
        }
    }

    func startPreview(sessionID: String) async {
        guard let target = targets[sessionID] else {
            stopPreview()
            previewStatus = "Attach a simulator to begin."
            return
        }
        if uiTestingPointSize != nil {
            previewSessionID = sessionID
            previewIsLive = true
            previewStatus = "Live"
            return
        }
        if previewSessionID == sessionID, previewIsLive { return }
        stopPreview()
        previewSessionID = sessionID
        previewStatus = "Connecting to \(target.device.name)…"
        do {
            let capture = SimulatorStreamCapture()
            previewCapture = capture
            try await capture.start(
                deviceName: target.device.name,
                settings: streamSettings,
                onFrame: { [weak self] image in
                    Task { @MainActor [weak self] in
                        self?.latestFrame = image
                        self?.previewIsLive = true
                        self?.previewStatus = "Live"
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.previewIsLive = false
                        self?.previewStatus = message
                    }
                }
            )
        } catch {
            previewIsLive = false
            previewStatus = "Live stream unavailable — showing screenshots."
            if let data = try? await screenshotData(for: target.udid) {
                latestFrame = NSImage(data: data)
            }
        }
    }

    func restartPreview(sessionID: String) async {
        stopPreview()
        await startPreview(sessionID: sessionID)
    }

    func stopPreview() {
        previewCapture?.stop()
        previewCapture = nil
        previewSessionID = nil
        previewIsLive = false
    }

    func devicePointSize(sessionID: String) async throws -> CGSize {
        guard let target = targets[sessionID] else {
            throw SimulatorControlError.noAttachedDevice
        }
        if let uiTestingPointSize { return uiTestingPointSize }
        let info = try await screenInformation(for: target.udid)
        return CGSize(width: info.pointWidth, height: info.pointHeight)
    }

    func showFallbackFrame(_ data: Data) {
        latestFrame = NSImage(data: data)
        previewIsLive = false
        previewStatus = "Live stream unavailable — showing a screenshot."
    }

    func perform(
        tool: String,
        arguments: [String: Any],
        sessionID: String,
        workspacePath: String,
        hostedProvider: String?,
        timeoutMilliseconds: Int = 120_000
    ) async -> [String: Any] {
        do {
            switch tool {
            case "simulator_list_devices":
                await refreshDevices()
                let lines = devices.map {
                    "- \($0.name) · \($0.runtime) · \($0.state.rawValue) · \($0.udid)"
                }
                return [
                    "text": lines.isEmpty
                        ? "No available iPhone or iPad simulators were found."
                        : lines.joined(separator: "\n"),
                    "devices": devices.map {
                        [
                            "udid": $0.udid, "name": $0.name, "runtime": $0.runtime,
                            "family": $0.family, "state": $0.state.rawValue,
                            "available": $0.isAvailable,
                        ] as [String: Any]
                    },
                ]

            case "simulator_attach":
                guard let current = targets[sessionID] else {
                    throw SimulatorControlError.noAttachedDevice
                }
                let requested = (arguments["udid"] as? String) ?? current.udid
                guard requested == current.udid else {
                    throw SimulatorControlError.invalidArguments(
                        "Choose another simulator from the Locus composer so the replacement remains explicit."
                    )
                }
                _ = try await attach(sessionID: sessionID, udid: requested)
                return ["text": "Attached \(current.device.name) (\(current.udid))."]

            case "simulator_detach":
                detach(sessionID: sessionID)
                return ["text": "Detached the simulator without shutting it down."]

            default:
                guard let target = targets[sessionID] else {
                    throw SimulatorControlError.noAttachedDevice
                }
                return try await withDeviceLock(target.udid) {
                    try await self.performAttached(
                        tool: tool,
                        arguments: arguments,
                        target: target,
                        sessionID: sessionID,
                        workspacePath: workspacePath,
                        hostedProvider: hostedProvider,
                        timeoutMilliseconds: timeoutMilliseconds
                    )
                }
            }
        } catch is CancellationError {
            return ["error": "Simulator action was cancelled."]
        } catch SimulatorControlError.build(let detail) {
            return [
                "error": detail,
                "build": [
                    "succeeded": false,
                    "stage": "xcodebuild",
                    "log": String(detail.suffix(30_000)),
                ],
            ]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    func userTap(sessionID: String, point: CGPoint) async {
        _ = await perform(
            tool: "simulator_tap",
            arguments: ["x": point.x, "y": point.y],
            sessionID: sessionID,
            workspacePath: "",
            hostedProvider: nil
        )
    }

    func userSwipe(sessionID: String, from: CGPoint, to: CGPoint, duration: Int) async {
        _ = await perform(
            tool: "simulator_swipe",
            arguments: [
                "from_x": from.x, "from_y": from.y,
                "to_x": to.x, "to_y": to.y,
                "duration_ms": duration,
            ],
            sessionID: sessionID,
            workspacePath: "",
            hostedProvider: nil
        )
    }

    func userType(sessionID: String, text: String) async {
        _ = await perform(
            tool: "simulator_type_text",
            arguments: ["text": text],
            sessionID: sessionID,
            workspacePath: "",
            hostedProvider: nil
        )
    }

    func userPress(sessionID: String, button: String) async {
        _ = await perform(
            tool: "simulator_press_button",
            arguments: ["button": button],
            sessionID: sessionID,
            workspacePath: "",
            hostedProvider: nil
        )
    }

    func saveScreenshot(sessionID: String) async throws -> Data {
        guard let target = targets[sessionID] else { throw SimulatorControlError.noAttachedDevice }
        return try await screenshotData(for: target.udid)
    }

    func shutdown(sessionID: String) async throws {
        guard let target = targets[sessionID] else { throw SimulatorControlError.noAttachedDevice }
        let result = try await simctl(["shutdown", target.udid], timeout: 30)
        guard result.status == 0 else {
            throw SimulatorControlError.command(result.stderrText.nilIfEmpty ?? "Shutdown failed.")
        }
        detach(sessionID: sessionID)
        await refreshDevices()
    }

    func startRecording(sessionID: String) throws {
        guard recordingProcess == nil else { throw SimulatorControlError.busy }
        guard let target = targets[sessionID] else { throw SimulatorControlError.noAttachedDevice }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Locus-\(target.device.name)-\(UUID().uuidString).mov")
        let process = Process()
        process.executableURL = xcrunURL
        process.arguments = [
            "simctl", "io", target.udid, "recordVideo", "--codec=h264", "--force", url.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        recordingProcess = process
        recordingURL = url
        recordingSessionID = sessionID
    }

    func stopRecording() async throws -> URL {
        guard let process = recordingProcess, let url = recordingURL else {
            throw SimulatorControlError.invalidArguments("No simulator recording is active.")
        }
        process.interrupt()
        await Task.detached { process.waitUntilExit() }.value
        recordingProcess = nil
        recordingURL = nil
        recordingSessionID = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SimulatorControlError.command("The simulator video could not be finalized.")
        }
        return url
    }

    private func cancelRecording() {
        recordingProcess?.interrupt()
        recordingProcess = nil
        recordingURL = nil
        recordingSessionID = nil
    }

    private func performAttached(
        tool: String,
        arguments: [String: Any],
        target: SimulatorTarget,
        sessionID: String,
        workspacePath: String,
        hostedProvider: String?,
        timeoutMilliseconds: Int
    ) async throws -> [String: Any] {
        switch tool {
        case "simulator_get_state":
            let state = try await inspect(target: target, sessionID: sessionID)
            var result: [String: Any] = [
                "text": state.text,
                "snapshot": state.snapshot.token,
                "width": state.info.pointWidth,
                "height": state.info.pointHeight,
                "elements": state.elements,
            ]
            if (arguments["include_screenshot"] as? Bool) == true {
                addScreenshot(
                    try await screenshotData(for: target.udid),
                    target: target,
                    hostedProvider: hostedProvider,
                    sessionID: sessionID,
                    to: &result
                )
            }
            return result

        case "simulator_tap":
            let tapPoint: CGPoint
            if let element = arguments["element"] as? String {
                guard let descriptor = snapshots[sessionID]?.elements[element] else {
                    throw SimulatorControlError.staleElement
                }
                tapPoint = descriptor.center
            } else {
                tapPoint = try point(arguments, x: "x", y: "y")
            }
            let info = try await screenInformation(for: target.udid)
            try validate(tapPoint, within: info)
            let nativeTapPoint = info.accessibilityPoint(fromLogicalPoint: tapPoint)
            try await touch(
                ["tap", pixel(nativeTapPoint.x, scale: info.scale),
                 pixel(nativeTapPoint.y, scale: info.scale),
                 String(info.pixelWidth), String(info.pixelHeight)],
                udid: target.udid
            )
            snapshots.removeValue(forKey: sessionID)
            return ["text": "Tapped (\(Int(tapPoint.x)), \(Int(tapPoint.y))). Refresh state before using another element id."]

        case "simulator_swipe":
            let start = try point(arguments, x: "from_x", y: "from_y")
            let end = try point(arguments, x: "to_x", y: "to_y")
            let duration = max(min(number(arguments["duration_ms"]) ?? 300, 5_000), 50)
            let info = try await screenInformation(for: target.udid)
            try validate(start, within: info)
            try validate(end, within: info)
            let nativeStart = info.accessibilityPoint(fromLogicalPoint: start)
            let nativeEnd = info.accessibilityPoint(fromLogicalPoint: end)
            let steps = max(10, Int(duration / 16))
            try await touch([
                "swipe",
                pixel(nativeStart.x, scale: info.scale), pixel(nativeStart.y, scale: info.scale),
                pixel(nativeEnd.x, scale: info.scale), pixel(nativeEnd.y, scale: info.scale),
                String(info.pixelWidth), String(info.pixelHeight),
                String(Int(duration)), String(steps),
            ], udid: target.udid)
            snapshots.removeValue(forKey: sessionID)
            return ["text": "Swiped the simulator. Refresh state before using element ids."]

        case "simulator_type_text":
            let text = String((arguments["text"] as? String ?? "").prefix(20_000))
            guard !text.isEmpty else {
                throw SimulatorControlError.invalidArguments("Text cannot be empty.")
            }
            let copied = try await simctl(["pbcopy", target.udid], input: Data(text.utf8), timeout: 15)
            guard copied.status == 0 else {
                throw SimulatorControlError.command(copied.stderrText.nilIfEmpty ?? "Simulator pasteboard copy failed.")
            }
            try await simulatorShortcut(
                target: target,
                javascript: "const se = Application(\"System Events\"); se.keystroke(\"v\", { using: \"command down\" });"
            )
            snapshots.removeValue(forKey: sessionID)
            return ["text": "Typed text into the focused simulator field. Refresh state."]

        case "simulator_press_button":
            let button = (arguments["button"] as? String ?? "").lowercased()
            try await pressButton(button, target: target)
            snapshots.removeValue(forKey: sessionID)
            return ["text": "Pressed \(button.replacingOccurrences(of: "_", with: " ")). Refresh state."]

        case "simulator_open_url":
            let value = (arguments["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw SimulatorControlError.invalidArguments("Only absolute HTTP and HTTPS URLs can be opened.")
            }
            let opened = try await simctl(["openurl", target.udid, url.absoluteString], timeout: 30)
            guard opened.status == 0 else {
                throw SimulatorControlError.command(opened.stderrText.nilIfEmpty ?? "The URL could not be opened.")
            }
            snapshots.removeValue(forKey: sessionID)
            return ["text": "Opened \(url.absoluteString) in the simulator."]

        case "simulator_build_and_launch":
            return try await buildAndLaunch(
                arguments: arguments,
                target: target,
                workspacePath: workspacePath,
                timeoutMilliseconds: timeoutMilliseconds
            )

        case "simulator_screenshot":
            // Accessibility state makes the one-time image fallback useful for
            // a text-only route instead of returning a content-free warning.
            let state = try await inspect(target: target, sessionID: sessionID)
            var result: [String: Any] = [
                "text": state.text,
                "snapshot": state.snapshot.token,
                "width": state.info.pointWidth,
                "height": state.info.pointHeight,
                "elements": state.elements,
            ]
            addScreenshot(
                try await screenshotData(for: target.udid),
                target: target,
                hostedProvider: hostedProvider,
                sessionID: sessionID,
                to: &result
            )
            return result

        default:
            throw SimulatorControlError.invalidArguments("Unknown native simulator action: \(tool)")
        }
    }

    private func withDeviceLock<T>(
        _ udid: String,
        operation: () async throws -> T
    ) async throws -> T {
        guard busyDevices.insert(udid).inserted else { throw SimulatorControlError.busy }
        defer { busyDevices.remove(udid) }
        return try await operation()
    }

    private func inspect(
        target: SimulatorTarget,
        sessionID: String
    ) async throws -> (
        text: String,
        snapshot: SimulatorSnapshot,
        info: SimulatorScreenInfo,
        elements: [[String: Any]]
    ) {
        let result = try await helper(treeHelperURL, arguments: ["--udid", target.udid], timeout: 30)
        guard result.status == 0 else {
            throw SimulatorControlError.command(result.stderrText.nilIfEmpty ?? "The simulator UI tree is unavailable.")
        }
        guard let raw = try JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else {
            throw SimulatorControlError.command("The simulator bridge returned an invalid UI tree.")
        }
        let info = try await screenInformation(
            for: target.udid,
            accessibilityElements: raw
        )
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        var elements: [String: SimulatorElementDescriptor] = [:]
        var payload: [[String: Any]] = []
        var lines = [
            "Simulator: \(target.device.name) · \(target.device.runtime)",
            "Snapshot: \(token). Element ids expire after every action.",
        ]
        for (index, element) in raw.prefix(400).enumerated() {
            let id = "\(token)-\(index)"
            let bounds = element["bounds"] as? [String: Any] ?? [:]
            let center = element["center"] as? [String: Any] ?? [:]
            let x = number(center["x"])
                ?? ((number(bounds["x"]) ?? 0) + (number(bounds["width"]) ?? 0) / 2)
            let y = number(center["y"])
                ?? ((number(bounds["y"]) ?? 0) + (number(bounds["height"]) ?? 0) / 2)
            let accessibilityRect = CGRect(
                x: number(bounds["x"]) ?? 0,
                y: number(bounds["y"]) ?? 0,
                width: number(bounds["width"]) ?? 0,
                height: number(bounds["height"]) ?? 0
            )
            let logicalRect = info.logicalRect(fromAccessibilityRect: accessibilityRect)
            let logicalCenter = info.logicalPoint(
                fromAccessibilityPoint: CGPoint(x: x, y: y)
            )
            elements[id] = SimulatorElementDescriptor(center: logicalCenter)
            let type = (element["type"] as? String)
                ?? (element["elementType"] as? String)
            let summary = [
                type,
                element["identifier"] as? String,
                element["label"] as? String,
                element["value"] as? String,
            ].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
            lines.append(
                "[\(id)] \(String(summary.prefix(800))) · center "
                    + "\(Int(logicalCenter.x)),\(Int(logicalCenter.y))"
            )
            payload.append([
                "id": id,
                "type": type ?? "",
                "identifier": element["identifier"] as? String ?? "",
                "label": element["label"] as? String ?? "",
                "value": element["value"] as? String ?? "",
                "enabled": element["enabled"] as? Bool ?? true,
                "focused": element["focused"] as? Bool ?? false,
                "frame": [
                    "x": logicalRect.minX,
                    "y": logicalRect.minY,
                    "width": logicalRect.width,
                    "height": logicalRect.height,
                ],
            ])
        }
        if raw.count > 400 { lines.append("… bounded at 400 elements") }
        let snapshot = SimulatorSnapshot(token: token, elements: elements)
        snapshots[sessionID] = snapshot
        return (lines.joined(separator: "\n"), snapshot, info, payload)
    }

    private func addScreenshot(
        _ data: Data,
        target: SimulatorTarget,
        hostedProvider: String?,
        sessionID: String,
        to result: inout [String: Any]
    ) {
        guard HostedScreenshotConsent.shared.isAllowed(
            provider: hostedProvider,
            sessionID: sessionID
        ) else {
            result["text"] = (result["text"] as? String ?? "")
                + "\n\nScreenshot not shared; simulator accessibility text remains available."
            return
        }
        result["screenshot"] = [
            "mime_type": "image/png",
            "data": data.base64EncodedString(),
            "description": "Newest screenshot for \(target.device.name)",
        ]
    }

    private func screenshotData(for udid: String) async throws -> Data {
        let data = try await rawScreenshotData(for: udid)
        let quarterTurns = displayRotations[udid] ?? 0
        guard quarterTurns != 0, let image = CIImage(data: data) else { return data }
        let orientation: CGImagePropertyOrientation
        switch quarterTurns {
        case 1: orientation = .right
        case 2: orientation = .down
        case 3: orientation = .left
        default: return data
        }
        return CIContext().pngRepresentation(
            of: image.oriented(orientation),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) ?? data
    }

    private func rawScreenshotData(for udid: String) async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("locus-simulator-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await simctl(
            ["io", udid, "screenshot", "--type=png", url.path],
            timeout: 30
        )
        guard result.status == 0,
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else {
            throw SimulatorControlError.command(result.stderrText.nilIfEmpty ?? "Simulator screenshot failed.")
        }
        return data
    }

    private func screenInformation(
        for udid: String,
        accessibilityElements: [[String: Any]]? = nil
    ) async throws -> SimulatorScreenInfo {
        if let cached = screenInfo[udid] { return cached }
        let data = try await rawScreenshotData(for: udid)
        guard let bitmap = NSBitmapImageRep(data: data) else {
            throw SimulatorControlError.command("The simulator screenshot dimensions are unavailable.")
        }
        let screenshotWidth = bitmap.pixelsWide
        let screenshotHeight = bitmap.pixelsHigh
        let shortest = min(screenshotWidth, screenshotHeight)
        let scale: Int
        if shortest >= 1_536 {
            scale = 2
        } else if shortest % 3 == 0, (350...500).contains(shortest / 3) {
            scale = 3
        } else if shortest % 2 == 0, (300...500).contains(shortest / 2) {
            scale = 2
        } else {
            scale = 3
        }
        let rootBounds = accessibilityElements?
            .compactMap { $0["bounds"] as? [String: Any] }
            .compactMap { bounds -> (width: Int, height: Int)? in
                let width = Int(number(bounds["width"]) ?? 0)
                let height = Int(number(bounds["height"]) ?? 0)
                return width > 0 && height > 0 ? (width, height) : nil
            }
            .max { ($0.width * $0.height) < ($1.width * $1.height) }
        // simctl PNGs retain the display's native pixel orientation, while
        // Accessibility and Indigo HID use the current logical orientation.
        // Keep width/height in that logical coordinate space after rotation.
        let nativePointWidth = screenshotWidth / scale
        let nativePointHeight = screenshotHeight / scale
        let pointWidth = rootBounds?.width ?? nativePointWidth
        let pointHeight = rootBounds?.height ?? nativePointHeight
        let isSwapped = pointWidth == nativePointHeight && pointHeight == nativePointWidth
        let previousRotation = displayRotations[udid] ?? 0
        let rotation: Int
        if isSwapped {
            rotation = previousRotation % 2 == 1 ? previousRotation : 1
        } else {
            rotation = previousRotation % 2 == 0 ? previousRotation : 0
        }
        displayRotations[udid] = rotation
        let info = SimulatorScreenInfo(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            nativePointWidth: nativePointWidth,
            nativePointHeight: nativePointHeight,
            pixelWidth: screenshotWidth,
            pixelHeight: screenshotHeight,
            scale: scale,
            rotationQuarterTurns: rotation
        )
        screenInfo[udid] = info
        return info
    }

    private func touch(_ arguments: [String], udid: String) async throws {
        let result = try await helper(
            touchHelperURL,
            arguments: arguments + ["--udid", udid],
            timeout: 15
        )
        guard result.status == 0 else {
            throw SimulatorControlError.command(result.stderrText.nilIfEmpty ?? "Simulator touch injection failed.")
        }
    }

    private func pressButton(_ button: String, target: SimulatorTarget) async throws {
        let action: String
        switch button {
        case "home":
            action = "se.keystroke(\"h\", { using: [\"command down\", \"shift down\"] });"
        case "lock":
            action = "se.keystroke(\"l\", { using: \"command down\" });"
        case "volume_up":
            action = "se.keyCode(126, { using: \"command down\" });"
        case "volume_down":
            action = "se.keyCode(125, { using: \"command down\" });"
        case "rotate_left":
            action = "se.keyCode(123, { using: \"command down\" });"
        case "rotate_right":
            action = "se.keyCode(124, { using: \"command down\" });"
        default:
            throw SimulatorControlError.invalidArguments(
                "Button must be home, lock, volume_up, volume_down, rotate_left, or rotate_right."
            )
        }
        try await simulatorShortcut(
            target: target,
            javascript: "const se = Application(\"System Events\"); \(action)"
        )
        if button == "rotate_left" {
            displayRotations[target.udid] = ((displayRotations[target.udid] ?? 0) + 3) % 4
            screenInfo.removeValue(forKey: target.udid)
        } else if button == "rotate_right" {
            displayRotations[target.udid] = ((displayRotations[target.udid] ?? 0) + 1) % 4
            screenInfo.removeValue(forKey: target.udid)
        }
    }

    private func simulatorShortcut(target: SimulatorTarget, javascript: String) async throws {
        _ = try await SimulatorProcessRunner.run(
            openURL,
            arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", target.udid],
            timeout: 15
        )
        let result = try await SimulatorProcessRunner.run(
            osascriptURL,
            arguments: ["-l", "JavaScript", "-e", javascript],
            timeout: 15
        )
        guard result.status == 0 else {
            throw SimulatorControlError.command(
                result.stderrText.nilIfEmpty
                    ?? "Simulator keyboard control requires Accessibility permission."
            )
        }
    }

    private func buildAndLaunch(
        arguments: [String: Any],
        target: SimulatorTarget,
        workspacePath: String,
        timeoutMilliseconds: Int
    ) async throws -> [String: Any] {
        let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard !workspacePath.isEmpty else {
            throw SimulatorControlError.build("A workspace is required to build an app.")
        }
        let projectValue = (arguments["project"] as? String)?.nilIfEmpty
        let workspaceValue = (arguments["workspace"] as? String)?.nilIfEmpty
        guard !(projectValue != nil && workspaceValue != nil) else {
            throw SimulatorControlError.invalidArguments("Provide either project or workspace, not both.")
        }
        let container = try resolveBuildContainer(
            project: projectValue,
            workspace: workspaceValue,
            root: workspace
        )
        let scheme = try await resolveScheme(
            requested: (arguments["scheme"] as? String)?.nilIfEmpty,
            container: container
        )
        let configuration = (arguments["configuration"] as? String)?.nilIfEmpty ?? "Debug"
        let derived = FileManager.default.temporaryDirectory
            .appendingPathComponent("locus-derived-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: derived) }
        var buildArgs = ["xcodebuild", container.flag, container.url.path]
        buildArgs += [
            "-scheme", scheme,
            "-configuration", configuration,
            "-sdk", "iphonesimulator",
            "-destination", "id=\(target.udid)",
            "-derivedDataPath", derived.path,
            "build",
        ]
        let budget = min(max(Double(timeoutMilliseconds) / 1_000, 60), 900)
        let build = try await SimulatorProcessRunner.run(
            xcrunURL,
            arguments: buildArgs,
            timeout: budget
        )
        guard build.status == 0 else {
            let evidence = String((build.stdoutText + "\n" + build.stderrText).suffix(30_000))
            throw SimulatorControlError.build("xcodebuild failed:\n\(evidence)")
        }
        let products = derived.appendingPathComponent("Build/Products", isDirectory: true)
        guard let app = FileManager.default.enumerator(at: products, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: {
                $0.pathExtension == "app"
                    && $0.path.contains("\(configuration)-iphonesimulator")
            })
        else { throw SimulatorControlError.build("The build succeeded but no simulator .app was produced.") }
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty
        else { throw SimulatorControlError.build("The built app has no bundle identifier.") }
        let install = try await simctl(["install", target.udid, app.path], timeout: 90)
        guard install.status == 0 else {
            throw SimulatorControlError.build(install.stderrText.nilIfEmpty ?? "App installation failed.")
        }
        let launch = try await simctl(["launch", target.udid, bundleID], timeout: 30)
        guard launch.status == 0 else {
            throw SimulatorControlError.build(launch.stderrText.nilIfEmpty ?? "App launch failed.")
        }
        snapshots.removeValue(forKey: target.sessionID)
        return [
            "text": "Built \(scheme), installed \(bundleID), and launched it on \(target.device.name).",
            "build": [
                "succeeded": true, "scheme": scheme, "configuration": configuration,
                "bundle_id": bundleID, "udid": target.udid,
            ],
        ]
    }

    private func resolveBuildContainer(
        project: String?,
        workspace: String?,
        root: URL
    ) throws -> (url: URL, flag: String) {
        if let value = workspace ?? project {
            let url = URL(fileURLWithPath: value, relativeTo: root)
                .standardizedFileURL.resolvingSymlinksInPath()
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard url.path == root.path || url.path.hasPrefix(prefix) else {
                throw SimulatorControlError.invalidArguments("The Xcode container must be inside the active workspace.")
            }
            let expected = workspace != nil ? "xcworkspace" : "xcodeproj"
            guard url.pathExtension == expected, FileManager.default.fileExists(atPath: url.path) else {
                throw SimulatorControlError.invalidArguments("The selected .\(expected) does not exist.")
            }
            return (url, workspace != nil ? "-workspace" : "-project")
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let workspaces = children.filter { $0.pathExtension == "xcworkspace" }
        let projects = children.filter { $0.pathExtension == "xcodeproj" }
        if workspaces.count == 1 { return (workspaces[0], "-workspace") }
        if workspaces.isEmpty, projects.count == 1 { return (projects[0], "-project") }
        throw SimulatorControlError.invalidArguments(
            "The workspace does not contain one unambiguous Xcode project. Provide project or workspace."
        )
    }

    private func resolveScheme(
        requested: String?,
        container: (url: URL, flag: String)
    ) async throws -> String {
        if let requested { return requested }
        let result = try await SimulatorProcessRunner.run(
            xcrunURL,
            arguments: ["xcodebuild", container.flag, container.url.path, "-list", "-json"],
            timeout: 30
        )
        guard result.status == 0,
              let root = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        else { throw SimulatorControlError.build("Could not discover Xcode schemes.") }
        let section = (root["workspace"] as? [String: Any])
            ?? (root["project"] as? [String: Any])
        let schemes = section?["schemes"] as? [String] ?? []
        guard schemes.count == 1, let scheme = schemes.first else {
            throw SimulatorControlError.invalidArguments(
                "The Xcode container has multiple schemes. Provide scheme explicitly."
            )
        }
        return scheme
    }

    private func simctl(
        _ arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> SimulatorCommandResult {
        try await SimulatorProcessRunner.run(
            xcrunURL,
            arguments: ["simctl"] + arguments,
            input: input,
            timeout: timeout
        )
    }

    private func helper(
        _ url: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> SimulatorCommandResult {
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let developer = selectedDeveloperDirectory()
        else { throw SimulatorControlError.unavailable(helperHealth.message) }
        var lastResult: SimulatorCommandResult?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let result = try await SimulatorProcessRunner.run(
                url,
                arguments: arguments,
                environment: ["LOCUS_DEVELOPER_DIR": developer],
                timeout: timeout
            )
            if result.status == 0 {
                if compatibilityFailure != nil {
                    compatibilityFailure = nil
                    capabilityDidChange?()
                }
                return result
            }
            lastResult = result
            if attempt < 2 {
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 150 : 400))
            }
        }
        let result = lastResult ?? SimulatorCommandResult(
            stdout: Data(),
            stderr: Data("The simulator helper failed to start.".utf8),
            status: 1
        )
        compatibilityFailure = result.stderrText.nilIfEmpty
            ?? "The simulator helper compatibility probe failed."
        capabilityDidChange?()
        return result
    }

    private var helpersDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    private var touchHelperURL: URL {
        helpersDirectory.appendingPathComponent("LocusSimulatorTouch")
    }

    private var treeHelperURL: URL {
        helpersDirectory.appendingPathComponent("LocusSimulatorTree")
    }

    private func selectedDeveloperDirectory() -> String? {
        let path = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode.app/Contents/Developer"
        let simulator = URL(fileURLWithPath: path)
            .appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework")
        return FileManager.default.fileExists(atPath: simulator.path) ? path : nil
    }

    private func point(_ arguments: [String: Any], x: String, y: String) throws -> CGPoint {
        guard let xValue = number(arguments[x]), let yValue = number(arguments[y]),
              xValue.isFinite, yValue.isFinite, xValue >= 0, yValue >= 0
        else { throw SimulatorControlError.invalidArguments("Simulator coordinates must be non-negative numbers.") }
        return CGPoint(x: xValue, y: yValue)
    }

    private func validate(_ point: CGPoint, within info: SimulatorScreenInfo) throws {
        guard point.x <= CGFloat(info.pointWidth), point.y <= CGFloat(info.pointHeight) else {
            throw SimulatorControlError.invalidArguments(
                "Simulator coordinates must fit within \(info.pointWidth)×\(info.pointHeight) device points."
            )
        }
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private func pixel(_ value: CGFloat, scale: Int) -> String {
        String(Int((value * CGFloat(scale)).rounded()))
    }

    static func parseDevices(_ data: Data) throws -> [SimulatorDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]]
        else { throw SimulatorControlError.command("simctl returned an invalid device list.") }
        var result: [SimulatorDevice] = []
        for (runtimeID, values) in runtimes {
            let runtime = runtimeID
                .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                .replacingOccurrences(of: "-", with: ".")
                .replacingOccurrences(of: "iOS.", with: "iOS ")
            for value in values {
                guard let name = value["name"] as? String,
                      name.hasPrefix("iPhone") || name.hasPrefix("iPad"),
                      let udid = value["udid"] as? String
                else { continue }
                result.append(SimulatorDevice(
                    udid: udid,
                    name: name,
                    runtime: runtime,
                    deviceTypeIdentifier: value["deviceTypeIdentifier"] as? String ?? "",
                    state: SimulatorDeviceState(simctlValue: value["state"] as? String ?? ""),
                    isAvailable: value["isAvailable"] as? Bool ?? true
                ))
            }
        }
        return result.sorted {
            if $0.state != $1.state { return $0.state == .booted }
            if $0.isIPad != $1.isIPad { return $0.isIPad }
            let runtime = $0.runtime.localizedStandardCompare($1.runtime)
            if runtime != .orderedSame { return runtime == .orderedDescending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// ScreenCaptureKit output for the visible Simulator device window. Device
/// actions use native HID/simctl and do not depend on this stream, so a stream
/// failure degrades to explicit screenshots without granting a broader path.
private final class SimulatorStreamCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var onFrame: ((NSImage) -> Void)?
    private var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "locus.simulator.stream", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])

    func start(
        deviceName: String,
        settings: SimulatorStreamSettings,
        onFrame: @escaping (NSImage) -> Void,
        onError: @escaping (String) -> Void
    ) async throws {
        self.onFrame = onFrame
        self.onError = onError
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.iphonesimulator"
                && $0.frame.width >= 100
                && $0.frame.height >= 100
        }
        guard let window = candidates.first(where: {
            ($0.title ?? "").localizedCaseInsensitiveContains(deviceName)
        }) ?? candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            throw SimulatorControlError.command("Open Simulator.app to start the live stream.")
        }
        let configuration = SCStreamConfiguration()
        let scale = max(min(settings.resolutionScale, 1), 0.35)
        configuration.width = max(Int(window.frame.width * 2 * scale), 1)
        configuration.height = max(Int(window.frame.height * 2 * scale), 1)
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(min(settings.framesPerSecond, 60), 5))
        )
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let buffer = sampleBuffer.imageBuffer
        else { return }
        let input = CIImage(cvImageBuffer: buffer)
        guard let cgImage = context.createCGImage(input, from: input.extent) else {
            onError?("Live stream frame conversion failed.")
            return
        }
        onFrame?(NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width,
            height: cgImage.height
        )))
    }
}
