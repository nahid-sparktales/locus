import Foundation

private final class WalletSignerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.hostApplication)
        let service = WalletSignerService()
        connection.exportedInterface = NSXPCInterface(with: WalletSignerXPCProtocol.self)
        connection.exportedObject = service
        connection.interruptionHandler = { service.invalidateConnection() }
        connection.invalidationHandler = { service.invalidateConnection() }
        connection.resume()
        return true
    }
}

private let delegate = WalletSignerListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
