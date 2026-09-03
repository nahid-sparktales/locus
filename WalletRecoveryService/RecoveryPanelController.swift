import AppKit
import Foundation

/// These secret-bearing payloads are linked only into WalletRecovery.app and
/// WalletSigner.xpc. The main Locus executable has no corresponding types.
private struct WalletVaultCreation: Codable {
    let words: [String]
    let verificationIndices: [Int]
    var purpose: WalletVaultCreationPurpose = .create
}

private struct WalletBackupConfirmation: Codable {
    let wordsByIndex: [Int: String]
}

private struct WalletVaultRestoreRequest: Codable {
    let words: [String]
}

private final class RecoverySecureField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           ["v", "x", "c"].contains(
               event.charactersIgnoringModifiers?.lowercased() ?? ""
           ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        menu = NSMenu()
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

private final class RecoveryVisibleField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           ["v", "x", "c"].contains(
               event.charactersIgnoringModifiers?.lowercased() ?? ""
           ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateProposedFirstResponder(
        _ responder: NSResponder,
        for event: NSEvent?
    ) -> Bool {
        menu = NSMenu()
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

/// Keeps the ordinary and revealed editors inside the recovery helper. The
/// visible editor remains protected from accessibility capture and retains the
/// same clipboard and writing-assistance restrictions as the secure editor.
private final class RecoverySecretEntry: NSView, NSTextFieldDelegate {
    let secureField = RecoverySecureField(frame: .zero)
    private let visibleField = RecoveryVisibleField(frame: .zero)
    private var revealed = false

    init(position: Int, fieldWidth: CGFloat) {
        super.init(frame: .zero)

        let positionLabel = NSTextField(labelWithString: "Word \(position)")
        positionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        positionLabel.alignment = .right
        positionLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let editorContainer = NSView()
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        editorContainer.heightAnchor.constraint(equalToConstant: 24).isActive = true

        configure(secureField)
        configure(visibleField)
        secureField.placeholderString = "Enter word"
        visibleField.placeholderString = "Enter word"
        secureField.delegate = self
        visibleField.delegate = self
        visibleField.isHidden = true
        for field in [secureField, visibleField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setAccessibilityProtectedContent(true)
            editorContainer.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
                field.topAnchor.constraint(equalTo: editorContainer.topAnchor),
                field.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            ])
        }

        let row = NSStackView(views: [positionLabel, editorContainer])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var stringValue: String {
        get { revealed ? visibleField.stringValue : secureField.stringValue }
        set {
            secureField.stringValue = newValue
            visibleField.stringValue = newValue
        }
    }

    func setInputAccessibilityIdentifier(_ identifier: String) {
        secureField.setAccessibilityIdentifier(identifier)
        visibleField.setAccessibilityIdentifier("\(identifier).visible")
    }

    func setRevealed(_ shouldReveal: Bool) {
        guard revealed != shouldReveal else { return }
        let source = revealed ? visibleField : secureField
        let destination = shouldReveal ? visibleField : secureField
        let wasEditing = window?.firstResponder === source.currentEditor()
        destination.stringValue = source.stringValue
        source.stringValue = ""
        source.isHidden = true
        destination.isHidden = false
        revealed = shouldReveal
        if wasEditing { window?.makeFirstResponder(destination) }
    }

    func setEnabled(_ enabled: Bool) {
        secureField.isEnabled = enabled
        visibleField.isEnabled = enabled
    }

    func clear() {
        secureField.stringValue = ""
        visibleField.stringValue = ""
    }

    func focus() {
        window?.makeFirstResponder(revealed ? visibleField : secureField)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.enabledTextCheckingTypes = 0
    }

    #if DEBUG
    func uiTestRevealRoundTrip() -> Bool {
        let original = stringValue
        setRevealed(true)
        let visibleValuePreserved = revealed
            && visibleField.stringValue == original
            && secureField.stringValue.isEmpty
        setRevealed(false)
        return visibleValuePreserved
            && !revealed
            && secureField.stringValue == original
            && visibleField.stringValue.isEmpty
    }
    #endif

    private func configure(_ field: NSTextField) {
        field.menu = NSMenu()
        field.isAutomaticTextCompletionEnabled = false
        field.allowsEditingTextAttributes = false
        field.font = .systemFont(ofSize: 14)
    }
}

final class RecoveryPanelController: NSObject, NSWindowDelegate {
    #if DEBUG
    private var uiTestSecurePresentationVerified = false
    private var uiTestConfirmationProbePending = false
    #endif

    private let invocationID: String
    private let mode: WalletRecoveryCeremonyMode
    private let allowPresentationOverExistingVaultForUITesting: Bool
    private let onPresented: () -> Void
    private let onFinish: (WalletRecoveryCeremonyResult) -> Void
    private let signer = RecoverySignerClient()
    private let panel: NSPanel
    private var handle: WalletRecoveryCeremonyHandle?
    private var brokerConnection: NSXPCConnection?
    private var secretWords: [String] = []
    private var verificationIndices: [Int] = []
    private var verificationFields: [(Int, RecoverySecretEntry)] = []
    private var restoreFields: [RecoverySecretEntry] = []
    private var errorLabel: NSTextField?
    private var revealButton: NSButton?
    private var submissionButton: NSButton?
    private var submissionInFlight = false
    private var typedWordsRevealed = false
    private var finished = false
    private var presentationAcknowledged = false

    init(
        invocationID: String,
        mode: WalletRecoveryCeremonyMode,
        allowPresentationOverExistingVaultForUITesting: Bool,
        onPresented: @escaping () -> Void,
        onFinish: @escaping (WalletRecoveryCeremonyResult) -> Void
    ) {
        self.invocationID = invocationID
        self.mode = mode
        self.allowPresentationOverExistingVaultForUITesting =
            allowPresentationOverExistingVaultForUITesting
        self.onPresented = onPresented
        self.onFinish = onFinish
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 570),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Locus Vault Recovery"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.setAccessibilityIdentifier("wallet.recovery.window")
    }

    func start() {
        showLoading()
        presentPanel()
        signer.invalidationHandler = { [weak self] in
            self?.finish(
                outcome: .failed,
                error: "The isolated signer interrupted recovery."
            )
        }
        signer.begin(
            mode: mode,
            allowPresentationOverExistingVaultForUITesting:
                allowPresentationOverExistingVaultForUITesting
        ) { [weak self] result in
            guard let self, !self.finished else { return }
            switch result {
            case let .success((handle, endpoint)):
                self.handle = handle
                self.connectBroker(endpoint: endpoint)
                switch self.mode {
                case .create, .rotateForMainnet:
                    self.loadCreationMaterial()
                case .restore:
                    self.showRestore()
                }
            case let .failure(error):
                self.finish(outcome: .failed, error: error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        clearSecretBuffers()
        guard let handle else {
            return finish(outcome: .canceled)
        }
        withBroker { [weak self] broker in
            broker.cancel(handle.id) { _ in
                DispatchQueue.main.async { self?.finish(outcome: .canceled) }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func connectBroker(endpoint: NSXPCListenerEndpoint) {
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.signerService)
        connection.remoteObjectInterface = NSXPCInterface(
            with: WalletRecoveryBrokerXPCProtocol.self
        )
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.finish(
                    outcome: .failed,
                    error: "The one-time recovery channel was interrupted."
                )
            }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                self.finish(
                    outcome: .failed,
                    error: "The one-time recovery channel closed."
                )
            }
        }
        connection.resume()
        brokerConnection = connection
    }

    private func loadCreationMaterial() {
        guard let handle else { return finish(outcome: .failed, error: "Recovery did not start.") }
        withBroker { [weak self] broker in
            broker.creationMaterial(handle.id) { data in
                DispatchQueue.main.async {
                    guard let self, !self.finished else { return }
                    do {
                        let material: WalletVaultCreation = try self.decode(data)
                        guard material.words.count == 24,
                              material.verificationIndices.count == 6 else {
                            throw RecoveryPanelError.invalidSignerResponse
                        }
                        self.secretWords = material.words
                        self.showPhrase(material)
                    } catch {
                        self.finish(outcome: .failed, error: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func showLoading() {
        clearVisibleContent()
        setContent(
            title: "Preparing secure recovery",
            detail: "Locus is opening the isolated, network-disabled recovery channel.",
            body: NSProgressIndicator.spinning(),
            buttons: [cancelButton()]
        )
    }

    private func showPhrase(_ material: WalletVaultCreation) {
        clearVisibleContent()
        verificationIndices = material.verificationIndices
        let labels = material.words.enumerated().map { index, word -> NSTextField in
            let label = NSTextField(labelWithString: "\(index + 1).  \(word)")
            label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            label.isSelectable = false
            label.setAccessibilityElement(false)
            return label
        }
        let rows = stride(from: 0, to: 24, by: 3).map { offset in
            (0..<3).map { labels[offset + $0] as NSView }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 26
        grid.setAccessibilityElement(false)
        let next = NSButton(
            title: "I Saved All 24 Words",
            target: self,
            action: #selector(advanceToVerification)
        )
        next.keyEquivalent = "\r"
        next.bezelStyle = .rounded
        next.setAccessibilityIdentifier("wallet.recovery.saved")
        setContent(
            title: material.purpose == .rotateForMainnet
                ? "Write down your new production recovery phrase"
                : "Write down your Locus Vault recovery phrase",
            detail: "This is the only display. Keep all 24 words offline and never share them.",
            body: grid,
            buttons: [cancelButton(), next]
        )
        #if DEBUG
        if allowPresentationOverExistingVaultForUITesting {
            DispatchQueue.main.async { [weak self] in self?.advanceToVerification() }
        }
        #endif
    }

    @objc private func advanceToVerification() {
        guard handle != nil, verificationIndices.count == 6 else {
            return finish(
                outcome: .failed,
                error: "The isolated signer returned invalid confirmation positions."
            )
        }
        let indices = verificationIndices
        clearVisibleContent()
        secretWords.removeAll(keepingCapacity: false)
        showVerification(indices: indices)
    }

    private func showVerification(indices: [Int]) {
        clearVisibleContent()
        verificationFields = indices.map { index in
            let entry = RecoverySecretEntry(position: index + 1, fieldWidth: 250)
            entry.setInputAccessibilityIdentifier(
                "wallet.recovery.confirmation.\(index + 1)"
            )
            return (index, entry)
        }
        let stack = NSStackView(views: verificationFields.map(\.1))
        stack.orientation = .vertical
        stack.spacing = 9
        stack.alignment = .leading
        let reveal = makeRevealButton()
        let body = NSStackView(views: [stack, reveal])
        body.orientation = .vertical
        body.spacing = 12
        body.alignment = .leading
        let confirm = NSButton(
            title: "Activate Vault",
            target: self,
            action: #selector(confirmBackup)
        )
        confirm.keyEquivalent = "\r"
        confirm.setAccessibilityIdentifier("wallet.recovery.confirm")
        submissionButton = confirm
        setContent(
            title: "Confirm your recovery phrase",
            detail: "Enter the word shown for each numbered position. Your entries stay here if a word does not match.",
            body: body,
            buttons: [cancelButton(), confirm]
        )
        verificationFields.first?.1.focus()
        #if DEBUG
        if allowPresentationOverExistingVaultForUITesting {
            guard uiTestSecureFieldsAreValid(
                prefix: "wallet.recovery.confirmation.", count: 6
            ), revealButton?.accessibilityIdentifier()
                == "wallet.recovery.show-typed-words" else {
                return finish(
                    outcome: .failed,
                    error: "The recovery confirmation fields did not render correctly."
                )
            }
            verificationFields.forEach { $0.1.stringValue = "visibility-check" }
            uiTestConfirmationProbePending = true
            confirmBackup()
        }
        #endif
    }

    @objc private func confirmBackup() {
        guard let handle, !submissionInFlight else { return }
        let answers = Dictionary(uniqueKeysWithValues: verificationFields.map {
            ($0.0, normalizedRecoveryWord($0.1.stringValue))
        })
        guard answers.count == 6, answers.values.allSatisfy({ !$0.isEmpty }) else {
            return showInlineError("Enter all six requested words.")
        }
        setSubmissionInFlight(true)
        do {
            let data = try JSONEncoder().encode(WalletBackupConfirmation(wordsByIndex: answers))
            withBroker { [weak self] broker in
                broker.confirmBackup(handle.id, confirmation: data) { response in
                    DispatchQueue.main.async { self?.complete(response, retry: .confirmation) }
                }
            }
        } catch {
            setSubmissionInFlight(false)
            finish(outcome: .failed, error: error.localizedDescription)
        }
    }

    private func showRestore() {
        clearVisibleContent()
        restoreFields = (0..<24).map { index in
            let entry = RecoverySecretEntry(position: index + 1, fieldWidth: 140)
            entry.setInputAccessibilityIdentifier("wallet.recovery.restore.\(index + 1)")
            return entry
        }
        let rows = stride(from: 0, to: 24, by: 3).map { offset in
            (0..<3).map { restoreFields[offset + $0] as NSView }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        let reveal = makeRevealButton()
        let body = NSStackView(views: [grid, reveal])
        body.orientation = .vertical
        body.spacing = 12
        body.alignment = .leading
        let restore = NSButton(
            title: "Restore Vault",
            target: self,
            action: #selector(restoreVault)
        )
        restore.keyEquivalent = "\r"
        restore.setAccessibilityIdentifier("wallet.recovery.restore.submit")
        submissionButton = restore
        setContent(
            title: "Restore Locus Vault",
            detail: "Enter your one Locus Vault 24-word phrase in order. Clipboard and writing assistance are disabled.",
            body: body,
            buttons: [cancelButton(), restore]
        )
        restoreFields.first?.focus()
        #if DEBUG
        if allowPresentationOverExistingVaultForUITesting {
            guard uiTestSecureFieldsAreValid(
                prefix: "wallet.recovery.restore.", count: 24
            ), revealButton?.accessibilityIdentifier()
                == "wallet.recovery.show-typed-words",
                restoreFields.allSatisfy({ entry in
                    entry.stringValue = "visibility-check"
                    defer { entry.clear() }
                    return entry.uiTestRevealRoundTrip()
                }) else {
                return finish(
                    outcome: .failed,
                    error: "The recovery restore fields did not render correctly."
                )
            }
            uiTestSecurePresentationVerified = true
        }
        #endif
    }

    @objc private func restoreVault() {
        guard let handle, !submissionInFlight else { return }
        var words = restoreFields.map {
            normalizedRecoveryWord($0.stringValue)
        }
        guard words.count == 24, words.allSatisfy({ !$0.isEmpty }) else {
            words.removeAll(keepingCapacity: false)
            return showInlineError("Enter all 24 recovery words.")
        }
        setSubmissionInFlight(true)
        do {
            let data = try JSONEncoder().encode(WalletVaultRestoreRequest(words: words))
            words.removeAll(keepingCapacity: false)
            withBroker { [weak self] broker in
                broker.restoreVault(handle.id, request: data) { response in
                    DispatchQueue.main.async { self?.complete(response, retry: .restore) }
                }
            }
        } catch {
            words.removeAll(keepingCapacity: false)
            setSubmissionInFlight(false)
            finish(outcome: .failed, error: error.localizedDescription)
        }
    }

    private enum RetryScreen { case confirmation, restore }

    private func complete(_ data: Data, retry: RetryScreen) {
        guard !finished else { return }
        #if DEBUG
        if uiTestConfirmationProbePending {
            uiTestConfirmationProbePending = false
            let expectedPositions = verificationIndices
                .map { String($0 + 1) }
                .joined(separator: ", ")
            let expectedError = "The words at positions \(expectedPositions) did not match. Check them and try again."
            let error = try? decodeFailure(data)
            let inputWasPreserved = verificationFields.allSatisfy {
                $0.1.stringValue == "visibility-check"
            }
            let revealRoundTripWorked = verificationFields.allSatisfy {
                $0.1.uiTestRevealRoundTrip()
            }
            verificationFields.forEach { $0.1.clear() }
            setSubmissionInFlight(false)
            errorLabel?.stringValue = ""
            errorLabel?.isHidden = true
            guard error == expectedError, inputWasPreserved, revealRoundTripWorked else {
                return finish(
                    outcome: .failed,
                    error: "The recovery confirmation retry controls did not validate correctly."
                )
            }
            uiTestSecurePresentationVerified = true
            verificationFields.first?.1.focus()
            acknowledgePresentation(attempt: 0)
            return
        }
        #endif
        do {
            let status: WalletSignerStatus = try decode(data)
            finish(outcome: .completed, status: status)
        } catch {
            setSubmissionInFlight(false)
            showInlineError(error.localizedDescription)
            switch retry {
            case .confirmation:
                verificationFields.first?.1.focus()
            case .restore:
                restoreFields.first?.focus()
            }
        }
    }

    private func presentPanel() {
        NSApp.setActivationPolicy(.accessory)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        acknowledgePresentation(attempt: 0)
    }

    private func acknowledgePresentation(attempt: Int) {
        guard !presentationAcknowledged, !finished else { return }
        if panel.isVisible && panel.isKeyWindow {
            #if DEBUG
            if allowPresentationOverExistingVaultForUITesting,
               !uiTestSecurePresentationVerified {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.acknowledgePresentation(attempt: attempt)
                }
                return
            }
            #endif
            presentationAcknowledged = true
            onPresented()
            return
        }
        guard attempt < 40 else {
            return finish(
                outcome: .failed,
                error: "The recovery panel could not become visible."
            )
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.acknowledgePresentation(attempt: attempt + 1)
        }
    }

    private func setContent(
        title: String,
        detail: String,
        body: NSView,
        buttons: [NSButton]
    ) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabelColor
        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 13, weight: .medium)
        errorLabel.isHidden = true
        self.errorLabel = errorLabel

        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        let buttonContainer = NSStackView()
        buttonContainer.orientation = .horizontal
        buttonContainer.addArrangedSubview(NSView())
        buttonContainer.addArrangedSubview(buttonRow)

        let stack = NSStackView(views: [titleLabel, detailLabel, body, errorLabel, buttonContainer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        buttonContainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    private func makeRevealButton() -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "Show typed words",
            target: self,
            action: #selector(toggleTypedWords(_:))
        )
        button.state = .off
        button.setAccessibilityIdentifier("wallet.recovery.show-typed-words")
        revealButton = button
        typedWordsRevealed = false
        return button
    }

    @objc private func toggleTypedWords(_ sender: NSButton) {
        guard !submissionInFlight else {
            sender.state = typedWordsRevealed ? .on : .off
            return
        }
        typedWordsRevealed = sender.state == .on
        let entries = verificationFields.map(\.1) + restoreFields
        entries.forEach { $0.setRevealed(typedWordsRevealed) }
    }

    private func setSubmissionInFlight(_ inFlight: Bool) {
        submissionInFlight = inFlight
        submissionButton?.isEnabled = !inFlight
        revealButton?.isEnabled = !inFlight
        let entries = verificationFields.map(\.1) + restoreFields
        entries.forEach { $0.setEnabled(!inFlight) }
        if inFlight { errorLabel?.isHidden = true }
    }

    private func normalizedRecoveryWord(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func cancelButton() -> NSButton {
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelButtonPressed))
        button.keyEquivalent = "\u{1b}"
        button.setAccessibilityIdentifier("wallet.recovery.cancel")
        return button
    }

    @objc private func cancelButtonPressed() { cancel() }

    private func showInlineError(_ message: String) {
        errorLabel?.stringValue = message
        errorLabel?.isHidden = false
    }

    private func clearVisibleContent() {
        verificationFields.forEach { $0.1.clear() }
        restoreFields.forEach { $0.clear() }
        verificationFields.removeAll(keepingCapacity: false)
        restoreFields.removeAll(keepingCapacity: false)
        errorLabel = nil
        revealButton = nil
        submissionButton = nil
        submissionInFlight = false
        typedWordsRevealed = false
    }

    private func clearSecretBuffers() {
        clearVisibleContent()
        secretWords.removeAll(keepingCapacity: false)
        verificationIndices.removeAll(keepingCapacity: false)
    }

    #if DEBUG
    private func uiTestSecureFieldsAreValid(
        prefix: String,
        count: Int
    ) -> Bool {
        let fields = secureFields(in: panel.contentView)
        return fields.count == count
            && fields.allSatisfy { $0.accessibilityIdentifier().hasPrefix(prefix) }
    }

    private func secureFields(in root: NSView?) -> [RecoverySecureField] {
        guard let root else { return [] }
        return ((root as? RecoverySecureField).map { [$0] } ?? [])
            + root.subviews.flatMap { secureFields(in: $0) }
    }
    #endif

    private func withBroker(_ body: (WalletRecoveryBrokerXPCProtocol) -> Void) {
        guard !finished,
              let broker = brokerConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
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
            throw RecoveryPanelError.message(failure.error)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func decodeFailure(_ data: Data) throws -> String {
        try JSONDecoder().decode(WalletSignerErrorPayload.self, from: data).error
    }

    private func finish(
        outcome: WalletRecoveryCeremonyOutcome,
        status: WalletSignerStatus? = nil,
        error: String? = nil
    ) {
        guard !finished else { return }
        finished = true
        clearSecretBuffers()
        panel.delegate = nil
        panel.orderOut(nil)
        brokerConnection?.interruptionHandler = nil
        brokerConnection?.invalidationHandler = nil
        brokerConnection?.invalidate()
        brokerConnection = nil
        signer.invalidationHandler = nil
        signer.invalidate()
        onFinish(WalletRecoveryCeremonyResult(
            ceremonyID: handle?.id ?? invocationID,
            outcome: outcome,
            signerStatus: status,
            error: error
        ))
    }
}

private enum RecoveryPanelError: LocalizedError {
    case invalidSignerResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidSignerResponse: "The isolated signer returned an invalid recovery response."
        case let .message(message): message
        }
    }
}

private extension NSProgressIndicator {
    static func spinning() -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.startAnimation(nil)
        return indicator
    }
}
