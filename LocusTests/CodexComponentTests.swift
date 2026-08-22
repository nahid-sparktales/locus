import CryptoKit
import XCTest

@testable import Locus

/// The component installer is the one place in Locus that takes a file off the
/// internet and executes it, so the tests here are deliberately about refusal:
/// every case that must *not* install.
final class CodexComponentTests: XCTestCase {
    private func release(
        arch: String = "arm64",
        minAppVersion: String = "2.0.0",
        url: String = "https://example.test/chatgpt-plan-0.147.0-arm64.zip",
        sha256: String = String(repeating: "a", count: 64),
        id: String = "chatgpt-plan"
    ) -> CodexComponentRelease {
        CodexComponentRelease(
            id: id,
            version: "0.147.0",
            arch: arch,
            minAppVersion: minAppVersion,
            url: url,
            sha256: sha256,
            downloadBytes: 100_300_000,
            installedBytes: 269_258_768
        )
    }

    private func feed(_ releases: [CodexComponentRelease], schema: Int = 1) -> CodexComponentFeed {
        CodexComponentFeed(schemaVersion: schema, components: releases)
    }

    func testSelectsMatchingArchitecture() throws {
        let selected = try CodexComponentInstaller.selectRelease(
            from: feed([release(arch: "x86_64"), release(arch: "arm64")]),
            arch: "arm64",
            appVersion: "2.0.0"
        )
        XCTAssertEqual(selected.arch, "arm64")
    }

    func testRejectsUnpublishedArchitecture() {
        XCTAssertThrowsError(
            try CodexComponentInstaller.selectRelease(
                from: feed([release(arch: "arm64")]),
                arch: "x86_64",
                appVersion: "2.0.0"
            )
        ) { error in
            XCTAssertEqual(error as? CodexComponentError, .unsupportedArchitecture("x86_64"))
        }
    }

    func testRejectsFeedThatOutranksTheApp() {
        XCTAssertThrowsError(
            try CodexComponentInstaller.selectRelease(
                from: feed([release(minAppVersion: "2.4.0")]),
                arch: "arm64",
                appVersion: "2.0.0"
            )
        ) { error in
            XCTAssertEqual(error as? CodexComponentError, .appTooOld("2.4.0"))
        }
    }

    /// A numeric compare, not a lexicographic one: "2.10.0" is newer than
    /// "2.9.0" even though it sorts earlier as a string.
    func testVersionComparisonIsNumericNotLexicographic() throws {
        let selected = try CodexComponentInstaller.selectRelease(
            from: feed([release(minAppVersion: "2.9.0")]),
            arch: "arm64",
            appVersion: "2.10.0"
        )
        XCTAssertEqual(selected.minAppVersion, "2.9.0")
    }

    func testRejectsPlaintextDownloadURL() {
        XCTAssertThrowsError(
            try CodexComponentInstaller.selectRelease(
                from: feed([release(url: "http://example.test/payload.zip")]),
                arch: "arm64",
                appVersion: "2.0.0"
            )
        )
    }

    func testRejectsMalformedChecksum() {
        for bad in ["", "not-hex", String(repeating: "a", count: 63), String(repeating: "z", count: 64)] {
            XCTAssertThrowsError(
                try CodexComponentInstaller.selectRelease(
                    from: feed([release(sha256: bad)]),
                    arch: "arm64",
                    appVersion: "2.0.0"
                ),
                "sha256 \(bad.isEmpty ? "<empty>" : bad) must be rejected"
            )
        }
    }

    func testRejectsUnknownSchemaVersion() {
        XCTAssertThrowsError(
            try CodexComponentInstaller.selectRelease(
                from: feed([release()], schema: 2),
                arch: "arm64",
                appVersion: "2.0.0"
            )
        )
    }

    func testIgnoresOtherComponentsInTheFeed() {
        XCTAssertThrowsError(
            try CodexComponentInstaller.selectRelease(
                from: feed([release(id: "some-other-component")]),
                arch: "arm64",
                appVersion: "2.0.0"
            )
        )
    }

    // MARK: - Signing requirement

    /// The requirement string is the trust boundary for a binary that arrives
    /// outside the app's notarized seal. It must pin both the team and the
    /// exact identifier — a valid SparkTales signature on some *other* binary
    /// is not good enough.
    func testRequirementPinsTeamAndIdentifier() {
        let requirement = CodexComponent.requirement(identifier: "io.sparktales.locus.codex")
        XCTAssertTrue(requirement.contains("identifier \"io.sparktales.locus.codex\""))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"4X4RJA7GMD\""))
        XCTAssertTrue(requirement.contains("anchor apple generic"))
    }

    func testUnsignedBinaryIsRejected() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "locus-unsigned-\(UUID().uuidString)")
        try Data("not a mach-o".utf8).write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        XCTAssertThrowsError(
            try CodexComponent.verifySignature(
                at: scratch, identifier: CodexComponent.helperIdentifier
            )
        )
    }

    // MARK: - Hashing

    func testStreamedHashMatchesCryptoKit() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "locus-hash-\(UUID().uuidString)")
        // Larger than the 1 MB read window, so the chunked loop is exercised.
        let payload = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        try payload.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let expected = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try CodexComponent.sha256(ofFileAt: scratch), expected)
    }

    // MARK: - Backend hand-off

    /// The backend re-`stat`s this path on every availability check, so it is
    /// exported even before anything is installed. Returning nil here instead
    /// would require restarting the agent after an install.
    func testHelperPathIsExportedBeforeInstall() throws {
        let path = try XCTUnwrap(CodexComponent.helperPathForBackend())
        XCTAssertTrue(path.hasSuffix("/codex"), "unexpected helper path: \(path)")
        if CodexComponent.bundledHelper == nil {
            XCTAssertTrue(
                path.contains("Components/chatgpt-plan/current"),
                "component path should be stable across versions: \(path)"
            )
        }
    }
}

