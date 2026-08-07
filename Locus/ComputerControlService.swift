import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Native, direct-build-only broker for bounded Mac UI automation. The Python
/// agent never receives an AX object: it gets snapshot-scoped ids, and every
/// mutation invalidates those ids so stale UI state cannot be acted on.
@MainActor
final class ComputerControlService: ObservableObject {
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var isExecuting = false

    static var isAvailable: Bool {
        #if LOCUS_APP_STORE
        false
        #else
        !WorkspaceAccess.isSandboxed
        #endif
    }

    private struct ElementDescriptor {
        let element: AXUIElement
        let role: String
        let title: String
        let detail: String
        let secure: Bool
        let frame: CGRect?
    }

    private struct Snapshot {
        let token: String
        let app: NSRunningApplication
        let elements: [String: ElementDescriptor]
    }

    private var snapshots: [String: Snapshot] = [:]
    private var hostedScreenshotConsent: Set<String> = []
    private var latestScreenshot: Data?
    private var cancellationGeneration = 0
    private var currentSessionID: String?

    func beginSession(_ sessionID: String) {
        guard !sessionID.isEmpty, currentSessionID != sessionID else { return }
        currentSessionID = sessionID
        hostedScreenshotConsent.removeAll()
        latestScreenshot = nil
        snapshots.removeAll()
        cancelPendingActions()
    }

    func cancelPendingActions() {
        cancellationGeneration += 1
        isExecuting = false
    }

