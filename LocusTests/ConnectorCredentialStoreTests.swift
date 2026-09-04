import Foundation
import Security
import XCTest
@testable import Locus

final class ConnectorCredentialStoreTests: XCTestCase {
    func testFailedRefreshPreservesTheExistingCredential() throws {
        let existing = try JSONEncoder().encode(["token": "previous"])
        var stored = existing
        var addCalls = 0
        let store = ConnectorCredentialStore(
            updateItem: { _, _ in errSecInteractionNotAllowed },
            addItem: { item in
                addCalls += 1
                stored = (item as NSDictionary)[kSecValueData] as! Data
                return errSecSuccess
            }
        )

        XCTAssertThrowsError(try store.save(["token": "replacement"], for: "fixture"))
        XCTAssertEqual(stored, existing)
        XCTAssertEqual(addCalls, 0)
    }

    func testExistingItemIsUpdatedWithoutRecreation() throws {
        var updatedData: Data?
        let store = ConnectorCredentialStore(
            updateItem: { query, changes in
                XCTAssertEqual((query as NSDictionary)[kSecAttrAccount] as? String, "fixture")
                updatedData = (changes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            },
            addItem: { _ in XCTFail("existing credentials must not be recreated"); return errSecSuccess }
        )

        try store.save(["token": "replacement"], for: "fixture")
        XCTAssertEqual(
            try JSONDecoder().decode([String: String].self, from: XCTUnwrap(updatedData)),
            ["token": "replacement"]
        )
    }

    func testFirstSaveAddsDeviceBoundCredential() throws {
        var added = false
        let store = ConnectorCredentialStore(
            updateItem: { _, _ in errSecItemNotFound },
            addItem: { item in
                added = true
                XCTAssertEqual(
                    (item as NSDictionary)[kSecAttrAccessible] as? String,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                )
                return errSecSuccess
            }
        )
        try store.save(["token": "first"], for: "fixture")
        XCTAssertTrue(added)
    }

    func testConcurrentFirstSaveRetriesUpdateAfterDuplicate() throws {
        var updates = 0
        let store = ConnectorCredentialStore(
            updateItem: { _, _ in
                updates += 1
                return updates == 1 ? errSecItemNotFound : errSecSuccess
            },
            addItem: { _ in errSecDuplicateItem }
        )
        try store.save(["token": "replacement"], for: "fixture")
        XCTAssertEqual(updates, 2)
    }
}
