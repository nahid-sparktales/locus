import XCTest
@testable import Locus

final class FeatureLogicTests: XCTestCase {
    // MARK: - Slash commands

    func testSlashQueryDetection() {
        XCTAssertEqual(SlashCommand.query(from: "/"), "")
        XCTAssertEqual(SlashCommand.query(from: "/mod"), "mod")
        XCTAssertEqual(SlashCommand.query(from: "/model qwen3:8b"), "model qwen3:8b")
        XCTAssertNil(SlashCommand.query(from: "plain prose"))
        XCTAssertNil(SlashCommand.query(from: "/clear\nsecond line"))
    }

    func testSlashMatchesRankPrefixFirst() {
        let matches = SlashCommand.matches(for: "c")
        XCTAssertTrue(matches.count >= 4)
        XCTAssertTrue(matches.first!.name.hasPrefix("c"))
        XCTAssertEqual(SlashCommand.matches(for: "").count, SlashCommand.all.count)
        XCTAssertTrue(SlashCommand.matches(for: "zzzz").isEmpty)
    }

    func testSlashInvocationAndArguments() {
        XCTAssertEqual(SlashCommand.command(invokedBy: "/plan")?.name, "plan")
        XCTAssertEqual(SlashCommand.command(invokedBy: "/new")?.name, "clear")
        XCTAssertNil(SlashCommand.command(invokedBy: "/pla"))
        XCTAssertEqual(SlashCommand.argument(in: "/model qwen3:8b"), "qwen3:8b")
        XCTAssertEqual(SlashCommand.argument(in: "/model"), "")
    }

