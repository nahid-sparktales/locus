import XCTest
@testable import Locus

/// Coverage for the workspace watcher that feeds the Overview's Outputs list.
///
/// The filter and the create-versus-edit decision are static so they can be
/// exercised without an FSEvents stream; a test that had to provoke real
/// kernel events would be slow and flaky, and would still not pin the policy.
final class SessionOutputWatcherTests: XCTestCase {
    func testIgnoresVersionControlDependencyCacheAndScratchPaths() {
        for path in [
            ".git/objects/ab/cdef",
            "node_modules/react/index.js",
            ".venv/lib/python3.12/site-packages/x.py",
            "__pycache__/module.cpython-312.pyc",
            "vendor/.terraform/plugin",
            ".DS_Store",
            "notes.md.tmp",
            "notes.md~",
            ".#notes.md",
            "Cargo.lock",
            "docs/.hidden/secret.md",
        ] {
            XCTAssertTrue(
                SessionOutputWatcher.isIgnored(path),
                "\(path) is churn, not something the run produced"
            )
        }

        for path in [
            "report.pdf",
            "docs/summary.md",
            "src/main.swift",
            "scripts/build.py",
        ] {
            XCTAssertFalse(SessionOutputWatcher.isIgnored(path), "\(path) is a real file")
        }
    }

    func testBuildDirectoriesKeepDeliverablesAndDropRubble() {
        // These directories cannot simply be skipped: a generated PDF or site
        // is exactly what a run is asked to produce, and that is where it
        // lands. But nor is everything under them an output.
        XCTAssertFalse(SessionOutputWatcher.isIgnored("dist/report.pdf"))
        XCTAssertFalse(SessionOutputWatcher.isIgnored("build/slides.pptx"))
        XCTAssertFalse(SessionOutputWatcher.isIgnored("out/index.html"))

        XCTAssertTrue(SessionOutputWatcher.isIgnored("dist/main.js.map"))
        XCTAssertTrue(SessionOutputWatcher.isIgnored("build/Release/App.o"))
        XCTAssertTrue(SessionOutputWatcher.isIgnored("target/debug/deps/lib.rlib"))
    }

    func testIgnoresPathsBuriedTooDeepToBeADeliverable() {
        let deep = Array(repeating: "nested", count: SessionOutputWatcher.depthCeiling)
            .joined(separator: "/") + "/report.pdf"
        XCTAssertTrue(SessionOutputWatcher.isIgnored(deep))
        XCTAssertFalse(SessionOutputWatcher.isIgnored("a/b/c/report.pdf"))
    }

    func testCreateVersusEditComesFromTheFileNotTheEventFlags() throws {
        // An atomic write — what apply_patch and most editors do — writes a
        // temporary and renames it over the target, and FSEvents coalesces the
        // flags, so an ordinary edit arrives carrying ItemCreated. The file's
        // own creation date is the signal that survives that.
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("locus-watcher-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let existing = root.appendingPathComponent("existing.md")
        try Data("old".utf8).write(to: existing)
        // The run starts after the file already existed.
        let runStart = Date().addingTimeInterval(1)
        let produced = root.appendingPathComponent("report.pdf")
        try Data("%PDF-1.4".utf8).write(to: produced)
        try fileManager.setAttributes(
            [.creationDate: runStart.addingTimeInterval(1)],
            ofItemAtPath: produced.path
        )

        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path

        XCTAssertEqual(
            SessionOutputWatcher.classify(
                path: rootPath + "/report.pdf",
                root: rootPath,
                runStart: runStart
            ),
            .init(path: "report.pdf", effect: .created)
        )
        XCTAssertEqual(
            SessionOutputWatcher.classify(
                path: rootPath + "/existing.md",
                root: rootPath,
                runStart: runStart
            ),
            .init(path: "existing.md", effect: .edited)
        )
        XCTAssertNil(
            SessionOutputWatcher.classify(
                path: rootPath + "/vanished.pdf",
                root: rootPath,
                runStart: runStart
            ),
            "a coalesced create-then-delete is a temporary, not an output"
        )
        XCTAssertNil(
            SessionOutputWatcher.classify(
                path: "/elsewhere/report.pdf",
                root: rootPath,
                runStart: runStart
            )
        )
    }

    func testExclusionPathsStayWithinTheFSEventsLimit() {
        // FSEventStreamSetExclusionPaths accepts at most eight.
        let paths = SessionOutputWatcher.exclusionPaths(root: "/tmp/project")
        XCTAssertLessThanOrEqual(paths.count, 8)
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/tmp/project/") })
    }
}
