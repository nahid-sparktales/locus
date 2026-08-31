import Foundation

struct WalletRecoveryCeremonyLaunch: @unchecked Sendable {
    let handle: WalletRecoveryCeremonyHandle
    let signerEndpoint: NSXPCListenerEndpoint?
}

@MainActor
protocol WalletRecoveryViewClient: AnyObject {
    var isAvailable: Bool { get }
    var invalidationHandler: (() -> Void)? { get set }
    func present(launch: WalletRecoveryCeremonyLaunch) async throws
        -> WalletRecoveryCeremonyResult
    func cancel()
}

@MainActor
final class UnavailableWalletRecoveryViewClient: WalletRecoveryViewClient {
    let isAvailable = false
    var invalidationHandler: (() -> Void)?

    func present(launch: WalletRecoveryCeremonyLaunch) async throws
        -> WalletRecoveryCeremonyResult {
        throw WalletGateway.Error.signerUnavailable
    }
    func cancel() {}
}

@MainActor
enum WalletRecoveryViewClientFactory {
    static func make() -> WalletRecoveryViewClient {
        #if LOCUS_DIRECT_DOWNLOAD
        let client = XPCWalletRecoveryViewClient()
        return client.isAvailable ? client : UnavailableWalletRecoveryViewClient()
        #else
        return UnavailableWalletRecoveryViewClient()
        #endif
    }
}

#if LOCUS_DIRECT_DOWNLOAD
@MainActor
final class XPCWalletRecoveryViewClient: WalletRecoveryViewClient {
    let isAvailable: Bool
    var invalidationHandler: (() -> Void)?
    private var connection: NSXPCConnection?

    init(bundle: Bundle = .main) {
        let serviceURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("XPCServices", isDirectory: true)
            .appendingPathComponent("WalletRecovery.xpc", isDirectory: true)
        isAvailable = FileManager.default.fileExists(atPath: serviceURL.path)
    }

    func present(launch: WalletRecoveryCeremonyLaunch) async throws
        -> WalletRecoveryCeremonyResult {
        guard isAvailable, let endpoint = launch.signerEndpoint else {
            throw WalletGateway.Error.signerUnavailable
        }
        let handle = try JSONEncoder().encode(launch.handle)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = WalletXPCReplyGate()
            do {
                let proxy = try remoteProxy(errorHandler: { error in
                    if gate.take() { continuation.resume(throwing: error) }
                })
                proxy.presentCeremony(handle, signerEndpoint: endpoint) { data in
                    if gate.take() { continuation.resume(returning: data) }
                }
            } catch {
                if gate.take() { continuation.resume(throwing: error) }
            }
        }
        if let failure = try? JSONDecoder().decode(WalletSignerErrorPayload.self, from: data) {
            throw NSError(
                domain: "WalletRecovery", code: 1,
                userInfo: [NSLocalizedDescriptionKey: failure.error]
            )
        }
        return try JSONDecoder().decode(WalletRecoveryCeremonyResult.self, from: data)
    }

    func cancel() { invalidate() }

    private func remoteProxy(
        errorHandler: @escaping (Error) -> Void
    ) throws -> WalletRecoveryServiceXPCProtocol {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? WalletRecoveryServiceXPCProtocol else {
            throw WalletGateway.Error.signerUnavailable
        }
        return proxy
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "io.sparktales.locus.WalletRecovery")
        connection.remoteObjectInterface = NSXPCInterface(
            with: WalletRecoveryServiceXPCProtocol.self
        )
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func invalidate() {
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
        invalidationHandler?()
    }
}
#endif
