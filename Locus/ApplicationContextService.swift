import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ApplicationTarget: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let name: String
    let windowTitle: String
    let windowIdentifier: UInt32?
    let iconData: Data?

    var id: String {
        "\(bundleIdentifier):\(processIdentifier):\(windowIdentifier.map(String.init) ?? "window")"
    }

    var scopePayload: [String: Any] {
        var payload: [String: Any] = [
            "bundle_id": bundleIdentifier,
            "pid": Int(processIdentifier),
            "name": name,
            "window_title": windowTitle,
        ]
        if let windowIdentifier { payload["window_id"] = Int(windowIdentifier) }
        return payload
    }
}

enum ApplicationContextError: LocalizedError {
    case unavailable
    case applicationClosed
    case accessibilityPermission
    case screenRecordingPermission
    case windowUnavailable
    case screenshotFailed
    case screenshotTooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Application context is unavailable in the Mac App Store build."
        case .applicationClosed:
            "That application is no longer running."
        case .accessibilityPermission:
            "Accessibility permission is required. Grant it in Settings → Permissions, then try again."
        case .screenRecordingPermission:
            "Screen Recording permission is required. Grant it in Settings → Permissions, then try again."
        case .windowUnavailable:
            "The application does not have a capturable window."
        case .screenshotFailed:
            "Locus could not capture that application window."
        case .screenshotTooLarge:
            "The application snapshot is larger than the 15 MB image limit."
        }
    }
}

/// Tracks the most recently active external application and creates explicit,
/// one-message Appshots. Appshots combine a target-window PNG with a bounded,
/// secure-field-redacted Accessibility transcript, including content exposed
/// by the app outside the currently visible scroll region.
@MainActor
final class ApplicationContextService: ObservableObject {
    static let maximumAccessibilityCharacters = 60_000
    static let maximumScreenshotBytes = 15 * 1_024 * 1_024

    static var isAvailable: Bool {
        #if LOCUS_APP_STORE
        false
        #else
        !WorkspaceAccess.isSandboxed
        #endif
    }

    @Published private(set) var runningApplications: [ApplicationTarget] = []
    @Published private(set) var lastExternalApplication: ApplicationTarget?

