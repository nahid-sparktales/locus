import Foundation

private final class WalletSignerEndpointDelegate: NSObject, NSXPCListenerDelegate {
    enum Access {
        case host
        case recovery
    }

    private let access: Access
    private let service: WalletSignerService
    private let lock = NSLock()
    private var accepted = false

    init(access: Access, service: WalletSignerService) {
        self.access = access
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !accepted else { return false }
        accepted = true
        switch access {
        case .host:
            connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.hostApplication)
            connection.exportedInterface = NSXPCInterface(with: WalletSignerXPCProtocol.self)
        case .recovery:
            connection.setCodeSigningRequirement(
                WalletXPCCodeSigningRequirement.recoveryApplication
            )
            connection.exportedInterface = NSXPCInterface(
                with: WalletRecoverySignerXPCProtocol.self
            )
        }
        connection.exportedObject = service
        connection.interruptionHandler = { [weak service] in service?.invalidateConnection() }
        connection.invalidationHandler = { [weak service] in service?.invalidateConnection() }
        connection.resume()
        return true
    }
}

private final class WalletSignerBootstrapService: NSObject, WalletSignerBootstrapXPCProtocol {
    private let signer = WalletSignerService()
    private let lock = NSLock()
    private var listeners: [NSXPCListener] = []
    private var delegates: [WalletSignerEndpointDelegate] = []

    func connectHost(reply: @escaping (NSXPCListenerEndpoint?) -> Void) {
        reply(makeEndpoint(access: .host))
    }

    func connectRecovery(reply: @escaping (NSXPCListenerEndpoint?) -> Void) {
        reply(makeEndpoint(access: .recovery))
    }

    func invalidate() {
        lock.lock()
        let active = listeners
        listeners.removeAll()
        delegates.removeAll()
        lock.unlock()
        active.forEach { $0.invalidate() }
        signer.invalidateConnection()
    }

    private func makeEndpoint(
        access: WalletSignerEndpointDelegate.Access
    ) -> NSXPCListenerEndpoint {
        let listener = NSXPCListener.anonymous()
        let delegate = WalletSignerEndpointDelegate(access: access, service: signer)
        listener.delegate = delegate
        lock.lock()
        listeners.append(listener)
        delegates.append(delegate)
        lock.unlock()
        listener.resume()
        return listener.endpoint
    }
}

private final class WalletSignerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.setCodeSigningRequirement(
            WalletXPCCodeSigningRequirement.signerBootstrapClient
        )
        let service = WalletSignerBootstrapService()
        connection.exportedInterface = NSXPCInterface(
            with: WalletSignerBootstrapXPCProtocol.self
        )
        connection.exportedObject = service
        connection.interruptionHandler = { service.invalidate() }
        connection.invalidationHandler = { service.invalidate() }
        connection.resume()
        return true
    }
}

private let delegate = WalletSignerListenerDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