/// The expanded archive is checked before any of it is trusted, because the
/// checksum only proves the payload matches the feed — not that the feed is ours.
final class CodexComponentExtractionTests: XCTestCase {
    private var staging: URL!

    override func setUpWithError() throws {
        staging = FileManager.default.temporaryDirectory
            .appending(path: "locus-extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: staging)
    }

    private func writeExpectedPayload() throws {
        for entry in ["codex", "codex-code-mode-host", "LICENSE", "NOTICE", "PROVENANCE"] {
            try Data("x".utf8).write(to: staging.appending(path: entry))
        }
    }

    func testAcceptsTheArchivePackageComponentsProduces() throws {
        try writeExpectedPayload()
        XCTAssertNoThrow(try CodexComponentInstaller.validateExpandedTree(at: staging))
    }

    func testRejectsUnexpectedEntry() throws {
        try writeExpectedPayload()
        try Data("payload".utf8).write(to: staging.appending(path: "install.sh"))
        XCTAssertThrowsError(try CodexComponentInstaller.validateExpandedTree(at: staging))
    }

    /// A symlink named `codex` could satisfy the signature check at one file and
    /// hand the agent a different one to execute.
    func testRejectsSymlinkedBinary() throws {
        try writeExpectedPayload()
        try FileManager.default.removeItem(at: staging.appending(path: "codex"))
        try FileManager.default.createSymbolicLink(
            atPath: staging.appending(path: "codex").path,
            withDestinationPath: "/bin/sh"
        )
        XCTAssertThrowsError(try CodexComponentInstaller.validateExpandedTree(at: staging)) { error in
            guard case .extractionFailed = error as? CodexComponentError ?? .feedUnavailable else {
                return XCTFail("expected extractionFailed, got \(error)")
            }
        }
    }

    func testRejectsDirectoryWhereABinaryBelongs() throws {
        try writeExpectedPayload()
        try FileManager.default.removeItem(at: staging.appending(path: "codex"))
        try FileManager.default.createDirectory(
            at: staging.appending(path: "codex"), withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try CodexComponentInstaller.validateExpandedTree(at: staging))
    }

    /// Every name the packaging script writes must be on the allow-list, or a
    /// legitimate component would be refused in the field.
    func testPermittedEntriesCoverThePublishedArchive() {
        XCTAssertEqual(
            CodexComponentInstaller.permittedEntries,
            ["codex", "codex-code-mode-host", "LICENSE", "NOTICE", "PROVENANCE"]
        )
    }
}

/// The manifest is attacker-shaped input: every field that reaches the
/// filesystem or the network has to be constrained before it is used.
final class CodexComponentManifestSafetyTests: XCTestCase {
    func testRejectsVersionsThatEscapeTheComponentRoot() {
        for hostile in ["../../../../bin", "..", ".", "", "0.147.0/../..", ".hidden",
                        "a/b", "with space", String(repeating: "9", count: 65),
                        // The symlink that publishes the active install.
                        "current"] {
            XCTAssertFalse(
                CodexComponentInstaller.isSafePathComponent(hostile),
                "\(hostile.isEmpty ? "<empty>" : hostile) must not become a directory name"
            )
        }
    }

    func testAcceptsRealVersionStrings() {
        for good in ["0.147.0", "1.0.0-beta.2", "2026_08_22", "0.147.0+build7"] {
            XCTAssertTrue(CodexComponentInstaller.isSafePathComponent(good), good)
        }
    }

    func testHostileVersionIsRejectedByFeedSelection() {
        let feed = CodexComponentFeed(
            schemaVersion: 1,
            components: [
                CodexComponentRelease(
                    id: "chatgpt-plan",
                    version: "../../../../../../tmp/pwned",
                    arch: "arm64",
                    minAppVersion: "2.0.0",
                    url: "https://example.test/p.zip",
                    sha256: String(repeating: "a", count: 64),
                    downloadBytes: 1,
                    installedBytes: 1
                )
            ]
        )
        XCTAssertThrowsError(
            try CodexComponentInstaller.selectRelease(
                from: feed, arch: "arm64", appVersion: "2.0.0"
            )
        )
    }
}
