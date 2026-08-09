import XCTest
@testable import Locus

/// Hunk parsing, patch synthesis, and the remote/branch/push helpers — the
/// pure machinery behind "ship a change". The real-repo tests at the bottom
/// prove the synthesized patches against an actual git index.
final class GitWorkflowTests: XCTestCase {
    // MARK: - Parsing

    private let twoHunkDiff = """
    diff --git a/app.py b/app.py
    index 1111111..2222222 100644
    --- a/app.py
    +++ b/app.py
    @@ -1,3 +1,3 @@
     first
    -second
    +second changed
     third
    @@ -10,4 +10,3 @@ def tail():
     tenth
    -eleventh
    -twelfth
    +eleventh merged
     thirteenth
    """

    func testParsesMultipleHunksWithOffsets() throws {
        let parsed = try XCTUnwrap(ParsedFileDiff.parse(twoHunkDiff))

        XCTAssertEqual(parsed.hunks.count, 2)
        XCTAssertFalse(parsed.isBinary)
        XCTAssertFalse(parsed.isRenameOrCopy)
        XCTAssertFalse(parsed.isModeChangeOnly)
        let first = parsed.hunks[0]
        XCTAssertEqual(first.oldStart, 1)
        XCTAssertEqual(first.oldCount, 3)
        XCTAssertEqual(first.newStart, 1)
        XCTAssertEqual(first.newCount, 3)
        XCTAssertEqual(first.lines, [" first", "-second", "+second changed", " third"])
        let second = parsed.hunks[1]
        XCTAssertEqual(second.header, "@@ -10,4 +10,3 @@ def tail():")
        XCTAssertEqual(second.oldCount, 4)
        XCTAssertEqual(second.newCount, 3)
        XCTAssertEqual(parsed.headerLines.first, "diff --git a/app.py b/app.py")
    }

    func testParsesOmittedCountAndSingleLineHunks() throws {
        let raw = """
        --- a/one.txt
        +++ b/one.txt
        @@ -3 +3 @@
        -old
        +new
        """
        let parsed = try XCTUnwrap(ParsedFileDiff.parse(raw))
        let hunk = try XCTUnwrap(parsed.hunks.first)
        XCTAssertEqual(hunk.oldStart, 3)
        XCTAssertEqual(hunk.oldCount, 1)
        XCTAssertEqual(hunk.newCount, 1)
        XCTAssertEqual(hunk.lines, ["-old", "+new"])
    }

