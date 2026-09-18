import XCTest
import AppKit

/// `Image(systemName:)` fails silently at runtime: the view renders nothing and
/// AppKit logs "No symbol named … found in system symbol set". This scans the
/// app sources so a name that does not exist fails here instead.
final class SystemSymbolCatalogTests: XCTestCase {
    func testEverySystemSymbolLiteralResolves() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Locus")
        let pattern = try NSRegularExpression(
            pattern: #"system(?:Name|Image):\s*"([A-Za-z0-9._]+)""#
        )

        var names: [String: String] = [:]
        let files = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        )
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let found = Range(match.range(at: 1), in: source) else { continue }
                names[String(source[found])] = url.lastPathComponent
            }
        }

        XCTAssertGreaterThan(names.count, 100, "the scan found suspiciously few symbol literals")
        let missing = names
            .filter { NSImage(systemSymbolName: $0.key, accessibilityDescription: nil) == nil }
            .map { "\($0.key) (\($0.value))" }
            .sorted()
        XCTAssertEqual(missing, [], "these names are not in the system symbol set")
    }
}