    private var observers: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        refreshRunningApplications()
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID
        {
            lastExternalApplication = Self.target(from: frontmost)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.noteActivation(app) }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // WebKit and other helper processes launch frequently but
                    // can never appear in this picker. Rebuilding every app
                    // icon for those notifications creates needless layout and
                    // memory pressure while the Browser panel is opening.
                    guard app.activationPolicy == .regular
                            || self.runningApplications.contains(where: {
                                $0.processIdentifier == app.processIdentifier
                            })
                    else { return }
                    self.refreshRunningApplications()
                }
            })
        }
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func refreshRunningApplications() {
        let refreshed = NSWorkspace.shared.runningApplications
            .filter {
                !$0.isTerminated
                    && $0.activationPolicy == .regular
                    && $0.processIdentifier != ownPID
                    && $0.bundleIdentifier != nil
            }
            .compactMap(Self.target(from:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // The composer menu rebuilds when this publisher changes. Publishing
        // an identical list makes its onAppear refresh run again, repeatedly
        // re-encoding every app icon and preventing the window from settling.
        if refreshed != runningApplications {
            runningApplications = refreshed
        }
        if let last = lastExternalApplication,
           !refreshed.contains(where: { $0.id == last.id }) {
            lastExternalApplication = nil
        }
    }

    func isConnected(_ target: ApplicationTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return false
        }
        return !app.isTerminated && app.bundleIdentifier == target.bundleIdentifier
    }

    func captureSnapshot(of target: ApplicationTarget) async throws -> ChatAttachment {
        guard Self.isAvailable else { throw ApplicationContextError.unavailable }
        guard let app = exactApplication(for: target) else {
            throw ApplicationContextError.applicationClosed
        }
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            throw ApplicationContextError.accessibilityPermission
        }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ApplicationContextError.screenRecordingPermission
        }

        let windowTitle = Self.focusedWindowTitle(for: app)?.nilIfEmpty
            ?? target.windowTitle.nilIfEmpty
            ?? "Main Window"
        let accessibilityText = Self.accessibilityTranscript(for: app)
        guard let png = try await Self.captureWindow(
            for: app,
            windowIdentifier: target.windowIdentifier
        ) else {
            throw ApplicationContextError.screenshotFailed
        }
        guard png.count <= Self.maximumScreenshotBytes else {
            throw ApplicationContextError.screenshotTooLarge
        }
        let identity = UUID()
        let metadata = ApplicationSnapshotContext(
            bundleIdentifier: target.bundleIdentifier,
            processIdentifier: target.processIdentifier,
            applicationName: target.name,
            windowTitle: windowTitle,
            windowIdentifier: target.windowIdentifier,
            accessibilityText: accessibilityText,
            iconData: target.iconData
        )
        return ChatAttachment(
            id: identity,
            url: URL(fileURLWithPath: "/dev/null/appshot-\(identity.uuidString).png"),
            kind: .applicationSnapshot,
            imageData: png,
            mimeType: "image/png",
            overrideName: "\(target.name) — \(windowTitle)",
            applicationContext: metadata
        )
    }

    private func noteActivation(_ app: NSRunningApplication) {
        refreshRunningApplications()
        guard app.processIdentifier != ownPID,
              app.activationPolicy == .regular,
              let target = Self.target(from: app)
        else { return }
        lastExternalApplication = target
    }

    private func exactApplication(for target: ApplicationTarget) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier),
              !app.isTerminated,
              app.bundleIdentifier == target.bundleIdentifier
        else { return nil }
        return app
    }

    private static func target(from app: NSRunningApplication) -> ApplicationTarget? {
        guard !app.isTerminated,
              app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              let name = app.localizedName
        else { return nil }
        return ApplicationTarget(
            bundleIdentifier: bundleID,
            processIdentifier: app.processIdentifier,
            name: name,
            windowTitle: focusedWindowTitle(for: app) ?? "",
            windowIdentifier: preferredWindow(for: app)?.id,
            iconData: pngData(for: app.icon)
        )
    }

    private static func preferredWindow(
        for app: NSRunningApplication
    ) -> (id: UInt32, title: String)? {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return rows.compactMap { row -> (UInt32, String, CGFloat)? in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == app.processIdentifier,
                  let number = row[kCGWindowNumber as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width >= 80, height >= 80
            else { return nil }
            return (
                number.uint32Value,
                row[kCGWindowName as String] as? String ?? "",
                width * height
            )
        }
        .max(by: { $0.2 < $1.2 })
        .map { ($0.0, $0.1) }
    }

    private static func pngData(for image: NSImage?) -> Data? {
        guard let image else { return nil }
        let size = NSSize(width: 64, height: 64)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()
        guard let data = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func focusedWindowTitle(for app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            root,
            kAXFocusedWindowAttribute as CFString,
            &rawWindow
        ) == .success,
        let rawWindow
        else { return nil }
        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        return stringAttribute(window, kAXTitleAttribute)
    }

    private static func accessibilityTranscript(for app: NSRunningApplication) -> String {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var visited = 0
        var output = ""

        while cursor < queue.count,
              visited < 500,
              output.count < maximumAccessibilityCharacters {
            let (element, depth) = queue[cursor]
            cursor += 1
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
            let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
            let title = stringAttribute(element, kAXTitleAttribute)
                ?? stringAttribute(element, kAXDescriptionAttribute)
                ?? ""
            let secure = role.localizedCaseInsensitiveContains("secure")
                || subrole.localizedCaseInsensitiveContains("secure")
                || boolAttribute(element, "AXProtectedContent")
            let value = secure ? "••••••" : (stringAttribute(element, kAXValueAttribute) ?? "")
            let line = [role, title.nilIfEmpty, value.nilIfEmpty]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !line.isEmpty {
                output += String(repeating: "  ", count: min(depth, 8))
                    + String(line.prefix(1_000)) + "\n"
            }
            if depth < 10 {
                queue.append(contentsOf: children(of: element).prefix(80).map { ($0, depth + 1) })
            }
        }
        if cursor < queue.count || output.count >= maximumAccessibilityCharacters {
            output += "… accessibility context was bounded for this message\n"
        }
        return String(output.prefix(maximumAccessibilityCharacters))
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = attribute(element, kAXChildrenAttribute) else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let string = value as? String { return String(string.prefix(4_000)) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? NSNumber)?.boolValue == true
    }

    private static func captureWindow(
        for app: NSRunningApplication,
        windowIdentifier: UInt32?
    ) async throws -> Data? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        let candidates = content.windows.filter {
                $0.owningApplication?.processID == app.processIdentifier
                    && $0.frame.width >= 80
                    && $0.frame.height >= 80
            }
        let selected = windowIdentifier.flatMap { id in candidates.first { $0.windowID == id } }
        guard let window = selected
            ?? candidates.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            })
        else { throw ApplicationContextError.windowUnavailable }
        let configuration = SCStreamConfiguration()
        let scale = min(2.0, 1_600 / max(window.frame.width, 1))
        configuration.width = max(Int(window.frame.width * scale), 1)
        configuration.height = max(Int(window.frame.height * scale), 1)
        configuration.showsCursor = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
