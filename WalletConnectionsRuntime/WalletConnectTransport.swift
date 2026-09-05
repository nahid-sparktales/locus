import Foundation
import WalletConnectSign

/// Reown transport backed only by URLSession. No extra socket dependency is
/// linked into the privileged Direct application.
final class WalletConnectURLSessionSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        WalletConnectURLSessionSocket(url: url)
    }
}

private final class WalletConnectURLSessionSocket: NSObject, WebSocketConnecting,
    URLSessionWebSocketDelegate {
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?
    var request: URLRequest

    private let lock = NSLock()
    private var connected = false
    private var socketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?

    var isConnected: Bool { lock.withLock { connected } }

    init(url: URL) {
        request = URLRequest(url: url)
        super.init()
    }

    func connect() {
        lock.lock()
        guard socketTask == nil else { lock.unlock(); return }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(
            configuration: .ephemeral,
            delegate: self,
            delegateQueue: queue
        )
        let socket = session.webSocketTask(with: request)
        self.session = session
        socketTask = socket
        lock.unlock()
        socket.resume()
    }

    func disconnect() {
        let state = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            connected = false
            let value = (socketTask, session)
            socketTask = nil
            session = nil
            return value
        }
        receiveTask?.cancel()
        receiveTask = nil
        state.0?.cancel(with: .normalClosure, reason: nil)
        state.1?.invalidateAndCancel()
    }

    func write(string: String, completion: (() -> Void)?) {
        guard string.utf8.count <= 1_048_576,
              let socket = lock.withLock({ socketTask }) else {
            completion?()
            return
        }
        Task {
            try? await socket.send(.string(string))
            completion?()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.withLock { connected = true }
        onConnect?()
        receiveTask = Task { [weak self, weak webSocketTask] in
            guard let self, let webSocketTask else { return }
            while !Task.isCancelled {
                do {
                    let message = try await webSocketTask.receive()
                    switch message {
                    case .string(let value):
                        guard value.utf8.count <= 1_048_576 else {
                            disconnect()
                            return
                        }
                        onText?(value)
                    case .data:
                        // WalletConnect relay payloads are JSON text. Binary
                        // frames cannot enter the request decoder.
                        disconnect()
                        return
                    @unknown default:
                        disconnect()
                        return
                    }
                } catch {
                    if !Task.isCancelled { finish(error) }
                    return
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(nil)
    }

    private func finish(_ error: Error?) {
        let shouldNotify = lock.withLock { () -> Bool in
            let wasActive = connected || socketTask != nil
            connected = false
            socketTask = nil
            session = nil
            return wasActive
        }
        receiveTask?.cancel()
        receiveTask = nil
        if shouldNotify { onDisconnect?(error) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

