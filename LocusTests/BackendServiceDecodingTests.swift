import Foundation
import XCTest
@testable import Locus

/// Records the executor that actually performs Decodable work, rather than
/// timing localhost or relying on the thread URLSession uses for callbacks.
private struct ResponseDecodingProbe: Decodable {
    let value: String
    let decodedOnMainThread: Bool
    private enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        decodedOnMainThread = Thread.isMainThread
        value = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
    }
}

@MainActor
final class BackendServiceDecodingTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
    }

    func testEveryRESTResponseDecodesAwayFromTheMainActor() async throws {
        BackendStub.respond(toPath: "/fixture") { _ in ["value": "Synthetic response"] }
        let backend = stubbedBackendService()
        let responses = [
            try await backend.get("/fixture", as: ResponseDecodingProbe.self),
            try await backend.post("/fixture", body: [:], as: ResponseDecodingProbe.self),
            try await backend.patch("/fixture", body: [:], as: ResponseDecodingProbe.self),
            try await backend.put("/fixture", body: [:], as: ResponseDecodingProbe.self),
            try await backend.delete("/fixture", as: ResponseDecodingProbe.self),
            try await backend.delete("/fixture", query: [.init(name: "id", value: "example")], as: ResponseDecodingProbe.self),
            try await backend.upload("/fixture", data: Data("fixture".utf8), as: ResponseDecodingProbe.self),
        ]
        XCTAssertEqual(responses.count, 7)
        for response in responses {
            XCTAssertFalse(response.decodedOnMainThread, "Response decoding must not block companion send feedback")
            XCTAssertEqual(response.value, "Synthetic response")
        }
        XCTAssertTrue(Thread.isMainThread, "Connection and caller state still belong to the main actor")
    }

    func testHTTPAndDecodingErrorsRemainDistinct() async throws {
        BackendStub.respond(toPath: "/denied", status: 409) { _ in ["detail": "Conversation changed"] }
        BackendStub.respond(toPath: "/malformed") { _ in Data("invalid JSON".utf8) }
        let backend = stubbedBackendService()
        do {
            let _ = try await backend.get("/denied", as: ResponseDecodingProbe.self)
            XCTFail("The server rejected the request")
        } catch {
            XCTAssertEqual((error as NSError).domain, "Locus.Backend")
            XCTAssertEqual((error as NSError).code, 409)
            XCTAssertEqual(error.localizedDescription, "Conversation changed")
        }
        do {
            let _ = try await backend.get("/malformed", as: ResponseDecodingProbe.self)
            XCTFail("Malformed JSON must not become a successful response")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }
}
