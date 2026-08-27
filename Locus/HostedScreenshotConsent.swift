import AppKit

/// One answer, once per session, for "may a screenshot leave this machine?"
///
/// Shared by both native brokers on purpose. A picture of a logged-in web page
/// is no less sensitive than a picture of Notes, and asking twice for the same
/// provider in the same session would read as a bug rather than as care.
@MainActor
final class HostedScreenshotConsent {
    static let shared = HostedScreenshotConsent()

    private var grantedBySession: [String: Set<String>] = [:]
    private var currentSessionID: String?

    /// Consent is per conversation: a new session starts from no again.
    func beginSession(_ sessionID: String) {
        guard !sessionID.isEmpty, currentSessionID != sessionID else { return }
        currentSessionID = sessionID
        grantedBySession[sessionID, default: []] = grantedBySession[sessionID] ?? []
    }

    /// `nil` means a local model, which never leaves the machine and never asks.
    func isAllowed(provider: String?, sessionID: String? = nil) -> Bool {
        guard let provider, !provider.isEmpty else { return true }
        guard let sessionID = sessionID ?? currentSessionID, !sessionID.isEmpty else {
            return false
        }
        if grantedBySession[sessionID, default: []].contains(provider) { return true }
        guard ask(provider: provider) else { return false }
        grantedBySession[sessionID, default: []].insert(provider)
        return true
    }

    private func ask(provider: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Share a screenshot with \(provider)?"
        alert.informativeText = """
        Locus will send only the newest screenshot, and only for this session. \
        Text-only inspection still works if you decline.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Share This Session")
        alert.addButton(withTitle: "Use Text Only")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
