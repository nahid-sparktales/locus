import Foundation
import Security
import XCTest
@testable import Locus

private final class ConnectorCredentialFixtureState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

final class ConnectorCredentialStoreTests: XCTestCase {
    func testMemoryConnectorStoresKeepCopiesAndDeleteOnlyTheirOwnEntries() throws {
        let first = InMemoryConnectorCredentialStore()
        let second = InMemoryConnectorCredentialStore()
        var input = ["access_token": "fixture-only"]
        try first.save(input, for: "same-fixture")
        input["access_token"] = "changed-after-save"
        XCTAssertEqual(try first.load(for: "same-fixture"), ["access_token": "fixture-only"])
        XCTAssertNil(try second.load(for: "same-fixture"))
        try second.save(["access_token": "independent"], for: "same-fixture")
        try first.delete(for: "same-fixture")
        XCTAssertNil(try first.load(for: "same-fixture"))
        XCTAssertEqual(try second.load(for: "same-fixture"), ["access_token": "independent"])
        XCTAssertNoThrow(try first.delete(for: "missing"))
    }

    func testFailedRefreshPreservesTheExistingCredential() throws {
        let existing = try JSONEncoder().encode(["token": "previous"])
        let state = ConnectorCredentialFixtureState((stored: existing, addCalls: 0))
        let store = ConnectorCredentialStore(
            updateItem: { _, _ in errSecInteractionNotAllowed },
            addItem: { item in
                state.withValue {
                    $0.addCalls += 1
                    $0.stored = (item as NSDictionary)[kSecValueData] as! Data
                }
                return errSecSuccess
            }
        )

        XCTAssertThrowsError(try store.save(["token": "replacement"], for: "fixture"))
        XCTAssertEqual(state.withValue { $0.stored }, existing)
        XCTAssertEqual(state.withValue { $0.addCalls }, 0)
    }

    func testExistingItemIsUpdatedWithoutRecreation() throws {
        let updatedData = ConnectorCredentialFixtureState<Data?>(nil)
        let store = ConnectorCredentialStore(
            updateItem: { query, changes in
                XCTAssertEqual((query as NSDictionary)[kSecAttrAccount] as? String, "fixture")
                updatedData.withValue { $0 = (changes as NSDictionary)[kSecValueData] as? Data }
                return errSecSuccess
            },
            addItem: { _ in XCTFail("existing credentials must not be recreated"); return errSecSuccess }
        )

        try store.save(["token": "replacement"], for: "fixture")
        XCTAssertEqual(
            try JSONDecoder().decode([String: String].self, from: XCTUnwrap(updatedData.withValue { $0 })),
            ["token": "replacement"]
        )
    }

    func testFirstSaveAddsDeviceBoundCredential() throws {
        let added = ConnectorCredentialFixtureState(false)
        let store = ConnectorCredentialStore(
            updateItem: { _, _ in errSecItemNotFound },
            addItem: { item in
                added.withValue { $0 = true }
                XCTAssertEqual(
                    (item as NSDictionary)[kSecAttrAccessible] as? String,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                )
                return errSecSuccess
            }
        )
        try store.save(["token": "first"], for: "fixture")
        XCTAssertTrue(added.withValue { $0 })
    }

    func testConcurrentFirstSaveRetriesUpdateAfterDuplicate() throws {
        let updates = ConnectorCredentialFixtureState(0)
        let store = ConnectorCredentialStore(
            updateItem: { _, _ in
                updates.withValue {
                    $0 += 1
                    return $0 == 1 ? errSecItemNotFound : errSecSuccess
                }
            },
            addItem: { _ in errSecDuplicateItem }
        )
        try store.save(["token": "replacement"], for: "fixture")
        XCTAssertEqual(updates.withValue { $0 }, 2)
    }
}
