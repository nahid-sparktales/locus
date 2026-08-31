import Foundation
import XCTest

@testable import Locus

/// Route-keyed backend stub for feature-model tests. Register JSON responders
/// per path, build a BackendService whose URLSession routes every request
/// here, and read back the recorded traffic.
final class BackendStub: URLProtocol {
    struct Route {
        let matches: (URL) -> Bool
        let respond: (URL) -> (status: Int, body: Any)
    }

    private static let lock = NSLock()
    private static var routes: [Route] = []
    private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock()
        routes = []
        recorded = []
        lock.unlock()
    }

    static func respond(
        toPath path: String,
        status: Int = 200,
        with body: @escaping (URL) -> Any
    ) {
        lock.lock()
        routes.append(Route(matches: { $0.path == path }, respond: { (status, body($0)) }))
        lock.unlock()
    }

    static func respond(
        whenPathHasPrefix prefix: String,
        status: Int = 200,
        with body: @escaping (URL) -> Any
    ) {
        lock.lock()
        routes.append(Route(matches: { $0.path.hasPrefix(prefix) }, respond: { (status, body($0)) }))
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static var requestPaths: [String] {
        requests.compactMap { $0.url?.path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.recorded.append(request)
        let route = Self.routes.first { $0.matches(url) }
        Self.lock.unlock()
        let (status, body) = route?.respond(url) ?? (404, ["error": "unstubbed \(url.path)"])
        let data = (body as? Data) ?? ((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A BackendService that answers only through BackendStub. Feature models
/// receive it in configure(...), mirroring AppModel's backendOverride seam.
@MainActor
func stubbedBackendService() -> BackendService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BackendStub.self]
    return BackendService(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        authToken: "test-token",
        session: URLSession(configuration: configuration)
    )
}

/// The inertness contract: constructing (and restoring) a feature model with
/// persistence disabled must produce zero backend traffic.
func XCTAssertNoBackendTraffic(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(BackendStub.requestPaths, [], "expected no backend traffic", file: file, line: line)
}
