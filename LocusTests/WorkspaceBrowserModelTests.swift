import XCTest
@testable import Locus

final class WorkspaceBrowserModelTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locus-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func write(_ path: String, root: URL, text: String = "example") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testDirectoryListsAllTypesWithoutWalkingGeneratedFolders() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["report.pdf", "README", ".hidden.txt", "node_modules/deep/package.json", "dist/result.xlsx"] {
            try write(path, root: root)
        }
        let provider = WorkspaceBrowserProvider()
        let entries = try await provider.children(workspace: root.path, directory: "", showHidden: false)
        XCTAssertEqual(entries.map(\.path), ["dist", "node_modules", "README", "report.pdf"])
        XCTAssertEqual(entries.first(where: { $0.path == "report.pdf" })?.contextAction, .attachment)
        let generated = try await provider.children(workspace: root.path, directory: "node_modules", showHidden: false)
        XCTAssertEqual(generated.map(\.path), ["node_modules/deep"])
        let hidden = try await provider.children(workspace: root.path, directory: "", showHidden: true)
        XCTAssertTrue(hidden.contains(where: { $0.path == ".hidden.txt" }))
    }

    func testFilesystemRootCanOpenAChildDirectory() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("child.txt", root: directory)
        let path = String(directory.path.dropFirst())
        let entries = try await WorkspaceBrowserProvider().children(
            workspace: "/", directory: path, showHidden: false
        )
        XCTAssertEqual(entries.map(\.path), [path + "/child.txt"])
    }

    func testSearchFindsCollapsedAndGeneratedFoldersAndSharesHiddenPolicy() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["dist/report.pdf", "node_modules/nested/report.json", ".secret/report.txt", "visible/report.md"] {
            try write(path, root: root)
        }
        let provider = WorkspaceBrowserProvider()
        let id = UUID()
        try await provider.beginSearch(id: id, workspace: root.path, query: "report", showHidden: false)
        let visible = try await provider.nextSearchBatch(id: id, maximumMatches: 100)
        XCTAssertTrue(visible.finished)
        XCTAssertEqual(Set(visible.entries.map(\.path)), ["dist/report.pdf", "node_modules/nested/report.json", "visible/report.md"])
        let hiddenID = UUID()
        try await provider.beginSearch(id: hiddenID, workspace: root.path, query: "report", showHidden: true)
        let all = try await provider.nextSearchBatch(id: hiddenID, maximumMatches: 100)
        XCTAssertEqual(all.entries.count, 4)
    }

    func testSearchBudgetResumesFromCursorWithoutDroppingOrDuplicatingMatches() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<7 { try write("match-\(index).txt", root: root) }
        let provider = WorkspaceBrowserProvider(), id = UUID()
        try await provider.beginSearch(id: id, workspace: root.path, query: "match", showHidden: false)
        let first = try await provider.nextSearchBatch(id: id, maximumMatches: 3)
        let second = try await provider.nextSearchBatch(id: id, maximumMatches: 3)
        let third = try await provider.nextSearchBatch(id: id, maximumMatches: 3)
        XCTAssertEqual(first.entries.count, 3)
        XCTAssertFalse(first.finished)
        XCTAssertEqual(second.entries.count, 3)
        XCTAssertEqual(third.entries.count, 1)
        XCTAssertTrue(third.finished)
        XCTAssertEqual(Set((first.entries + second.entries + third.entries).map(\.path)).count, 7)
    }

    func testDirectorySymlinksRemainLeavesAndCannotEscapeWorkspace() async throws {
        let root = try workspace(), outside = try workspace()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write("outside-secret.txt", root: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: outside)
        let provider = WorkspaceBrowserProvider()
        let entries = try await provider.children(workspace: root.path, directory: "", showHidden: false)
        XCTAssertEqual(entries.first?.kind, .symbolicLink)
        XCTAssertEqual(entries.first?.contextAction, .unavailable)
        do {
            _ = try await provider.children(workspace: root.path, directory: "outside", showHidden: false)
            XCTFail("A symlink directory must not be traversed")
        } catch { }
        let id = UUID()
        try await provider.beginSearch(id: id, workspace: root.path, query: "secret", showHidden: false)
        let result = try await provider.nextSearchBatch(id: id, maximumMatches: 100)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testContextCapabilityUsesSeparateTextAndAttachmentLimits() {
        XCTAssertEqual(WorkspaceBrowserEntry.contextAction(extension: "py", size: 256_000, isRegularFile: true), .context)
        XCTAssertEqual(WorkspaceBrowserEntry.contextAction(extension: "py", size: 300_000, isRegularFile: true), .attachment)
        XCTAssertEqual(WorkspaceBrowserEntry.contextAction(extension: "pdf", size: 99_000_000, isRegularFile: true), .attachment)
        XCTAssertEqual(WorkspaceBrowserEntry.contextAction(extension: "pdf", size: 101_000_000, isRegularFile: true), .unavailable)
        XCTAssertEqual(WorkspaceBrowserEntry.contextAction(extension: "png", size: 16_000_000, isRegularFile: true), .unavailable)
        XCTAssertEqual(WorkspaceBrowserEntry.contextAction(extension: "zip", size: 100, isRegularFile: true), .unavailable)
    }

    @MainActor
    func testTreePagesAndOnlyLoadsExpandedDirectories() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceBrowserModel()
        model.seed(urls: (0..<240).map { root.appendingPathComponent("file\($0).txt") } + [root.appendingPathComponent("nested/child.txt")], workspace: root.path)
        XCTAssertNil(model.directories["nested"])
        XCTAssertEqual(model.rows.filter { if case .entry = $0.content { return true }; return false }.count, 200)
        XCTAssertTrue(model.rows.contains { if case .more(_, 41) = $0.content { return true }; return false })
        model.showMore(in: "")
        XCTAssertEqual(model.rows.filter { if case .entry = $0.content { return true }; return false }.count, 241)
        model.toggle("nested")
        XCTAssertEqual(model.directories["nested"]?.entries.map(\.path), ["nested/child.txt"])
    }

    @MainActor
    func testWorkspaceSwitchRejectsOldEnumerationAndSearchResults() async throws {
        let first = try workspace(), second = try workspace()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try write("old-match.txt", root: first)
        try write("new-match.txt", root: second)
        let model = WorkspaceBrowserModel()
        model.activate(workspace: first.path, watch: false)
        model.query = "old"
        model.activate(workspace: second.path, watch: false)
        model.query = "new"
        await settle { model.searchState == .ready && model.rootState == .ready }
        XCTAssertEqual(model.directories[""]?.entries.map(\.path), ["new-match.txt"])
        XCTAssertEqual(model.searchResults.map(\.path), ["new-match.txt"])
        model.stop()
    }

    @MainActor
    func testFixtureCanReceiveFilesAfterAnEmptyInitialSeed() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceBrowserModel()
        model.seed(urls: [], workspace: root.path)
        XCTAssertTrue(model.directories[""]?.entries.isEmpty == true)
        model.seed(urls: [root.appendingPathComponent("ready.txt")], workspace: root.path)
        XCTAssertEqual(model.directories[""]?.entries.map(\.path), ["ready.txt"])
    }

    @MainActor
    func testDroppedEventsRefreshExpandedNodesAndFailedNodesCanRetry() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("folder/old.txt", root: root)
        let model = WorkspaceBrowserModel()
        model.activate(workspace: root.path, watch: false)
        await settle { model.rootState == .ready }
        model.toggle("folder")
        await settle { model.directories["folder"]?.state == .ready }
        try write("folder/new.txt", root: root)
        model.invalidate(paths: [], full: true)
        await settle { model.directories["folder"]?.entries.count == 2 }
        model.toggle("missing")
        await settle { if case .failed = model.directories["missing"]?.state { return true }; return false }
        try write("missing/now-here.txt", root: root)
        model.loadDirectory("missing")
        await settle { model.directories["missing"]?.state == .ready }
        XCTAssertEqual(model.directories["missing"]?.entries.map(\.path), ["missing/now-here.txt"])
        model.stop()
    }

    @MainActor
    func testInvalidationRefreshesLoadedParentForCreateRenameAndDelete() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("folder/old.txt", root: root)
        let model = WorkspaceBrowserModel()
        model.activate(workspace: root.path, watch: false)
        await settle { model.rootState == .ready }
        model.toggle("folder")
        await settle { model.directories["folder"]?.state == .ready }
        model.select("folder/old.txt")
        try FileManager.default.moveItem(at: root.appendingPathComponent("folder/old.txt"), to: root.appendingPathComponent("folder/new.txt"))
        model.invalidate(paths: [root.appendingPathComponent("folder/old.txt").path, root.appendingPathComponent("folder/new.txt").path])
        await settle { model.directories["folder"]?.entries.map(\.path) == ["folder/new.txt"] }
        XCTAssertNil(model.selectedPath)
        XCTAssertTrue(model.expanded.contains("folder"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("folder/new.txt"))
        model.invalidate(paths: [root.appendingPathComponent("folder/new.txt").path])
        await settle { model.directories["folder"]?.entries.isEmpty == true }
        model.stop()
    }

    @MainActor
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Browser did not reach the expected state", file: file, line: line)
    }
}
