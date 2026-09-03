import AppKit
import Foundation

final class RecoveryProcessController {
    private var decoder = WalletRecoveryProcessFrameDecoder()
    private var invocationID: String?
    private var panelController: RecoveryPanelController?
    private var terminalSent = false
    private var cancelReceived = false

    func start() {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if data.isEmpty { self.inputClosed() } else { self.receive(data) }
            }
        }
    }

    private func receive(_ data: Data) {
        do {
            for message in try decoder.append(data) { try receive(message) }
        } catch {
            panelController?.cancel()
            terminateAfterFlushing()
        }
    }

    private func receive(_ message: WalletRecoveryProcessMessage) throws {
        switch message.kind {
        case .start:
            guard invocationID == nil, panelController == nil,
                  let mode = message.mode else {
                throw WalletRecoveryProcessFrameError.malformed
            }
            invocationID = message.invocationID
            let controller = RecoveryPanelController(
                invocationID: message.invocationID,
                mode: mode,
                allowPresentationOverExistingVaultForUITesting:
                    message.allowPresentationOverExistingVaultForUITesting,
                onPresented: { [weak self] in self?.sendPresented() },
                onFinish: { [weak self] result in self?.sendTerminal(result) }
            )
            panelController = controller
            controller.start()
        case .cancel:
            guard message.invocationID == invocationID, panelController != nil,
                  !cancelReceived else {
                throw WalletRecoveryProcessFrameError.malformed
            }
            cancelReceived = true
            panelController?.cancel()
        case .presented, .terminal:
            throw WalletRecoveryProcessFrameError.malformed
        }
    }

    private func inputClosed() {
        FileHandle.standardInput.readabilityHandler = nil
        if panelController != nil {
            panelController?.cancel()
        } else {
            terminateAfterFlushing()
        }
    }

    private func sendPresented() {
        guard let invocationID, !terminalSent else { return }
        send(WalletRecoveryProcessMessage(invocationID: invocationID, kind: .presented))
    }

    private func sendTerminal(_ result: WalletRecoveryCeremonyResult) {
        guard let invocationID, !terminalSent else { return }
        terminalSent = true
        send(WalletRecoveryProcessMessage(
            invocationID: invocationID,
            kind: .terminal,
            result: result
        ))
        panelController = nil
        terminateAfterFlushing()
    }

    private func send(_ message: WalletRecoveryProcessMessage) {
        guard let frame = try? WalletRecoveryProcessFrameDecoder.encode(message) else {
            return terminateAfterFlushing()
        }
        do {
            try FileHandle.standardOutput.write(contentsOf: frame)
        } catch {
            terminateAfterFlushing()
        }
    }

    private func terminateAfterFlushing() {
        FileHandle.standardInput.readabilityHandler = nil
        try? FileHandle.standardOutput.synchronize()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