    func testNoNewlineMarkerStaysWithItsHunk() throws {
        let raw = """
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let parsed = try XCTUnwrap(ParsedFileDiff.parse(raw))
        let hunk = try XCTUnwrap(parsed.hunks.first)
        XCTAssertEqual(hunk.lines.count, 4)
        XCTAssertTrue(hunk.lines[1].hasPrefix("\\ No newline"))
        let patch = try XCTUnwrap(parsed.minimalPatch(for: hunk))
        XCTAssertTrue(patch.contains("\\ No newline at end of file"))
        XCTAssertTrue(patch.hasSuffix("\n"))
    }

    func testCRLFBytesSurviveParseAndSynthesis() throws {
        let raw = "--- a/dos.txt\n+++ b/dos.txt\n@@ -1,2 +1,2 @@\n line one\r\n-old\r\n+new\r"
        let parsed = try XCTUnwrap(ParsedFileDiff.parse(raw))
        let hunk = try XCTUnwrap(parsed.hunks.first)
        XCTAssertEqual(hunk.lines, [" line one\r", "-old\r", "+new\r"])
        let patch = try XCTUnwrap(parsed.minimalPatch(for: hunk))
        XCTAssertTrue(patch.contains("-old\r\n"))
    }

    func testNewAndDeletedFileShapesParse() throws {
        let created = try XCTUnwrap(ParsedFileDiff.parse("""
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +alpha
        +beta
        """))
        XCTAssertEqual(created.hunks.count, 1)
        XCTAssertEqual(created.hunks[0].oldStart, 0)
        XCTAssertEqual(created.hunks[0].oldCount, 0)

        let deleted = try XCTUnwrap(ParsedFileDiff.parse("""
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -alpha
        -beta
        """))
        XCTAssertEqual(deleted.hunks.count, 1)
        XCTAssertEqual(deleted.hunks[0].newCount, 0)
    }

    func testRenameIsFlaggedAndRefusesSynthesis() throws {
        let parsed = try XCTUnwrap(ParsedFileDiff.parse("""
        diff --git a/old-name.txt b/new-name.txt
        similarity index 95%
        rename from old-name.txt
        rename to new-name.txt
        --- a/old-name.txt
        +++ b/new-name.txt
        @@ -1,2 +1,2 @@
         kept
        -tweak
        +tweaked
        """))
        XCTAssertTrue(parsed.isRenameOrCopy)
        XCTAssertNil(parsed.minimalPatch(for: parsed.hunks[0]))
    }

    func testBinaryAndModeChangeShapesCarryNoHunks() throws {
        let binary = try XCTUnwrap(ParsedFileDiff.parse("""
        diff --git a/icon.png b/icon.png
        index 1111111..2222222 100644
        Binary files a/icon.png and b/icon.png differ
        """))
        XCTAssertTrue(binary.isBinary)
        XCTAssertTrue(binary.hunks.isEmpty)

        let mode = try XCTUnwrap(ParsedFileDiff.parse("""
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        """))
        XCTAssertTrue(mode.isModeChangeOnly)
        XCTAssertTrue(mode.hunks.isEmpty)
    }

    func testProseWithoutDiffHeadersDoesNotParse() {
        XCTAssertNil(ParsedFileDiff.parse("Could not load the diff."))
        XCTAssertNil(ParsedFileDiff.parse("No changes to show."))
    }

    func testMinimalPatchIsHeaderPlusExactlyOneHunk() throws {
        let parsed = try XCTUnwrap(ParsedFileDiff.parse(twoHunkDiff))
        let patch = try XCTUnwrap(parsed.minimalPatch(for: parsed.hunks[0]))

        XCTAssertTrue(patch.contains("@@ -1,3 +1,3 @@"))
        XCTAssertFalse(patch.contains("@@ -10,4 +10,3 @@"))
        XCTAssertFalse(patch.contains("eleventh"))
        XCTAssertTrue(patch.hasPrefix("diff --git a/app.py b/app.py\n"))
        XCTAssertTrue(patch.hasSuffix(" third\n"))
    }

    func testDriftMatchingFindsMovedHunksAndRefusesEditedOnes() throws {
        let original = try XCTUnwrap(ParsedFileDiff.parse(twoHunkDiff))
        let stale = original.hunks[1]

        // Same edits, shifted offsets: content identity re-locates it.
        let moved = try XCTUnwrap(ParsedFileDiff.parse(
            twoHunkDiff.replacingOccurrences(
                of: "@@ -10,4 +10,3 @@ def tail():",
                with: "@@ -14,4 +14,3 @@ def tail():"
            )
        ))
        XCTAssertNotNil(moved.matching(stale))

        // Edited content: no match, nothing to apply.
        let edited = try XCTUnwrap(ParsedFileDiff.parse(
            twoHunkDiff.replacingOccurrences(of: "eleventh merged", with: "rewritten")
        ))
        XCTAssertNil(edited.matching(stale))
    }

    // MARK: - Remote helpers

    func testGitHubCompareURLUnderstandsAllRemoteShapes() {
        for remote in [
            "git@github.com:acme/widget.git",
            "git@github.com:acme/widget",
            "ssh://git@github.com/acme/widget",
            "https://github.com/acme/widget.git",
            "https://github.com/acme/widget",
        ] {
            XCTAssertEqual(
                GitRemoteURL.githubCompareURL(remote: remote, branch: "ship-test")?.absoluteString,
                "https://github.com/acme/widget/compare/ship-test?expand=1",
                remote
            )
        }
        XCTAssertNil(GitRemoteURL.githubCompareURL(
            remote: "https://gitlab.com/acme/widget.git", branch: "b"
        ))
        XCTAssertNil(GitRemoteURL.githubCompareURL(
            remote: "git@example.com:acme/widget.git", branch: "b"
        ))
        XCTAssertNil(GitRemoteURL.githubCompareURL(remote: "", branch: "b"))
    }

    func testBranchNamePreValidationCatchesTheObviousRefusals() {
        XCTAssertNil(GitBranchName.validationError("feature/ship-test"))
        XCTAssertNil(GitBranchName.validationError("hotfix-2026.08"))
        for bad in [
            "", "has space", "-leading-dash", "trailing.lock", "double..dot",
            "at@{brace", "ends/", "/starts", "seg//ment", "ends.", "wild*card",
        ] {
            XCTAssertNotNil(GitBranchName.validationError(bad), bad)
        }
    }

    func testPushPlanPublishesOnlyWhenNoUpstreamExists() {
        XCTAssertEqual(
            GitPushPlan.arguments(branch: "main", upstream: "origin/main"),
            ["push"]
        )
        XCTAssertEqual(
            GitPushPlan.arguments(branch: "ship-test", upstream: nil),
            ["push", "--set-upstream", "origin", "ship-test"]
        )
        XCTAssertEqual(
            GitPushPlan.arguments(branch: "ship-test", upstream: ""),
            ["push", "--set-upstream", "origin", "ship-test"]
        )
    }

    // MARK: - Real repository integration

    private func makeRepo() throws -> (URL, GitClient) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "locus-git-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let client = GitClient(workspaceRoot: root.path)
        return (root, client)
    }

    private func runGit(_ client: GitClient, _ args: [String], stdin: Data? = nil) async throws
        -> GitCommandResult
    {
        // Neutralized identity/config so the host's gitconfig cannot steer
        // these tests, mirroring the agent suite's fixture.
        try await client.run(
            ["-c", "user.name=Locus Tests", "-c", "user.email=tests@example.invalid",
             "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false"] + args,
            stdin: stdin
        )
    }

    func testStagingOneHunkStagesOnlyThatHunk() async throws {
        let (root, client) = try makeRepo()
        try await runGit(client, ["init", "-q", "-b", "main"])
        let file = root.appending(path: "app.py")
        let original = (1...14).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        try await runGit(client, ["add", "."])
        try await runGit(client, ["commit", "-q", "-m", "seed"])

        let edited = original
            .replacingOccurrences(of: "line 2", with: "line 2 changed")
            .replacingOccurrences(of: "line 12", with: "line 12 changed")
        try edited.write(to: file, atomically: true, encoding: .utf8)

        let diff = try await runGit(client, ["diff", "-U3", "--", "app.py"])
        let parsed = try XCTUnwrap(ParsedFileDiff.parse(diff.stdout))
        XCTAssertEqual(parsed.hunks.count, 2)
        let patch = try XCTUnwrap(parsed.minimalPatch(for: parsed.hunks[0]))

        try await runGit(client, ["apply", "--cached"], stdin: Data(patch.utf8))

        let staged = try await runGit(client, ["diff", "--cached", "--", "app.py"])
        XCTAssertTrue(staged.stdout.contains("line 2 changed"))
        XCTAssertFalse(staged.stdout.contains("line 12 changed"))
        let unstaged = try await runGit(client, ["diff", "--", "app.py"])
        XCTAssertTrue(unstaged.stdout.contains("line 12 changed"))

        // Reverse-apply discards only the still-unstaged hunk from the tree.
        let remaining = try XCTUnwrap(ParsedFileDiff.parse(unstaged.stdout))
        let discard = try XCTUnwrap(remaining.minimalPatch(for: remaining.hunks[0]))
        try await runGit(client, ["apply", "-R"], stdin: Data(discard.utf8))
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(after.contains("line 2 changed"))
        XCTAssertFalse(after.contains("line 12 changed"))
    }

    func testStaleHunkFailsWithoutTouchingIndexOrWorktree() async throws {
        let (root, client) = try makeRepo()
        try await runGit(client, ["init", "-q", "-b", "main"])
        let file = root.appending(path: "notes.txt")
        try "alpha\nbeta\ngamma\n".write(to: file, atomically: true, encoding: .utf8)
        try await runGit(client, ["add", "."])
        try await runGit(client, ["commit", "-q", "-m", "seed"])
        try "alpha\nbeta edited\ngamma\n".write(to: file, atomically: true, encoding: .utf8)

        let diff = try await runGit(client, ["diff", "-U3", "--", "notes.txt"])
        let stale = try XCTUnwrap(ParsedFileDiff.parse(diff.stdout)).hunks[0]

        // The file changes again between reading the diff and clicking Stage.
        try "alpha\nbeta rewritten\ngamma\n".write(to: file, atomically: true, encoding: .utf8)
        let fresh = try await runGit(client, ["diff", "-U3", "--", "notes.txt"])
        let reparsed = try XCTUnwrap(ParsedFileDiff.parse(fresh.stdout))

        XCTAssertNil(reparsed.matching(stale), "a drifted hunk must never re-match")
        let staged = try await runGit(client, ["diff", "--cached"])
        XCTAssertEqual(staged.stdout, "")
    }

    func testLargePatchRoundTripsThroughStdin() async throws {
        let (root, client) = try makeRepo()
        try await runGit(client, ["init", "-q", "-b", "main"])
        let file = root.appending(path: "big.txt")
        let lines = (1...4_000).map { "row \($0) with a reasonably long tail of text" }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try await runGit(client, ["add", "."])
        try await runGit(client, ["commit", "-q", "-m", "seed"])
        let edited = lines.map { $0 + " EDITED" }
        try (edited.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let diff = try await runGit(client, ["diff", "-U3", "--", "big.txt"])
        XCTAssertGreaterThan(diff.stdout.utf8.count, 64 * 1024, "must exceed one pipe buffer")
        let parsed = try XCTUnwrap(ParsedFileDiff.parse(diff.stdout))
        let patch = try XCTUnwrap(parsed.minimalPatch(for: parsed.hunks[0]))

        try await runGit(client, ["apply", "--cached"], stdin: Data(patch.utf8))

        let staged = try await runGit(client, ["diff", "--cached", "--stat"])
        XCTAssertTrue(staged.stdout.contains("big.txt"))
    }
}
