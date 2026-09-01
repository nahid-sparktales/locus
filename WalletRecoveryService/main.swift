import Foundation

private final class WalletRecoveryListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.hostApplication)
        let service = WalletRecoveryService()
        connection.exportedInterface = NSXPCInterface(with: WalletRecoveryServiceXPCProtocol.self)
        connection.exportedObject = service
        connection.interruptionHandler = { service.invalidate() }
        connection.invalidationHandler = { service.invalidate() }
        connection.resume()
        return true
    }
}

private let delegate = WalletRecoveryListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
