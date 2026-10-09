import AppKit
import XCTest
@testable import Locus

@MainActor
final class IdentityVaultSecretClipboardTests: XCTestCase {
    private func fixture(lifetime: Duration = .seconds(60)) -> (IdentityVaultSecretClipboard, NSPasteboard) {
        let pasteboard = NSPasteboard(name: .init("locus.identity-vault-test.\(UUID().uuidString)"))
        addTeardownBlock { await MainActor.run { pasteboard.releaseGlobally() } }
        return (IdentityVaultSecretClipboard(pasteboard: pasteboard, lifetime: lifetime), pasteboard)
    }

    private func waitForCleanup(_ pasteboard: NSPasteboard) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pasteboard.string(forType: .string) != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testCopyIsMarkedPrivateAndClearRemovesOwnedSecret() {
        let (clipboard, pasteboard) = fixture()
        XCTAssertTrue(clipboard.copy("SYNTHETIC_API_KEY"))
        XCTAssertEqual(pasteboard.string(forType: .string), "SYNTHETIC_API_KEY")
        XCTAssertNotNil(pasteboard.data(forType: .init("org.nspasteboard.ConcealedType")))
        XCTAssertNotNil(pasteboard.data(forType: .init("org.nspasteboard.TransientType")))
        clipboard.clear()
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testClearPreservesLaterUserCopyEvenWhenTheTextMatches() {
        let (clipboard, pasteboard) = fixture()
        XCTAssertTrue(clipboard.copy("SYNTHETIC_API_KEY"))
        pasteboard.clearContents()
        pasteboard.setString("SYNTHETIC_API_KEY", forType: .string)
        clipboard.clear()
        XCTAssertEqual(pasteboard.string(forType: .string), "SYNTHETIC_API_KEY")
    }

    func testSecretExpiresWithoutAnotherAction() async throws {
        let (clipboard, pasteboard) = fixture(lifetime: .milliseconds(20))
        XCTAssertTrue(clipboard.copy("SYNTHETIC_API_KEY"))
        try await waitForCleanup(pasteboard)
    }

    func testTimeoutPreservesAnotherApplicationCopy() async throws {
        let (clipboard, pasteboard) = fixture(lifetime: .milliseconds(20))
        XCTAssertTrue(clipboard.copy("SYNTHETIC_API_KEY"))
        pasteboard.clearContents()
        pasteboard.setString("Later user text", forType: .string)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(pasteboard.string(forType: .string), "Later user text")
    }

    func testCopyAgainStartsANewExpiration() async throws {
        let (clipboard, pasteboard) = fixture(lifetime: .milliseconds(200))
        XCTAssertTrue(clipboard.copy("FIRST_SYNTHETIC_KEY"))
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertTrue(clipboard.copy("SECOND_SYNTHETIC_KEY"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pasteboard.string(forType: .string), "SECOND_SYNTHETIC_KEY")
        try await waitForCleanup(pasteboard)
    }

    func testEmptyCopyDoesNotReplaceClipboard() {
        let (clipboard, pasteboard) = fixture()
        pasteboard.clearContents()
        pasteboard.setString("Existing user text", forType: .string)
        XCTAssertFalse(clipboard.copy(""))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing user text")
        clipboard.clear()
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing user text")
    }
}
