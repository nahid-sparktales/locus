import Combine
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
        for _ in 0..<40 where model.files.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.files, [expected])
    }

    @MainActor
    func testInvalidationRejectsAnInFlightScanAndNextRequestRefreshes() async {
        let root = "/tmp/locus-workspace-files"
        let old = URL(fileURLWithPath: root).appendingPathComponent("removed.md")
        let current = URL(fileURLWithPath: root).appendingPathComponent("new.md")
        let scanner = ControlledWorkspaceIndexScanner(old: old, current: current)
        let model = WorkspaceFileModel(scanner: { _ in scanner.scan() })
        model.configure(isUITesting: false, workspacePath: { root }, canIndex: { true })
        defer { scanner.releaseFirst.signal(); model.stop() }
        let obsoletePublished = expectation(description: "Invalidated snapshot must not publish")
        obsoletePublished.isInverted = true
        let subscription = model.$files.dropFirst().sink { files in
            if files.contains(old) { obsoletePublished.fulfill() }
        }

        model.refresh()
        await fulfillment(of: [scanner.firstStarted], timeout: 1)
        model.invalidateIndex()
        scanner.releaseFirst.signal()
        await fulfillment(of: [scanner.firstReturning], timeout: 1)
        await fulfillment(of: [obsoletePublished], timeout: 0.1)
        XCTAssertTrue(model.files.isEmpty)

        // The obsolete completion must not mark this root as indexed.
        model.refresh()
        await fulfillment(of: [scanner.secondStarted], timeout: 1)
        for _ in 0..<40 where model.files != [current] {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.files, [current])
        subscription.cancel()
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

    @MainActor
    func testRepeatedTabSelectionReusesInFlightScan() async {
        let root = "/tmp/locus-workspace-files"
        let old = URL(fileURLWithPath: root).appendingPathComponent("first.md")
        let current = URL(fileURLWithPath: root).appendingPathComponent("forced.md")
        let scanner = ControlledWorkspaceIndexScanner(old: old, current: current)
        let model = WorkspaceFileModel(scanner: { _ in scanner.scan() })
        model.configure(isUITesting: false, workspacePath: { root }, canIndex: { true })
        defer { scanner.releaseFirst.signal(); model.stop() }

        model.refresh()
        await fulfillment(of: [scanner.firstStarted], timeout: 1)
        for _ in 0..<20 { model.refresh() }
        scanner.releaseFirst.signal()
        for _ in 0..<40 where model.files.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.files, [old], "Tab changes must not replace an in-flight scan")
        XCTAssertEqual(scanner.callCount, 1)

        model.refresh(force: true)
        await fulfillment(of: [scanner.secondStarted], timeout: 1)
        for _ in 0..<40 where model.files != [current] {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(model.files, [current], "Explicit refresh still scans again")
    }

    @MainActor
    func testEmptyIndexIsCachedUntilInvalidated() async {
        let root = "/tmp/locus-empty-workspace"
        let calls = expectation(description: "Exactly two scans: initial and invalidated")
        calls.expectedFulfillmentCount = 2
        calls.assertForOverFulfill = true
        let model = WorkspaceFileModel(scanner: { _ in calls.fulfill(); return [] })
        model.configure(isUITesting: false, workspacePath: { root }, canIndex: { true })
        defer { model.stop() }
        let initial = expectation(description: "Initial empty index committed")
        let subscription = model.$files.dropFirst().prefix(1).sink { _ in initial.fulfill() }
        model.refresh()
        await fulfillment(of: [initial], timeout: 1)
        for _ in 0..<20 {
            model.refresh()
            await Task.yield()
        }
        model.invalidateIndex()
        model.refresh()
        await fulfillment(of: [calls], timeout: 1)
        withExtendedLifetime(subscription) {}
    }
}

private final class ControlledWorkspaceIndexScanner: @unchecked Sendable {
    let firstStarted = XCTestExpectation(description: "First scan started")
    let firstReturning = XCTestExpectation(description: "First scan returning")
    let secondStarted = XCTestExpectation(description: "Next scan started")
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    private let old: URL
    private let current: URL

    init(old: URL, current: URL) { self.old = old; self.current = current }

    func scan() -> [URL] {
        lock.lock()
        calls += 1
        let first = calls == 1
        lock.unlock()
        if first {
            firstStarted.fulfill()
            _ = releaseFirst.wait(timeout: .now() + 3)
            firstReturning.fulfill()
            return [old]
        }
        secondStarted.fulfill()
        return [current]
    }
}