    func testSlashCommandNamesAndAliasesAreUnique() {
        let names = SlashCommand.all.flatMap { [$0.name] + $0.aliases }
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testWorkspaceCommandsAreDistinguishable() {
        XCTAssertEqual(SlashCommand.command(invokedBy: "/workspace")?.action, .chooseWorkspace)
        XCTAssertEqual(SlashCommand.command(invokedBy: "/newworkspace")?.action, .newWorkspace)
        XCTAssertEqual(SlashCommand.command(invokedBy: "/mkdir")?.action, .newWorkspace)
        // "/new" is the clear-chat alias and must not be captured by the
        // new-workspace command's prefix.
        XCTAssertEqual(SlashCommand.command(invokedBy: "/new")?.action, .clearChat)
    }

    // MARK: - Thinking segments

    func testThinkingSegmentsAreSeparatedFromVisibleText() {
        let segments = AssistantSegment.parse(
            "<think>weighing options</think>Here is the answer."
        )
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], .thinking(text: "weighing options", isComplete: true))
        XCTAssertEqual(segments[1], .visible("Here is the answer."))
    }

    func testUnclosedThinkingTagIsStreamedAsIncomplete() {
        let segments = AssistantSegment.parse("<think>still going")
        XCTAssertEqual(segments, [.thinking(text: "still going", isComplete: false)])
    }

    func testPlainTextHasSingleVisibleSegment() {
        XCTAssertEqual(AssistantSegment.parse("hello"), [.visible("hello")])
        XCTAssertTrue(AssistantSegment.parse("  \n ").isEmpty)
    }

    func testThinkingTagVariantAndSurroundingProse() {
        let segments = AssistantSegment.parse(
            "intro\n<thinking>plan</thinking>\noutro"
        )
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1], .thinking(text: "plan", isComplete: true))
    }

    // MARK: - Markdown fragments

    func testFencedCodeBlocksBecomeCodeFragments() {
        let fragments = MarkdownFragment.parse(
            "Before\n```swift\nlet x = 1\n```\nAfter"
        )
        XCTAssertEqual(fragments.count, 3)
        XCTAssertEqual(fragments[0], .text("Before"))
        XCTAssertEqual(fragments[1], .code(language: "swift", body: "let x = 1"))
        XCTAssertEqual(fragments[2], .text("After"))
    }

    func testUnterminatedFenceStillProducesCode() {
        let fragments = MarkdownFragment.parse("```\nraw")
        XCTAssertEqual(fragments, [.code(language: nil, body: "raw")])
    }

    // MARK: - Diff detection

    func testUnifiedDiffIsDetected() {
        XCTAssertTrue(DiffDetector.isDiff("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new"))
        XCTAssertTrue(DiffDetector.isDiff("-removed line\n+added line"))
        XCTAssertFalse(DiffDetector.isDiff("just some prose\nwith lines"))
        XCTAssertFalse(DiffDetector.isDiff("+ only additions bullet style"))
    }

    // MARK: - Mentions

    func testActiveMentionDetection() {
        let mention = WorkspaceIndex.activeMention(in: "please read @App")
        XCTAssertEqual(mention?.query, "App")

        XCTAssertNil(WorkspaceIndex.activeMention(in: "email me a@b done"))
        XCTAssertNil(WorkspaceIndex.activeMention(in: "no mention here"))
        XCTAssertEqual(WorkspaceIndex.activeMention(in: "@")?.query, "")
    }

    func testMentionMatchingRanksFileNamePrefixFirst() {
        let root = "/tmp/ws"
        let files = [
            URL(fileURLWithPath: "/tmp/ws/Sources/AppModel.swift"),
            URL(fileURLWithPath: "/tmp/ws/Sources/Model.swift"),
            URL(fileURLWithPath: "/tmp/ws/Docs/app-notes.md"),
        ]
        let matches = WorkspaceIndex.matches(query: "app", in: files, root: root)
        XCTAssertEqual(matches.first?.lastPathComponent, "app-notes.md")
        XCTAssertTrue(matches.contains { $0.lastPathComponent == "AppModel.swift" })

        let modelMatches = WorkspaceIndex.matches(query: "model", in: files, root: root)
        XCTAssertEqual(modelMatches.first?.lastPathComponent, "Model.swift")
    }

    // MARK: - Inspector chrome

    func testInspectorTabsAreStableAndUnique() {
        XCTAssertEqual(InspectorTab.allCases.count, 5)
        let raws = InspectorTab.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        XCTAssertEqual(Set(InspectorTab.allCases.map(\.symbol)).count, raws.count)
        XCTAssertEqual(Set(InspectorTab.allCases.map(\.title)).count, raws.count)
        // rawValue is the accessibility-identifier and persistence contract.
        XCTAssertEqual(InspectorTab(rawValue: "plan"), .plan)
        XCTAssertEqual(InspectorTab(rawValue: "terminal"), .terminal)
    }

    func testInspectorShortcutsAreOneThroughFive() {
        XCTAssertEqual(InspectorTab.allCases.map(\.shortcutKey), ["1", "2", "3", "4", "5"])
    }

    func testInspectorWidthIsClampedToTheUsableRange() {
        XCTAssertEqual(AppSettings.clampInspectorWidth(0), 280)
        XCTAssertEqual(AppSettings.clampInspectorWidth(9999), 520)
        XCTAssertEqual(AppSettings.clampInspectorWidth(400), 400)
        XCTAssertEqual(AppSettings.clampInspectorWidth(.nan), 340, "a corrupt value must not survive")
    }

    func testInspectorChromeSurvivesASettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.inspectorWidth = 412
        settings.inspectorCollapsed = true
        settings.inspectorLastTab = InspectorTab.terminal.rawValue

        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.inspectorWidth, 412)
        XCTAssertTrue(restored.inspectorCollapsed)
        XCTAssertEqual(restored.resolvedInspectorTab, .terminal)
    }

    func testStoredInspectorWidthIsClampedOnDecode() throws {
        let hostile = #"{"inspectorWidth": 5000, "inspectorLastTab": "plan"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(hostile.utf8))
        XCTAssertEqual(restored.inspectorWidth, 520)
    }

    func testUnknownStoredTabFallsBackToPlan() throws {
        let future = #"{"inspectorLastTab": "quantum", "previewURL": "http://x"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(future.utf8))
        XCTAssertEqual(restored.resolvedInspectorTab, .plan)
        // The unknown tab must not take the rest of the settings down with it.
        XCTAssertEqual(restored.previewURL, "http://x")
    }

    func testSettingsFromBeforeTheInspectorGetDefaults() throws {
        let legacy = #"{"backendURL":"http://127.0.0.1:8791"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(restored.inspectorWidth, 340)
        XCTAssertTrue(restored.inspectorCollapsed, "the right panel starts collapsed")
        XCTAssertEqual(restored.resolvedInspectorTab, .plan)
        XCTAssertFalse(restored.sidebarCollapsed, "the session sidebar starts open")
    }

    func testPanelStatesRoundTripThroughSettings() throws {
        var settings = AppSettings()
        XCTAssertFalse(settings.sidebarCollapsed, "left sidebar open by default")
        XCTAssertTrue(settings.inspectorCollapsed, "right inspector collapsed by default")

        settings.sidebarCollapsed = true
        settings.inspectorCollapsed = false
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(restored.sidebarCollapsed, "a collapsed sidebar stays collapsed across launches")
        XCTAssertFalse(restored.inspectorCollapsed, "an opened inspector stays open across launches")
    }

    func testGitChangeSummaryAndNaming() {
        let change = GitChange(
            path: "Locus/AppModel.swift", status: .modified, additions: 12, deletions: 3
        )
        XCTAssertEqual(change.name, "AppModel.swift")
        XCTAssertEqual(change.directory, "Locus")
        XCTAssertEqual(change.changeSummary, "+12 −3")

        let binary = GitChange(path: "icon.png", status: .added, binary: true)
        XCTAssertEqual(binary.changeSummary, "binary")
        XCTAssertEqual(binary.directory, "")
    }

    func testGitChangeDecodesAndToleratesAnUnknownStatus() throws {
        let json = """
        [{"path":"a.swift","status":"modified","staged":true,"unstaged":false,
          "binary":false,"additions":4,"deletions":1,"orig_path":null},
         {"path":"b.swift","status":"quantum"}]
        """
        let changes = try JSONDecoder().decode([GitChange].self, from: Data(json.utf8))
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].status, .modified)
        XCTAssertTrue(changes[0].staged)
        XCTAssertEqual(changes[1].status, .modified, "an unknown state must not drop the file")
    }

    // MARK: - Console

    @MainActor
    func testConsoleAssemblesStreamedChunksIntoLines() {
        let terminal = TerminalSession()
        terminal.handle(["type": "terminal_output", "text": "hel"])
        terminal.handle(["type": "terminal_output", "text": "lo\nwor"])
        terminal.handle(["type": "terminal_output", "text": "ld\n"])

        // A chunk boundary is not a line boundary; "hel" + "lo" is one line.
        XCTAssertEqual(terminal.lines.map(\.text), ["hello", "world"])
    }

    @MainActor
    func testConsoleTracksRunningStateAndExit() {
        let terminal = TerminalSession()
        terminal.handle(["type": "terminal_started", "run_id": "abc"])
        XCTAssertTrue(terminal.isRunning)

        terminal.handle(["type": "terminal_exit", "exit_code": 0, "reason": "exited"])
        XCTAssertFalse(terminal.isRunning)
        XCTAssertEqual(terminal.lastExitCode, 0)
        XCTAssertEqual(terminal.lines.last?.text, "Finished.")
    }

    @MainActor
    func testConsoleExitSummariesReadPlainly() {
        XCTAssertEqual(
            TerminalSession.exitSummary(["reason": "exited", "exit_code": 0]), "Finished."
        )
        XCTAssertEqual(
            TerminalSession.exitSummary(["reason": "exited", "exit_code": 2]),
            "Exited with code 2."
        )
        XCTAssertEqual(TerminalSession.exitSummary(["reason": "cancelled"]), "Cancelled.")
        XCTAssertEqual(
            TerminalSession.exitSummary(["reason": "timeout"]), "Timed out and was stopped."
        )
        XCTAssertEqual(
            TerminalSession.exitSummary(["reason": "cancelled", "signal": "SIGKILL"]),
            "Stopped by SIGKILL."
        )
    }

    @MainActor
    func testConsoleOutputIsBounded() {
        let terminal = TerminalSession()
        for index in 0..<(TerminalSession.maximumLines + 500) {
            terminal.handle(["type": "terminal_output", "text": "line \(index)\n"])
        }
        XCTAssertEqual(terminal.lines.count, TerminalSession.maximumLines)
        XCTAssertTrue(terminal.lines.last?.text.contains("5499") == true, "newest is kept")
    }

    @MainActor
    func testConsoleReportsABlockedCommand() {
        let terminal = TerminalSession()
        terminal.handle([
            "type": "terminal_error",
            "code": "blocked",
            "message": "blocked by the deny list: commands matching 'rm -rf /'",
        ])
        XCTAssertFalse(terminal.isRunning)
        XCTAssertTrue(terminal.lines.last?.text.contains("deny list") == true)
    }

    @MainActor
    func testConsoleWithoutATransportDoesNotClaimToBeRunning() {
        let terminal = TerminalSession()
        terminal.run("echo hi")
        XCTAssertFalse(terminal.isRunning, "a dropped send must not look like a live run")
        XCTAssertTrue(terminal.lines.last?.text.contains("Reconnect") == true)
    }

    // MARK: - Permission modes

    func testPermissionModesMatchTheAgentsWireValues() {
        XCTAssertEqual(PermissionMode.ask.rawValue, "ask")
        XCTAssertEqual(PermissionMode.acceptEdits.rawValue, "accept_edits")
        XCTAssertEqual(PermissionMode.bypass.rawValue, "bypass")
        XCTAssertTrue(PermissionMode.bypass.isRisky)
        XCTAssertFalse(PermissionMode.ask.isRisky)
        XCTAssertEqual(Set(PermissionMode.allCases.map(\.title)).count, 3)
    }

    func testPermissionsDecodeFromTheAgent() throws {
        let json = """
        {"skip_all": false, "mode": "accept_edits", "allowed": ["bash"]}
        """
        let permissions = try JSONDecoder().decode(
            SessionPermissions.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(permissions.effectiveMode, .acceptEdits)
        XCTAssertEqual(permissions.allowed, ["bash"])
    }

    func testPermissionsFallBackWhenTheAgentPredatesModes() throws {
        let legacy = try JSONDecoder().decode(
            SessionPermissions.self,
            from: Data(#"{"skip_all": true, "allowed": []}"#.utf8)
        )
        XCTAssertEqual(legacy.effectiveMode, .bypass, "skip_all means bypass")

        let asking = try JSONDecoder().decode(
            SessionPermissions.self,
            from: Data(#"{"skip_all": false, "allowed": []}"#.utf8)
        )
        XCTAssertEqual(asking.effectiveMode, .ask)

        let unknown = try JSONDecoder().decode(
            SessionPermissions.self,
            from: Data(#"{"skip_all": false, "allowed": [], "mode": "future"}"#.utf8)
        )
        XCTAssertEqual(unknown.effectiveMode, .ask, "an unknown mode must not crash")
    }

    func testPermissionSlashCommandsCoverEveryMode() {
        XCTAssertEqual(
            SlashCommand.command(invokedBy: "/permissions")?.action,
            .setPermissionMode(.ask)
        )
        XCTAssertEqual(
            SlashCommand.command(invokedBy: "/acceptedits")?.action,
            .setPermissionMode(.acceptEdits)
        )
        XCTAssertEqual(
            SlashCommand.command(invokedBy: "/bypass")?.action,
            .setPermissionMode(.bypass)
        )
        XCTAssertEqual(
            SlashCommand.command(invokedBy: "/yolo")?.action,
            .setPermissionMode(.bypass)
        )
    }

    // MARK: - Provider settings

    func testProviderSettingsSurviveEncodingAndNeverCarryTheKey() throws {
        var settings = AppSettings()
        settings.provider = .remote
        settings.remoteBaseURL = "https://abc.endpoints.huggingface.cloud"
        settings.remoteModel = "meta-llama/Llama-3.1-8B-Instruct"

        let data = try JSONEncoder().encode(settings)
        let encoded = String(decoding: data, as: UTF8.self)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(restored.provider, .remote)
        XCTAssertEqual(restored.remoteBaseURL, settings.remoteBaseURL)
        XCTAssertEqual(restored.remoteModel, settings.remoteModel)
        XCTAssertFalse(encoded.lowercased().contains("apikey"))
        XCTAssertFalse(encoded.lowercased().contains("api_key"))
    }

    func testSettingsFromAnOlderVersionDefaultToLocalOllama() throws {
        let legacy = """
        {"backendURL":"http://127.0.0.1:8791","previewURL":"http://localhost:3000"}
        """
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(restored.provider, .ollama)
        XCTAssertTrue(restored.remoteBaseURL.isEmpty)
        XCTAssertTrue(restored.notifyOnCompletion)
    }

    func testProviderTitlesAreDistinct() {
        let titles = ModelProvider.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertTrue(ModelProvider.remote.detail.contains("GPU"))
    }

    func testKeychainRoundTripsAndClearsTheAPIKey() {
        let account = "unit-test-\(UUID().uuidString)"
        defer { Keychain.remove(account: account) }

        XCTAssertNil(Keychain.get(account: account))
        XCTAssertTrue(Keychain.set("hf_secret_value", account: account))
        XCTAssertEqual(Keychain.get(account: account), "hf_secret_value")
        XCTAssertTrue(Keychain.has(account: account))

        XCTAssertTrue(Keychain.set("replacement", account: account))
        XCTAssertEqual(Keychain.get(account: account), "replacement")

        // Saving an empty value removes the item rather than storing a blank.
        XCTAssertTrue(Keychain.set("   ", account: account))
        XCTAssertNil(Keychain.get(account: account))
        XCTAssertFalse(Keychain.has(account: account))
    }

    func testRelativePathTrimsWorkspaceRoot() {
        XCTAssertEqual(
            WorkspaceIndex.relativePath(
                URL(fileURLWithPath: "/tmp/ws/a/b.swift"),
                root: "/tmp/ws"
            ),
            "a/b.swift"
        )
    }
}
