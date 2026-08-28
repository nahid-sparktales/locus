import XCTest
@testable import Locus

final class WorkspaceFileModelTests: XCTestCase {
    @MainActor
    func testFilteringUsesTheConfiguredWorkspaceAndCapsResults() {
        let root = "/tmp/locus-workspace-files"
        let model = WorkspaceFileModel()
        model.configure(isUITesting: true, workspacePath: { root }, canIndex: { true })
        model.seed(
            (0..<240).map {
                URL(fileURLWithPath: root).appending(path: "Sources/Feature\($0).swift")
            },
            workspacePath: root
        )

        model.query = "feature"

        XCTAssertEqual(model.filteredFiles.count, 200)
        XCTAssertEqual(
            WorkspaceIndex.relativePath(model.filteredFiles[0], root: root),
            "Sources/Feature0.swift"
        )
    }

    @MainActor
    func testRefreshWaitsForSessionReadinessAndPublishesTheCurrentWorkspace() async {
        let root = "/tmp/locus-workspace-files"
        var isReady = false
        let expected = URL(fileURLWithPath: root).appending(path: "README.md")
        let model = WorkspaceFileModel(scanner: { _ in [expected] })
        model.configure(
            isUITesting: false,
            workspacePath: { root },
            canIndex: { isReady }
        )

        model.refresh()
        await Task.yield()
        XCTAssertTrue(model.files.isEmpty)

        isReady = true
        model.refresh()
        for _ in 0..<20 where model.files.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(model.files, [expected])
    }

    @MainActor
    func testPreviewPublishesReadableTextAndCloseClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "notes.txt")
        try Data("hello from the workspace".utf8).write(to: file)

        let model = WorkspaceFileModel()
        model.configure(
            isUITesting: false,
            workspacePath: { root.path },
            canIndex: { true }
        )
        model.preview(file)
        for _ in 0..<20 where model.previewedContents == nil {
            await Task.yield()
        }

        XCTAssertEqual(model.previewedPath, "notes.txt")
        XCTAssertEqual(model.previewedContents, "hello from the workspace")
        model.closePreview()
        XCTAssertNil(model.previewedPath)
        XCTAssertNil(model.previewedContents)
    }
}
