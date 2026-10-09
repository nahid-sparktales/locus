import AppKit

/// A short-lived, explicitly requested copy. Clipboard managers can recognize the
/// private/transient markers, and cleanup never removes a subsequent user copy.
@MainActor
final class IdentityVaultSecretClipboard {
    private let pasteboard: NSPasteboard
    private let lifetime: Duration
    private var ownedChangeCount: Int?
    private var cleanupTask: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general, lifetime: Duration = .seconds(60)) {
        self.pasteboard = pasteboard
        self.lifetime = lifetime
    }

    @discardableResult
    func copy(_ secret: String) -> Bool {
        guard !secret.isEmpty else { return false }
        let item = NSPasteboardItem()
        guard item.setString(secret, forType: .string),
              item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")),
              item.setData(Data(), forType: .init("org.nspasteboard.TransientType")) else { return false }
        cleanupTask?.cancel()
        cleanupTask = nil
        ownedChangeCount = nil
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        ownedChangeCount = pasteboard.changeCount

        let delay = lifetime
        cleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.clear()
        }
        return true
    }

    func clear() {
        cleanupTask?.cancel()
        cleanupTask = nil
        if let ownedChangeCount, pasteboard.changeCount == ownedChangeCount {
            pasteboard.clearContents()
        }
        ownedChangeCount = nil
    }

    deinit { cleanupTask?.cancel() }
}
