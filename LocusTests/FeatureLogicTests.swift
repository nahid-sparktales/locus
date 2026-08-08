import AppKit
import Darwin
import XCTest
@testable import Locus

final class FeatureLogicTests: XCTestCase {
    // MARK: - Application lifecycle

    func testMainWindowUsesTheCompactDefaultSize() {
        XCTAssertEqual(LocusWindowSizing.defaultSize.width, 1_200)
        XCTAssertEqual(LocusWindowSizing.defaultSize.height, 760)

        let visibleFrame = NSRect(x: 20, y: 40, width: 1_600, height: 1_000)
        let frame = LocusWindowSizing.centeredFrame(in: visibleFrame)
        XCTAssertEqual(frame.size, LocusWindowSizing.defaultSize)
        XCTAssertEqual(frame.midX, visibleFrame.midX)
        XCTAssertEqual(frame.midY, visibleFrame.midY)
    }

    func testMainWindowFitsSmallerDisplays() {
        let visibleFrame = NSRect(x: 0, y: 24, width: 980, height: 650)
        XCTAssertEqual(
            LocusWindowSizing.centeredFrame(in: visibleFrame),
            visibleFrame
        )
    }

    func testRuntimePhasesDistinguishRecoveryFromFailure() {
        XCTAssertFalse(RuntimePhase.starting("starting").isOnline)
        XCTAssertTrue(RuntimePhase.online.isOnline)
        XCTAssertEqual(RuntimePhase.recovering("retrying").message, "retrying")
        XCTAssertEqual(RuntimePhase.unavailable("missing").message, "missing")
        XCTAssertNil(RuntimePhase.online.message)
    }

    func testOllamaAutomaticLaunchIsRestrictedToLoopback() {
        XCTAssertTrue(OllamaRuntime.isLoopback(URL(string: "http://127.0.0.1:11434")!))
        XCTAssertTrue(OllamaRuntime.isLoopback(URL(string: "http://localhost:11434")!))
        XCTAssertTrue(OllamaRuntime.isLoopback(URL(string: "http://[::1]:11434")!))
        XCTAssertFalse(OllamaRuntime.isLoopback(URL(string: "https://models.example.com")!))
    }

    func testOllamaExecutableSelectionUsesTheFirstInstalledCandidate() {
        XCTAssertEqual(
            OllamaRuntime.firstExecutable(in: ["/definitely/missing/ollama", "/bin/sh"]),
            URL(fileURLWithPath: "/bin/sh")
        )
    }

    func testAgentLaunchFallsBackWhenThePreferredPortIsOccupied() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(descriptor, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        XCTAssertEqual(read, 0)
        let occupiedPort = Int(UInt16(bigEndian: address.sin_port))

        XCTAssertFalse(BackendProcess.portIsAvailable(occupiedPort))
        let fallback = try XCTUnwrap(BackendProcess.resolvedLaunchPort(preferred: occupiedPort))
        XCTAssertNotEqual(fallback, occupiedPort)
        XCTAssertTrue(BackendProcess.portIsAvailable(fallback))
    }

