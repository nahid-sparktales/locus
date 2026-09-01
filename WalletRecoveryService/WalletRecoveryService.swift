import AppKit
import Foundation

/// These Codable shapes deliberately exist only in the network-disabled
/// recovery view and isolated signer processes. The main app never links a
/// recovery-phrase payload type.
private struct WalletVaultCreation: Codable, Equatable, Sendable {
    let words: [String]
    let verificationIndices: [Int]
    var purpose: WalletVaultCreationPurpose = .create
}

private struct WalletBackupConfirmation: Codable, Equatable, Sendable {
    let wordsByIndex: [Int: String]
}

private struct WalletVaultRestoreRequest: Codable, Equatable, Sendable {
    let words: [String]
}

private final class RecoverySecureField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           ["v", "x", "c"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class RecoveryCeremonyController {
    private let handle: WalletRecoveryCeremonyHandle
    private let connection: NSXPCConnection
    private let reply: (Data) -> Void
    private let onFinish: () -> Void
    private var finished = false
    private var secretWords: [String] = []

    init(
        handle: WalletRecoveryCeremonyHandle,
        endpoint: NSXPCListenerEndpoint,
        reply: @escaping (Data) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.handle = handle
        self.reply = reply
        self.onFinish = onFinish
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.signerService)
        connection.remoteObjectInterface = NSXPCInterface(
            with: WalletRecoveryBrokerXPCProtocol.self
        )
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.finish(outcome: .failed, error: "The isolated signer interrupted recovery.")
            }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                self.finish(outcome: .failed, error: "The one-time recovery channel closed.")
            }
        }
        connection.resume()
    }

    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        switch handle.mode {
        case .create, .rotateForMainnet:
            loadCreationMaterial()
        case .restore:
            presentRestore()
        }
    }

    func invalidate() {
        guard !finished else { return }
        cancel()
    }

    private func loadCreationMaterial() {
        withBroker { broker in
            broker.creationMaterial(handle.id) { [weak self] data in
                DispatchQueue.main.async {
                    guard let self else { return }
                    do {
                        let material: WalletVaultCreation = try self.decode(data)
                        self.secretWords = material.words
                        self.presentPhrase(material)
                    } catch {
                        self.finish(outcome: .failed, error: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func presentPhrase(_ material: WalletVaultCreation) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = material.purpose == .rotateForMainnet
            ? "Write down your new production recovery phrase"
            : "Write down your Locus Vault recovery phrase"
        alert.informativeText = "This is the only display. Keep all 24 words offline. Never enter another wallet's phrase into Locus."
        alert.addButton(withTitle: "I Saved All 24 Words")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = phraseView(words: material.words)
        if alert.runModal() == .alertFirstButtonReturn {
            presentVerification(indices: material.verificationIndices)
        } else {
            cancel()
        }
    }

    private func presentVerification(indices: [Int]) {
        let alert = NSAlert()
        alert.messageText = "Confirm your recovery phrase"
        alert.informativeText = "Enter the six requested words. Paste and clipboard actions are disabled."
        alert.addButton(withTitle: "Activate Vault")
        alert.addButton(withTitle: "Cancel")
        let fields = indices.map { index -> (Int, RecoverySecureField) in
            let field = RecoverySecureField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.placeholderString = "Word \(index + 1)"
            field.menu = NSMenu()
            field.isAutomaticTextCompletionEnabled = false
            return (index, field)
        }
        let stack = NSStackView(views: fields.map(\.1))
        stack.orientation = .vertical
        stack.spacing = 7
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 190)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else {
            return cancel()
        }
        let answers = Dictionary(uniqueKeysWithValues: fields.map {
            ($0.0, $0.1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        guard answers.values.allSatisfy({ !$0.isEmpty }) else {
            return presentVerification(indices: indices)
        }
        secretWords.removeAll(keepingCapacity: false)
        do {
            let data = try JSONEncoder().encode(WalletBackupConfirmation(wordsByIndex: answers))
            withBroker { broker in
                broker.confirmBackup(handle.id, confirmation: data) { [weak self] response in
                    DispatchQueue.main.async { self?.complete(response) }
                }
            }
        } catch {
            finish(outcome: .failed, error: error.localizedDescription)
        }
    }

    private func presentRestore() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Restore Locus Vault"
        alert.informativeText = "Enter the one Locus Vault 24-word phrase in order. Paste, clipboard, autocomplete, and spell-check are disabled."
        alert.addButton(withTitle: "Restore Vault")
        alert.addButton(withTitle: "Cancel")
        let fields = (0..<24).map { index -> RecoverySecureField in
            let field = RecoverySecureField(frame: NSRect(x: 0, y: 0, width: 210, height: 24))
            field.placeholderString = "\(index + 1)"
            field.menu = NSMenu()
            field.isAutomaticTextCompletionEnabled = false
            return field
        }
        let grid = NSGridView(views: stride(from: 0, to: 24, by: 3).map { row in
            (0..<3).map { column -> NSView in fields[row + column] }
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 680, height: 240)
        alert.accessoryView = grid
        guard alert.runModal() == .alertFirstButtonReturn else {
            return cancel()
        }
        var words = fields.map {
            $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard words.count == 24, words.allSatisfy({ !$0.isEmpty }) else {
            words.removeAll(keepingCapacity: false)
            return presentRestore()
        }
        do {
            let data = try JSONEncoder().encode(WalletVaultRestoreRequest(words: words))
            words.removeAll(keepingCapacity: false)
            withBroker { broker in
                broker.restoreVault(handle.id, request: data) { [weak self] response in
                    DispatchQueue.main.async { self?.complete(response) }
                }
            }
        } catch {
            words.removeAll(keepingCapacity: false)
            finish(outcome: .failed, error: error.localizedDescription)
        }
    }

    private func complete(_ data: Data) {
        do {
            let status: WalletSignerStatus = try decode(data)
            finish(outcome: .completed, status: status)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            switch handle.mode {
            case .create, .rotateForMainnet:
                loadCreationMaterial()
            case .restore:
                presentRestore()
            }
        }
    }

    private func cancel() {
        secretWords.removeAll(keepingCapacity: false)
        withBroker { broker in
            broker.cancel(handle.id) { [weak self] _ in
                DispatchQueue.main.async { self?.finish(outcome: .canceled) }
            }
        }
    }

    private func phraseView(words: [String]) -> NSView {
        let labels = words.enumerated().map { index, word -> NSTextField in
            let field = NSTextField(labelWithString: "\(index + 1). \(word)")
            field.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            field.isSelectable = false
            return field
        }
        let rows = stride(from: 0, to: 24, by: 3).map { row in
            (0..<3).map { column -> NSView in labels[row + column] }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 18
        grid.frame = NSRect(x: 0, y: 0, width: 650, height: 230)
        return grid
    }

    private func withBroker(_ body: (WalletRecoveryBrokerXPCProtocol) -> Void) {
        guard let broker = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            DispatchQueue.main.async {
                self?.finish(outcome: .failed, error: error.localizedDescription)
            }
        }) as? WalletRecoveryBrokerXPCProtocol else {
            return finish(outcome: .failed, error: "The isolated signer is unavailable.")
        }
        body(broker)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        if let failure = try? JSONDecoder().decode(WalletSignerErrorPayload.self, from: data) {
            throw NSError(
                domain: "WalletRecovery", code: 1,
                userInfo: [NSLocalizedDescriptionKey: failure.error]
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func finish(
        outcome: WalletRecoveryCeremonyOutcome,
        status: WalletSignerStatus? = nil,
        error: String? = nil
    ) {
        guard !finished else { return }
        finished = true
        secretWords.removeAll(keepingCapacity: false)
        connection.interruptionHandler = nil
        connection.invalidationHandler = nil
        connection.invalidate()
        let result = WalletRecoveryCeremonyResult(
            ceremonyID: handle.id, outcome: outcome, signerStatus: status, error: error
        )
        reply((try? JSONEncoder().encode(result)) ?? Data())
        onFinish()
    }
}

final class WalletRecoveryService: NSObject, WalletRecoveryServiceXPCProtocol {
    private let lock = NSLock()
    private var controller: RecoveryCeremonyController?

    func presentCeremony(
        _ handleData: Data,
        signerEndpoint: NSXPCListenerEndpoint,
        reply: @escaping (Data) -> Void
    ) {
        DispatchQueue.main.async {
            do {
                let handle = try JSONDecoder().decode(
                    WalletRecoveryCeremonyHandle.self, from: handleData
                )
                self.lock.lock()
                guard self.controller == nil else {
                    self.lock.unlock()
                    return reply(self.error("Another recovery window is already active."))
                }
                let controller = RecoveryCeremonyController(
                    handle: handle, endpoint: signerEndpoint, reply: reply
                ) { [weak self] in
                    self?.lock.lock()
                    self?.controller = nil
                    self?.lock.unlock()
                }
                self.controller = controller
                self.lock.unlock()
                controller.start()
            } catch {
                reply(self.error("The recovery request is invalid."))
            }
        }
    }

    func invalidate() {
        DispatchQueue.main.async {
            self.lock.lock()
            let controller = self.controller
            self.controller = nil
            self.lock.unlock()
            controller?.invalidate()
        }
    }

    private func error(_ message: String) -> Data {
        (try? JSONEncoder().encode(WalletSignerErrorPayload(error: message))) ?? Data()
    }
}