    func refreshPermissionStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        refreshPermissionStatus()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissionStatus()
    }

    func openAccessibilitySettings() {
        openPrivacySettings("Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openPrivacySettings("Privacy_ScreenCapture")
    }

    func perform(
        tool: String,
        arguments: [String: Any],
        hostedProvider: String?,
        timeoutMilliseconds: Int = 60_000
    ) async -> [String: Any] {
        guard Self.isAvailable else {
            return ["error": "Computer Control is unavailable in the App Store sandbox build."]
        }
        refreshPermissionStatus()
        guard accessibilityGranted else {
            return ["error": "Accessibility permission is required. Open Locus Settings → Permissions."]
        }
        let generation = cancellationGeneration
        let deadline = Date().addingTimeInterval(
            Double(max(min(timeoutMilliseconds, 120_000), 1_000)) / 1_000
        )
        isExecuting = true
        defer { isExecuting = false }

        switch tool {
        case "computer_list_apps":
            let apps = runningApps().map { app in
                "- \(app.localizedName ?? "Unknown") · \(app.bundleIdentifier ?? "no bundle id") · pid \(app.processIdentifier)"
            }
            return ["text": apps.isEmpty ? "No visible apps are running." : apps.joined(separator: "\n")]

        case "computer_get_state":
            guard let app = resolveApp(arguments["app"] as? String) else {
                return ["error": "The requested app is not running."]
            }
            let state = inspect(app: app)
            var result: [String: Any] = ["text": state.text]
            if (arguments["include_screenshot"] as? Bool) == true,
               screenRecordingGranted,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            {
                if let provider = hostedProvider,
                   !hostedScreenshotConsent.contains(provider)
                {
                    if requestHostedScreenshotConsent(provider: provider) {
                        hostedScreenshotConsent.insert(provider)
                    } else {
                        result["text"] = state.text + "\n\nScreenshot not shared; the user declined hosted-provider consent. AX text is still available."
                        return result
                    }
                }
                guard actionIsCurrent(generation, deadline: deadline) else {
                    return staleActionResult(generation)
                }
                if let screenshot = await captureTargetWindow(app: app) {
                    guard actionIsCurrent(generation, deadline: deadline) else {
                        return staleActionResult(generation)
                    }
                    latestScreenshot = screenshot
                    result["screenshot"] = [
                        "mime_type": "image/png",
                        "data": screenshot.base64EncodedString(),
                        "description": "Newest target-window screenshot for \(app.localizedName ?? "the app")",
                    ]
                }
            }
            return result

        case "computer_activate_app":
            guard let app = resolveApp(arguments["app"] as? String) else {
                return ["error": "The requested app is not running."]
            }
            guard actionIsCurrent(generation, deadline: deadline) else {
                return staleActionResult(generation)
            }
            guard app.activate(options: [.activateAllWindows]) else {
                return ["error": "The app could not be activated."]
            }
            invalidate(app)
            return ["text": "Activated \(app.localizedName ?? "the app"). Refresh state before using element ids."]

        case "computer_click", "computer_set_value", "computer_drag":
            return performElementAction(
                tool: tool,
                arguments: arguments,
                generation: generation,
                deadline: deadline
            )

        case "computer_type_text":
            return typeFocusedText(arguments, generation: generation, deadline: deadline)

        case "computer_press_key":
            return pressKey(arguments, generation: generation, deadline: deadline)

        case "computer_scroll":
            return scroll(arguments, generation: generation, deadline: deadline)

        default:
            return ["error": "Unknown native computer action: \(tool)"]
        }
    }

    // MARK: - AX state

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func resolveApp(_ query: String?) -> NSRunningApplication? {
        let wanted = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return runningApps().first {
            $0.bundleIdentifier?.caseInsensitiveCompare(wanted) == .orderedSame
                || $0.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame
        } ?? runningApps().first {
            $0.localizedName?.localizedCaseInsensitiveContains(wanted) == true
        }
    }

    private func appKey(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    }

    private func inspect(app: NSRunningApplication) -> (text: String, snapshot: Snapshot) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let token = UUID().uuidString.prefix(8).lowercased()
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var elements: [String: ElementDescriptor] = [:]
        var lines = [
            "App: \(app.localizedName ?? "Unknown") (\(app.bundleIdentifier ?? "no bundle id"))",
            "Snapshot: \(token). Element ids expire after every action.",
        ]

        while cursor < queue.count, elements.count < 300 {
            let (element, depth) = queue[cursor]
            cursor += 1
            let role = stringAttribute(element, "AXRole") ?? "AXUnknown"
            let subrole = stringAttribute(element, "AXSubrole") ?? ""
            let title = stringAttribute(element, "AXTitle")
                ?? stringAttribute(element, "AXDescription")
                ?? ""
            let secure = role.localizedCaseInsensitiveContains("secure")
                || subrole.localizedCaseInsensitiveContains("secure")
                || boolAttribute(element, "AXProtectedContent")
            let rawValue = secure ? "••••••" : (stringAttribute(element, "AXValue") ?? "")
            let id = "\(token)-\(elements.count)"
            elements[id] = ElementDescriptor(
                element: element,
                role: role,
                title: title,
                detail: rawValue,
                secure: secure,
                frame: frame(of: element)
            )
            let summary = [role, title.nilIfEmpty, rawValue.nilIfEmpty]
                .compactMap { $0 }
                .joined(separator: " · ")
            lines.append("\(String(repeating: "  ", count: min(depth, 8)))[\(id)] \(String(summary.prefix(500)))")
            if depth < 8 {
                queue.append(contentsOf: children(of: element).prefix(60).map { ($0, depth + 1) })
            }
        }
        if cursor < queue.count { lines.append("… bounded at 300 elements") }
        let snapshot = Snapshot(token: String(token), app: app, elements: elements)
        snapshots[appKey(app)] = snapshot
        return (lines.joined(separator: "\n"), snapshot)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = attribute(element, "AXChildren") else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let string = value as? String { return String(string.prefix(2_000)) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? NSNumber)?.boolValue == true
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRaw = attribute(element, "AXPosition"),
              let sizeRaw = attribute(element, "AXSize"),
              CFGetTypeID(positionRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRaw as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    // MARK: - Mutations and safety

    private func performElementAction(
        tool: String,
        arguments: [String: Any],
        generation: Int,
        deadline: Date
    ) -> [String: Any] {
        guard let app = resolveApp(arguments["app"] as? String) else {
            return ["error": "The requested app is not running."]
        }
        guard let firstID = arguments[tool == "computer_drag" ? "from_element" : "element"] as? String,
              let snapshot = snapshots[appKey(app)],
              firstID.hasPrefix(snapshot.token + "-"),
              let first = snapshot.elements[firstID]
        else { return ["error": "Stale or unknown element id. Refresh computer_get_state."] }
        if first.secure {
            return ["error": "User takeover is required for secure fields; Locus will not read or modify them."]
        }
        let requestedText = arguments["text"] as? String ?? ""
        guard approveIfNeeded(tool: tool, descriptor: first, requestedText: requestedText) else {
            return ["error": "The user did not approve this high-consequence computer action."]
        }
        guard actionIsCurrent(generation, deadline: deadline) else {
            return staleActionResult(generation)
        }

        let error: AXError
        switch tool {
        case "computer_click":
            error = AXUIElementPerformAction(first.element, "AXPress" as CFString)
        case "computer_set_value":
            error = AXUIElementSetAttributeValue(first.element, "AXValue" as CFString, requestedText as CFTypeRef)
        case "computer_drag":
            guard let secondID = arguments["to_element"] as? String,
                  secondID.hasPrefix(snapshot.token + "-"),
                  let second = snapshot.elements[secondID],
                  let start = first.frame?.center,
                  let end = second.frame?.center
            else { return ["error": "Drag endpoints are stale or do not expose screen bounds."] }
            guard approveIfNeeded(tool: tool, descriptor: second, requestedText: requestedText) else {
                return ["error": "The user did not approve this high-consequence computer action."]
            }
            guard actionIsCurrent(generation, deadline: deadline) else {
                return staleActionResult(generation)
            }
            postDrag(from: start, to: end)
            error = .success
        default:
            error = .actionUnsupported
        }
        invalidate(app)
        guard error == .success else { return ["error": "Accessibility action failed (\(error.rawValue))."] }
        return ["text": "Computer action completed. Refresh state before another element action."]
    }

    private func typeFocusedText(
        _ arguments: [String: Any],
        generation: Int,
        deadline: Date
    ) -> [String: Any] {
        guard let app = resolveApp(arguments["app"] as? String) else {
            return ["error": "The requested app is not running."]
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let raw = attribute(root, "AXFocusedUIElement") else {
            return ["error": "No focused text element is available."]
        }
        let element = raw as! AXUIElement
        let role = stringAttribute(element, "AXRole") ?? ""
        let subrole = stringAttribute(element, "AXSubrole") ?? ""
        let secure = role.localizedCaseInsensitiveContains("secure")
            || subrole.localizedCaseInsensitiveContains("secure")
            || boolAttribute(element, "AXProtectedContent")
        guard !secure else {
            return ["error": "User takeover is required for secure fields."]
        }
        let text = arguments["text"] as? String ?? ""
        let descriptor = ElementDescriptor(
            element: element,
            role: role,
            title: stringAttribute(element, "AXTitle") ?? "focused field",
            detail: "",
            secure: false,
            frame: frame(of: element)
        )
        guard approveIfNeeded(tool: "computer_type_text", descriptor: descriptor, requestedText: text) else {
            return ["error": "The user did not approve this high-consequence computer action."]
        }
        guard actionIsCurrent(generation, deadline: deadline) else {
            return staleActionResult(generation)
        }
        let existing = stringAttribute(element, "AXValue") ?? ""
        let error = AXUIElementSetAttributeValue(element, "AXValue" as CFString, (existing + text) as CFTypeRef)
        invalidate(app)
        return error == .success
            ? ["text": "Typed into the focused field. Refresh state."]
            : ["error": "The focused field does not accept Accessibility text input."]
    }

    private func pressKey(
        _ arguments: [String: Any],
        generation: Int,
        deadline: Date
    ) -> [String: Any] {
        guard let app = resolveApp(arguments["app"] as? String),
              let keyName = (arguments["key"] as? String)?.lowercased(),
              let keyCode = keyCodes[keyName]
        else { return ["error": "Unknown app or unsupported key."] }
        if ["return", "enter", "space", "delete"].contains(keyName),
           let descriptor = appWideDescriptor(app),
           !approveIfNeeded(tool: "computer_press_key", descriptor: descriptor, requestedText: keyName)
        {
            return ["error": "User takeover or confirmation is required for this key action."]
        }
        guard actionIsCurrent(generation, deadline: deadline) else {
            return staleActionResult(generation)
        }
        _ = app.activate(options: [.activateAllWindows])
        let modifiers = Set(arguments["modifiers"] as? [String] ?? [])
        var flags: CGEventFlags = []
        if modifiers.contains("command") { flags.insert(.maskCommand) }
        if modifiers.contains("shift") { flags.insert(.maskShift) }
        if modifiers.contains("option") { flags.insert(.maskAlternate) }
        if modifiers.contains("control") { flags.insert(.maskControl) }
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        invalidate(app)
        return ["text": "Pressed \(keyName). Refresh state."]
    }

    private func scroll(
        _ arguments: [String: Any],
        generation: Int,
        deadline: Date
    ) -> [String: Any] {
        guard let app = resolveApp(arguments["app"] as? String) else {
            return ["error": "The requested app is not running."]
        }
        guard actionIsCurrent(generation, deadline: deadline) else {
            return staleActionResult(generation)
        }
        _ = app.activate(options: [.activateAllWindows])
        let x = max(min((arguments["delta_x"] as? Int) ?? 0, 1_000), -1_000)
        let y = max(min((arguments["delta_y"] as? Int) ?? 0, 1_000), -1_000)
        CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(y),
            wheel2: Int32(x),
            wheel3: 0
        )?.post(tap: .cghidEventTap)
        invalidate(app)
        return ["text": "Scrolled the app. Refresh state."]
    }

    private func postDrag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func invalidate(_ app: NSRunningApplication) {
        snapshots.removeValue(forKey: appKey(app))
    }

    private func actionIsCurrent(_ generation: Int, deadline: Date) -> Bool {
        generation == cancellationGeneration && Date() < deadline
    }

    private func staleActionResult(_ generation: Int) -> [String: Any] {
        [
            "error": generation == cancellationGeneration
                ? "native computer action timed out"
                : "cancelled by the user",
        ]
    }

    private func appWideDescriptor(_ app: NSRunningApplication) -> ElementDescriptor? {
        guard let snapshot = snapshots[appKey(app)] else { return nil }
        let descriptors = Array(snapshot.elements.values.prefix(300))
        let context = descriptors.map { "\($0.role) \($0.title) \($0.detail)" }
            .joined(separator: " ")
        return ElementDescriptor(
            element: AXUIElementCreateApplication(app.processIdentifier),
            role: "application state",
            title: app.localizedName ?? "the app",
            detail: String(context.prefix(20_000)),
            secure: descriptors.contains(where: \.secure),
            frame: nil
        )
    }

    private func approveIfNeeded(
        tool: String,
        descriptor: ElementDescriptor,
        requestedText: String
    ) -> Bool {
        let context = "\(descriptor.role) \(descriptor.title) \(descriptor.detail) \(requestedText)".lowercased()
        let takeover = [
            "password", "passcode", "credential", "one-time code", "verification code",
            "api key", "secret", "contract", "security interstitial", "certificate warning",
            "connection is not private", "place order", "confirm purchase", "wire transfer",
            "pay now", "buy now", "submit payment", "final transaction",
        ]
        if descriptor.secure || takeover.contains(where: context.contains) { return false }
        let confirm = ["delete", "erase", "privacy", "security", "install", "upload", "share file"]
        guard confirm.contains(where: context.contains) else { return true }
        let alert = NSAlert()
        alert.messageText = "Allow this computer action?"
        alert.informativeText = "Locus wants to use \(tool) on “\(descriptor.title.nilIfEmpty ?? descriptor.role)”. This action stays confirmation-gated even in Bypass mode."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - ScreenCaptureKit

    private func captureTargetWindow(app: NSRunningApplication) async -> Data? {
        guard screenRecordingGranted else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            guard let window = content.windows
                .filter({ $0.owningApplication?.processID == app.processIdentifier })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { return nil }
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
        } catch {
            return nil
        }
    }

    private func requestHostedScreenshotConsent(provider: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Share a screenshot with \(provider)?"
        alert.informativeText = "Locus will capture only the target app window, exclude Locus, and send only the newest screenshot for this session. Accessibility text will still work if you decline."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Share This Session")
        alert.addButton(withTitle: "Use Text Only")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6,
        "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20,
    ]
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