    func testLegacyAutomaticLaunchSettingIsIgnoredAndNotReencoded() throws {
        let legacy = #"{"backendURL":"http://127.0.0.1:8791","launchBackendAutomatically":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.backendURL, "http://127.0.0.1:8791")
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains("launchBackendAutomatically"))
    }

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
        XCTAssertEqual(InspectorTab.allCases.count, 7)
        let raws = InspectorTab.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        XCTAssertEqual(Set(InspectorTab.allCases.map(\.symbol)).count, raws.count)
        XCTAssertEqual(Set(InspectorTab.allCases.map(\.title)).count, raws.count)
        // rawValue is the accessibility-identifier and persistence contract.
        XCTAssertEqual(InspectorTab(rawValue: "plan"), .plan)
        XCTAssertEqual(InspectorTab(rawValue: "terminal"), .terminal)
        XCTAssertEqual(InspectorTab(rawValue: "checkpoints"), .checkpoints)
        XCTAssertEqual(InspectorTab(rawValue: "agents"), .agents)
    }

    func testInspectorShortcutsAreOneThroughSeven() {
        XCTAssertEqual(
            InspectorTab.allCases.map(\.shortcutKey),
            ["1", "2", "3", "4", "5", "6", "7"]
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

    // MARK: - Proxy

    func testProxySettingsSurviveARoundTrip() throws {
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyTypeRaw = ProxyType.socks5.rawValue
        settings.proxyHost = "proxy.corp.example.com"
        settings.proxyPort = 1080
        settings.proxyBypass = "*.internal.example.com, 10.0.0.5"
        settings.proxyUsername = "nahid"

        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.resolvedProxyMode, .manual)
        XCTAssertEqual(restored.resolvedProxyType, .socks5)
        XCTAssertEqual(restored.proxyHost, "proxy.corp.example.com")
        XCTAssertEqual(restored.proxyPort, 1080)
        XCTAssertEqual(restored.proxyBypass, "*.internal.example.com, 10.0.0.5")
        XCTAssertEqual(restored.proxyUsername, "nahid")
    }

    func testUnknownProxyModeAndTypeFallBackWithoutTakingTheRest() throws {
        let future = #"{"proxyModeRaw":"quantum","proxyTypeRaw":"socks9","proxyHost":"p.example"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(future.utf8))
        XCTAssertEqual(restored.resolvedProxyMode, .off, "an unknown mode must fail safe, to direct")
        XCTAssertEqual(restored.resolvedProxyType, .http)
        // The unknown enum must not take the rest of the settings down with it.
        XCTAssertEqual(restored.proxyHost, "p.example")
    }

    func testSettingsFromBeforeProxySupportGetDefaults() throws {
        let legacy = #"{"backendURL":"http://127.0.0.1:8791"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(restored.resolvedProxyMode, .off)
        XCTAssertEqual(restored.proxyHost, "")
        XCTAssertNil(restored.proxyPort)
        XCTAssertEqual(restored.proxyUsername, "")
    }

    func testProxyPortIsClampedOnDecodeAndInTheHelper() throws {
        for hostile in ["0", "-1", "70000"] {
            let json = "{\"proxyPort\": \(hostile)}"
            let restored = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertNil(restored.proxyPort, "\(hostile) is not a port")
        }
        XCTAssertEqual(AppSettings.clampProxyPort(8080), 8080)
        XCTAssertEqual(AppSettings.clampProxyPort(1), 1)
        XCTAssertEqual(AppSettings.clampProxyPort(65535), 65535)
        XCTAssertNil(AppSettings.clampProxyPort(nil))
    }

    func testProxyHostNormalizationStripsWhatOtherFieldsOwn() {
        XCTAssertEqual(ProxyConfigurator.normalizedHost("  Proxy.Corp  "), "proxy.corp")
        XCTAssertEqual(ProxyConfigurator.normalizedHost("http://proxy.corp:3128/"), "proxy.corp")
        XCTAssertEqual(ProxyConfigurator.normalizedHost("socks5://user:pass@proxy.corp:1080"), "proxy.corp")
        XCTAssertEqual(ProxyConfigurator.normalizedHost("proxy.corp:8080"), "proxy.corp")
        XCTAssertEqual(ProxyConfigurator.normalizedHost("10.1.2.3"), "10.1.2.3")
        XCTAssertEqual(ProxyConfigurator.normalizedHost("[::1]:8080"), "::1", "brackets belong to URLs")
        XCTAssertEqual(ProxyConfigurator.normalizedHost("::1"), "::1", "an IPv6 literal keeps its colons")
        XCTAssertEqual(ProxyConfigurator.normalizedHost(""), "")
    }

    func testProxyBypassParsingNormalizesSuffixes() {
        XCTAssertEqual(
            ProxyConfigurator.parseBypassList("*.corp.example.com, 10.0.0.5\u{20}\u{20}HostA.example ,,"),
            [".corp.example.com", "10.0.0.5", "hosta.example"]
        )
        XCTAssertEqual(ProxyConfigurator.parseBypassList(""), [])
    }

    func testProxyBypassHostsAlwaysKeepTheAppsOwnPlumbingDirect() {
        var settings = AppSettings()
        settings.proxyBypass = "*.corp.example.com, 127.0.0.1"
        let hosts = ProxyConfigurator.bypassHosts(
            settings: settings,
            ollamaHost: "http://192.168.1.20:11434"
        )
        XCTAssertEqual(
            hosts,
            ["localhost", "127.0.0.1", "::1", "192.168.1.20", ".corp.example.com"],
            "loopback, the agent, and Ollama lead; user entries follow; duplicates collapse"
        )
    }

    func testManualHTTPProxyChildEnvironment() {
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "proxy.corp"
        settings.proxyPort = 3128
        let environment = ProxyConfigurator.childEnvironment(
            settings: settings,
            password: nil,
            ollamaHost: nil
        )
        for name in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            XCTAssertEqual(environment[name], "http://proxy.corp:3128")
        }
        XCTAssertEqual(environment["ALL_PROXY"], "",
                       "tombstoned, so an inherited ALL_PROXY is removed rather than left to apply")
        XCTAssertEqual(environment["all_proxy"], "")
        XCTAssertEqual(environment["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(environment["no_proxy"], environment["NO_PROXY"])
        XCTAssertNil(environment["LOCUS_PROXY_CREDENTIAL"],
                     "the credential never travels in the environment")
    }

    func testTheOverlayTombstonesEveryProxyVariableItDoesNotSet() {
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyTypeRaw = ProxyType.socks5.rawValue
        settings.proxyHost = "socks.corp"
        settings.proxyPort = 1080
        let environment = ProxyConfigurator.childEnvironment(
            settings: settings, password: nil, ollamaHost: nil
        )
        // Every name is present: the ones this proxy uses carry a URL, the
        // rest carry the empty tombstone. A variable left absent would be
        // inherited from the shell, and a scheme-specific HTTPS_PROXY
        // outranks ALL_PROXY in requests, httpx and curl alike.
        for name in ProxyConfigurator.proxyURLVariables {
            XCTAssertNotNil(environment[name], "\(name) must be set or tombstoned")
        }
        XCTAssertEqual(environment["HTTPS_PROXY"], "")
        XCTAssertEqual(environment["ALL_PROXY"], "socks5h://socks.corp:1080")
    }

    func testTheCredentialIsHandedOverSeparatelyFromTheEnvironment() {
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "proxy.corp"
        settings.proxyPort = 3128
        XCTAssertNil(ProxyConfigurator.childCredential(settings: settings, password: "secret"),
                     "no username means no sign-in, whatever password is stored")

        settings.proxyUsername = "user@corp"
        XCTAssertEqual(
            ProxyConfigurator.childCredential(settings: settings, password: "p:s@w/d"),
            "user%40corp:p%3As%40w%2Fd",
            "both halves encoded, so the first colon is unambiguously the separator"
        )

        settings.proxyModeRaw = ProxyMode.off.rawValue
        XCTAssertNil(ProxyConfigurator.childCredential(settings: settings, password: "secret"))
    }

    func testManualSOCKSProxyChildEnvironmentUsesRemoteResolution() {
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyTypeRaw = ProxyType.socks5.rawValue
        settings.proxyHost = "socks.corp"
        settings.proxyPort = 1080
        let environment = ProxyConfigurator.childEnvironment(
            settings: settings,
            password: nil,
            ollamaHost: nil
        )
        XCTAssertEqual(environment["ALL_PROXY"], "socks5h://socks.corp:1080",
                       "socks5h so DNS resolves at the proxy, not locally")
        XCTAssertEqual(environment["all_proxy"], environment["ALL_PROXY"])
        XCTAssertEqual(environment["HTTP_PROXY"], "", "tombstoned, not left inherited")
    }

    func testProxyCredentialNeverRidesTheProxyURLOrTheEnvironment() {
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "proxy.corp"
        settings.proxyPort = 3128
        settings.proxyUsername = "user@corp"
        let environment = ProxyConfigurator.childEnvironment(
            settings: settings,
            password: "p:s@w/d",
            ollamaHost: nil
        )
        XCTAssertEqual(environment["HTTP_PROXY"], "http://proxy.corp:3128",
                       "children inherit the route, never the secret")
        for (name, value) in environment {
            XCTAssertFalse(value.contains("s%40w"), "\(name) must not carry the password")
            XCTAssertFalse(value.contains("user%40corp"), "\(name) must not carry the username")
        }
    }

    func testIncompleteOrInactiveProxyProducesNoEnvironment() {
        var incomplete = AppSettings()
        incomplete.proxyModeRaw = ProxyMode.manual.rawValue
        incomplete.proxyHost = "proxy.corp"  // no port
        XCTAssertTrue(ProxyConfigurator.childEnvironment(
            settings: incomplete, password: nil, ollamaHost: nil
        ).isEmpty)

        var off = AppSettings()
        off.proxyHost = "proxy.corp"
        off.proxyPort = 3128
        XCTAssertTrue(ProxyConfigurator.childEnvironment(
            settings: off, password: nil, ollamaHost: nil
        ).isEmpty, "off means off, whatever else is filled in")
        XCTAssertTrue(ProxyConfigurator.agentEnvironmentOverlay(
            settings: off, ollamaHost: nil
        ).isEmpty, "off manages nothing, so the shell's own proxy passes through untouched")
    }

    func testProxyRuntimeRebuildsSessionsOnlyWhenTheProxyActuallyChanges() {
        let runtime = ProxyRuntime()
        var settings = AppSettings()
        runtime.update(settings: settings, password: nil)
        let atRest = runtime.generation
        XCTAssertNil(runtime.current)

        runtime.update(settings: settings, password: nil)
        XCTAssertEqual(runtime.generation, atRest, "an identical update must not churn sessions")

        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "proxy.corp"
        settings.proxyPort = 3128
        runtime.update(settings: settings, password: nil)
        XCTAssertEqual(runtime.current?.host, "proxy.corp")
        let configured = runtime.generation
        XCTAssertGreaterThan(configured, atRest)

        // The Ollama host arrives later, from the agent — it belongs to the
        // bypass list, so it has to move the generation too.
        runtime.noteOllamaHost("http://192.168.1.20:11434")
        XCTAssertGreaterThan(runtime.generation, configured)
        XCTAssertEqual(runtime.current?.bypass.contains("192.168.1.20"), true)
    }

    func testSystemProxyDictionaryTranslation() {
        let settings = AppSettings()
        let proxies: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "sys.proxy", "HTTPPort": 8080,
            "HTTPSEnable": 1, "HTTPSProxy": "sys.proxy", "HTTPSPort": 8443,
            "ExceptionsList": ["*.local", "169.254/16"],
        ]
        let environment = ProxyConfigurator.environmentFromSystemProxies(
            proxies, settings: settings, ollamaHost: nil
        )
        XCTAssertEqual(environment["HTTP_PROXY"], "http://sys.proxy:8080")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://sys.proxy:8443",
                       "an HTTPS proxy is reached over http; the scheme names the hop, not the cargo")
        XCTAssertEqual(environment["NO_PROXY"], "localhost,127.0.0.1,::1,.local,169.254/16")
    }

    func testPACAndDisabledSystemProxiesLeaveNoProxyButStillTombstone() {
        let settings = AppSettings()
        let cases: [[String: Any]] = [
            // A PAC file cannot be expressed as env vars at all.
            ["ProxyAutoConfigEnable": 1, "HTTPEnable": 1, "HTTPProxy": "p", "HTTPPort": 1],
            ["HTTPEnable": 0, "HTTPProxy": "p", "HTTPPort": 1],
            [:],
        ]
        for proxies in cases {
            let environment = ProxyConfigurator.environmentFromSystemProxies(
                proxies, settings: settings, ollamaHost: nil
            )
            // "Follow the system" has to be deterministic: with nothing to
            // follow the agent connects directly, rather than inheriting
            // whatever proxy the launching shell happened to carry.
            for name in ProxyConfigurator.proxyURLVariables {
                XCTAssertEqual(environment[name], "", "\(name) must be tombstoned, not absent")
            }
        }
    }

    func testSystemSOCKSProxyTranslatesToAllProxy() {
        let environment = ProxyConfigurator.environmentFromSystemProxies(
            ["SOCKSEnable": 1, "SOCKSProxy": "socks.sys", "SOCKSPort": 1080],
            settings: AppSettings(),
            ollamaHost: nil
        )
        XCTAssertEqual(environment["ALL_PROXY"], "socks5h://socks.sys:1080")
    }

    func testTheSystemOverlayIsEmptyOnlyWhenTheProxyIsOff() {
        var settings = AppSettings()
        XCTAssertTrue(ProxyConfigurator.agentEnvironmentOverlay(
            settings: settings, ollamaHost: nil
        ).isEmpty, "off manages nothing")

        settings.proxyModeRaw = ProxyMode.system.rawValue
        let overlay = ProxyConfigurator.agentEnvironmentOverlay(
            settings: settings, ollamaHost: nil
        )
        XCTAssertFalse(
            overlay.isEmpty,
            "system mode always states the routing, even when the system has no proxy to state"
        )
    }

    func testProxyFailuresAreDescribedInTermsOfTheProxy() {
        let authenticated = ResolvedProxy(
            type: .http, host: "proxy.corp", port: 3128,
            username: "nahid", password: "secret", bypass: []
        )
        let anonymous = ResolvedProxy(
            type: .http, host: "proxy.corp", port: 3128,
            username: nil, password: nil, bypass: []
        )
        func describe(_ domain: String, _ code: Int, _ proxy: ResolvedProxy) -> String {
            ProxyProbe.describe(NSError(domain: domain, code: code), proxy: proxy)
        }

        // A real proxy reports a rejected sign-in as POSIX EAUTH through the
        // Network framework, not as NSURLErrorUserAuthenticationRequired —
        // matching only the URL-loading constant left the one genuinely
        // actionable failure showing "The operation couldn't be completed."
        XCTAssertTrue(
            describe(NSPOSIXErrorDomain, Int(EAUTH), authenticated).contains("rejected the sign-in")
        )
        XCTAssertTrue(
            describe(NSURLErrorDomain, NSURLErrorUserAuthenticationRequired, authenticated)
                .contains("rejected the sign-in")
        )
        // With no sign-in configured at all, the same refusal means something
        // different to the user.
        XCTAssertTrue(
            describe(NSPOSIXErrorDomain, Int(EAUTH), anonymous).contains("requires a sign-in")
        )
        // A proxy awaiting credentials it never got often just stops answering,
        // which is indistinguishable from a dead one — so say so.
        XCTAssertTrue(
            describe(NSURLErrorDomain, NSURLErrorTimedOut, anonymous).contains("requires a sign-in")
        )
        XCTAssertTrue(
            describe(NSURLErrorDomain, NSURLErrorTimedOut, authenticated).contains("did not answer")
        )
        XCTAssertTrue(
            describe(NSURLErrorDomain, NSURLErrorCannotFindHost, authenticated)
                .contains("No host named proxy.corp")
        )
        XCTAssertEqual(
            describe(NSURLErrorDomain, NSURLErrorBadURL, authenticated),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL).localizedDescription,
            "anything unrecognised falls back to the system's own wording"
        )
    }

    func testProxyResolutionCarriesTheCredentialOnlyWithAUsername() {
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "HTTP://Proxy.Corp:9/"
        settings.proxyPort = 3128
        settings.proxyUsername = "  "
        let anonymous = ProxyConfigurator.resolved(
            settings: settings, password: "secret", ollamaHost: nil
        )
        XCTAssertEqual(anonymous?.host, "proxy.corp", "resolution normalizes a pasted URL")
        XCTAssertNil(anonymous?.username)
        XCTAssertNil(anonymous?.password, "a password without a username is inert")

        settings.proxyUsername = "nahid"
        let authenticated = ProxyConfigurator.resolved(
            settings: settings, password: "secret", ollamaHost: nil
        )
        XCTAssertEqual(authenticated?.username, "nahid")
        XCTAssertEqual(authenticated?.password, "secret")

        settings.proxyModeRaw = ProxyMode.off.rawValue
        XCTAssertNil(ProxyConfigurator.resolved(
            settings: settings, password: "secret", ollamaHost: nil
        ))
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

    func testCredentialStoreRoundTripsAndClearsTheAPIKey() {
        let account = "unit-test-\(UUID().uuidString)"
        defer { CredentialStore.remove(account: account) }

        XCTAssertNil(CredentialStore.get(account: account))
        XCTAssertTrue(CredentialStore.set("hf_secret_value", account: account))
        XCTAssertEqual(CredentialStore.get(account: account), "hf_secret_value")
        XCTAssertTrue(CredentialStore.has(account: account))

        XCTAssertTrue(CredentialStore.set("replacement", account: account))
        XCTAssertEqual(CredentialStore.get(account: account), "replacement")

        // Saving an empty value removes the item rather than storing a blank.
        XCTAssertTrue(CredentialStore.set("   ", account: account))
        XCTAssertNil(CredentialStore.get(account: account))
        XCTAssertFalse(CredentialStore.has(account: account))
    }

    /// File permissions are the only thing protecting these secrets now, so
    /// they are the app's responsibility rather than the keychain's.
    func testCredentialFileIsNotReadableByOtherUsers() throws {
        let account = "unit-test-\(UUID().uuidString)"
        defer { CredentialStore.remove(account: account) }
        XCTAssertTrue(CredentialStore.set("sk-permission-check", account: account))

        let file = CredentialStore.fileURL
        let directory = file.deletingLastPathComponent()
        let fileMode = try FileManager.default
            .attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber

        XCTAssertEqual(fileMode?.int16Value, 0o600, "the credential file must be owner-only")
        XCTAssertEqual(directoryMode?.int16Value, 0o700, "its directory must be owner-only")
    }

    /// The secret is the point: it must never be legible in the surrounding
    /// structure, and a second account must not disturb the first.
    func testCredentialsPersistIndependentlyAcrossAReload() throws {
        let first = "unit-test-\(UUID().uuidString)"
        let second = "unit-test-\(UUID().uuidString)"
        defer {
            CredentialStore.remove(account: first)
            CredentialStore.remove(account: second)
        }
        XCTAssertTrue(CredentialStore.set("sk-first", account: first))
        XCTAssertTrue(CredentialStore.set("sk-second", account: second))

        // Drop the in-memory copy so this reads what actually reached disk.
        CredentialStore.resetCacheForTesting()
        XCTAssertEqual(CredentialStore.get(account: first), "sk-first")
        XCTAssertEqual(CredentialStore.get(account: second), "sk-second")

        XCTAssertTrue(CredentialStore.remove(account: first))
        CredentialStore.resetCacheForTesting()
        XCTAssertNil(CredentialStore.get(account: first))
        XCTAssertEqual(CredentialStore.get(account: second), "sk-second", "removal is surgical")
    }

    /// A truncated or hand-edited file must not read as "every account was
    /// deleted" — that is exactly the state in which a sweep would destroy
    /// live credentials.
    func testUnreadableCredentialFileSuppressesOrphanSweeps() throws {
        let survivor = "\(CredentialStore.mcpCredentialPrefix)unit-test-\(UUID().uuidString)"
        let file = CredentialStore.fileURL
        let backup = file.appendingPathExtension("testbackup")
        let hadFile = FileManager.default.fileExists(atPath: file.path)
        if hadFile { try? FileManager.default.moveItem(at: file, to: backup) }
        defer {
            try? FileManager.default.removeItem(at: file)
            if hadFile { try? FileManager.default.moveItem(at: backup, to: file) }
            CredentialStore.resetCacheForTesting()
        }

        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        CredentialStore.resetCacheForTesting()
        XCTAssertTrue(CredentialStore.isDegraded, "an unparseable file must report itself")

        // Sweeping against a list we could not read would delete live tokens.
        CredentialStore.removeOrphanedMCPCredentials(keeping: [])
        CredentialStore.removeOrphanedProviderKeys(keeping: [])

        // The unreadable file is preserved rather than overwritten in place.
        XCTAssertTrue(CredentialStore.set("sk-after-corruption", account: survivor))
        let salvage = file.deletingLastPathComponent().appendingPathComponent("auth.json.corrupt")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: salvage.path),
            "the file we could not parse must be kept, not silently destroyed"
        )
        try? FileManager.default.removeItem(at: salvage)
        CredentialStore.remove(account: survivor)
    }

    /// A file that parses as JSON but holds one unreadable value is the more
    /// likely corruption — a hand-edit, or a future format. Reading the section
    /// as a whole made a single bad value drop every sibling key silently, and
    /// the next write then overwrote them for good.
    func testOneBadValueDoesNotDiscardTheRestOfTheFile() throws {
        let file = CredentialStore.fileURL
        let backup = file.appendingPathExtension("testbackup")
        let hadFile = FileManager.default.fileExists(atPath: file.path)
        if hadFile { try? FileManager.default.moveItem(at: file, to: backup) }
        defer {
            try? FileManager.default.removeItem(at: file)
            if hadFile { try? FileManager.default.moveItem(at: backup, to: file) }
            CredentialStore.resetCacheForTesting()
        }

        // Valid JSON; one value is null rather than a string.
        try """
        {
          "version": 1,
          "provider_accounts": {
            "provider-account-LIVE": "sk-must-not-vanish",
            "provider-account-BROKEN": null
          },
          "mcp_servers": {}
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        CredentialStore.resetCacheForTesting()

        XCTAssertTrue(
            CredentialStore.isDegraded,
            "a value we cannot read must degrade the whole file, not vanish quietly"
        )
        // And because it degraded, the sweeps must not run against it.
        CredentialStore.removeOrphanedProviderKeys(keeping: [])
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(
            onDisk.contains("sk-must-not-vanish"),
            "a sweep must never act on a file it could not fully read"
        )

        // The first write salvages the original rather than overwriting it.
        XCTAssertTrue(CredentialStore.set("sk-new", account: "provider-account-NEW"))
        let salvage = file.deletingLastPathComponent().appendingPathComponent("auth.json.corrupt")
        let salvaged = try String(contentsOf: salvage, encoding: .utf8)
        XCTAssertTrue(salvaged.contains("sk-must-not-vanish"), "the original must be recoverable")
        try? FileManager.default.removeItem(at: salvage)
        CredentialStore.remove(account: "provider-account-NEW")
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
        XCTAssertEqual(restored[0].keychainAccount, CredentialStore.providerAccountKey(account.id))
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
        XCTAssertEqual(account?.keychainAccount, CredentialStore.remoteAPIKeyAccount)
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

    func testSessionInfoWithoutAProvenanceFieldDecodes() throws {
        let older = #"{"model":"m","host":"h","context_limit":8192}"#
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(older.utf8))
        XCTAssertNil(info.contextSource)

        let current = #"{"model":"m","host":"h","context_limit":8192,"context_source":"reported"}"#
        let newer = try JSONDecoder().decode(SessionInfo.self, from: Data(current.utf8))
        XCTAssertEqual(newer.contextSource, "reported")
    }

    func testAPublishedWindowIsTheOnlyOneMarkedAssumed() {
        typealias Provenance = AppModel.ContextWindowProvenance
        for measured in [Provenance.configured, .pinned, .measured, .reported, .remembered] {
            XCTAssertTrue(measured.isMeasured, "\(measured.rawValue) came from something real")
        }
        XCTAssertFalse(Provenance.published.isMeasured, "a vendor's documentation is not a measurement")
        XCTAssertFalse(Provenance.unknown.isMeasured)
    }

    @MainActor
    func testAnOlderAgentsWindowIsNotMarkedAssumed() {
        // No provenance field at all: the window it reports is still real, and
        // marking every such session "assumed" would cry wolf.
        let model = AppModel(startImmediately: false)
        model.sessionInfo = SessionInfo(
            model: "m", host: "h", cwd: "/tmp", session: "s", sessionID: "s",
            messages: 1, approxTokens: 10, promptTokens: 5, completionTokens: 5,
            contextLimit: 8_192, maxIterations: 40, hasProjectContext: false,
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )
        XCTAssertEqual(model.contextWindowProvenance, AppModel.ContextWindowProvenance.measured)
        XCTAssertTrue(model.contextWindowProvenance.isMeasured)
    }

    func testReplacingPermissionsKeepsTheWindowFields() {
        // Every field has to be carried by hand here, and two were not — which
        // blanked the context meter for a moment on every permission decision.
        let info = SessionInfo(
            model: "m", host: "h", cwd: "/tmp", session: "s", sessionID: "s",
            messages: 3, approxTokens: 100, promptTokens: 60, completionTokens: 40,
            contextLimit: 32_768, usableTokens: 18_400, contextSource: "pinned",
            maxIterations: 40, hasProjectContext: false,
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )

        let updated = info.replacingPermissions(SessionPermissions(skipAll: true, allowed: ["bash"]))

        XCTAssertEqual(updated.usableTokens, 18_400)
        XCTAssertEqual(updated.contextSource, "pinned")
        XCTAssertEqual(updated.contextLimit, 32_768)
        XCTAssertTrue(updated.permissions.skipAll)
    }

    func testTheIterationLimitIsNamedWhenItStopsATurn() {
        // "Iteration limit reached" alone reads as the model giving up. Naming
        // the number is what points at a setting instead — a config carrying
        // max_iterations: 5 stopped turns early for a week without saying so.
        let named = TurnCompletion(
            outcome: .maxIterations, mode: .build, durationMilliseconds: 1_000,
            iterationLimit: 5
        )
        XCTAssertEqual(named.title, "Iteration limit reached (5 steps)")

        let unknown = TurnCompletion(
            outcome: .maxIterations, mode: .build, durationMilliseconds: 1_000
        )
        XCTAssertEqual(unknown.title, "Iteration limit reached", "no number, no parenthetical")

        let finished = TurnCompletion(
            outcome: .complete, mode: .build, durationMilliseconds: 1_000
        )
        XCTAssertEqual(finished.title, "Task finished")
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

    // MARK: - Agent teams

    func testAgentTeamRequiresAReadOnlyDispatcherAndExactlyOneWriter() {
        let dispatcher = AgentProfile(
            name: "Dispatch",
            model: "qwen",
            role: .dispatcher
        )
        let writer = AgentProfile(
            name: "Writer",
            model: "kimi",
            role: .implementer,
            accessCeiling: .workspaceWrite
        )
        let valid = AgentTeam(
            name: "Builders",
            dispatcherID: dispatcher.id,
            fallbackDispatcherID: nil,
            memberIDs: [dispatcher.id, writer.id],
            defaultWriterID: writer.id
        )
        XCTAssertTrue(AgentTeamValidation.errors(team: valid, profiles: [dispatcher, writer]).isEmpty)

        var extraWriter = AgentProfile(
            name: "Second Writer",
            model: "claude",
            role: .implementer,
            accessCeiling: .computerControl
        )
        extraWriter.clamp()
        var invalid = valid
        invalid.memberIDs.append(extraWriter.id)
        XCTAssertTrue(
            AgentTeamValidation.errors(team: invalid, profiles: [dispatcher, writer, extraWriter])
                .contains(where: { $0.contains("exactly one") })
        )
    }

    func testTeamMentionsResolveAgentsAndTeamsWithoutMatchingOrdinaryText() {
        let agent = AgentProfile(name: "CodeReviewer", model: "local", role: .reviewer)
        let team = AgentTeam(
            name: "CoreTeam",
            dispatcherID: agent.id,
            fallbackDispatcherID: nil,
            memberIDs: [agent.id],
            defaultWriterID: agent.id
        )
        XCTAssertEqual(
            TeamMentionResolver.selection(
                in: "Please use @CodeReviewer",
                profiles: [agent],
                teams: [team]
            ).agent?.id,
            agent.id
        )
        XCTAssertEqual(
            TeamMentionResolver.selection(
                in: "@CoreTeam handle this",
                profiles: [agent],
                teams: [team]
            ).team?.id,
            team.id
        )
        XCTAssertNil(
            TeamMentionResolver.selection(
                in: "CodeReviewer is a noun here",
                profiles: [agent],
                teams: [team]
            ).agent
        )
    }

    func testAgentProfileStoreSalvagesValidElements() throws {
        let suite = "LocusTests.AgentTeams.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AgentProfile(name: "Planner", model: "qwen", role: .planner)
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        defaults.set(
            try JSONSerialization.data(withJSONObject: [valid, ["id": 4, "broken": true]]),
            forKey: AgentTeamStore.profilesKey
        )
        XCTAssertEqual(AgentTeamStore.loadProfiles(from: defaults), [profile])
    }

    func testSessionInfoDecodesManagedTaskMetadataTolerantly() throws {
        let data = Data(#"""
        {
          "session_id":"s1","cwd":"/source","permissions":{},
          "task":{"id":"t1","workspace_root":"/source","execution_path":"/private/checkout","baseline_tree":"abc"},
          "workspace_root":"/source","execution_path":"/private/checkout"
        }
        """#.utf8)
        let info = try JSONDecoder().decode(SessionInfo.self, from: data)
        XCTAssertEqual(info.task?.id, "t1")
        XCTAssertEqual(info.workspaceRoot, "/source")
        XCTAssertEqual(info.executionPath, "/private/checkout")
    }

    func testAgentActivityDecodesProviderSuppliedReasoningAndUsage() throws {
        let data = Data(#"""
        {
          "id":"review","agent_name":"Reviewer","role":"reviewer",
          "provider":"Anthropic","model":"claude","goal":"Review",
          "state":"completed","output":"Approved","reasoning_text":"Explicit reasoning",
          "tool":null,"evidence":["App.swift:12"],"elapsed_milliseconds":42,
          "prompt_tokens":20,"completion_tokens":5
        }
        """#.utf8)
        let activity = try JSONDecoder().decode(AgentActivity.self, from: data)
        XCTAssertEqual(activity.reasoningText, "Explicit reasoning")
        XCTAssertEqual(activity.promptTokens + activity.completionTokens, 25)
    }

    func testTaskConversationStateRoundTripsWithoutConversationContent() throws {
        let state = TaskConversationState(
            sessionID: "session",
            taskID: "task",
            teamID: "team",
            workerID: "worker",
            runID: "run",
            state: .waitingPermission,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(TaskConversationState.self, from: data), state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("api_key"))
    }
}
