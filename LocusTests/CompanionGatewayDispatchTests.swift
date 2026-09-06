import Foundation
import XCTest
@testable import Locus

@MainActor
final class CompanionGatewayDispatchTests: XCTestCase {
    private func gateway() throws -> CompanionGateway {
        let suite = "CompanionGatewayDispatchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return CompanionGateway(defaults: defaults)
    }

    func testConcurrentDuplicateExecutesOnceAndThenReplaysTheResult() async throws {
        let gateway = try gateway()
        let started = expectation(description: "handler began")
        var completion: CheckedContinuation<CompanionResponse, Never>?
        var executions = 0
        await gateway.configure(commandHandler: { request in
            executions += 1
            return await withCheckedContinuation { continuation in
                completion = continuation
                started.fulfill()
            }
        }, eventProvider: { [] }, stateHandler: { _ in })
        let request = CompanionRequest(id: "same-request", method: .chatSend)
        let first = Task { await gateway.dispatchAuthenticated(request, deviceID: "device") }
        await fulfillment(of: [started], timeout: 2)
        let duplicate = await gateway.dispatchAuthenticated(request, deviceID: "device")
        XCTAssertFalse(duplicate.ok)
        XCTAssertEqual(duplicate.error?.code, "request_in_progress")
        completion?.resume(returning: .success(id: request.id, data: .object(["count": .number(1)])))
        let result = await first.value
        let replay = await gateway.dispatchAuthenticated(request, deviceID: "device")
        XCTAssertEqual(result.data, replay.data)
        XCTAssertTrue(replay.ok)
        XCTAssertEqual(executions, 1)
    }

    func testStoppingMobileAccessPreservesDeduplicationOfAlreadyAdmittedWork() async throws {
        let gateway = try gateway()
        let started = expectation(description: "handler began")
        var completion: CheckedContinuation<CompanionResponse, Never>?
        var executions = 0
        await gateway.configure(commandHandler: { request in
            executions += 1
            if executions > 1 { return .success(id: request.id) }
            return await withCheckedContinuation { continuation in
                completion = continuation
                started.fulfill()
            }
        }, eventProvider: { [] }, stateHandler: { _ in })
        let request = CompanionRequest(id: "request", method: .chatSend)
        let first = Task { await gateway.dispatchAuthenticated(request, deviceID: "device") }
        await fulfillment(of: [started], timeout: 2)
        await gateway.setEnabled(false)
        let duplicate = await gateway.dispatchAuthenticated(request, deviceID: "device")
        XCTAssertEqual(duplicate.error?.code, "request_in_progress")
        completion?.resume(returning: .success(id: request.id))
        let result = await first.value
        XCTAssertTrue(result.ok)
        _ = await gateway.dispatchAuthenticated(request, deviceID: "device")
        XCTAssertEqual(executions, 1)
    }
}
