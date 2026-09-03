import Foundation

final class RecoverySignerClient {
    private var bootstrapConnection: NSXPCConnection?
    private var signerConnection: NSXPCConnection?
    var invalidationHandler: (() -> Void)?

    func begin(
        mode: WalletRecoveryCeremonyMode,
        allowPresentationOverExistingVaultForUITesting: Bool,
        completion: @escaping (Result<(WalletRecoveryCeremonyHandle, NSXPCListenerEndpoint), Error>) -> Void
    ) {
        let bootstrap = makeBootstrapConnection()
        guard let proxy = bootstrap.remoteObjectProxyWithErrorHandler({ error in
            DispatchQueue.main.async { completion(.failure(error)) }
        }) as? WalletSignerBootstrapXPCProtocol else {
            return completion(.failure(RecoverySignerError.unavailable))
        }
        proxy.connectRecovery { [weak self] endpoint in
            DispatchQueue.main.async {
                guard let self, let endpoint else {
                    return completion(.failure(RecoverySignerError.unavailable))
                }
                self.begin(
                    mode: mode,
                    allowPresentationOverExistingVaultForUITesting:
                        allowPresentationOverExistingVaultForUITesting,
                    endpoint: endpoint,
                    completion: completion
                )
            }
        }
    }

    func invalidate() {
        signerConnection?.invalidationHandler = nil
        signerConnection?.interruptionHandler = nil
        if let proxy = signerConnection?.remoteObjectProxy as? WalletRecoverySignerXPCProtocol {
            proxy.lock { _ in }
        }
        signerConnection?.invalidate()
        signerConnection = nil
        bootstrapConnection?.invalidationHandler = nil
        bootstrapConnection?.interruptionHandler = nil
        bootstrapConnection?.invalidate()
        bootstrapConnection = nil
    }

    private func begin(
        mode: WalletRecoveryCeremonyMode,
        allowPresentationOverExistingVaultForUITesting: Bool,
        endpoint: NSXPCListenerEndpoint,
        completion: @escaping (Result<(WalletRecoveryCeremonyHandle, NSXPCListenerEndpoint), Error>) -> Void
    ) {
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.signerService)
        connection.remoteObjectInterface = NSXPCInterface(
            with: WalletRecoverySignerXPCProtocol.self
        )
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.invalidationHandler?() }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.invalidationHandler?() }
        }
        connection.resume()
        signerConnection = connection

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            DispatchQueue.main.async { completion(.failure(error)) }
        }) as? WalletRecoverySignerXPCProtocol else {
            return completion(.failure(RecoverySignerError.unavailable))
        }
        do {
            let request = try JSONEncoder().encode(WalletRecoveryCeremonyRequest(
                mode: mode,
                allowPresentationOverExistingVaultForUITesting:
                    allowPresentationOverExistingVaultForUITesting
            ))
            proxy.beginRecoveryCeremony(request) { data, brokerEndpoint in
                DispatchQueue.main.async {
                    do {
                        if let failure = try? JSONDecoder().decode(
                            WalletSignerErrorPayload.self, from: data
                        ) {
                            throw RecoverySignerError.message(failure.error)
                        }
                        let handle = try JSONDecoder().decode(
                            WalletRecoveryCeremonyHandle.self, from: data
                        )
                        guard let brokerEndpoint else {
                            throw RecoverySignerError.unavailable
                        }
                        completion(.success((handle, brokerEndpoint)))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func makeBootstrapConnection() -> NSXPCConnection {
        if let bootstrapConnection { return bootstrapConnection }
        let connection = NSXPCConnection(serviceName: "io.sparktales.locus.WalletSigner")
        connection.setCodeSigningRequirement(WalletXPCCodeSigningRequirement.signerService)
        connection.remoteObjectInterface = NSXPCInterface(
            with: WalletSignerBootstrapXPCProtocol.self
        )
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.invalidationHandler?() }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.invalidationHandler?() }
        }
        connection.resume()
        bootstrapConnection = connection
        return connection
    }
}

private enum RecoverySignerError: LocalizedError {
    case unavailable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The isolated wallet signer is unavailable."
        case let .message(message): message
        }
    }
}
