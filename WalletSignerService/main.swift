import Foundation

private final class WalletSignerListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = WalletSignerService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: WalletSignerXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private let delegate = WalletSignerListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
