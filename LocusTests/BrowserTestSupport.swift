import Foundation
import WebKit

/// Bridges `WKNavigationDelegate` to `async` for tests.
///
/// Every terminal callback settles exactly once: WebKit can deliver `didFail`
/// after `didFinish` on a redirect, and a second resume of a
/// `CheckedContinuation` is a crash, not an error.
final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    func wait(timeout: Duration = .seconds(10)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    if let outcome = self.outcome {
                        continuation.resume(with: outcome)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LoadWaiterError.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Arms the waiter for another load on the same web view.
    func reset() {
        outcome = nil
        continuation = nil
    }

    private func finish(_ result: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }
}

enum LoadWaiterError: Error {
    case timedOut
}
