import AppKit
import XCTest
@testable import Locus

final class FeatureLogicTests: XCTestCase {
    // MARK: - Application lifecycle

    func testApplicationProhibitsMultipleProcesses() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool,
            true
        )
    }

    @MainActor
    func testApplicationDelegateTargetsOnlyTheMarkedMainWindow() {
        let settings = NSWindow()
        settings.identifier = NSUserInterfaceItemIdentifier("locus.settings")
        let main = NSWindow()
        main.identifier = LocusApplicationDelegate.mainWindowIdentifier

        XCTAssertTrue(
            LocusApplicationDelegate.mainWindow(in: [settings, main]) === main
        )
        XCTAssertTrue(
            LocusApplicationDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }

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
        XCTAssertEqual(InspectorTab.allCases.count, 8)
        let raws = InspectorTab.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        XCTAssertEqual(Set(InspectorTab.allCases.map(\.symbol)).count, raws.count)
        XCTAssertEqual(Set(InspectorTab.allCases.map(\.title)).count, raws.count)
        // rawValue is the accessibility-identifier and persistence contract.
        XCTAssertEqual(InspectorTab(rawValue: "plan"), .plan)
        XCTAssertEqual(InspectorTab(rawValue: "terminal"), .terminal)
        XCTAssertEqual(InspectorTab(rawValue: "checkpoints"), .checkpoints)
        XCTAssertEqual(InspectorTab(rawValue: "agents"), .agents)
        XCTAssertEqual(InspectorTab(rawValue: "workflows"), .workflows)
    }

    func testInspectorShortcutsAreOneThroughEight() {
        XCTAssertEqual(
            InspectorTab.allCases.map(\.shortcutKey),
            ["1", "2", "3", "4", "5", "6", "7", "8"]
        )
    }

    func testAgentInstructionsFileRoundTripsAndRejectsEscapingSymlinks() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let workspace = base.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(AgentInstructionsFile.load(from: workspace.path), .init(
            exists: false,
            content: "",
            error: nil
        ))

        try AgentInstructionsFile.save("# Rules\n\n- Run tests.\n", in: workspace.path)
        XCTAssertEqual(
            AgentInstructionsFile.load(from: workspace.path).content,
            "# Rules\n\n- Run tests.\n"
        )

        let outside = base.appending(path: "outside.md")
        try "do not overwrite".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: AgentInstructionsFile.url(for: workspace.path))
        try FileManager.default.createSymbolicLink(
            at: AgentInstructionsFile.url(for: workspace.path),
            withDestinationURL: outside
        )
        XCTAssertNotNil(AgentInstructionsFile.load(from: workspace.path).error)
        XCTAssertThrowsError(try AgentInstructionsFile.save("escaped", in: workspace.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "do not overwrite")
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

    // MARK: - Provider accounts

    func testProviderAccountEncodesWithoutTheKeyAndKeepsItsKind() throws {
        let account = ProviderAccount(
            kind: .claude,
            name: "Work",
            preferredModel: "claude-sonnet-4-5"
        )
        let data = try JSONEncoder().encode([account])
        let encoded = String(decoding: data, as: UTF8.self).lowercased()
        let restored = ProviderAccountStore.decode(data)

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].kind, .claude)
        XCTAssertEqual(restored[0].displayName, "Claude — Work")
        XCTAssertEqual(restored[0].resolvedBaseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(restored[0].keychainAccount, Keychain.providerAccountKey(account.id))
        XCTAssertFalse(encoded.contains("apikey"))
        XCTAssertFalse(encoded.contains("sk-"))
    }

    func testAccountWithoutANameFallsBackToTheProviderName() {
        let account = ProviderAccount(kind: .kimi)
        XCTAssertEqual(account.displayName, "Kimi")
        XCTAssertEqual(account.shortName, "Kimi")
    }

    func testUnknownAccountKindStaysUsableAsACustomEndpoint() {
        let json = """
        [{"id":"\(UUID().uuidString)","kindRaw":"gemini","name":"Future",
          "baseURLOverride":"https://api.example.com/v1","preferredModel":"x",
          "createdAt":0}]
        """
        let restored = ProviderAccountStore.decode(Data(json.utf8))

        XCTAssertEqual(restored.count, 1, "a newer provider must not drop the account")
        XCTAssertEqual(restored[0].kind, .custom)
        XCTAssertEqual(restored[0].resolvedBaseURL, "https://api.example.com/v1")
    }

    func testOneCorruptAccountDoesNotDiscardTheRest() {
        let good = UUID().uuidString
        let json = """
        [{"id":"not-a-uuid","kindRaw":"claude","name":"Broken","preferredModel":"",
          "createdAt":0},
         {"id":"\(good)","kindRaw":"codex","name":"Fine","preferredModel":"gpt-5",
          "createdAt":0}]
        """
        let restored = ProviderAccountStore.decode(Data(json.utf8))

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].name, "Fine")
        XCTAssertEqual(restored[0].kind, .codex)
    }

    func testLegacyRemoteEndpointMigratesIntoACustomAccount() {
        var settings = AppSettings()
        settings.provider = .remote
        settings.remoteBaseURL = "https://abc.endpoints.huggingface.cloud/v1"
        settings.remoteModel = "meta-llama/Llama-3.1-8B-Instruct"

        let migrated = ProviderAccountStore.migrateLegacyEndpoint(
            settings: settings,
            existing: []
        )

        let account = try? XCTUnwrap(migrated)
        XCTAssertEqual(account?.kind, .custom)
        XCTAssertEqual(account?.resolvedBaseURL, settings.remoteBaseURL)
        XCTAssertEqual(account?.preferredModel, settings.remoteModel)
        // The key is not copied: the account points at the entry that is
        // already there, so an interrupted migration cannot lose it.
        XCTAssertEqual(account?.keychainAccount, Keychain.remoteAPIKeyAccount)
    }

    func testMigrationSkipsWhenThereIsNothingToMoveOrAccountsExist() {
        // Nothing configured.
        XCTAssertNil(
            ProviderAccountStore.migrateLegacyEndpoint(settings: AppSettings(), existing: [])
        )
        // Already migrated once: it must not run again and duplicate.
        var settings = AppSettings()
        settings.remoteBaseURL = "https://abc.example.com/v1"
        XCTAssertNil(
            ProviderAccountStore.migrateLegacyEndpoint(
                settings: settings,
                existing: [ProviderAccount(kind: .custom)]
            )
        )
    }

    func testDuplicateAccountNamesAreSuffixedPerProvider() {
        let existing = [
            ProviderAccount(kind: .claude, name: "Work"),
            ProviderAccount(kind: .codex, name: "Work"),
        ]
        XCTAssertEqual(
            ProviderAccountStore.uniqueName("Work", kind: .claude, existing: existing),
            "Work 2"
        )
        // A different provider may reuse the name — "Claude — Work" and
        // "Codex — Work" are already distinct.
        XCTAssertEqual(
            ProviderAccountStore.uniqueName("Personal", kind: .claude, existing: existing),
            "Personal"
        )
        // Editing an account keeps its own name.
        XCTAssertEqual(
            ProviderAccountStore.uniqueName(
                "Work",
                kind: .claude,
                existing: existing,
                excluding: existing[0].id
            ),
            "Work"
        )
    }

    func testModelFilterKeepsChatModelsAndDropsTheRest() {
        let openAI = [
            "gpt-5", "o3", "text-embedding-3-large", "whisper-1", "dall-e-3",
            "gpt-4o-realtime-preview", "tts-1", "omni-moderation-latest",
        ]
        XCTAssertEqual(
            ProviderModelFilter.chatModels(kind: .codex, names: openAI),
            ["gpt-5", "o3"]
        )
        XCTAssertEqual(
            ProviderModelFilter.chatModels(
                kind: .claude,
                names: ["claude-opus-4-1", "claude-sonnet-4-5", "gpt-5"]
            ),
            ["claude-opus-4-1", "claude-sonnet-4-5"]
        )
        XCTAssertEqual(
            ProviderModelFilter.chatModels(
                kind: .kimi,
                names: ["kimi-k2-0905-preview", "moonshot-v1-128k"]
            ),
            ["kimi-k2-0905-preview", "moonshot-v1-128k"]
        )
    }

    func testModelFilterFallsBackRatherThanShowingAnEmptyPicker() {
        // A renamed line-up must not produce an empty menu.
        let renamed = ["anthropic.something-new", "another-one"]
        XCTAssertEqual(
            ProviderModelFilter.chatModels(kind: .claude, names: renamed),
            renamed
        )
        XCTAssertTrue(ProviderModelFilter.chatModels(kind: .codex, names: []).isEmpty)
    }

    func testModelListParsingHandlesEveryProviderShapeAndGarbage() {
        let payload = """
        {"data":[{"id":"claude-sonnet-4-5"},{"id":"claude-opus-4-1"},{"id":""}]}
        """
        XCTAssertEqual(
            ProviderModelFilter.parseModelList(Data(payload.utf8)),
            ["claude-sonnet-4-5", "claude-opus-4-1"]
        )
        XCTAssertTrue(ProviderModelFilter.parseModelList(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(ProviderModelFilter.parseModelList(Data("{}".utf8)).isEmpty)
    }

    func testCuratedModelsAreListedFirst() {
        let fetched = ["some-old-model", "claude-sonnet-5", "another", "claude-opus-5"]
        XCTAssertEqual(
            ProviderModelFilter.ordered(kind: .claude, fetched: fetched),
            ["claude-opus-5", "claude-sonnet-5", "some-old-model", "another"]
        )
    }

    func testPickerSectionsPutLocalFirstThenEachAccount() {
        let claude = ProviderAccount(kind: .claude, name: "Work")
        let kimi = ProviderAccount(kind: .kimi)
        let sections = ModelPickerSection.build(
            localModels: ["qwen3:8b"],
            accounts: [claude, kimi],
            accountModels: [claude.id: ["claude-sonnet-4-5"]],
            accountStatus: [kimi.id: .keyRejected]
        )

        XCTAssertEqual(sections.map(\.title), ["Local (Ollama)", "Claude — Work", "Kimi"])
        XCTAssertNil(sections[0].account)
        XCTAssertEqual(sections[1].models, ["claude-sonnet-4-5"])
        XCTAssertNil(sections[1].emptyMessage)
        // An account with no models says why rather than showing a blank group.
        XCTAssertEqual(sections[2].models, [])
        XCTAssertEqual(sections[2].emptyMessage, "Check the API key in Settings")
    }

    func testPickerSectionsExplainAnEmptyLocalRuntime() {
        let sections = ModelPickerSection.build(
            localModels: [],
            accounts: [],
            accountModels: [:],
            accountStatus: [:]
        )
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].emptyMessage, "No Ollama models found")
    }

    func testAnthropicAccountsSendTheNativeHeadersAsWell() {
        let anthropic = RemoteEndpointTester.authHeaders(apiKey: "sk-ant-x", kind: .claude)
        XCTAssertNil(anthropic["Authorization"])
        XCTAssertEqual(anthropic["x-api-key"], "sk-ant-x")
        XCTAssertEqual(anthropic["anthropic-version"], "2023-06-01")

        let bearer = RemoteEndpointTester.authHeaders(apiKey: "sk-x", kind: .codex)
        XCTAssertEqual(bearer["Authorization"], "Bearer sk-x")
        XCTAssertNil(bearer["x-api-key"])

        XCTAssertTrue(RemoteEndpointTester.authHeaders(apiKey: "", kind: .claude).isEmpty)
    }

    func testEveryProviderHasTheMetadataTheUIDependsOn() {
        for kind in ProviderKind.allCases where kind != .custom {
            XCTAssertFalse(kind.defaultBaseURL.isEmpty, "\(kind) needs an endpoint")
            XCTAssertFalse(kind.keyDocsURL.isEmpty, "\(kind) needs a docs link")
            XCTAssertFalse(kind.curatedModels.isEmpty, "\(kind) needs fallback models")
            XCTAssertFalse(kind.probeModel.isEmpty)
        }
        // Titles are what the Add Account menu shows; they must not collide.
        let titles = ProviderKind.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testKimiCodeIsASeparateProviderFromPayPerTokenKimi() {
        XCTAssertNotEqual(ProviderKind.kimiCode.defaultBaseURL, ProviderKind.kimi.defaultBaseURL)
        XCTAssertTrue(ProviderKind.kimiCode.defaultBaseURL.contains("api.kimi.com"))
        XCTAssertTrue(ProviderKind.kimi.defaultBaseURL.contains("api.moonshot.ai"))
        XCTAssertNotEqual(ProviderKind.kimiCode.keyDocsURL, ProviderKind.kimi.keyDocsURL)

        // The two are unrelated services, so their account names live in
        // separate namespaces — a subscription "Work" must not be renamed
        // because a pay-per-token "Work" already exists.
        let payPerToken = ProviderAccount(kind: .kimi, name: "Work")
        XCTAssertEqual(
            ProviderAccountStore.uniqueName("Work", kind: .kimiCode, existing: [payPerToken]),
            "Work"
        )
    }

    func testKimiCodeModelFilterKeepsTheCodingModelIDs() {
        let listed = ["kimi-for-coding", "kimi-for-coding-highspeed", "k3", "k3-256k"]
        XCTAssertEqual(
            ProviderModelFilter.chatModels(kind: .kimiCode, names: listed),
            listed
        )
        // The reason this is its own kind: `k3` starts with neither "kimi" nor
        // "moonshot", and the empty-filter fallback would not rescue it because
        // `kimi-for-coding` passes the pay-per-token rule.
        XCTAssertEqual(
            ProviderModelFilter.chatModels(kind: .kimi, names: ["k3", "kimi-for-coding"]),
            ["kimi-for-coding"]
        )
    }

    func testKimiCodeProbesWithTheModelEveryMembershipTierCanReach() {
        XCTAssertEqual(ProviderKind.kimiCode.probeModel, "kimi-for-coding")
    }

    func testProvidersThatDoNotDocumentAModelListingSaySo() {
        XCTAssertFalse(ProviderKind.kimiCode.listsModels)
        for kind in ProviderKind.allCases where kind != .kimiCode {
            XCTAssertTrue(kind.listsModels, "\(kind) serves /models")
        }
    }

    func testProviderNotesExplainWhyAKeyIsNeeded() {
        // Claude's note is the one that has to exist: without it, the absence
        // of subscription sign-in reads as an oversight rather than a rule.
        let claude = ProviderKind.claude.note
        XCTAssertNotNil(claude, "Claude must explain why a key is required")
        XCTAssertTrue(claude?.text.contains("console.anthropic.com") == true)
        XCTAssertTrue(claude?.hasLink == true)

        XCTAssertTrue(ProviderKind.kimiCode.note?.text.contains("Kimi Code Console") == true)
        XCTAssertTrue(ProviderKind.kimi.note?.text.contains("Kimi Code") == true)

        for kind in ProviderKind.allCases {
            guard let note = kind.note else { continue }
            XCTAssertFalse(note.text.isEmpty)
            if note.hasLink {
                XCTAssertEqual(URL(string: note.linkURL)?.scheme, "https")
            }
        }
    }

    func testProviderEndpointsSurviveNormalization() {
        let kimiCode = "https://api.kimi.com/coding/v1"
        for given in [
            kimiCode,
            "https://api.kimi.com/coding/v1/",
            "https://api.kimi.com/coding/",
            "https://api.kimi.com/coding",
            "https://api.kimi.com/coding/v1/chat/completions",
            "api.kimi.com/coding/v1",
        ] {
            XCTAssertEqual(
                RemoteEndpointTester.normalizeBaseURL(given), kimiCode,
                "\(given) must keep the /coding path"
            )
        }
        for fixed in [ProviderKind.claude, .codex, .kimi] {
            XCTAssertEqual(
                RemoteEndpointTester.normalizeBaseURL(fixed.defaultBaseURL),
                fixed.defaultBaseURL
            )
        }
    }

    func testStoredCountDistinguishesACompleteReadFromASalvagedOne() {
        // The sweep that deletes keys keys off this: a salvaged read must
        // never be mistaken for "these accounts no longer exist".
        let defaults = UserDefaults(suiteName: "locus.tests.storedCount")!
        defaults.removePersistentDomain(forName: "locus.tests.storedCount")
        defer { defaults.removePersistentDomain(forName: "locus.tests.storedCount") }

        XCTAssertNil(
            ProviderAccountStore.storedCount(in: defaults),
            "nothing stored is not the same as zero accounts"
        )

        let good = [ProviderAccount(kind: .claude, name: "Work")]
        ProviderAccountStore.save(good, to: defaults)
        XCTAssertEqual(ProviderAccountStore.storedCount(in: defaults), 1)
        XCTAssertEqual(ProviderAccountStore.load(from: defaults).count, 1)

        // One unreadable element: the list salvages, and the counts disagree,
        // which is exactly the signal that stops a destructive sweep.
        let mixed = """
        [{"id":"\(UUID().uuidString)","kindRaw":"claude","name":"Work",
          "preferredModel":"","createdAt":0},
         {"id":"not-a-uuid"}]
        """
        defaults.set(Data(mixed.utf8), forKey: ProviderAccountStore.defaultsKey)
        XCTAssertEqual(ProviderAccountStore.storedCount(in: defaults), 2)
        XCTAssertEqual(ProviderAccountStore.load(from: defaults).count, 1)
    }

    func testHostedProvidersCarryAPublishedContextWindow() {
        // Before this, a hosted account had no window at all: the meter was
        // dead and automatic compaction never engaged.
        XCTAssertEqual(ProviderKind.claude.publishedContextWindow(for: "claude-sonnet-4-5"), 200_000)
        XCTAssertEqual(ProviderKind.codex.publishedContextWindow(for: "gpt-5"), 400_000)
        XCTAssertEqual(ProviderKind.kimiCode.publishedContextWindow(for: "k3-256k"), 256_000)
        XCTAssertEqual(ProviderKind.claude.publishedContextWindow(for: "claude-sonnet-5"), 1_000_000)
        XCTAssertEqual(ProviderKind.codex.publishedContextWindow(for: "gpt-5.6"), 1_050_000)
        XCTAssertEqual(ProviderKind.kimiCode.publishedContextWindow(for: "k3"), 1_000_000)
        // Someone else's deployment; only they know how it was configured.
        XCTAssertNil(ProviderKind.custom.publishedContextWindow(for: "anything"))
        XCTAssertNil(ProviderKind.claude.publishedContextWindow(for: "some-future-model"))
    }

    func testAnAccountsOwnWindowWinsOverThePublishedOne() {
        var account = ProviderAccount(kind: .claude, name: "Work", preferredModel: "claude-sonnet-4-5")
        XCTAssertEqual(account.resolvedContextWindow, 200_000, "published figure by default")

        account.contextWindow = 64_000
        XCTAssertEqual(account.resolvedContextWindow, 64_000, "the user's value must win")

        account.contextWindow = nil
        XCTAssertEqual(account.resolvedContextWindow, 200_000)
    }

    func testAccountsStoredBeforeWindowsExistedStillDecode() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","kindRaw":"claude","name":"Work",
          "preferredModel":"claude-sonnet-4-5","createdAt":0}]
        """
        let restored = ProviderAccountStore.decode(Data(legacy.utf8))
        XCTAssertEqual(restored.count, 1)
        XCTAssertNil(restored[0].contextWindow)
        // It still resolves, from the published table.
        XCTAssertEqual(restored[0].resolvedContextWindow, 200_000)
    }

    func testSessionInfoFromAnOlderAgentHasNoUsableTokens() throws {
        let json = #"{"model":"m","host":"h","context_limit":8192,"approx_tokens":100}"#
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.contextLimit, 8192)
        XCTAssertNil(info.usableTokens, "an older agent does not send it")

        let current = #"{"model":"m","host":"h","context_limit":8192,"usable_tokens":5000}"#
        let newer = try JSONDecoder().decode(SessionInfo.self, from: Data(current.utf8))
        XCTAssertEqual(newer.usableTokens, 5000)
    }

    func testLocusIdentifiesItselfHonestlyToProviders() {
        XCTAssertEqual(
            LocusClientIdentity.userAgent(version: "1.7.0"),
            "Locus/1.7.0 (macOS; io.sparktales.locus)"
        )
        let live = LocusClientIdentity.value
        XCTAssertTrue(live.hasPrefix("Locus/"))
        XCTAssertTrue(live.contains(LocusClientIdentity.bundleID))
        // Moonshot's terms turn on the client identifier being real. Borrowing
        // another tool's name would be a violation, not a compatibility trick.
        for impostor in ["claude", "kimi", "cursor", "codex", "curl", "mozilla", "python-requests"] {
            XCTAssertFalse(
                live.lowercased().contains(impostor),
                "the user agent must not claim to be \(impostor)"
            )
        }
    }

    func testWorkspaceProfilesFromBeforeAccountsStillDecode() throws {
        let legacy = """
        [{"path":"/tmp/ws","lastOpened":0,"model":"qwen3:8b","mode":"build",
          "previewURL":"http://localhost:3000","contextFiles":[],"draft":""}]
        """
        let restored = try JSONDecoder().decode(
            [WorkspaceProfile].self,
            from: Data(legacy.utf8)
        )
        XCTAssertEqual(restored.count, 1)
        XCTAssertNil(restored[0].accountID, "an old profile means the local runtime")
        XCTAssertEqual(restored[0].model, "qwen3:8b")
        XCTAssertNil(restored[0].executionEngine, "Classic remains the legacy decode default")
        XCTAssertNil(restored[0].planWorkflowID)
        XCTAssertNil(restored[0].buildWorkflowID)
    }

    func testWorkspaceProfilePersistsLangGraphSelectionsWithoutCredentials() throws {
        let profile = WorkspaceProfile(
            path: "/tmp/ws",
            lastOpened: .now,
            model: "local-model",
            accountID: nil,
            mode: .build,
            previewURL: "http://localhost:3000",
            contextFiles: [],
            draft: "",
            executionEngine: .langgraph,
            planWorkflowID: "planner-team",
            buildWorkflowID: "builder-team"
        )
        let data = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(WorkspaceProfile.self, from: data)
        XCTAssertEqual(restored.executionEngine, .langgraph)
        XCTAssertEqual(restored.planWorkflowID, "planner-team")
        XCTAssertEqual(restored.buildWorkflowID, "builder-team")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("api_key"))
    }

    func testGraphWorkflowDecodesTypedPortsAndToleratesLegacyNodes() throws {
        let typed = #"""
        {
          "schema_version":1,"id":"typed","slug":"typed","name":"Typed","description":"",
          "supported_modes":["build"],"revision":1,
          "nodes":[{
            "id":"join","type":"join","label":"Join","position":{"x":1,"y":2},"config":{},
            "input_ports":[{"id":"branches","type":"text","multiple":true}],
            "output_ports":[{"id":"out","type":"context"}]
          }],
          "edges":[],"settings":{"max_steps":20,"failure_policy":"fail"},
          "capability_diff":{"first_trust":false,"prompts_changed":true,
            "tools_added":["mcp__linear__update_issue"],"tools_removed":[],
            "models_added":[],"models_removed":[],"provider_accounts_added":[],
            "provider_accounts_removed":[],"mutation_before":false,"mutation_after":true,
            "parallel_width_before":1,"parallel_width_after":2,"changed":true}
        }
        """#.data(using: .utf8)!
        let workflow = try JSONDecoder().decode(GraphWorkflow.self, from: typed)
        XCTAssertEqual(workflow.nodes[0].resolvedInputPorts[0].id, "branches")
        XCTAssertEqual(workflow.nodes[0].resolvedInputPorts[0].type, "text")
        XCTAssertEqual(workflow.nodes[0].resolvedInputPorts[0].multiple, true)
        XCTAssertEqual(workflow.capabilityDiff?.toolsAdded, ["mcp__linear__update_issue"])
        XCTAssertEqual(workflow.capabilityDiff?.mutationAfter, true)

        let legacy = #"""
        {
          "schema_version":1,"id":"legacy","slug":"legacy","name":"Legacy","description":"",
          "supported_modes":["plan"],"revision":1,
          "nodes":[{"id":"agent","type":"agent","label":"Agent","position":{"x":0,"y":0},"config":{}}],
          "edges":[],"settings":{"max_steps":20,"failure_policy":"fail"}
        }
        """#.data(using: .utf8)!
        let oldWorkflow = try JSONDecoder().decode(GraphWorkflow.self, from: legacy)
        XCTAssertEqual(oldWorkflow.nodes[0].resolvedOutputPorts.map(\.id), ["out", "tools", "final"])
    }

    func testGraphRouteRuleDecodesSafeLegacyScalarValues() throws {
        let numeric = Data(#"{"operation":"equals","value":42,"target":"answer"}"#.utf8)
        let rule = try JSONDecoder().decode(GraphRouteRule.self, from: numeric)
        XCTAssertEqual(rule.path, "outputs")
        XCTAssertEqual(rule.value, "42.0")
        XCTAssertEqual(rule.target, "answer")
    }

    func testSettingsCarryTheActiveAccountAndOldOnesDecodeWithout() throws {
        var settings = AppSettings()
        let id = UUID().uuidString
        settings.activeAccountID = id
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.activeAccountID, id)

        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"backendURL":"http://127.0.0.1:8791"}"#.utf8)
        )
        XCTAssertNil(legacy.activeAccountID)
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

    // MARK: - Plan prompt suggestions

    func testPlanPromptSuggestionsAreFiveDistinctReadyToSendPrompts() {
        let suggestions = PlanPromptSuggestion.curated
        XCTAssertEqual(suggestions.count, 5)
        XCTAssertEqual(Set(suggestions.map(\.title)).count, suggestions.count)
        XCTAssertEqual(Set(suggestions.map(\.prompt)).count, suggestions.count)
        for suggestion in suggestions {
            XCTAssertFalse(suggestion.title.isEmpty)
            XCTAssertFalse(
                suggestion.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "an empty prompt would send nothing"
            )
            XCTAssertFalse(
                suggestion.prompt.hasPrefix("/"),
                "a leading slash would be routed as a command, not a plan request"
            )
        }
    }
}
