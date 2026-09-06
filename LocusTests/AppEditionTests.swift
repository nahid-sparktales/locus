import XCTest
@testable import Locus

final class AppEditionTests: XCTestCase {
    func testOnlyStandardLocusFallsBackToTheSourceTreeBackend() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ollama_code"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".venv/bin/python"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        try Data().write(to: root.appendingPathComponent("ollama_code/server.py"))

        XCTAssertEqual(
            BackendProcess.resolvedRuntime(root: root.path, resources: nil, edition: .locus)?.source.path,
            root.standardizedFileURL.path
        )
        XCTAssertNil(BackendProcess.resolvedRuntime(root: root.path, resources: nil, edition: .locusX))

        let resources = root.appendingPathComponent("Resources")
        let runtime = resources.appendingPathComponent("AgentRuntime")
        for directory in ["source/ollama_code", "python/bin", "site-packages"] {
            try FileManager.default.createDirectory(
                at: runtime.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
        try FileManager.default.createSymbolicLink(
            at: runtime.appendingPathComponent("python/bin/python3"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        try Data().write(to: runtime.appendingPathComponent("source/ollama_code/server.py"))
        let bundled = try XCTUnwrap(
            BackendProcess.resolvedRuntime(root: root.path, resources: resources, edition: .locusX)
        )
        XCTAssertEqual(bundled.source.path, runtime.appendingPathComponent("source").path)
        XCTAssertNotNil(bundled.packages)
    }

    func testLocusKeepsItsExistingProfileLocationsAndIdentifiers() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let support = home.appendingPathComponent("Library/Application Support")
        let edition = AppEdition.locus
        XCTAssertEqual(edition.bundleIdentifier, "io.sparktales.locus")
        XCTAssertEqual(edition.supportDirectory(in: support).path, support.path + "/Locus")
        XCTAssertEqual(edition.credentialFile(in: home).path, "/Users/fixture/.locus/auth.json")
        XCTAssertEqual(edition.keychainService("mcp"), "io.sparktales.locus.mcp")
        XCTAssertEqual(edition.mcpRedirectURI, "locus://mcp/oauth")
        XCTAssertEqual(edition.browserProfileKey(for: "/tmp/project"), "/tmp/project")
        XCTAssertEqual(edition.companionCertificateLabel, "Locus Companion TLS")
        XCTAssertNil(edition.backendHomes(in: support, sandboxed: false)["OLLAMA_CODE_HOME"])
        XCTAssertEqual(edition.backendHomes(in: support, sandboxed: true)["OLLAMA_CODE_HOME"],
                       support.path + "/Locus/Agent")
    }

    func testLocusXHasIndependentHomesCredentialsAndCallbacks() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let support = home.appendingPathComponent("Library/Application Support")
        let edition = AppEdition.locusX
        XCTAssertEqual(edition.bundleIdentifier, "io.sparktales.locusx")
        XCTAssertEqual(edition.supportDirectory(in: support).path, support.path + "/LocusX")
        XCTAssertEqual(edition.credentialFile(in: home).path, "/Users/fixture/.locusx/auth.json")
        for suffix in ["mcp", "connector", "browser-autofill.v2", "companion.identity"] {
            XCTAssertNotEqual(edition.keychainService(suffix), AppEdition.locus.keychainService(suffix))
        }
        XCTAssertEqual(edition.mcpRedirectURI, "locusx://mcp/oauth")
        XCTAssertNotEqual(edition.browserProfileKey(for: "/tmp/project"),
                          AppEdition.locus.browserProfileKey(for: "/tmp/project"))
        XCTAssertNotEqual(edition.companionCertificateLabel, AppEdition.locus.companionCertificateLabel)
        XCTAssertEqual(edition.backendHomes(in: support, sandboxed: false), [
            "OLLAMA_CODE_HOME": support.path + "/LocusX/Agent",
            "LOCUS_CODEX_HOME": support.path + "/LocusX/Codex",
        ])
    }

    func testMissingGoogleConfigurationFailsBeforeStartingAuthentication() {
        XCTAssertThrowsError(try GmailOAuthConfiguration(clientID: "", callbackScheme: "")) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Google sign-in is not configured for this \(AppEdition.current.displayName) build.")
        }
    }

    func testMCPCallbacksCannotCrossEditionsOrAddRedirectComponents() {
        for edition in AppEdition.allCases {
            XCTAssertEqual(edition.canonicalMCPRedirectURI(edition.mcpRedirectURI), edition.mcpRedirectURI)
            let other: AppEdition = edition == .locus ? .locusX : .locus
            XCTAssertNil(edition.canonicalMCPRedirectURI(other.mcpRedirectURI))
            for suffix in ["?token=secret", "#fragment", "/extra"] {
                XCTAssertNil(edition.canonicalMCPRedirectURI(edition.mcpRedirectURI + suffix))
            }
        }
    }
}
