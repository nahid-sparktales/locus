import AppKit
import Darwin
import Security
import SwiftTerm
import SwiftUI
import XCTest
@testable import Locus

private final class MCPURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw NSError(domain: "MCPURLProtocol", code: 1)
            }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class FeatureLogicTests: XCTestCase {
    // MARK: - Application lifecycle

    func testMainWindowUsesTheCompactDefaultSize() {
        XCTAssertEqual(LocusWindowSizing.defaultSize.width, 1_250)
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

    func testUITestWindowSupportsBothAcceptanceSizes() {
        let display = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let compact = LocusWindowSizing.uiTestFrame(
            in: display,
            environment: [
                "LOCUS_UI_TESTING_WINDOW_WIDTH": "1120",
                "LOCUS_UI_TESTING_WINDOW_HEIGHT": "700",
            ]
        )
        let standard = LocusWindowSizing.uiTestFrame(in: display, environment: [:])

        XCTAssertEqual(compact.size, NSSize(width: 1_120, height: 700))
        XCTAssertEqual(standard.size, NSSize(width: 1_250, height: 760))
        XCTAssertEqual(compact.midX, display.midX)
        XCTAssertEqual(compact.midY, display.midY)
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

    func testLoopbackReadinessDistinguishesListeningAndClosedPorts() throws {
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
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }, 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))

        XCTAssertFalse(BackendProcess.loopbackPortIsListening(at: endpoint))
        XCTAssertEqual(listen(descriptor, 1), 0)
        XCTAssertTrue(BackendProcess.loopbackPortIsListening(at: endpoint))
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
        XCTAssertFalse(
            LocusApplicationDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared)
        )
    }

    func testScheduledTaskDecodesDurableConfigurationAndDates() throws {
        let json = #"""
        {
          "id":"schedule-1","name":"Morning review","prompt":"Inspect changes",
          "workspace_root":"/tmp/project","mode":"plan",
          "execution_environment":"worktree","runner":"solo_swarm",
          "provider":"ollama","model":"qwen3:8b","timezone":"America/Toronto",
          "rule":{"kind":"weekdays","hour":9,"minute":30},
          "enabled":true,"next_run_at":1787322600,
          "created_at":1,"updated_at":2,"last_run_at":null,
          "last_run_id":null,"last_error":null
        }
        """#
        let task = try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))

        XCTAssertEqual(task.mode, .plan)
        XCTAssertEqual(task.executionEnvironment, .worktree)
        XCTAssertEqual(task.runner, .soloSwarm)
        XCTAssertEqual(task.rule.kind, .weekdays)
        XCTAssertEqual(task.rule.hour, 9)
        XCTAssertEqual(task.nextRunDate?.timeIntervalSince1970, 1_787_322_600)
    }

    func testScheduleDraftBuildsOneTimeAndMinimumIntervalRules() {
        var once = ScheduleEditorDraft()
        once.ruleKind = .once
        once.oneTimeDate = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(once.rule(now: Date(timeIntervalSince1970: 1_000)).at, 2_000)

        var interval = ScheduleEditorDraft()
        interval.ruleKind = .interval
        interval.intervalEvery = 15
        interval.intervalUnit = .minutes
        interval.oneTimeDate = Date(timeIntervalSince1970: 900)
        let rule = interval.rule(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(rule.every, 15)
        XCTAssertEqual(rule.unit, .minutes)
        XCTAssertEqual(rule.anchor, 1_000)
    }

    func testLaunchAtLoginDefaultsOffAndRoundTrips() throws {
        XCTAssertFalse(AppSettings().launchAtLogin)
        XCTAssertFalse(
            try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).launchAtLogin
        )
        var settings = AppSettings()
        settings.launchAtLogin = true
        XCTAssertTrue(
            try JSONDecoder().decode(
                AppSettings.self, from: JSONEncoder().encode(settings)
            ).launchAtLogin
        )
    }

    func testMobileAccessDefaultsOffAndRoundTrips() throws {
        XCTAssertFalse(AppSettings().mobileAccessEnabled)
        XCTAssertFalse(
            try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).mobileAccessEnabled
        )
        var settings = AppSettings()
        settings.mobileAccessEnabled = true
        XCTAssertTrue(
            try JSONDecoder().decode(
                AppSettings.self, from: JSONEncoder().encode(settings)
            ).mobileAccessEnabled
        )
    }

    private func companionFixture() throws -> [String: Any] {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: FeatureLogicTests.self).url(
                forResource: "companion-v1",
                withExtension: "json"
            )
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    /// The fixture is the contract the iOS companion is written against, so it
    /// has to stay exhaustive: a new method or event that nobody adds a golden
    /// envelope for fails here rather than surfacing as a decode failure on a
    /// phone months later.
    func testCompanionProtocolFixturesCoverEveryMethodAndEvent() throws {
        let fixture = try companionFixture()
        let requests = try XCTUnwrap(fixture["requests"] as? [String: Any])
        let responses = try XCTUnwrap(fixture["responses"] as? [String: Any])
        let expectedMethods = Set(CompanionMethod.allCases.map(\.rawValue))

        XCTAssertEqual(Set(requests.keys), expectedMethods, "every method needs a golden request")
        XCTAssertEqual(Set(responses.keys), expectedMethods, "every method needs a golden response")

        let expectedEvents: Set<String> = [
            "connection.status", "chat.updated", "activity.updated",
            "schedule.updated", "approval.required",
        ]
        let events = try XCTUnwrap(fixture["events"] as? [String: Any])
        XCTAssertEqual(Set(events.keys), expectedEvents)
    }

    func testCompanionProtocolFixturesDecodeOnSwift() throws {
        let fixture = try companionFixture()

        for (name, value) in try XCTUnwrap(fixture["requests"] as? [String: Any]) {
            let request = try decode(CompanionRequest.self, from: value)
            XCTAssertEqual(request.method.rawValue, name, "request is filed under the wrong method")
            XCTAssertEqual(request.version, CompanionProtocolV1.version)
            XCTAssertFalse(request.id.isEmpty)
        }

        for (name, value) in try XCTUnwrap(fixture["responses"] as? [String: Any]) {
            let response = try decode(CompanionResponse.self, from: value)
            XCTAssertTrue(response.ok, "\(name) golden response should be a success")
            XCTAssertNotNil(response.data, "\(name) success carries data")
            XCTAssertNil(response.error, "\(name) success omits error")
        }

        // Failures are the half the Dart suite used to cover and nothing does now.
        for (code, value) in try XCTUnwrap(fixture["errors"] as? [String: Any]) {
            let response = try decode(CompanionResponse.self, from: value)
            XCTAssertFalse(response.ok)
            XCTAssertNil(response.data, "\(code) failure omits data")
            XCTAssertEqual(response.error?.code, code)
            XCTAssertFalse(try XCTUnwrap(response.error?.message).isEmpty)
        }

        for (name, value) in try XCTUnwrap(fixture["events"] as? [String: Any]) {
            let event = try decode(CompanionEvent.self, from: value)
            XCTAssertEqual(event.event, name)
            XCTAssertEqual(event.version, CompanionProtocolV1.version)
        }

        let pairing = try decode(
            CompanionPairingPayload.self, from: try XCTUnwrap(fixture["pairing_payload"])
        )
        XCTAssertEqual(pairing.version, CompanionProtocolV1.version)
        XCTAssertFalse(pairing.endpoints.isEmpty)

        // Spot-check the payload accessors the gateway reads requests through.
        let create = try decode(
            CompanionRequest.self,
            from: try XCTUnwrap(
                (fixture["requests"] as? [String: Any])?[CompanionMethod.chatCreate.rawValue]
            )
        )
        XCTAssertEqual(CompanionPayload.string("mode", in: create.payload), "work")
        let toggle = try decode(
            CompanionRequest.self,
            from: try XCTUnwrap(
                (fixture["requests"] as? [String: Any])?[CompanionMethod.scheduleSetEnabled.rawValue]
            )
        )
        XCTAssertEqual(CompanionPayload.bool("enabled", in: toggle.payload), false)
    }

    /// Round-tripping is what catches CodingKeys drift — a one-way decode still
    /// passes if someone renames `v` back to `version` on one side only.
    func testCompanionProtocolEnvelopesRoundTrip() throws {
        let fixture = try companionFixture()
        for value in try XCTUnwrap(fixture["responses"] as? [String: Any]).values {
            let decoded = try decode(CompanionResponse.self, from: value)
            let reencoded = try JSONDecoder().decode(
                CompanionResponse.self, from: JSONEncoder().encode(decoded)
            )
            XCTAssertEqual(decoded, reencoded)
        }
        for value in try XCTUnwrap(fixture["events"] as? [String: Any]).values {
            let decoded = try decode(CompanionEvent.self, from: value)
            let reencoded = try JSONDecoder().decode(
                CompanionEvent.self, from: JSONEncoder().encode(decoded)
            )
            XCTAssertEqual(decoded, reencoded)
        }
    }

    func testCompanionPairingNonceExpiresAndCannotReplay() throws {
        var store = CompanionPairingNonceStore()
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try store.issue(now: now)
        XCTAssertTrue(store.consume(first.nonce, now: now.addingTimeInterval(60)))
        XCTAssertFalse(store.consume(first.nonce, now: now.addingTimeInterval(61)))

        let expired = try store.issue(now: now)
        XCTAssertFalse(store.consume(
            expired.nonce,
            now: now.addingTimeInterval(CompanionProtocolV1.pairingLifetime + 1)
        ))
    }

    func testCompanionTokensAreHashedAndRevocable() throws {
        var registry = CompanionDeviceRegistry(serviceID: "install-1")
        let paired = try registry.pair(name: "Nahid's iPhone", platform: "iOS")
        XCTAssertNotEqual(paired.device.tokenHash, paired.token)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(registry.devices), as: UTF8.self)
            .contains(paired.token))
        XCTAssertEqual(registry.authenticate(paired.token)?.id, paired.device.id)
        XCTAssertTrue(registry.revoke(deviceID: paired.device.id))
        XCTAssertNil(registry.authenticate(paired.token))
    }

    func testCompanionCertificateIsValidX509AndUsesAFullFingerprint() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicBytes = try XCTUnwrap(
            SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        )
        let certificateData = try CompanionX509.makeCertificate(
            publicKey: publicBytes,
            privateKey: privateKey
        )

        XCTAssertNotNil(SecCertificateCreateWithData(nil, certificateData as CFData))
        let fingerprint = CompanionCrypto.fingerprint(certificateData)
        XCTAssertEqual(fingerprint.split(separator: ":").count, 32)
    }

    func testCompanionAuthorizationUtilitiesEnforceBounds() {
        XCTAssertEqual(
            Set(CompanionMethod.allCases),
            Set([
                .pairExchange, .statusGet, .chatsList, .chatGet, .chatSend, .chatCreate,
                .activityList, .runStop, .approvalRespond, .schedulesList,
                .scheduleRunNow, .scheduleSetEnabled,
            ])
        )
        XCTAssertEqual(CompanionProtocolV1.maximumConnections, 4)
        XCTAssertEqual(CompanionProtocolV1.maximumPayloadBytes, 256 * 1_024)

        let now = Date(timeIntervalSince1970: 1_000)
        var limiter = CompanionRateLimiter(maximumRequests: 2, window: 60)
        XCTAssertTrue(limiter.allows("phone", now: now))
        XCTAssertTrue(limiter.allows("phone", now: now.addingTimeInterval(1)))
        XCTAssertFalse(limiter.allows("phone", now: now.addingTimeInterval(2)))
        XCTAssertTrue(limiter.allows("phone", now: now.addingTimeInterval(61)))

        var cache = CompanionIdempotencyCache(lifetime: 5, limit: 2)
        let response = CompanionResponse.success(id: "request-1")
        cache.insert(response, now: now)
        XCTAssertEqual(cache.response(for: "request-1", now: now.addingTimeInterval(4)), response)
        XCTAssertNil(cache.response(for: "request-1", now: now.addingTimeInterval(6)))
    }

    func testCompanionEventSanitizerDropsPrivateFieldsAndHiddenResults() {
        let clean = CompanionEventSanitizer.sanitize(.object([
            "message": .string("Visible answer"),
            "api_key": .string("secret"),
            "nested": .object([
                "system_prompt": .string("private instructions"),
                "raw_tool_result": .string("filesystem dump"),
                "state": .string("running"),
            ]),
        ]))
        guard case .object(let root) = clean,
              case .object(let nested)? = root["nested"] else {
            return XCTFail("sanitizer should preserve a safe object")
        }
        XCTAssertNil(root["api_key"])
        XCTAssertNil(nested["system_prompt"])
        XCTAssertNil(nested["raw_tool_result"])
        XCTAssertEqual(nested["state"]?.string, "running")
    }

    func testRunDecodesScheduleProvenanceAndSavedMode() throws {
        let json = #"""
        {
          "id":"occurrence-1","session_id":"chat-1","state":"queued",
          "request":"Inspect","created_at":1,"updated_at":2,"last_seq":0,
          "pinned":false,"legacy":false,"recoverable":false,"run_kind":"solo",
          "schedule_id":"schedule-1","occurrence_id":"occurrence-1",
          "scheduled_for":1787322600,
          "manifest":{"scheduled":true,"mode":"plan","provider":"ollama","model":"qwen3:8b"}
        }
        """#
        let run = try JSONDecoder().decode(OrchestrationRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.scheduleID, "schedule-1")
        XCTAssertEqual(run.occurrenceID, "occurrence-1")
        XCTAssertEqual(run.manifest?["mode"]?.string, "plan")
    }

    func testLifecycleJournalDistinguishesCleanAndUncleanTermination() throws {
        let suite = "LocusTests.lifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = AppLifecycleJournal(defaults: defaults, keyPrefix: "test")

        XCTAssertNil(journal.beginLaunch(), "the first launch is not a recovery")
        journal.record(
            sessionID: "session-1",
            runID: "run-1",
            state: .running,
            at: Date(timeIntervalSince1970: 10)
        )

        let afterForcedQuit = AppLifecycleJournal(defaults: defaults, keyPrefix: "test")
            .beginLaunch()
        XCTAssertEqual(afterForcedQuit?.snapshot?.runID, "run-1")
        XCTAssertEqual(afterForcedQuit?.snapshot?.state, .running)

        journal.markCleanExit()
        XCTAssertNil(
            AppLifecycleJournal(defaults: defaults, keyPrefix: "test").beginLaunch(),
            "normal termination must not show crash recovery"
        )
    }

    func testLifecycleRecoveryExplainsCompletedAndRecoverableRuns() {
        let completed = AppLifecycleRecovery(snapshot: AppLifecycleRunSnapshot(
            sessionID: "session",
            runID: "completed",
            state: .completed,
            updatedAt: Date()
        ))
        let active = AppLifecycleRecovery(snapshot: AppLifecycleRunSnapshot(
            sessionID: "session",
            runID: "active",
            state: .waitingPermission,
            updatedAt: Date()
        ))

        XCTAssertTrue(completed.message.contains("completed"))
        XCTAssertTrue(active.message.contains("resumed"))
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

    func testResponseCopyUsesTheCompleteVisibleAnswer() {
        let paragraphs = (1...80).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        let source = "<think>private reasoning</think>\n# Result\n\n\(paragraphs)\n"

        let copied = AssistantSegment.copyableText(from: source)

        XCTAssertEqual(copied, "# Result\n\n\(paragraphs)")
        XCTAssertFalse(copied.contains("private reasoning"))
        XCTAssertTrue(copied.hasSuffix("Paragraph 80"), "the response must not be truncated")
    }

    func testResponseCopyOffersPlainTextAndSourceFaithfulMarkdown() {
        let source = """
        <think>private reasoning</think>
        # Result

        Read **the [guide](https://example.com/guide)**.

        - First
        - [x] Complete

        > Quoted line

        ```swift
        let value = 42
        ```

        | Name | Value |
        | --- | --- |
        | Answer | 42 |

        ![Plot](images/plot.png)
        """

        XCTAssertEqual(
            ResponseCopyPayload.text(from: source, format: .markdown),
            source.replacingOccurrences(
                of: "<think>private reasoning</think>\n",
                with: ""
            )
        )
        XCTAssertEqual(
            ResponseCopyPayload.text(from: source, format: .plainText),
            """
            Result

            Read the guide (https://example.com/guide).

            • First
            [x] Complete

            > Quoted line

            let value = 42

            Name\tValue
            Answer\t42

            Plot (images/plot.png)
            """
        )
    }

    func testPlainTextCopyPreservesNestedNumberedLists() {
        XCTAssertEqual(
            MarkdownPlainTextRenderer.render(
                """
                3. Parent
                   - Nested child
                4. Second
                """
            ),
            """
            3. Parent

               • Nested child
            4. Second
            """
        )
    }

    func testLongOutputPolicyCountsLogicalLinesWithoutTheFenceTerminator() {
        let code = (1...25).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let lines = LongOutputPolicy.codeLines(code)

        XCTAssertEqual(lines.count, 25)
        XCTAssertEqual(Array(lines.prefix(LongOutputPolicy.codePreviewLineCount)).last, "line 12")
        XCTAssertGreaterThan(lines.count, LongOutputPolicy.codeCollapseThreshold)
        XCTAssertEqual(LongOutputPolicy.tableCollapseThreshold, 10)
        XCTAssertEqual(LongOutputPolicy.tablePreviewRowCount, 5)
    }

    func testFirstActivityOwnsSingleAssistantMarkerPerResponse() {
        let firstUser = ChatBlock(kind: .user, text: "First request")
        let reasoning = ChatBlock(kind: .assistant, reasoningText: "Planning")
        let commentary = ChatBlock(
            kind: .assistant,
            text: "Checking files",
            assistantPhase: .commentary
        )
        let finalAnswer = ChatBlock(
            kind: .assistant,
            text: "Finished",
            assistantPhase: .finalAnswer
        )
        let completion = ChatBlock(
            kind: .note,
            completion: TurnCompletion(
                outcome: .complete,
                mode: .work,
                durationMilliseconds: 1_000
            )
        )
        let secondUser = ChatBlock(kind: .user, text: "Second request")
        let secondAnswer = ChatBlock(kind: .assistant, text: "Done again", assistantPhase: .finalAnswer)
        let items = TranscriptPresentation.items(
            from: [firstUser, reasoning, commentary, finalAnswer, completion, secondUser, secondAnswer],
            toolVisibility: .collapsed,
            thinkingVisibility: .collapsed
        )

        let reasoningItemID = TranscriptPresentationItem.ID.thinkingGroup(.init(
            sourceBlockID: reasoning.id,
            ordinal: 0
        ))
        let finalItemID = TranscriptPresentationItem.ID.assistantSegment(.init(
            sourceBlockID: finalAnswer.id,
            ordinal: 0
        ))
        let secondItemID = TranscriptPresentationItem.ID.assistantSegment(.init(
            sourceBlockID: secondAnswer.id,
            ordinal: 0
        ))

        XCTAssertEqual(
            TranscriptPresentation.assistantMarkerItemIDs(in: items),
            Set([reasoningItemID, secondItemID])
        )
        XCTAssertEqual(
            TranscriptPresentation.assistantActionItemIDs(in: items),
            Set([finalItemID, secondItemID])
        )
    }

    func testToolRunOwnsMarkerWhenItStartsTheResponse() {
        let user = ChatBlock(kind: .user, text: "Inspect the project")
        let tool = ChatBlock(
            kind: .tool,
            tool: ToolPayload(
                toolID: "first-tool",
                tool: "read_file",
                summary: "Read files",
                detail: "",
                status: .running
            )
        )
        let commentary = ChatBlock(
            kind: .assistant,
            text: "I found the relevant files.",
            assistantPhase: .commentary
        )
        let items = TranscriptPresentation.items(
            from: [user, tool, commentary],
            toolVisibility: .collapsed,
            thinkingVisibility: .collapsed
        )

        XCTAssertEqual(
            TranscriptPresentation.assistantMarkerItemIDs(in: items),
            Set([.toolGroup(tool.id)])
        )
    }

    // MARK: - Swift Markdown rendering model

    func testFencedTildeIndentedAndIncompleteCodeBlocksArePreserved() {
        let blocks = MarkdownDocumentParser.parse(
            "Before\n```swift\nlet x = 1\n```\n~~~diff\n-old\n+new\n~~~\n\n    indented\n"
        )
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[0], .paragraph([.init(text: "Before")]))
        XCTAssertEqual(blocks[1], .code(language: "swift", body: "let x = 1\n"))
        XCTAssertEqual(blocks[2], .code(language: "diff", body: "-old\n+new\n"))
        XCTAssertEqual(blocks[3], .code(language: nil, body: "indented\n"))

        XCTAssertEqual(
            MarkdownDocumentParser.parse("```\nraw"),
            [.code(language: nil, body: "raw\n")]
        )
    }

    func testGFMParserRecognizesNestedAssistantStyleBlocks() {
        let blocks = MarkdownDocumentParser.parse(
            """
            ## Result

            - [x] Parsed **Markdown**
              - Nested `detail`
            - [ ] Verify layout

            3. First numbered item
            4. Second numbered item

            > Keep the interface calm.
            >
            > - Even in a nested quote.

            | Surface | State |
            | :--- | ---: |
            | Composer | Ready |

            ---
            """
        )

        guard case .heading(level: 2, runs: let heading) = blocks[0] else {
            return XCTFail("Expected heading")
        }
        XCTAssertEqual(heading.map(\.text).joined(), "Result")
        guard case .unordered(let tasks) = blocks[1] else { return XCTFail("Expected task list") }
        XCTAssertEqual(tasks.map(\.checked), [true, false])
        XCTAssertTrue(tasks[0].blocks.contains { if case .unordered = $0 { true } else { false } })
        guard case .ordered(start: 3, items: let ordered) = blocks[2] else {
            return XCTFail("Expected ordered list")
        }
        XCTAssertEqual(ordered.count, 2)
        guard case .quote(let quote) = blocks[3] else { return XCTFail("Expected quote") }
        XCTAssertTrue(quote.contains { if case .unordered = $0 { true } else { false } })
        guard case .table(let headers, let alignments, let rows) = blocks[4] else {
            return XCTFail("Expected table")
        }
        XCTAssertEqual(headers.map { $0.map(\.text).joined() }, ["Surface", "State"])
        XCTAssertEqual(alignments, [.left, .right])
        XCTAssertEqual(rows[0].map { $0.map(\.text).joined() }, ["Composer", "Ready"])
        XCTAssertEqual(blocks[5], .rule)
    }

    func testInlineGFMFormattingEscapesEntitiesBreaksLinksAndImages() {
        let blocks = MarkdownDocumentParser.parse(
            "**bold** *emphasis* ~~gone~~ `code` &amp; \\*literal\\*  \nnext [site](https://example.com) ![chart](chart.png)"
        )
        guard case .paragraph(let runs) = blocks.first else { return XCTFail("Expected paragraph") }
        XCTAssertTrue(runs.contains { $0.text == "bold" && $0.style.contains(.strong) })
        XCTAssertTrue(runs.contains { $0.text == "emphasis" && $0.style.contains(.emphasis) })
        XCTAssertTrue(runs.contains { $0.text == "gone" && $0.style.contains(.strikethrough) })
        XCTAssertTrue(runs.contains { $0.text == "code" && $0.style.contains(.code) })
        XCTAssertTrue(runs.map(\.text).joined().contains("& *literal*\nnext"))
        XCTAssertTrue(runs.contains { $0.destination == "https://example.com" })
        XCTAssertTrue(runs.contains { $0.isImage && $0.destination == "chart.png" })
    }

    func testRawHTMLIsLiteralAndUnsafeLinksAreRejected() {
        XCTAssertEqual(
            MarkdownDocumentParser.parse("<script>alert('no')</script>"),
            [.rawText("<script>alert('no')</script>\n")]
        )
        XCTAssertNil(MarkdownLinkPolicy.safeURL("javascript:alert(1)", workspacePath: "/tmp/project"))
        XCTAssertEqual(
            MarkdownLinkPolicy.safeURL("https://example.com", workspacePath: nil)?.scheme,
            "https"
        )
        XCTAssertNil(MarkdownLinkPolicy.workspaceImageURL("/tmp/outside.png", workspacePath: "/tmp/project"))
        XCTAssertEqual(
            MarkdownLinkPolicy.workspaceImageURL("images/chart.png", workspacePath: "/tmp/project")?.path,
            "/tmp/project/images/chart.png"
        )
    }

    func testResponseSelectionCopiesMarkdownAsOneStructuredDocument() {
        let blocks = MarkdownDocumentParser.parse(
            """
            Intro

            - Alpha
            - [x] Done

            3. Third
            4. Fourth

            > Quoted

            | Name | Value |
            | --- | --- |
            | A | B |

            ```text
              one\t2
            ```

            After
            """
        )
        let spans = MarkdownSelectionProjection.spans(for: blocks).values.sorted {
            TranscriptSelectionProjection.pathIsBefore($0.treePath, $1.treePath)
        }
        guard let first = spans.first, let last = spans.last else {
            return XCTFail("Expected selectable Markdown leaves")
        }
        let selection = TranscriptSelection(
            anchor: .init(spanID: first.id, utf16Offset: 0),
            focus: .init(spanID: last.id, utf16Offset: last.utf16Length)
        )

        XCTAssertEqual(
            TranscriptSelectionProjection.text(for: selection, spans: spans),
            """
            Intro

            • Alpha
            [x] Done

            3. Third
            4. Fourth

            > Quoted

            Name\tValue
            A\tB

              one\t2

            After
            """
        )
    }

    func testResponseSelectionSupportsReverseUnicodeRangesAndCollapsedProjections() {
        let first = TranscriptSelectionSpan(
            treePath: [0],
            displayedText: "A🙂B",
            separatorBefore: "",
            copyPrefix: ""
        )
        let second = TranscriptSelectionSpan(
            treePath: [1],
            displayedText: "café",
            separatorBefore: "\n",
            copyPrefix: "• "
        )
        let forward = TranscriptSelection(
            anchor: .init(spanID: first.id, utf16Offset: 1),
            focus: .init(spanID: second.id, utf16Offset: second.utf16Length)
        )
        let reverse = TranscriptSelection(anchor: forward.focus, focus: forward.anchor)

        XCTAssertEqual(
            TranscriptSelectionProjection.text(for: forward, spans: [second, first]),
            "🙂B\n• café"
        )
        XCTAssertEqual(
            TranscriptSelectionProjection.text(for: reverse, spans: [first, second]),
            "🙂B\n• café"
        )
        XCTAssertEqual(
            TranscriptSelectionProjection.ranges(for: reverse, spans: [first, second]),
            [first.id: NSRange(location: 1, length: 3), second.id: NSRange(location: 0, length: 4)]
        )

        let collapsed = TranscriptSelectionSpan(
            treePath: [2],
            displayedText: "line 1\nline 2\nhidden",
            separatorBefore: "\n\n",
            copyPrefix: ""
        ).displaying("line 1\nline 2")
        let visibleOnly = TranscriptSelection(
            anchor: .init(spanID: collapsed.id, utf16Offset: 0),
            focus: .init(spanID: collapsed.id, utf16Offset: collapsed.utf16Length)
        )
        XCTAssertEqual(
            TranscriptSelectionProjection.text(for: visibleOnly, spans: [collapsed]),
            "line 1\nline 2"
        )
    }

    func testWorkspaceArtifactReferencesAreContainedClassifiedAndLocationAware() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("locus-artifact-\(UUID().uuidString)", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        let outside = base.appendingPathComponent("outside.txt")
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        defer { try? fileManager.removeItem(at: base) }

        let source = sources.appendingPathComponent("File.swift")
        let image = workspace.appendingPathComponent("chart.png")
        let sheet = workspace.appendingPathComponent("results.xlsx")
        try Data("let value = 1\n".utf8).write(to: source)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try Data([0x50, 0x4B]).write(to: sheet)
        try fileManager.createSymbolicLink(
            at: workspace.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )

        XCTAssertEqual(
            WorkspacePathReferenceParser.parse("Sources/File.swift:12:4"),
            .init(path: "Sources/File.swift", location: .init(line: 12, column: 4))
        )
        XCTAssertEqual(
            WorkspacePathReferenceParser.parse("Sources/File.swift#L8C2"),
            .init(path: "Sources/File.swift", location: .init(line: 8, column: 2))
        )

        let reference = try XCTUnwrap(
            WorkspaceArtifactReference.classify(
                "Sources/File.swift:12:4",
                workspacePath: workspace.path
            )
        )
        XCTAssertEqual(reference.kind, .source)
        XCTAssertEqual(reference.relativePath, "Sources/File.swift")
        XCTAssertEqual(reference.sourceLocation, .init(line: 12, column: 4))
        XCTAssertEqual(
            WorkspaceArtifactReference.fromNavigationURL(
                reference.navigationURL,
                workspacePath: workspace.path
            ),
            reference
        )
        XCTAssertEqual(
            WorkspaceArtifactReference.classify("chart.png", workspacePath: workspace.path)?.kind,
            .image
        )
        XCTAssertEqual(
            WorkspaceArtifactReference.classify("results.xlsx", workspacePath: workspace.path)?.kind,
            .spreadsheet
        )
        XCTAssertNil(
            WorkspaceArtifactReference.classify("missing.pdf", workspacePath: workspace.path)
        )
        XCTAssertNil(
            WorkspaceArtifactReference.classify("escape.txt", workspacePath: workspace.path),
            "a workspace symlink must not escape the workspace boundary"
        )
        XCTAssertNil(
            WorkspaceArtifactReference.classify(
                "https://example.com/chart.png",
                workspacePath: workspace.path
            ),
            "remote media must never be auto-loaded as a local artifact"
        )
        XCTAssertNil(
            MarkdownLinkPolicy.workspaceImageURL(
                "https://example.com/chart.png",
                workspacePath: workspace.path
            )
        )
    }

    func testWorkspaceArtifactsRouteBinariesToTheDefaultAppAndTextToTheFilesTab() {
        // The Files peek decodes UTF-8 only, so anything that is not source has
        // to leave the app. The previous binary branch drove the shared
        // QLPreviewPanel without owning it through the responder chain, which
        // is what showed a blank or stale preview.
        for kind in [
            WorkspaceArtifactKind.pdf,
            .image,
            .spreadsheet,
            .document,
            .presentation,
            .audio,
            .video,
            .other,
        ] {
            XCTAssertEqual(
                WorkspaceArtifactOpener.destination(kind: kind, sourceLocation: nil),
                .defaultApp,
                "\(kind.rawValue) has no in-app renderer and must open externally"
            )
        }

        XCTAssertEqual(
            WorkspaceArtifactOpener.destination(kind: .source, sourceLocation: nil),
            .filesTab(line: nil, column: nil)
        )
        XCTAssertEqual(
            WorkspaceArtifactOpener.destination(
                kind: .source,
                sourceLocation: .init(line: 12, column: 4)
            ),
            .filesTab(line: 12, column: 4)
        )
        XCTAssertEqual(
            WorkspaceArtifactOpener.destination(
                kind: .pdf,
                sourceLocation: .init(line: 3, column: nil)
            ),
            .filesTab(line: 3, column: nil),
            "a named line is a citation to scroll to, not a document to hand to Preview"
        )
    }

    func testFileReferencesGetFullCardAtTopLevelAndChipInLists() {
        // A reply that lists a directory writes one bullet per file. Promoting
        // each of those to a 58pt card with three buttons turned a seven-file
        // answer into a wall of chrome, so nested references take the compact
        // chip tier instead of losing the tile entirely.
        XCTAssertEqual(MarkdownArtifactPromotion.presentation(nestingDepth: 0), .fullCard)
        XCTAssertEqual(
            MarkdownArtifactPromotion.presentation(nestingDepth: 1), .compactChip,
            "inside a list the reference keeps a tile, just a single-line one"
        )
        XCTAssertEqual(MarkdownArtifactPromotion.presentation(nestingDepth: 2), .compactChip)
    }

    func testLeadingArtifactPromotesAnnotatedBulletsButNotComparisons() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locus-chip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("a".utf8).write(to: workspace.appendingPathComponent("notes.md"))
        try Data("b".utf8).write(to: workspace.appendingPathComponent("todo.md"))

        func reference(_ runs: [MarkdownInlineRun]) -> WorkspaceArtifactReference? {
            MarkdownArtifactPromotion.leadingArtifact(in: runs, workspacePath: workspace.path)
        }

        // A bare backticked name and a bare link both promote.
        XCTAssertEqual(
            reference([.init(text: "notes.md", style: .code)])?.relativePath, "notes.md"
        )
        XCTAssertEqual(
            reference([.init(text: "notes.md", destination: "notes.md")])?.relativePath,
            "notes.md"
        )
        // The answer contract annotates every bullet; the annotation rides
        // along instead of demoting the reference to prose.
        XCTAssertEqual(
            reference([
                .init(text: "notes.md", style: .code),
                .init(text: " — the working notes"),
            ])?.relativePath,
            "notes.md"
        )
        // Prose that merely mentions a file does not lead with it.
        XCTAssertNil(reference([
            .init(text: "see "),
            .init(text: "notes.md", style: .code),
        ]))
        // A comparison of two files stays prose: a chip's actions would be
        // attributed to just one of them.
        XCTAssertNil(reference([
            .init(text: "notes.md", style: .code),
            .init(text: " duplicates "),
            .init(text: "todo.md", style: .code),
        ]))
        // Names that resolve to nothing in the workspace never promote.
        XCTAssertNil(reference([.init(text: "missing.md", style: .code)]))
    }

    @MainActor
    func testWorkspacePreviewPublishesAndClearsSourceLocation() {
        let model = WorkspaceFileModel()
        model.configure(isUITesting: true, workspacePath: { "/tmp/project" }, canIndex: { true })
        model.preview(URL(fileURLWithPath: "/tmp/project/File.swift"), line: 18, column: 6)

        XCTAssertEqual(model.previewedPath, "File.swift")
        XCTAssertEqual(model.previewedLocation, .init(line: 18, column: 6))

        model.closePreview()
        XCTAssertNil(model.previewedLocation)
    }

    func testLongUnbrokenMarkdownContentIsPreserved() {
        let value = String(repeating: "x", count: 100_000)
        guard case .paragraph(let runs) = MarkdownDocumentParser.parse(value).first else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertEqual(runs.map(\.text).joined(), value)
    }

    func testCodeHighlighterPreservesSourceAndClassifiesCommonTokens() {
        let source = "let answer = \"yes\" // explanation\nreturn 42"
        let tokens = CodeSyntaxHighlighter.tokens(for: source, language: "swift")

        XCTAssertEqual(tokens.map(\.text).joined(), source)
        XCTAssertTrue(tokens.contains(CodeToken(text: "let", kind: .keyword)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "\"yes\"", kind: .string)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "// explanation", kind: .comment)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "return", kind: .keyword)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "42", kind: .number)))
    }

    func testCodeHighlighterClassifiesCallsMembersAndTypes() {
        let source = "let view = Container.shared.build(width)"
        let tokens = CodeSyntaxHighlighter.tokens(for: source, language: "swift")

        XCTAssertEqual(tokens.map(\.text).joined(), source)
        XCTAssertTrue(tokens.contains(CodeToken(text: "Container", kind: .type)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "shared", kind: .property)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "build", kind: .function)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "(", kind: .punctuation)))
    }

    func testCodeHighlighterReadsLiteralsAsConstantsInEveryLanguage() {
        for language in ["python", "javascript", "swift"] {
            let tokens = CodeSyntaxHighlighter.tokens(for: "value = true", language: language)
            XCTAssertTrue(
                tokens.contains(CodeToken(text: "true", kind: .constant)),
                "Expected a constant token for \(language)"
            )
        }
    }

    /// The old fallback applied `//` line comments to every unrecognised fence,
    /// which turned ordinary TOML and INI paths into comments.
    func testHashCommentLanguagesDoNotTreatSlashesAsComments() {
        let source = "# note\nroot = /a//b"
        let tokens = CodeSyntaxHighlighter.tokens(for: source, language: "toml")

        XCTAssertEqual(tokens.map(\.text).joined(), source)
        XCTAssertTrue(tokens.contains(CodeToken(text: "# note", kind: .comment)))
        XCTAssertFalse(tokens.contains { $0.kind == .comment && $0.text.contains("//") })
    }

    func testUnknownLanguageStillReceivesKeywordsAndNoStrayComments() {
        let tokens = CodeSyntaxHighlighter.tokens(
            for: "if x then y end // not a comment here",
            language: "someunknownlang"
        )

        XCTAssertTrue(tokens.contains(CodeToken(text: "if", kind: .keyword)))
        XCTAssertTrue(tokens.contains(CodeToken(text: "end", kind: .keyword)))
        XCTAssertNil(tokens.first { $0.kind == .comment })
    }

    // MARK: - Transcript typography

    func testHeadingTakesMoreRoomAboveThanBelow() {
        let paragraph = MarkdownRenderBlock.paragraph([])
        let heading = MarkdownRenderBlock.heading(level: 2, runs: [])

        for density in [MarkdownRenderDensity.regular, .compact] {
            let above = density.topSpacing(from: paragraph, to: heading)
            let below = density.topSpacing(from: heading, to: paragraph)
            XCTAssertGreaterThan(above, below, "Heading rhythm should be asymmetric")
            XCTAssertEqual(density.topSpacing(from: nil, to: heading), 0)
        }
    }

    func testStrongRunsDarkenAsWellAsThicken() {
        let spec = MarkdownInlineStyleSpec.resolve(
            run: MarkdownInlineRun(text: "x", style: [.strong]),
            baseSize: 13,
            baseWeight: .regular,
            baseColor: LocusTheme.inkSoft,
            inlineCodeSize: 12,
            link: nil
        )

        XCTAssertTrue(spec.isBold)
        XCTAssertEqual(spec.foreground, LocusTheme.ink)
    }

    /// A file mentioned as inline code navigates like a link but reads like a
    /// code pill: the blue-underline treatment stays reserved for authored
    /// links and remote URLs.
    func testWorkspaceFileCodeRunsKeepThePillInsteadOfLinkBlue() {
        let classified = MarkdownInlineStyleSpec.resolve(
            run: MarkdownInlineRun(text: "AppModel.swift:12", style: [.code]),
            baseSize: 13,
            baseWeight: .regular,
            baseColor: LocusTheme.inkSoft,
            inlineCodeSize: 12,
            link: URL(string: "locus-workspace://open/AppModel.swift?line=12")
        )
        XCTAssertEqual(classified.foreground, LocusTheme.ink)
        XCTAssertFalse(classified.isUnderlined)
        XCTAssertEqual(classified.pillFill, LocusTheme.inlineCodeFill)

        let authored = MarkdownInlineStyleSpec.resolve(
            run: MarkdownInlineRun(
                text: "the model",
                style: [.code],
                destination: "AppModel.swift"
            ),
            baseSize: 13,
            baseWeight: .regular,
            baseColor: LocusTheme.inkSoft,
            inlineCodeSize: 12,
            link: URL(string: "locus-workspace://open/AppModel.swift")
        )
        // `signalDeep` mints a fresh accent-dynamic Color per access, so the
        // link treatment is asserted structurally: underlined, and no longer
        // the code pill's ink.
        XCTAssertNotEqual(authored.foreground, LocusTheme.ink)
        XCTAssertTrue(authored.isUnderlined)

        let remote = MarkdownInlineStyleSpec.resolve(
            run: MarkdownInlineRun(text: "docs", destination: "https://example.com"),
            baseSize: 13,
            baseWeight: .regular,
            baseColor: LocusTheme.inkSoft,
            inlineCodeSize: 12,
            link: URL(string: "https://example.com")
        )
        XCTAssertNotEqual(remote.foreground, LocusTheme.inkSoft)
        XCTAssertTrue(remote.isUnderlined)
    }

    /// Regression guard for the drift that motivated the shared spec: the
    /// AppKit leaf and the SwiftUI fallback must resolve one run identically.
    func testInlineCodeResolvesTheSameOnBothRenderPaths() {
        let run = MarkdownInlineRun(text: "value", style: [.code])
        let spec = MarkdownInlineStyleSpec.resolve(
            run: run,
            baseSize: 13,
            baseWeight: .regular,
            baseColor: LocusTheme.inkSoft,
            inlineCodeSize: 12,
            link: nil
        )

        XCTAssertEqual(spec.fontSize, 12)
        XCTAssertTrue(spec.isMonospaced)
        XCTAssertEqual(spec.foreground, LocusTheme.ink)
        XCTAssertEqual(spec.pillFill, LocusTheme.inlineCodeFill)

        let appKit = MarkdownNativeText.attributed(
            [run],
            size: 13,
            weight: .regular,
            color: LocusTheme.inkSoft,
            lineSpacing: 5,
            inlineCodeSize: 12,
            workspacePath: nil
        )
        let font = appKit.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, spec.fontSize)
        XCTAssertEqual(font?.isFixedPitch, true)
        XCTAssertNotNil(appKit.attribute(.locusInlineCodePill, at: 0, effectiveRange: nil))
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
        XCTAssertEqual(InspectorTab.allCases.count, 12)
        let raws = InspectorTab.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        XCTAssertEqual(Set(InspectorTab.allCases.map(\.symbol)).count, raws.count)
        XCTAssertEqual(Set(InspectorTab.allCases.map(\.title)).count, raws.count)
        // rawValue is the accessibility-identifier and persistence contract.
        XCTAssertEqual(InspectorTab(rawValue: "plan"), .plan)
        XCTAssertEqual(InspectorTab(rawValue: "terminal"), .terminal)
        XCTAssertEqual(InspectorTab(rawValue: "checkpoints"), .checkpoints)
        XCTAssertEqual(InspectorTab(rawValue: "runs"), .runs)
        XCTAssertEqual(InspectorTab(rawValue: "agents"), .agents)
        XCTAssertEqual(InspectorTab(rawValue: "notes"), .notes)
        XCTAssertEqual(InspectorTab(rawValue: "simulator"), .simulator)
        XCTAssertEqual(InspectorTab.plan.title, "Overview")
        XCTAssertEqual(InspectorTab.plan.symbol, "rectangle.grid.2x2")
        XCTAssertEqual(InspectorTab.notes.title, "Notes")
        XCTAssertEqual(InspectorTab.notes.symbol, "note.text")
        XCTAssertEqual(InspectorTab.router.title, "Router")
        XCTAssertEqual(InspectorTab.proxies.title, "Proxies")
        XCTAssertTrue(InspectorTab.workspaceTabs.contains(.router))
        XCTAssertTrue(InspectorTab.workspaceTabs.contains(.proxies))
        XCTAssertFalse(
            InspectorTab.workspaceTabs.contains(.checkpoints),
            "manual checkpoints use the focused manager rather than a persistent tab"
        )
    }

    func testInspectorShortcutsPreserveExistingKeysAndAddNotesOnNine() {
        XCTAssertEqual(
            InspectorTab.allCases.map(\.shortcutKey),
            ["1", "2", "3", "4", "5", nil, "9", "6", "7", "8", nil, nil]
        )
    }

    func testModelRouterSettingsAreOptInAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.automaticModelRoutingEnabled)
        XCTAssertFalse(legacy.automaticModelRoutingAllowHosted)
        XCTAssertEqual(legacy.resolvedModelRoutingPolicy, .balanced)

        var settings = AppSettings()
        settings.automaticModelRoutingEnabled = true
        settings.automaticModelRoutingAllowHosted = true
        settings.modelRoutingPolicyRaw = ModelRoutingPolicy.fast.rawValue
        settings.modelRouterFallbackAccountID = "account-1"
        settings.modelRouterFallbackModel = "qwen3:8b"
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertTrue(restored.automaticModelRoutingEnabled)
        XCTAssertTrue(restored.automaticModelRoutingAllowHosted)
        XCTAssertEqual(restored.resolvedModelRoutingPolicy, .fast)
        XCTAssertEqual(restored.modelRouterFallbackAccountID, "account-1")
        XCTAssertEqual(restored.modelRouterFallbackModel, "qwen3:8b")
    }

    func testUnknownModelRoutingPolicyFallsBackWithoutDisablingRouter() throws {
        let json = #"{"automaticModelRoutingEnabled":true,"modelRoutingPolicyRaw":"future"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertTrue(restored.automaticModelRoutingEnabled)
        XCTAssertEqual(restored.resolvedModelRoutingPolicy, .balanced)
    }

    func testModelRoutingPoliciesAlwaysHaveNormalizedScorecardWeights() {
        for policy in ModelRoutingPolicy.allCases {
            XCTAssertEqual(Set(policy.weights.keys), Set([
                "quality", "reliability", "privacy", "latency", "cost", "efficiency",
            ]))
            XCTAssertEqual(policy.weights.values.reduce(0, +), 1, accuracy: 0.000_001)
        }
    }

    @MainActor
    func testModelRoutingTagsClassifyLocallyWithoutReturningPromptContent() {
        let prompt = "Debug the failing Swift API test for CustomerSecretValue"
        let tags = AppModel.modelRoutingTags(for: prompt, mode: .grill)
        XCTAssertTrue(tags.contains("coding"))
        XCTAssertTrue(tags.contains("debugging"))
        XCTAssertTrue(tags.contains("testing"))
        XCTAssertFalse(tags.contains(where: { $0.contains("customersecretvalue") }))
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

    func testAgentInstructionStartersAppendWithoutReplacingExistingGuidance() {
        let existing = "# Workspace instructions\n\n- Keep public APIs stable.\n"
        let appended = AgentInstructionsStarter.verification.appending(to: existing)

        XCTAssertTrue(appended.hasPrefix("# Workspace instructions"))
        XCTAssertTrue(appended.contains("Keep public APIs stable"))
        XCTAssertTrue(appended.contains("## Verification"))
        XCTAssertTrue(appended.contains("Report anything you could not verify"))
        XCTAssertEqual(
            AgentInstructionsStarter.boundaries.appending(to: ""),
            AgentInstructionsStarter.boundaries.document
        )
    }

    func testInspectorWidthIsClampedToTheUsableRange() {
        XCTAssertEqual(AppSettings.clampInspectorWidth(0), 280)
        XCTAssertEqual(AppSettings.clampInspectorWidth(9999), 520)
        XCTAssertEqual(AppSettings.clampInspectorWidth(400), 400)
        XCTAssertEqual(AppSettings.clampInspectorWidth(.nan), 340, "a corrupt value must not survive")
    }

    func testSidebarWidthClampsPreferenceAndRenderedGeometryIndependently() throws {
        XCTAssertEqual(AppSettings.clampSidebarWidth(0), 220)
        XCTAssertEqual(AppSettings.clampSidebarWidth(9999), 420)
        XCTAssertEqual(AppSettings.clampSidebarWidth(310), 310)
        XCTAssertEqual(AppSettings.clampSidebarWidth(.nan), 260)
        XCTAssertEqual(AppSettings.renderedSidebarWidth(380, availableWidth: 295), 295)
        XCTAssertEqual(AppSettings.renderedSidebarWidth(380, availableWidth: 800), 380)

        var settings = AppSettings()
        settings.sidebarWidth = 375
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.sidebarWidth, 375)
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).sidebarWidth,
            260
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppSettings.self, from: Data(#"{"sidebarWidth":900}"#.utf8)
            ).sidebarWidth,
            420
        )
    }

    func testSoloSwarmClassificationUsesManifestAndLegacyWorkerAttempts() throws {
        func decodeRun(_ extra: String) throws -> OrchestrationRun {
            let json = """
            {
              "id":"run-1","state":"completed","request":"Inspect",
              "created_at":1,"updated_at":2,"last_seq":0,
              "pinned":false,"legacy":false,"recoverable":false,
              "run_kind":"solo"\(extra)
            }
            """
            return try JSONDecoder().decode(OrchestrationRun.self, from: Data(json.utf8))
        }

        let explicit = try decodeRun(",\"manifest\":{\"solo_swarm\":true}")
        let neverDelegated = try decodeRun(",\"manifest\":{\"solo_swarm\":true},\"attempts\":[]")
        let ordinary = try decodeRun("")
        let legacy = try decodeRun("""
        ,"attempts":[{"run_id":"run-1","job_id":"worker-1","attempt":1,
        "attempt_id":"worker-1:1","state":"completed","goal":"Inspect API"}]
        """)

        XCTAssertTrue(explicit.isSoloSwarm)
        XCTAssertTrue(neverDelegated.isSoloSwarm)
        XCTAssertFalse(ordinary.isSoloSwarm)
        XCTAssertTrue(legacy.isSoloSwarm)
        XCTAssertTrue(RunScope.soloSwarm.includes(explicit))
        XCTAssertFalse(RunScope.teams.includes(explicit))
        XCTAssertTrue(RunScope.all.includes(ordinary))

        // Eligibility keeps the Solo scope; delegation needs real evidence
        // (job_count in the list payload, attempts in the detail payload).
        let counted = try decodeRun(",\"manifest\":{\"solo_swarm\":true},\"job_count\":3")
        XCTAssertFalse(explicit.didDelegateWorkers)
        XCTAssertFalse(neverDelegated.didDelegateWorkers)
        XCTAssertFalse(ordinary.didDelegateWorkers)
        XCTAssertTrue(legacy.didDelegateWorkers)
        XCTAssertTrue(counted.didDelegateWorkers)
    }

    func testZoomedChatWidthIsClampedToTheUsableRange() {
        XCTAssertEqual(AppSettings.clampZoomedChatWidth(0), 360)
        XCTAssertEqual(AppSettings.clampZoomedChatWidth(9999), 600)
        XCTAssertEqual(AppSettings.clampZoomedChatWidth(480), 480)
        XCTAssertEqual(AppSettings.clampZoomedChatWidth(.nan), 420, "a corrupt value must not survive")
    }

    func testAppearanceSettingsRoundTripAndResolveColorSchemes() throws {
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)

        for appearance in AppAppearance.allCases {
            var settings = AppSettings()
            settings.appearanceRaw = appearance.rawValue
            let restored = try JSONDecoder().decode(
                AppSettings.self,
                from: JSONEncoder().encode(settings)
            )
            XCTAssertEqual(restored.resolvedAppearance, appearance)
        }
    }

    func testAppearanceDefaultsLegacyAndUnknownSettingsToSystem() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.resolvedAppearance, .system)

        let future = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"appearanceRaw":"midnight-blue"}"#.utf8)
        )
        XCTAssertEqual(future.resolvedAppearance, .system)
    }

    func testAccentOffersSevenPresetsAndAnOpenEndedCustomColour() throws {
        XCTAssertEqual(LocusAccentPreset.allCases.count, 7)
        XCTAssertEqual(LocusAccentPreset.allCases.map(\.title), [
            "Lime", "Green", "Blue", "Purple", "Orange", "Pink", "Neutral",
        ])

        assertColor(
            LocusAccentSelection(
                rawValue: LocusAccentPreset.green.rawValue,
                customHex: LocusAccentSelection.defaultCustomHex
            ).fillNSColor,
            hex: 0x2F7D4C
        )
        assertColor(
            LocusAccentSelection(
                rawValue: LocusAccentPreset.neutral.rawValue,
                customHex: LocusAccentSelection.defaultCustomHex
            ).fillNSColor,
            hex: 0xD4D5D2
        )

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.resolvedAccent.preset, .lime)

        let future = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"accentPresetRaw":"future-neon"}"#.utf8)
        )
        XCTAssertEqual(future.resolvedAccent.preset, .lime)

        var settings = AppSettings()
        settings.accentPresetRaw = LocusAccentSelection.customRawValue
        settings.customAccentHex = "#123456"
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertNil(restored.resolvedAccent.preset)
        XCTAssertEqual(restored.resolvedAccent.customHex, "123456")
        assertColor(restored.resolvedAccent.fillNSColor, hex: 0x123456)
    }

    func testAccentForegroundsStayReadableAndLogoRendererKeepsItsGeometry() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightBackground = NSColor(srgbRed: 0.953, green: 0.945, blue: 0.918, alpha: 1)
        let darkBackground = NSColor(srgbRed: 0.090, green: 0.090, blue: 0.075, alpha: 1)
        var renderedLogoAccents: Set<String> = []

        for preset in LocusAccentPreset.allCases {
            let accent = LocusAccentSelection(
                rawValue: preset.rawValue,
                customHex: LocusAccentSelection.defaultCustomHex
            )
            assertTextContrast(
                foregrounds: [accent.actionNSColor(for: light)],
                backgrounds: [lightBackground]
            )
            assertTextContrast(
                foregrounds: [accent.actionNSColor(for: dark)],
                backgrounds: [darkBackground]
            )
            XCTAssertEqual(
                LocusBrandIcon.image(accent: accent.logoNSColor, size: 128).size,
                NSSize(width: 128, height: 128)
            )
            let image = LocusBrandIcon.image(accent: accent.logoNSColor, size: 128)
            let data = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let sampledAccent = try XCTUnwrap(
                bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 14 / 128)
            )
            renderedLogoAccents.insert(try XCTUnwrap(
                LocusAccentSelection.hexString(for: sampledAccent)
            ))
        }
        XCTAssertEqual(
            renderedLogoAccents.count,
            LocusAccentPreset.allCases.count,
            "Each newly selected accent must produce visibly distinct logo artwork"
        )
    }

    func testAccentThemeColorsRefreshInsteadOfKeepingTheFirstSelection() throws {
        let previous = LocusAccentRuntime.shared.currentSelection()
        defer { LocusAccentRuntime.shared.configure(previous) }
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lime = LocusAccentSelection(
            rawValue: LocusAccentPreset.lime.rawValue,
            customHex: LocusAccentSelection.defaultCustomHex
        )
        let pink = LocusAccentSelection(
            rawValue: LocusAccentPreset.pink.rawValue,
            customHex: LocusAccentSelection.defaultCustomHex
        )

        // A colour read while lime was selected outlives that selection: SwiftUI
        // hands it to a view node that may not be re-evaluated for a long time.
        // It has to resolve to the accent in force when it is *drawn*, or that
        // node keeps painting an accent the customer has already changed.
        LocusAccentRuntime.shared.configure(lime)
        let heldFill = LocusTheme.signal
        let heldAction = LocusTheme.signalDeep
        LocusAccentRuntime.shared.configure(pink)
        let freshFill = LocusTheme.signal
        let freshAction = LocusTheme.signalDeep

        var resolvedHeldFill: NSColor?
        var resolvedHeldAction: NSColor?
        var resolvedFreshFill: NSColor?
        var resolvedFreshAction: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedHeldFill = NSColor(heldFill)
            resolvedHeldAction = NSColor(heldAction)
            resolvedFreshFill = NSColor(freshFill)
            resolvedFreshAction = NSColor(freshAction)
        }

        assertColor(try XCTUnwrap(resolvedHeldFill), hex: 0xFF5FA2)
        assertColor(try XCTUnwrap(resolvedFreshFill), hex: 0xFF5FA2)
        XCTAssertEqual(
            LocusAccentSelection.hexString(for: try XCTUnwrap(resolvedHeldAction)),
            LocusAccentSelection.hexString(for: try XCTUnwrap(resolvedFreshAction)),
            "A colour held across an accent change must resolve to the current accent"
        )

        // Each read still produces a distinct value, so a view body that *is*
        // re-evaluated registers the change rather than being diffed away.
        XCTAssertNotEqual(freshFill, heldFill)
        XCTAssertNotEqual(freshAction, heldAction)
    }

    @MainActor
    func testAssistantOutputMarkerRendersTheSelectedAccent() throws {
        func sampledAccent(_ preset: LocusAccentPreset) throws -> String {
            let accent = LocusAccentSelection(
                rawValue: preset.rawValue,
                customHex: LocusAccentSelection.defaultCustomHex
            )
            let renderer = ImageRenderer(content: LocusMessageMarker(accent: accent))
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(width: 20, height: 20)
            let image = try XCTUnwrap(renderer.nsImage)
            let data = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let color = try XCTUnwrap(bitmap.colorAt(x: 3, y: 10))
            return try XCTUnwrap(LocusAccentSelection.hexString(for: color))
        }

        XCTAssertNotEqual(
            try sampledAccent(.blue),
            try sampledAccent(.pink),
            "The icon beside completed assistant output must redraw for the selected accent"
        )
    }

    func testLegacySettingsLevelKeyIsIgnored() throws {
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"settingsLevelRaw":"advanced"}"#.utf8)
        )
        XCTAssertEqual(restored.backendURL, AppSettings().backendURL)
        XCTAssertEqual(restored.appearanceRaw, AppSettings().appearanceRaw)
        XCTAssertEqual(restored.provider, AppSettings().provider)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(restored), encoding: .utf8))
        XCTAssertFalse(encoded.contains("settingsLevelRaw"))
    }

    func testSettingsPagesUseTheExpectedGroupsAndDisclosureLevels() {
        XCTAssertEqual(
            SettingsPage.allCases.filter { $0.navigationGroup == .app },
            [.general, .appearance, .chat]
        )
        XCTAssertEqual(
            SettingsPage.allCases.filter { $0.navigationGroup == .models },
            [.accounts, .agents, .knowledge]
        )
        XCTAssertEqual(
            SettingsPage.allCases.filter { $0.navigationGroup == .tools },
            [.browser, .wallet, .extensions, .permissions, .network]
        )
        XCTAssertEqual(
            SettingsPage.allCases.filter { $0.navigationGroup == .system },
            [.developer, .updates, .shortcuts]
        )
        XCTAssertTrue(SettingsPage.allCases.contains(.developer))
    }

    func testSettingsSearchMetadataIsUniqueAndIndexesAdvancedControls() {
        let descriptors = SettingsSearchDescriptor.all
        XCTAssertEqual(Set(descriptors.map(\.id)).count, descriptors.count)
        XCTAssertEqual(Set(descriptors.map(\.anchor)).count, descriptors.count)

        let contextResult = try? XCTUnwrap(
            descriptors.first { $0.id == "settings.localContextWindow" }
        )
        XCTAssertEqual(contextResult?.isAdvanced, true)
        XCTAssertEqual(contextResult?.page, .accounts)
        XCTAssertTrue(contextResult?.matches("tokens") == true)
        XCTAssertTrue(
            descriptors.filter { $0.matches("diagnostics") }
                .allSatisfy { $0.isAdvanced }
        )
    }

    func testProviderBrandIdentityResolvesKnownAndCustomProviders() {
        XCTAssertEqual(
            ProviderBrandIdentity.resolve(name: "Claude Max").id,
            .anthropic
        )
        XCTAssertEqual(
            ProviderBrandIdentity.resolve(
                name: "Custom endpoint",
                url: "https://example.endpoints.huggingface.cloud"
            ).id,
            .huggingFace
        )
        XCTAssertEqual(
            ProviderBrandIdentity.resolve(name: "Local LM Studio").id,
            .lmStudio
        )
        XCTAssertEqual(
            ProviderBrandIdentity.resolve(name: "test vllm").id,
            .vLLM
        )

        let first = ProviderBrandIdentity.resolve(name: "Acme inference")
        let second = ProviderBrandIdentity.resolve(name: "Acme inference")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, .custom)
        XCTAssertEqual(first.fallbackMonogram, "AI")
    }

    func testSettingsMutationPolicyStagesOnlyRiskyPages() {
        XCTAssertEqual(SettingsPage.network.mutationPolicy, .staged)
        XCTAssertEqual(SettingsPage.accounts.mutationPolicy, .staged)
        XCTAssertEqual(SettingsPage.developer.mutationPolicy, .staged)
        XCTAssertTrue(
            SettingsPage.allCases
                .filter { ![.network, .accounts, .developer].contains($0) }
                .allSatisfy { $0.mutationPolicy == .immediate }
        )

        var saved = AppSettings()
        var draft = saved
        draft.appearanceRaw = AppAppearance.dark.rawValue
        draft.accentPresetRaw = LocusAccentPreset.purple.rawValue
        draft.previewURL = "https://preview.example"
        draft.proxyModeRaw = ProxyMode.manual.rawValue
        draft.proxyHost = "proxy.example"
        draft.backendURL = "http://127.0.0.1:9999"
        draft.localContextWindow = 65_536

        saved.applyImmediatePreferences(from: draft)

        XCTAssertEqual(saved.resolvedAppearance, .dark)
        XCTAssertEqual(saved.resolvedAccent.preset, .purple)
        XCTAssertEqual(saved.previewURL, "https://preview.example")
        XCTAssertEqual(saved.resolvedProxyMode, .off)
        XCTAssertTrue(saved.proxyHost.isEmpty)
        XCTAssertEqual(saved.backendURL, AppSettings().backendURL)
        XCTAssertNil(saved.localContextWindow)
    }

    func testThemePaletteResolvesWarmLightAndDarkColors() throws {
        let light = LocusTheme.palette(for: try XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = LocusTheme.palette(for: try XCTUnwrap(NSAppearance(named: .darkAqua)))

        assertColor(light.ink, red: 0.086, green: 0.094, blue: 0.078)
        assertColor(light.paper, red: 0.953, green: 0.945, blue: 0.918)
        assertColor(dark.ink, hex: 0xF2EEE4)
        assertColor(dark.paper, hex: 0x171713)
        assertColor(dark.white, hex: 0x292820)
        assertColor(dark.signalDeep, hex: 0xB6E33B)
        assertColor(dark.coral, hex: 0xF18364)
        assertColor(dark.permissionInk, hex: 0xD7A77E)
    }

    func testComposerScheduleSymbolExistsOnSupportedMacOS() {
        XCTAssertNotNil(
            NSImage(
                systemSymbolName: ComposerSymbols.schedule,
                accessibilityDescription: "Schedule"
            )
        )
    }

    func testSemanticTextColorsMeetNormalTextContrastAcrossPaperSurfaces() throws {
        let light = LocusTheme.palette(for: try XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = LocusTheme.palette(for: try XCTUnwrap(NSAppearance(named: .darkAqua)))

        assertTextContrast(
            foregrounds: [
                light.ink, light.inkSoft, light.muted, light.signalDeep,
                light.coral, light.danger, light.success, light.warning,
            ],
            backgrounds: [light.paper, light.paperDeep, light.panel, light.white]
        )
        assertTextContrast(
            foregrounds: [
                dark.ink, dark.inkSoft, dark.muted, dark.signalDeep,
                dark.coral, dark.danger, dark.success, dark.warning,
            ],
            backgrounds: [dark.paper, dark.paperDeep, dark.panel, dark.white]
        )
    }

    func testIncreasedContrastBoundariesMeetNonTextContrast() throws {
        let light = LocusTheme.palette(for: try XCTUnwrap(NSAppearance(named: .aqua)))
        let dark = LocusTheme.palette(for: try XCTUnwrap(NSAppearance(named: .darkAqua)))

        for surface in [light.paper, light.paperDeep, light.panel, light.white] {
            XCTAssertGreaterThanOrEqual(contrastRatio(light.lineStrong, surface), 3)
        }
        for surface in [dark.paper, dark.paperDeep, dark.panel, dark.white] {
            XCTAssertGreaterThanOrEqual(contrastRatio(dark.lineStrong, surface), 3)
        }
    }

    func testReduceMotionDisablesSpatialMotion() {
        XCTAssertFalse(LocusMotion.allowsSpatialMotion(reduceMotion: true))
        XCTAssertTrue(LocusMotion.allowsSpatialMotion(reduceMotion: false))
    }

    func testRecommendationsRankRecoveryBeforeSafetyAndContinuity() {
        let recommendations = RecommendationEngine.recommendations(for: RecommendationContext(
            runtimeUnavailable: true,
            modelUnavailable: true,
            lastRunFailed: true,
            changedFileCount: 4,
            hasPendingPlanSteps: true,
            hasTestFiles: true,
            projectKind: .swift,
            memoryConflictCount: 2
        ))

        XCTAssertEqual(recommendations.map(\.kind), [.chooseModel, .recoverRun, .reviewMemory])
        XCTAssertEqual(recommendations.count, 3)
        XCTAssertEqual(recommendations.first?.intent, .openSettings(.accounts))
        XCTAssertTrue(recommendations.allSatisfy { !$0.rationale.isEmpty })
    }

    func testRecommendationsRankSafetyContinuityAndVerification() {
        let recommendations = RecommendationEngine.recommendations(for: RecommendationContext(
            changedFileCount: 3,
            hasPendingPlanSteps: true,
            hasTestFiles: true,
            projectKind: .swift
        ))

        XCTAssertEqual(recommendations.map(\.kind), [.reviewChanges, .continuePlan, .verifyTests])
        XCTAssertEqual(recommendations[0].intent, .openInspector(.changes))
        guard case .prefill = recommendations[1].intent else {
            return XCTFail("Continuity work should remain editable before it is sent")
        }
    }

    func testLegacyRecommendationsAreDeduplicatedAndRemainFallbacks() {
        let recommendations = RecommendationEngine.recommendations(for: RecommendationContext(
            projectKind: .python,
            legacySuggestions: ["  Check retry paths  ", "Check another legacy item", ""]
        ))

        XCTAssertEqual(recommendations.map(\.kind), [.legacy, .exploreProject, .makePlan])
        XCTAssertEqual(recommendations.first?.title, "Check retry paths")
        XCTAssertEqual(recommendations.filter { $0.kind == .legacy }.count, 1)
        XCTAssertEqual(Set(recommendations.map(\.id)).count, recommendations.count)
    }

    @MainActor
    func testActivatingAgentRecommendationOnlyPrefillsTheComposer() {
        let model = AppModel(startImmediately: false)
        let messageCount = model.blocks.count
        let recommendation = LocusRecommendation(
            id: "prefill-test",
            kind: .verifyTests,
            title: "Run relevant tests",
            rationale: "The workspace contains changes.",
            priority: 1,
            intent: .prefill("Run the tests relevant to these changes.")
        )

        model.activateRecommendation(recommendation)

        XCTAssertEqual(model.draftText, "Run the tests relevant to these changes.")
        XCTAssertEqual(model.blocks.count, messageCount, "Prefill must never send a message")
        XCTAssertTrue(model.inspectorCollapsed)
    }

    func testEmptyWorkspaceRecommendationsAreStableProjectAwareAndCapped() {
        let first = RecommendationEngine.recommendations(for: RecommendationContext(projectKind: .web))
        let second = RecommendationEngine.recommendations(for: RecommendationContext(projectKind: .web))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.map(\.kind), [.exploreProject, .makePlan, .polishInterface])
        XCTAssertEqual(first.first?.title, "Polish the primary interface")
        XCTAssertTrue(first.allSatisfy { !$0.title.isEmpty && !$0.rationale.isEmpty })
    }

    func testEveryInspectorTabTitleIsWhiteInDarkAppearance() {
        for selected in [false, true] {
            assertColor(
                InspectorTabAppearance.titleColor(
                    colorScheme: .dark,
                    selected: selected
                ),
                red: 1,
                green: 1,
                blue: 1
            )
        }
    }

    func testWorkspaceFolderRetainsItsVisualAnchorMetrics() {
        XCTAssertEqual(SidebarIconMetrics.workspaceIconSize, 22)
        XCTAssertEqual(SidebarIconMetrics.workspaceSymbolSize, 11)
    }

    private func assertColor(
        _ color: NSColor,
        hex: UInt32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertColor(
            color,
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            file: file,
            line: line
        )
    }

    private func assertColor(
        _ color: NSColor,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let resolved = color.usingColorSpace(.sRGB) else {
            XCTFail("Color did not resolve into sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(resolved.redComponent, red, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, green, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, blue, accuracy: 0.0001, file: file, line: line)
    }

    private func assertTextContrast(
        foregrounds: [NSColor],
        backgrounds: [NSColor],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for foreground in foregrounds {
            for background in backgrounds {
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(foreground, background),
                    4.5,
                    file: file,
                    line: line
                )
            }
        }
    }

    private func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let resolved = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(resolved.redComponent)
            + 0.7152 * linear(resolved.greenComponent)
            + 0.0722 * linear(resolved.blueComponent)
    }

    func testInspectorChromeSurvivesASettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.inspectorWidth = 412
        settings.inspectorZoomedChatWidth = 480
        settings.inspectorCollapsed = true
        settings.inspectorLastTab = InspectorTab.terminal.rawValue
        settings.inspectorLastWorkspaceTab = InspectorTab.files.rawValue
        settings.inspectorOpenTabs = [
            InspectorTab.files.rawValue,
            InspectorTab.terminal.rawValue,
        ]
        settings.soloPlanPresentationRaw = AutomaticInspectorPresentation.always.rawValue
        settings.teamRunsPresentationRaw = AutomaticInspectorPresentation.never.rawValue

        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.inspectorWidth, 412)
        XCTAssertEqual(restored.inspectorZoomedChatWidth, 480)
        XCTAssertTrue(restored.inspectorCollapsed)
        XCTAssertEqual(restored.resolvedInspectorTab, .terminal)
        XCTAssertEqual(restored.resolvedInspectorWorkspaceTab, .files)
        XCTAssertEqual(restored.resolvedInspectorOpenTabs, [.files, .terminal])
        XCTAssertEqual(restored.resolvedSoloPlanPresentation, .always)
        XCTAssertEqual(restored.resolvedTeamRunsPresentation, .never)
    }

    func testStoredInspectorTabsDropUnknownValuesAndDuplicatesInOrder() throws {
        let stored = #"{"inspectorOpenTabs":["files","quantum","files","plan","runs"]}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(stored.utf8))

        XCTAssertEqual(restored.resolvedInspectorOpenTabs, [.files, .plan, .runs])
        XCTAssertEqual(restored.inspectorOpenTabs, ["files", "plan", "runs"])
    }

    func testStoredCheckpointTabMigratesOutOfInspectorRestoration() throws {
        let stored = #"{"inspectorLastTab":"checkpoints","inspectorOpenTabs":["checkpoints","files"]}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(stored.utf8))

        XCTAssertEqual(restored.resolvedInspectorTab, .plan)
        XCTAssertEqual(restored.resolvedInspectorOpenTabs, [.files])
    }

    func testInspectorRestorationKeepsAValidSelectionOrUsesTheFirstOpenTab() throws {
        let valid = #"{"inspectorLastTab":"runs","inspectorOpenTabs":["files","runs"]}"#
        let validRestored = try JSONDecoder().decode(AppSettings.self, from: Data(valid.utf8))
        XCTAssertEqual(validRestored.resolvedRestoredInspectorTab, .runs)

        let missing = #"{"inspectorLastTab":"plan","inspectorOpenTabs":["files","runs"]}"#
        let missingRestored = try JSONDecoder().decode(AppSettings.self, from: Data(missing.utf8))
        XCTAssertEqual(missingRestored.resolvedRestoredInspectorTab, .files)
    }

    func testLegacyInspectorSettingsSeedThePreviouslyRestoredWorkspacePanel() throws {
        let legacy = #"{"inspectorLastTab":"preview","inspectorLastWorkspaceTab":"files"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        XCTAssertEqual(restored.resolvedInspectorOpenTabs, [.files])
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
        XCTAssertEqual(
            restored.inspectorZoomedChatWidth, 420,
            "payloads from before the zoom feature decode to its default"
        )
        XCTAssertTrue(restored.inspectorCollapsed, "the right panel starts collapsed")
        XCTAssertEqual(restored.resolvedInspectorTab, .plan)
        XCTAssertEqual(restored.resolvedInspectorWorkspaceTab, .changes)
        XCTAssertEqual(restored.resolvedInspectorOpenTabs, [.changes])
        XCTAssertEqual(restored.resolvedSoloPlanPresentation, .ask)
        XCTAssertEqual(restored.resolvedTeamRunsPresentation, .ask)
        XCTAssertFalse(restored.sidebarCollapsed, "the session sidebar starts open")
    }

    func testLegacyMessageShortcutSettingsAreIgnoredAndDropped() throws {
        let legacy = #"{"enterSendsMessages":false,"sendShortcutPreferenceConfigured":true,"previewURL":"http://legacy.example"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(restored.previewURL, "http://legacy.example")

        let rewritten = String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
        XCTAssertFalse(rewritten.contains("enterSendsMessages"))
        XCTAssertFalse(rewritten.contains("sendShortcutPreferenceConfigured"))
    }

    func testTerminalSettingsSurviveRoundTripAndOlderSettingsRequestMigration() throws {
        let older = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(older.terminalSettingsMigrated)

        var settings = AppSettings()
        settings.terminalShell = "/bin/zsh"
        settings.terminalLoginShell = false
        settings.terminalSettingsMigrated = true
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.terminalShell, "/bin/zsh")
        XCTAssertFalse(restored.terminalLoginShell)
        XCTAssertTrue(restored.terminalSettingsMigrated)
    }

    func testCombinedInspectorPreferenceMigratesToSoloAndTeamChoices() throws {
        let legacy = #"{"automaticInspectorPresentationRaw":"always"}"#
        let restored = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        XCTAssertEqual(restored.resolvedSoloPlanPresentation, .always)
        XCTAssertEqual(restored.resolvedTeamRunsPresentation, .always)
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

    func testProxyProfilesRoutingAndSafetySettingsSurviveARoundTrip() throws {
        let standby = ProxyProfile(
            name: "Toronto standby",
            type: .socks5,
            host: "standby.proxy",
            port: 1080,
            bypass: "*.internal",
            username: "proxy-user"
        )
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "primary.proxy"
        settings.proxyPort = 3128
        settings.proxyProfiles = [standby]
        settings.proxyActiveProfileID = standby.id.uuidString
        settings.proxyStrictModeEnabled = true
        settings.proxyAutoFailoverEnabled = true
        settings.proxyScopeProfileIDs = [
            ProxyTrafficScope.browser.rawValue: standby.id.uuidString,
        ]
        settings.proxyWorkspaceProfileIDs = ["/tmp/work": standby.id.uuidString]
        settings.proxyProviderProfileIDs = ["provider-id": standby.id.uuidString]

        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )

        XCTAssertEqual(restored.proxyProfiles, [standby])
        XCTAssertEqual(restored.proxyActiveProfileID, standby.id.uuidString)
        XCTAssertTrue(restored.proxyStrictModeEnabled)
        XCTAssertTrue(restored.proxyAutoFailoverEnabled)
        XCTAssertEqual(
            restored.proxyScopeProfileIDs[ProxyTrafficScope.browser.rawValue],
            standby.id.uuidString
        )
        XCTAssertEqual(restored.proxyWorkspaceProfileIDs["/tmp/work"], standby.id.uuidString)
        XCTAssertEqual(restored.proxyProviderProfileIDs["provider-id"], standby.id.uuidString)
    }

    func testProxyProfileSelectionUsesScopeThenProviderThenWorkspaceThenDefault() {
        let workspace = ProxyProfile(name: "Workspace", host: "workspace.proxy", port: 8001)
        let provider = ProxyProfile(name: "Provider", host: "provider.proxy", port: 8002)
        let scope = ProxyProfile(name: "Browser", host: "browser.proxy", port: 8003)
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "default.proxy"
        settings.proxyPort = 8000
        settings.proxyProfiles = [workspace, provider, scope]
        settings.proxyWorkspaceProfileIDs = ["/tmp/project": workspace.id.uuidString]
        settings.proxyProviderProfileIDs = ["provider": provider.id.uuidString]
        settings.proxyScopeProfileIDs = [
            ProxyTrafficScope.browser.rawValue: scope.id.uuidString,
        ]

        XCTAssertEqual(
            ProxyConfigurator.selectedProfile(
                settings: settings,
                scope: .browser,
                workspacePath: "/tmp/project",
                providerAccountID: "provider"
            )?.id,
            scope.id
        )
        settings.proxyScopeProfileIDs = [:]
        XCTAssertEqual(
            ProxyConfigurator.selectedProfile(
                settings: settings,
                scope: .browser,
                workspacePath: "/tmp/project",
                providerAccountID: "provider"
            )?.id,
            provider.id
        )
        settings.proxyProviderProfileIDs = [:]
        XCTAssertEqual(
            ProxyConfigurator.selectedProfile(
                settings: settings,
                scope: .browser,
                workspacePath: "/tmp/project"
            )?.id,
            workspace.id
        )
        settings.proxyWorkspaceProfileIDs = [:]
        XCTAssertEqual(
            ProxyConfigurator.selectedProfile(settings: settings, scope: .browser)?.id,
            ProxyProfile.primaryID
        )
    }

    func testStrictTunnelIgnoresCustomBypassAndBlocksAnIncompleteRoute() {
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "strict.proxy"
        settings.proxyPort = 3128
        settings.proxyBypass = "*.example.com, 10.0.0.1"
        settings.proxyStrictModeEnabled = true

        let resolved = ProxyConfigurator.resolved(
            settings: settings,
            password: nil,
            ollamaHost: "http://192.168.1.30:11434"
        )
        XCTAssertEqual(
            resolved?.bypass,
            ["localhost", "127.0.0.1", "::1", "192.168.1.30"]
        )

        settings.proxyHost = ""
        settings.proxyPort = nil
        let runtime = ProxyRuntime()
        runtime.update(settings: settings, password: nil)
        XCTAssertEqual(runtime.current?.isBlocking, true)
        XCTAssertEqual(runtime.current?.host, "127.0.0.1")
        XCTAssertEqual(runtime.current?.port, 1)
    }

    func testProxyFailoverSelectsTheFastestHealthyProfileAndBlocksWhenExhausted() {
        let standby = ProxyProfile(
            name: "Standby", type: .socks5, host: "standby.proxy", port: 1080
        )
        var settings = AppSettings()
        settings.proxyModeRaw = ProxyMode.manual.rawValue
        settings.proxyHost = "primary.proxy"
        settings.proxyPort = 3128
        settings.proxyProfiles = [standby]
        settings.proxyAutoFailoverEnabled = true
        let runtime = ProxyRuntime()
        runtime.update(settings: settings, password: nil)

        runtime.applyHealthSnapshotForTesting([
            ProxyHealthRecord(
                profileID: ProxyProfile.primaryID,
                profileName: "Default",
                ok: false,
                latencyMilliseconds: nil,
                exitIP: nil,
                location: nil,
                message: "Down",
                checkedAt: Date()
            ),
            ProxyHealthRecord(
                profileID: standby.id,
                profileName: standby.name,
                ok: true,
                latencyMilliseconds: 42,
                exitIP: "203.0.113.7",
                location: "CA",
                message: "Healthy",
                checkedAt: Date()
            ),
        ])
        XCTAssertEqual(runtime.current?.profileID, standby.id)
        XCTAssertEqual(runtime.current?.type, .socks5)

        runtime.applyHealthSnapshotForTesting([
            ProxyHealthRecord(
                profileID: ProxyProfile.primaryID,
                profileName: "Default",
                ok: false,
                latencyMilliseconds: nil,
                exitIP: nil,
                location: nil,
                message: "Down",
                checkedAt: Date()
            ),
            ProxyHealthRecord(
                profileID: standby.id,
                profileName: standby.name,
                ok: false,
                latencyMilliseconds: nil,
                exitIP: nil,
                location: nil,
                message: "Down",
                checkedAt: Date()
            ),
        ])
        XCTAssertEqual(runtime.current?.isBlocking, true)
    }

    func testEveryProxyProfileUsesAnIndependentCredentialEntry() {
        let additional = UUID()
        XCTAssertEqual(
            CredentialStore.proxyCredentialKey(profileID: ProxyProfile.primaryID),
            CredentialStore.proxyCredentialKey
        )
        XCTAssertEqual(
            CredentialStore.proxyCredentialKey(profileID: additional),
            "network-proxy-profile-\(additional.uuidString)"
        )
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

    func testGitStatusDecodesTrackingFieldsAndToleratesOldAgents() throws {
        let full = try JSONDecoder().decode(GitStatusResponse.self, from: Data("""
        {"ok": true, "is_repo": true, "branch": "ship-test", "ahead": 2,
         "behind": 1, "upstream": "origin/ship-test", "detached": false,
         "has_commits": true, "files": []}
        """.utf8))
        XCTAssertEqual(full.upstream, "origin/ship-test")
        XCTAssertFalse(full.detached)
        XCTAssertTrue(full.hasCommits)

        // An agent from before these fields were read: absent upstream stays
        // nil, and has_commits defaults to true so push/unstage is not hidden
        // behind a wrong guess.
        let older = try JSONDecoder().decode(GitStatusResponse.self, from: Data("""
        {"ok": true, "is_repo": true, "branch": "main", "files": []}
        """.utf8))
        XCTAssertNil(older.upstream)
        XCTAssertFalse(older.detached)
        XCTAssertTrue(older.hasCommits)
    }

    // MARK: - Terminal

    @MainActor
    func testTerminalColorsFollowActiveTheme() throws {
        let session = TerminalSession()
        session.updateAppearance(isDark: false)
        let view = try XCTUnwrap(session.hostView as? LocusLocalProcessTerminalView)

        assertColor(view.nativeBackgroundColor, red: 0.953, green: 0.945, blue: 0.918)
        assertColor(view.nativeForegroundColor, red: 0.086, green: 0.094, blue: 0.078)

        session.updateAppearance(isDark: true)
        assertColor(view.nativeBackgroundColor, hex: 0x171713)
        assertColor(view.nativeForegroundColor, hex: 0xF2EEE4)
    }

    @MainActor
    func testNativeTerminalOwnsAPersistentPTY() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("locus-terminal-\(UUID().uuidString)", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = TerminalSession()
        session.configure(workspacePath: root.path, shell: "/bin/zsh", loginShell: false)
        let view = try XCTUnwrap(session.hostView as? LocusLocalProcessTerminalView)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        session.ensureStarted()
        defer { session.terminate() }
        XCTAssertTrue(session.isRunning)
        XCTAssertGreaterThan(view.process.shellPid, 0)

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            view.send(data: bytes[...])
        }
        func waitForFile(_ url: URL) async -> String? {
            for _ in 0..<100 {
                if let value = try? String(contentsOf: url, encoding: .utf8) {
                    return value
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return nil
        }

        let environment = root.appendingPathComponent("environment.txt")
        let environmentPending = root.appendingPathComponent("environment.pending")
        send("printf '%s|%s|' \"$TERM\" \"$COLORTERM\" > '\(environmentPending.path)'; tty >> '\(environmentPending.path)'; mv '\(environmentPending.path)' '\(environment.path)'\n")
        let environmentResult = await waitForFile(environment)
        let environmentValue = try XCTUnwrap(environmentResult)
        XCTAssertTrue(environmentValue.hasPrefix("xterm-256color|truecolor|"))
        XCTAssertTrue(environmentValue.contains("/dev/"))

        send("cd child\n")
        let location = root.appendingPathComponent("location.txt")
        send("pwd > '\(location.path)'\n")
        let locationResult = await waitForFile(location)
        let reportedLocation = URL(
            fileURLWithPath: try XCTUnwrap(locationResult)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ).resolvingSymlinksInPath().path
        XCTAssertEqual(
            reportedLocation,
            child.resolvingSymlinksInPath().path
        )
        for _ in 0..<100 where URL(fileURLWithPath: session.currentDirectory)
            .resolvingSymlinksInPath().path != reportedLocation {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(
            URL(fileURLWithPath: session.currentDirectory).resolvingSymlinksInPath().path,
            reportedLocation
        )

        let size = root.appendingPathComponent("size.txt")
        let sizePending = root.appendingPathComponent("size.pending")
        send("stty size > '\(sizePending.path)' && mv '\(sizePending.path)' '\(size.path)'\n")
        let sizeResult = await waitForFile(size)
        let dimensions = try XCTUnwrap(sizeResult)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0) }
        XCTAssertEqual(dimensions.count, 2)
        XCTAssertGreaterThan(dimensions[0], 0)
        XCTAssertGreaterThan(dimensions[1], 0)

        send("printf '\u{1B}[38;2;1;2;3mLOCUS-UNICODE-λ-界\u{1B}[0m\\n'\n")
        var rendered = ""
        for _ in 0..<100 {
            rendered = (0..<view.terminal.rows)
                .compactMap {
                    view.terminal.getLine(row: $0)?.translateToString(trimRight: true)
                }
                .joined(separator: "\n")
            if rendered.contains("LOCUS-UNICODE-λ-界") { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(rendered.contains("LOCUS-UNICODE-λ-界"))

        let interrupted = root.appendingPathComponent("interrupted.txt")
        send("sleep 30\n")
        try? await Task.sleep(for: .milliseconds(150))
        let controlC: [UInt8] = [3]
        view.send(data: controlC[...])
        send("printf interrupted > '\(interrupted.path)'\n")
        let interruptedResult = await waitForFile(interrupted)
        XCTAssertEqual(try XCTUnwrap(interruptedResult), "interrupted")
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
        XCTAssertTrue(restored.notifyOnNeedsAttention)

        let migrated = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"notifyOnCompletion":false}"#.utf8)
        )
        XCTAssertFalse(migrated.notifyOnCompletion)
        XCTAssertFalse(migrated.notifyOnNeedsAttention)
        XCTAssertTrue(restored.hiddenLocalModels.isEmpty)
    }

    func testHiddenLocalModelsRoundTripWithoutAffectingOllamaData() throws {
        var settings = AppSettings()
        settings.hiddenLocalModels = ["qwen3:8b", "hf.co/example/model:Q4_K_M"]

        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(restored.hiddenLocalModels, settings.hiddenLocalModels)
    }

    func testBrowserHasItsOwnSettingsDestination() {
        XCTAssertTrue(SettingsPage.allCases.contains(.browser))
        XCTAssertEqual(SettingsPage.browser.symbol, "globe")
        XCTAssertEqual(SettingsPage.browser.accessibilityKey, "browser")
    }

    func testLocalModelDeletionBuildsAnOllamaDeleteRequest() throws {
        let request = try LocalModelManagement.deleteRequest(
            ollamaHost: "http://127.0.0.1:11434/",
            model: "qwen3:8b"
        )

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/delete")
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(object, ["model": "qwen3:8b"])
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

    /// File permissions are the protection for locally stored secrets, so the
    /// app must create and maintain restrictive modes itself.
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
        XCTAssertEqual(restored[0].credentialAccount, CredentialStore.providerAccountKey(account.id))
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

    func testLegacyCodexAccountRemainsAnOpenAIAPIAccount() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","kindRaw":"codex","name":"Existing",
          "preferredModel":"gpt-5","createdAt":0}]
        """

        let account = try XCTUnwrap(ProviderAccountStore.decode(Data(json.utf8)).first)

        XCTAssertEqual(account.kind, .codex)
        XCTAssertEqual(account.kindRaw, "codex", "the stored raw value remains backward compatible")
        XCTAssertEqual(account.kind.marketingName, "OpenAI API")
        XCTAssertEqual(account.displayName, "OpenAI API — Existing")
        XCTAssertTrue(account.kind.requiresAPIKey)
    }

    func testChatGPTPlanIsASeparateManagedAccountKind() {
        let account = ProviderAccount(kind: .chatGPT, name: "Personal")

        XCTAssertEqual(account.kindRaw, "chatgpt")
        XCTAssertEqual(account.displayName, "ChatGPT plan — Personal")
        XCTAssertFalse(account.kind.requiresAPIKey)
        XCTAssertTrue(account.kind.usesManagedChatGPTAuthentication)
        XCTAssertFalse(account.kind.allowsBaseURLOverride)
    }

    func testCustomEndpointsWorkWithoutAStoredKey() {
        // A local llama.cpp / LM Studio server usually has no auth at all, so
        // the custom kind must be usable with no stored credential — while
        // hosted providers keep demanding theirs.
        let custom = ProviderAccount(kind: .custom, name: "Llama box")
        XCTAssertTrue(custom.kind.allowsEmptyAPIKey)
        XCTAssertTrue(custom.isCredentialReady)
        XCTAssertEqual(custom.kind.keyPlaceholder, "API key (optional)")

        let hosted = ProviderAccount(kind: .codex, name: "Work")
        XCTAssertFalse(hosted.kind.allowsEmptyAPIKey)
        XCTAssertFalse(hosted.isCredentialReady)
    }

    func testAccountStoredBeforeCodexNativeParityDecodesWithTheDefaults() throws {
        // An account written before the parity fields existed carries none of
        // them; the accessors supply parity on, web search off, default effort.
        let json = """
        [{"id":"\(UUID().uuidString)","kindRaw":"chatgpt","name":"Existing",
          "preferredModel":"gpt-5","createdAt":0}]
        """
        let account = try XCTUnwrap(ProviderAccountStore.decode(Data(json.utf8)).first)

        XCTAssertNil(account.codexNativeMode)
        XCTAssertNil(account.codexWebSearch)
        XCTAssertNil(account.codexReasoningEffort)
        XCTAssertTrue(account.codexNativeModeEnabled, "parity defaults to on")
        XCTAssertFalse(account.codexWebSearchEnabled, "web search stays opt-in")
        XCTAssertEqual(account.codexReasoningEffortValue, "", "empty means the model default")
    }

    func testNewChatGPTAccountStartsOnTheLocusContract() {
        // A ChatGPT account created now answers with Locus's prompt, tools,
        // memory, and skills. The value is stamped by the initialiser rather
        // than by the accessor's fallback, which is what lets the test above
        // keep its nil — an account added before this keeps answering as it did.
        let account = ProviderAccount(kind: .chatGPT, name: "New")

        XCTAssertEqual(account.codexNativeMode, false)
        XCTAssertFalse(account.codexNativeModeEnabled, "new accounts use Locus tools")
    }

    func testNonChatGPTAccountsCarryNoParityChoice() {
        // Parity is a ChatGPT-only contract; nothing should be stamped on the
        // other kinds, where the field has no meaning.
        let account = ProviderAccount(kind: .claude, name: "Work")

        XCTAssertNil(account.codexNativeMode)
    }

    func testCodexNativeParityFieldsRoundTrip() throws {
        var account = ProviderAccount(kind: .chatGPT, name: "Personal")
        account.codexNativeMode = false
        account.codexWebSearch = true
        account.codexReasoningEffort = "high"

        let data = try JSONEncoder().encode([account])
        let restored = try XCTUnwrap(ProviderAccountStore.decode(data).first)

        XCTAssertEqual(restored.codexNativeMode, false)
        XCTAssertEqual(restored.codexWebSearch, true)
        XCTAssertEqual(restored.codexReasoningEffort, "high")
        XCTAssertFalse(restored.codexNativeModeEnabled)
        XCTAssertTrue(restored.codexWebSearchEnabled)
        XCTAssertEqual(restored.codexReasoningEffortValue, "high")
    }

    func testChatGPTModelCatalogCarriesReasoningEfforts() throws {
        let json = """
        {"status":"ok","models":[
          {"id":"gpt-5.1-codex","display_name":"GPT-5.1 Codex","description":"Fast",
           "is_default":true,
           "supported_reasoning_efforts":[
             {"effort":"medium","description":"Balanced"},
             {"effort":"high"}],
           "default_reasoning_effort":"medium"},
          {"id":"gpt-5.1","display_name":"GPT-5.1","description":"General","is_default":false}
        ]}
        """
        let response = try JSONDecoder().decode(
            ChatGPTModelsResponse.self, from: Data(json.utf8)
        )

        XCTAssertEqual(response.models.count, 2)
        let codex = try XCTUnwrap(response.models.first)
        XCTAssertEqual(codex.supportedReasoningEfforts?.map(\.effort), ["medium", "high"])
        XCTAssertEqual(codex.supportedReasoningEfforts?.first?.description, "Balanced")
        XCTAssertNil(codex.supportedReasoningEfforts?.last?.description)
        XCTAssertEqual(codex.defaultReasoningEffort, "medium")
        // A backend that predates the fields must still decode.
        let plain = try XCTUnwrap(response.models.last)
        XCTAssertNil(plain.supportedReasoningEfforts)
        XCTAssertNil(plain.defaultReasoningEffort)
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
        XCTAssertEqual(account?.credentialAccount, CredentialStore.remoteAPIKeyAccount)
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

    func testProviderCatalogsRejectTransientTeamModelsFromOtherAccounts() {
        let kimi = ProviderAccount(
            kind: .kimiCode,
            preferredModel: "claude-sonnet-4-5"
        )
        let kimiModels = ProviderModelCatalog.scopedModels(
            for: kimi,
            result: .init(
                models: ["claude-sonnet-4-5"] + ProviderKind.kimiCode.curatedModels,
                status: .keySaved
            ),
            routedModels: ["kimi-for-coding-highspeed"]
        )
        XCTAssertFalse(kimiModels.contains("claude-sonnet-4-5"))
        XCTAssertTrue(kimiModels.contains("kimi-for-coding-highspeed"))

        let qwen = ProviderAccount(
            kind: .custom,
            name: "Qwen vLLM",
            baseURLOverride: "https://qwen.example/v1",
            preferredModel: "k3"
        )
        let qwenModels = ProviderModelCatalog.scopedModels(
            for: qwen,
            result: .init(models: ["k3"], status: .failed("endpoint is offline")),
            routedModels: ["/repository/Qwen3.6-27B.gguf"]
        )
        XCTAssertEqual(qwenModels, ["/repository/Qwen3.6-27B.gguf"])
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

    func testProviderFailuresPreserveUsefulVLLMDetailsAndRedactKeys() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "error": "Bad Request: The endpoint is paused for sk-private; ask a maintainer to restart it",
        ])

        let message = RemoteEndpointTester.failureMessage(
            status: 400,
            data: data,
            apiKey: "sk-private"
        )

        XCTAssertTrue(message.contains("rejected the request (400)"))
        XCTAssertTrue(message.contains("endpoint is paused"))
        XCTAssertFalse(message.contains("sk-private"))
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

    func testSessionExecutionEnvironmentDefaultsLegacyAndUnknownValuesToLocal() throws {
        let legacy = SessionSummary(
            id: "old", name: "old", preview: "", mtime: 0, size: 0
        )
        XCTAssertEqual(legacy.executionEnvironment, .local)

        let future = SessionSummary(
            id: "future", name: "future", preview: "", mtime: 0, size: 0,
            environment: ["type": "future_isolation"]
        )
        XCTAssertEqual(future.executionEnvironment, .local)

        let worktree = SessionSummary(
            id: "worktree", name: "worktree", preview: "", mtime: 0, size: 0,
            environment: ["type": "worktree", "worktree_id": "worktree"]
        )
        XCTAssertEqual(worktree.executionEnvironment, .worktree)
    }

    func testSessionInfoCopiesPreserveExecutionEnvironment() {
        let info = SessionInfo(
            model: "m", host: "h", cwd: "/tmp/private", session: "s", sessionID: "s",
            messages: 0, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            maxIterations: 40, hasProjectContext: false,
            environment: ["type": "worktree", "worktree_id": "s"],
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )

        XCTAssertEqual(info.replacingPermissions(info.permissions).environment?["type"], "worktree")
        XCTAssertEqual(info.replacingTask(nil).environment?["worktree_id"], "s")
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
            outcome: .maxIterations, mode: .work, durationMilliseconds: 1_000,
            iterationLimit: 5
        )
        XCTAssertEqual(named.title, "Iteration limit reached (5 steps)")

        let unknown = TurnCompletion(
            outcome: .maxIterations, mode: .work, durationMilliseconds: 1_000
        )
        XCTAssertEqual(unknown.title, "Iteration limit reached", "no number, no parenthetical")

        let finished = TurnCompletion(
            outcome: .complete, mode: .work, durationMilliseconds: 1_000
        )
        XCTAssertEqual(finished.title, "Work finished")

        let grilled = TurnCompletion(
            outcome: .complete, mode: .grill, durationMilliseconds: 1_000
        )
        XCTAssertEqual(grilled.title, "Grill finished")

        let teamBudget = TurnCompletion(
            outcome: .modelCallBudget, mode: .work, durationMilliseconds: 1_000,
            iterationLimit: 24
        )
        XCTAssertEqual(teamBudget.title, "Team call budget reached (24 calls)")
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
        XCTAssertTrue(restored[0].resolvedSoloSwarmEnabled)

        var updated = restored[0]
        updated.soloSwarmEnabled = true
        let roundTrip = try JSONDecoder().decode(
            WorkspaceProfile.self,
            from: JSONEncoder().encode(updated)
        )
        XCTAssertTrue(roundTrip.resolvedSoloSwarmEnabled)
    }

    func testWorkspaceProfilesFromBeforeReasoningEffortStillDecode() throws {
        let legacy = """
        [{"path":"/tmp/ws","lastOpened":0,"model":"claude-opus-5","mode":"build",
          "previewURL":"","contextFiles":[],"draft":""}]
        """
        let restored = try JSONDecoder().decode(
            [WorkspaceProfile].self,
            from: Data(legacy.utf8)
        )
        XCTAssertNil(restored[0].reasoningEffort, "no choice means the account's default")

        var updated = restored[0]
        updated.reasoningEffort = "xhigh"
        let roundTrip = try JSONDecoder().decode(
            WorkspaceProfile.self,
            from: JSONEncoder().encode(updated)
        )
        XCTAssertEqual(roundTrip.reasoningEffort, "xhigh")
    }

    func testPublishedReasoningEffortsCoverOnlyModelsThatAcceptThem() {
        // Effort is generally available across the Claude 5 family.
        XCTAssertEqual(
            ProviderKind.claude.publishedReasoningEfforts(for: "claude-opus-5"),
            ["low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(
            ProviderKind.claude.publishedReasoningEfforts(for: "claude-sonnet-5"),
            ["low", "medium", "high", "xhigh", "max"]
        )
        // Haiku rejects the parameter outright, so it gets no control at all
        // rather than a control that fails the turn.
        XCTAssertTrue(
            ProviderKind.claude.publishedReasoningEfforts(for: "claude-haiku-4-5").isEmpty
        )

        // OpenAI's reasoning models take an effort; the 4.1 line does not.
        XCTAssertEqual(
            ProviderKind.codex.publishedReasoningEfforts(for: "gpt-5.6"),
            ["minimal", "low", "medium", "high"]
        )
        XCTAssertEqual(
            ProviderKind.codex.publishedReasoningEfforts(for: "o3"),
            ["minimal", "low", "medium", "high"]
        )
        XCTAssertTrue(ProviderKind.codex.publishedReasoningEfforts(for: "gpt-4.1").isEmpty)

        // A ChatGPT plan reports its own efforts through the account catalog;
        // a static copy here could only go stale against it.
        XCTAssertTrue(
            ProviderKind.chatGPT.publishedReasoningEfforts(for: "gpt-5.3-codex").isEmpty
        )
        // Someone else's deployment, and an unknown model, get nothing.
        XCTAssertTrue(ProviderKind.custom.publishedReasoningEfforts(for: "anything").isEmpty)
        XCTAssertTrue(ProviderKind.kimi.publishedReasoningEfforts(for: "kimi-k3").isEmpty)
        XCTAssertTrue(
            ProviderKind.claude.publishedReasoningEfforts(for: "not-a-model").isEmpty
        )
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

    // MARK: - Plan panel presentation

    func testPlanPanelPhaseUsesAttentionAndRunStatePrecedence() {
        let pending = [TodoItem(content: "Inspect the panel", status: .pending)]
        let complete = [TodoItem(content: "Inspect the panel", status: .completed)]
        let stopped = TurnCompletion(
            outcome: .interrupted,
            mode: .work,
            durationMilliseconds: 2_000,
            iterationLimit: nil
        )

        XCTAssertEqual(
            planPhase(permission: true, approval: true, busy: true, mode: .plan, todos: pending),
            .waitingForPermission
        )
        XCTAssertEqual(
            planPhase(approval: true, busy: true, mode: .plan, todos: pending),
            .readyForApproval
        )
        XCTAssertEqual(planPhase(busy: true, mode: .plan), .planning)
        // Plan execution rides Work now: a busy Work turn holding todos is
        // following them; without todos it is just working.
        XCTAssertEqual(planPhase(busy: true, mode: .work, todos: pending), .executing)
        XCTAssertEqual(planPhase(busy: true, mode: .work), .working)
        XCTAssertEqual(planPhase(busy: true, mode: .grill, todos: pending), .working)
        XCTAssertEqual(planPhase(todos: complete), .completed)
        XCTAssertEqual(planPhase(todos: pending, completion: stopped), .stopped)
        XCTAssertEqual(
            planPhase(todos: complete, completion: stopped),
            .stopped,
            "an interrupted outcome takes precedence over completed step markers"
        )
        XCTAssertEqual(
            planPhase(
                todos: pending,
                completion: TurnCompletion(
                    outcome: .error,
                    mode: .work,
                    durationMilliseconds: 500,
                    iterationLimit: nil
                )
            ),
            .stopped
        )
        XCTAssertEqual(planPhase(todos: pending), .saved)
        XCTAssertEqual(planPhase(), .idle)
    }

    func testPlanWorkspaceBriefingSummarizesTheLiveRouteAndRepository() {
        let briefing = PlanWorkspaceBriefing.resolve(
            workspacePath: "/Users/example/Projects/locus",
            modelName: "Work · gpt-5.4",
            providerName: "OpenAI API",
            modelStatus: "Ready",
            contextWindowTokens: 400_000,
            isGitRepository: true,
            branch: "codex/plan-panel",
            changedFileCount: 3,
            gitChangeSummary: "1 staged · 2 modified",
            ahead: 2,
            behind: 1,
            indexedFileCount: 128,
            messageCount: 71
        )

        XCTAssertEqual(briefing.folderName, "locus")
        XCTAssertEqual(briefing.folderPath, "/Users/example/Projects/locus")
        XCTAssertEqual(briefing.repositoryDetail, "codex/plan-panel · 3 changed files · ↑2 · ↓1")
        XCTAssertEqual(briefing.modelName, "Work · gpt-5.4")
        XCTAssertTrue(briefing.modelDetail.contains("OpenAI API · Ready"))
        XCTAssertTrue(briefing.modelDetail.contains("400"))
        XCTAssertTrue(briefing.modelDetail.contains("token window"))
        XCTAssertEqual(briefing.activityTitle, "Workspace has unreviewed changes")
        XCTAssertEqual(
            briefing.activityDetail,
            "1 staged · 2 modified · 128 indexed files · 71 messages"
        )
    }

    func testPlanWorkspaceBriefingHandlesACleanNonGitFolder() {
        let briefing = PlanWorkspaceBriefing.resolve(
            workspacePath: "/tmp/notes",
            modelName: "qwen3:8b",
            providerName: "Local Ollama",
            modelStatus: "Starting",
            contextWindowTokens: nil,
            isGitRepository: false,
            branch: nil,
            changedFileCount: 0,
            gitChangeSummary: "No changes",
            ahead: 0,
            behind: 0,
            indexedFileCount: 1,
            messageCount: 1
        )

        XCTAssertEqual(briefing.repositoryDetail, "Git not detected")
        XCTAssertEqual(briefing.modelDetail, "Local Ollama · Starting")
        XCTAssertEqual(briefing.activityTitle, "Workspace indexed")
        XCTAssertEqual(briefing.activityDetail, "Ready for inspection · 1 indexed file · 1 message")
    }

    private func planPhase(
        permission: Bool = false,
        approval: Bool = false,
        busy: Bool = false,
        mode: WorkMode? = nil,
        todos: [TodoItem] = [],
        completion: TurnCompletion? = nil
    ) -> PlanPanelPhase {
        PlanPanelPresentation.resolve(
            hasPendingPermission: permission,
            planApprovalPending: approval,
            isBusy: busy,
            dispatchedMode: mode,
            todos: todos,
            latestCompletion: completion
        ).phase
    }

    // MARK: - Agent teams

    func testAgentBehaviorRoundTripsAndClampsEditableLimits() throws {
        var behavior = AgentBehavior.primaryDefault()
        behavior.displayName = "  Research Builder  "
        behavior.selfDescription = "Finds evidence before making changes."
        behavior.responseStyle.tone = .analytical
        behavior.responseStyle.verbosity = .detailed
        behavior.customInstructions = "Prefer focused patches."
        behavior.modeInstructions.grill = "Run the smallest relevant tests."
        behavior.capabilityPolicy.network = false
        behavior.memoryPolicy.scopes = [.personal, .agent, .personal]
        behavior.memoryPolicy.maxAutomaticMemories = 500
        behavior.runtimePolicy.maxToolIterations = 0
        behavior.clamp()

        let restored = try JSONDecoder().decode(
            AgentBehavior.self,
            from: JSONEncoder().encode(behavior)
        )

        XCTAssertEqual(restored.displayName, "Research Builder")
        XCTAssertEqual(restored.responseStyle.tone, .analytical)
        XCTAssertEqual(restored.modeInstructions.grill, "Run the smallest relevant tests.")

        // A config saved before the Grill rename keyed this overlay "build";
        // the custom text carries over instead of silently vanishing.
        let legacy = try JSONDecoder().decode(
            AgentModeOverlays.self,
            from: Data(#"{"ask":"","work":"","plan":"","build":"Old GSD text."}"#.utf8)
        )
        XCTAssertEqual(legacy.grill, "Old GSD text.")
        XCTAssertFalse(restored.capabilityPolicy.network)
        XCTAssertEqual(restored.memoryPolicy.scopes, [.personal, .agent])
        XCTAssertEqual(restored.memoryPolicy.maxAutomaticMemories, 20)
        XCTAssertEqual(restored.runtimePolicy.maxToolIterations, 1)
    }

    func testPartialAgentBehaviorMigratesMissingFieldsToSafeDefaults() throws {
        let restored = try JSONDecoder().decode(
            AgentBehavior.self,
            from: Data(#"{"version":0,"display_name":"Legacy Agent","custom_instructions":"Keep this."}"#.utf8)
        )

        XCTAssertEqual(restored.version, AgentBehavior.currentVersion)
        XCTAssertEqual(restored.displayName, "Legacy Agent")
        XCTAssertEqual(restored.customInstructions, "Keep this.")
        XCTAssertEqual(restored.responseStyle, AgentResponseStyle())
        XCTAssertEqual(restored.memoryPolicy.scopes, [.personal, .workspace, .agent])
    }

    func testAgentTeamRequiresAReadOnlyDispatcherAndWriteCapableLead() {
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
        var multiWriter = valid
        multiWriter.memberIDs.append(extraWriter.id)
        XCTAssertTrue(
            AgentTeamValidation.errors(
                team: multiWriter,
                profiles: [dispatcher, writer, extraWriter]
            ).isEmpty
        )

        var invalidLead = multiWriter
        invalidLead.defaultWriterID = dispatcher.id
        XCTAssertTrue(
            AgentTeamValidation.errors(
                team: invalidLead,
                profiles: [dispatcher, writer, extraWriter]
            ).contains(where: { $0.contains("lead writer") })
        )
    }

    func testQuickTeamFactoryBuildsSafeProfilesInVisualLaneOrder() throws {
        let dispatcherChoice = QuickTeamModelChoice(
            route: .localOllama,
            providerName: "Local (Ollama)",
            providerShortName: "Local",
            model: "qwen-dispatch"
        )
        let leadChoice = QuickTeamModelChoice(
            route: .localOllama,
            providerName: "Local (Ollama)",
            providerShortName: "Local",
            model: "qwen-code"
        )
        let helperChoice = QuickTeamModelChoice(
            route: .localOllama,
            providerName: "Local (Ollama)",
            providerShortName: "Local",
            model: "qwen-review"
        )

        let build = try QuickTeamFactory.build(
            draft: QuickTeamDraft(
                name: "Quick Team",
                dispatcher: dispatcherChoice,
                leadEditor: leadChoice,
                helpers: [helperChoice]
            ),
            existingProfiles: [],
            existingTeams: []
        )

        XCTAssertEqual(build.createdProfileIDs.count, 3)
        XCTAssertEqual(build.team.memberIDs.count, 3)
        let members = build.team.memberIDs.compactMap { id in
            build.profiles.first(where: { $0.id == id })
        }
        XCTAssertEqual(members.map(\.role), [.dispatcher, .implementer, .generalist])
        XCTAssertEqual(members.map(\.accessCeiling), [.readOnly, .workspaceWrite, .readOnly])
        XCTAssertEqual(build.team.dispatcherID, members[0].id)
        XCTAssertEqual(build.team.defaultWriterID, members[1].id)
        XCTAssertEqual(build.team.resolvedRoutingMode, .scorecard)
        XCTAssertEqual(build.team.resolvedDispatchApprovalMode, .preview)
        XCTAssertEqual(build.team.budget.callBudgetMode, .automatic)
        XCTAssertTrue(build.team.useManagedWorktree)
        XCTAssertEqual(build.team.resolvedSwarmPolicy, .adaptiveDefault)
    }

    func testQuickTeamFactoryReusesOnlyExactRoleAndAccessMatches() throws {
        let sharedChoice = QuickTeamModelChoice(
            route: .localOllama,
            providerName: "Local (Ollama)",
            providerShortName: "Local",
            model: "qwen"
        )
        let dispatcher = AgentProfile(
            name: "Existing Dispatcher",
            model: "qwen",
            role: .dispatcher,
            accessCeiling: .readOnly
        )
        let lead = AgentProfile(
            name: "Existing Lead",
            model: "qwen",
            role: .implementer,
            accessCeiling: .workspaceWrite
        )
        let overlyBroadLead = AgentProfile(
            name: "Computer Lead",
            model: "other-code",
            role: .implementer,
            accessCeiling: .computerControl
        )
        let otherChoice = QuickTeamModelChoice(
            route: .localOllama,
            providerName: "Local (Ollama)",
            providerShortName: "Local",
            model: "other-code"
        )

        let reused = try QuickTeamFactory.build(
            draft: QuickTeamDraft(
                name: "One Model Team",
                dispatcher: sharedChoice,
                leadEditor: sharedChoice
            ),
            existingProfiles: [dispatcher, lead],
            existingTeams: []
        )
        XCTAssertTrue(reused.createdProfileIDs.isEmpty)
        XCTAssertEqual(reused.team.memberIDs, [dispatcher.id, lead.id])

        let narrowed = try QuickTeamFactory.build(
            draft: QuickTeamDraft(
                name: "Narrow Team",
                dispatcher: sharedChoice,
                leadEditor: otherChoice
            ),
            existingProfiles: [dispatcher, overlyBroadLead],
            existingTeams: []
        )
        XCTAssertEqual(narrowed.createdProfileIDs.count, 1)
        let generatedLead = try XCTUnwrap(
            narrowed.profiles.first(where: { $0.id == narrowed.team.defaultWriterID })
        )
        XCTAssertEqual(generatedLead.accessCeiling, .workspaceWrite)
        XCTAssertNotEqual(generatedLead.id, overlyBroadLead.id)
    }

    func testQuickTeamNamingAndProviderScopedModelIdentity() throws {
        let accountA = UUID()
        let accountB = UUID()
        let first = QuickTeamModelChoice(
            route: .providerAccount(accountA),
            providerName: "Provider A",
            providerShortName: "A",
            model: "shared-model"
        )
        let second = QuickTeamModelChoice(
            route: .providerAccount(accountB),
            providerName: "Provider B",
            providerShortName: "B",
            model: "shared-model"
        )
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.id, second.id)

        let existing = [
            AgentTeam(
                name: "Quick Team",
                dispatcherID: nil,
                fallbackDispatcherID: nil,
                memberIDs: [],
                defaultWriterID: nil
            ),
            AgentTeam(
                name: "quick team 2",
                dispatcherID: nil,
                fallbackDispatcherID: nil,
                memberIDs: [],
                defaultWriterID: nil
            ),
        ]
        XCTAssertEqual(
            QuickTeamFactory.suggestedTeamName(existingTeams: existing),
            "Quick Team 3"
        )

        XCTAssertThrowsError(try QuickTeamFactory.build(
            draft: QuickTeamDraft(
                name: "QUICK TEAM",
                dispatcher: first,
                leadEditor: second
            ),
            existingProfiles: [],
            existingTeams: existing
        )) { error in
            XCTAssertEqual(error as? QuickTeamCreationError, .duplicateTeamName)
        }
    }

    func testLegacyTeamApprovalModesMigrateToOneTimePreview() {
        let team = AgentTeam(
            name: "Legacy automatic team",
            dispatcherID: nil,
            fallbackDispatcherID: nil,
            memberIDs: [],
            defaultWriterID: nil,
            dispatchApprovalMode: .automatic
        )

        let migration = AgentTeamStore.migrateToOneTimeApproval([team])

        XCTAssertTrue(migration.changed)
        XCTAssertEqual(migration.teams.first?.dispatchApprovalMode, .preview)
        XCTAssertEqual(migration.teams.first?.resolvedDispatchApprovalMode, .preview)

        let alreadyPreview = AgentTeamStore.migrateToOneTimeApproval(migration.teams)
        XCTAssertFalse(alreadyPreview.changed)
    }

    func testNewTeamsDefaultToAdaptiveSwarmWhileMissingPolicyDecodesFlat() throws {
        let newTeam = AgentTeam(
            name: "Adaptive",
            dispatcherID: nil,
            fallbackDispatcherID: nil,
            memberIDs: [],
            defaultWriterID: nil
        )
        XCTAssertEqual(newTeam.resolvedSwarmPolicy.delegationMode, .readOnlyChildren)
        XCTAssertEqual(newTeam.resolvedSwarmPolicy.engine, .locusManaged)
        XCTAssertEqual(newTeam.resolvedSwarmPolicy.maxTotalAgents, 8)
        XCTAssertEqual(newTeam.resolvedSwarmPolicy.maxDepth, 2)
        XCTAssertEqual(newTeam.budget.maxConcurrentCalls, 3)

        let encoded = try JSONEncoder().encode(newTeam)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "swarmPolicy")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let restored = try JSONDecoder().decode(AgentTeam.self, from: legacyData)

        XCTAssertNil(restored.swarmPolicy)
        XCTAssertEqual(restored.resolvedSwarmPolicy.delegationMode, .flat)
        XCTAssertEqual(restored.resolvedSwarmPolicy.engine, .locusManaged)
    }

    func testFormerDefaultTeamBudgetMigratesToAutomaticButCustomBudgetStaysFixed() {
        let legacyDefault = AgentTeam(
            name: "Former default",
            dispatcherID: nil,
            fallbackDispatcherID: nil,
            memberIDs: [],
            defaultWriterID: nil,
            budget: OrchestrationBudget(
                maxJobs: 4, maxRounds: 3, maxModelCalls: 12,
                maxConcurrentCalls: 3, maxMeteredTokens: 500_000,
                callBudgetMode: .fixed
            )
        )
        let custom = AgentTeam(
            name: "Custom",
            dispatcherID: nil,
            fallbackDispatcherID: nil,
            memberIDs: [],
            defaultWriterID: nil,
            budget: OrchestrationBudget(
                maxJobs: 4, maxRounds: 3, maxModelCalls: 24,
                maxConcurrentCalls: 3, maxMeteredTokens: 500_000,
                callBudgetMode: .fixed
            )
        )

        let migration = AgentTeamStore.migrateLegacyCallBudgets([legacyDefault, custom])

        XCTAssertTrue(migration.changed)
        XCTAssertEqual(migration.teams[0].budget.callBudgetMode, .automatic)
        XCTAssertEqual(migration.teams[0].budget.maxModelCalls, 100)
        XCTAssertEqual(migration.teams[1].budget.callBudgetMode, .fixed)
        XCTAssertEqual(migration.teams[1].budget.maxModelCalls, 24)
    }

    func testAgentTeamRejectsAModelTheSelectedProviderDoesNotReport() {
        let account = ProviderAccount(
            kind: .custom,
            name: "Hosted Qwen",
            preferredModel: "served-model"
        )
        let dispatcher = AgentProfile(
            name: "Dispatcher",
            route: .providerAccount(account.id),
            model: "friendly-but-invalid-name",
            role: .dispatcher
        )
        let writer = AgentProfile(
            name: "Writer",
            model: "local-writer",
            role: .implementer,
            accessCeiling: .workspaceWrite
        )
        let team = AgentTeam(
            name: "Validated routes",
            dispatcherID: dispatcher.id,
            fallbackDispatcherID: nil,
            memberIDs: [dispatcher.id, writer.id],
            defaultWriterID: writer.id
        )

        let errors = AgentTeamValidation.routeErrors(
            team: team,
            profiles: [dispatcher, writer],
            accounts: [account],
            accountModels: [account.id: ["served-model"]]
        )

        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("does not report that model"))
        XCTAssertTrue(
            AgentTeamValidation.routeErrors(
                team: team,
                profiles: [dispatcher, writer],
                accounts: [account],
                accountModels: [account.id: [dispatcher.model]]
            ).isEmpty
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

    func testOrchestrationBudgetDecodesLegacyAndProtocolKeys() throws {
        let legacy = Data(#"{"maxJobs":2,"maxRounds":1,"maxModelCalls":5,"maxConcurrentCalls":2,"maxMeteredTokens":9000}"#.utf8)
        let protocolValue = Data(#"{"max_jobs":3,"max_rounds":2,"max_model_calls":6,"max_concurrent_calls":3,"max_metered_tokens":12000}"#.utf8)
        let automatic = Data(#"{"max_jobs":4,"max_rounds":3,"max_model_calls":12,"max_concurrent_calls":3,"max_metered_tokens":500000,"call_budget_mode":"automatic"}"#.utf8)

        let legacyDecoded = try JSONDecoder().decode(OrchestrationBudget.self, from: legacy)
        XCTAssertEqual(legacyDecoded.maxJobs, 2)
        XCTAssertEqual(legacyDecoded.callBudgetMode, .fixed)
        let decoded = try JSONDecoder().decode(OrchestrationBudget.self, from: protocolValue)
        XCTAssertEqual(decoded.maxJobs, 3)
        XCTAssertEqual(decoded.maxMeteredTokens, 12_000)
        let automaticDecoded = try JSONDecoder().decode(OrchestrationBudget.self, from: automatic)
        XCTAssertEqual(automaticDecoded.callBudgetMode, .automatic)
        XCTAssertEqual(automaticDecoded.maxModelCalls, 100)

        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertTrue(encoded.contains("max_model_calls"))
        XCTAssertFalse(encoded.contains("maxModelCalls"))
    }

    func testRunIDGeneralizesHistoryAndDecodesLegacyTeamAnchors() throws {
        let historyData = Data(#"{"role":"user","content":"Build it","team_run_id":"run-42"}"#.utf8)
        let history = try JSONDecoder().decode(HistoryMessage.self, from: historyData)
        XCTAssertEqual(history.runID, "run-42")

        let soloData = Data(#"{"role":"user","content":"Inspect it","run_id":"solo-7"}"#.utf8)
        let solo = try JSONDecoder().decode(HistoryMessage.self, from: soloData)
        XCTAssertEqual(solo.runID, "solo-7")

        let block = ChatBlock(kind: .user, text: "Build it", runID: "run-42")
        let restored = try JSONDecoder().decode(
            ChatBlock.self,
            from: JSONEncoder().encode(block)
        )
        XCTAssertEqual(restored.runID, "run-42")
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(block), as: UTF8.self)
            .contains("run_id"))
    }

    func testStructuredTranscriptFieldsRoundTripAndLegacyReasoningStillDecodes() throws {
        let block = ChatBlock(
            kind: .assistant,
            text: "Checking now.",
            assistantPhase: .commentary,
            sourceItemID: "msg-42",
            reasoningText: "**First**\n\n**Second**",
            reasoningSections: ["**First**", "**Second**"]
        )
        let encoded = try JSONEncoder().encode(block)
        let restored = try JSONDecoder().decode(ChatBlock.self, from: encoded)
        XCTAssertEqual(restored.assistantPhase, .commentary)
        XCTAssertEqual(restored.sourceItemID, "msg-42")
        XCTAssertEqual(restored.reasoningSections, ["**First**", "**Second**"])
        XCTAssertEqual(restored.reasoningText, "**First**\n\n**Second**")

        let history = try JSONDecoder().decode(
            HistoryMessage.self,
            from: Data(#"{"role":"assistant","content":"Done","phase":"final_answer","item_id":"msg-7","reasoning_sections":["One","Two"],"reasoning":"One\n\nTwo"}"#.utf8)
        )
        XCTAssertEqual(history.phase, .finalAnswer)
        XCTAssertEqual(history.itemID, "msg-7")
        XCTAssertEqual(history.reasoningSections, ["One", "Two"])
        XCTAssertEqual(history.reasoning, "One\n\nTwo")

        let legacy = try JSONDecoder().decode(
            ChatBlock.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000999","kind":"assistant","text":"","reasoningText":"Legacy"}"#.utf8)
        )
        XCTAssertEqual(legacy.reasoningText, "Legacy")
        XCTAssertNil(legacy.reasoningSections)
        XCTAssertNil(legacy.assistantPhase)
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
        XCTAssertEqual(activity.depth, 0)
        XCTAssertEqual(activity.executionEngine, "locus_managed")
    }

    func testPerTokenTeamStreamsAreExcludedFromTheDurableTimeline() throws {
        let stream = try JSONDecoder().decode(
            OrchestrationEvent.self,
            from: Data(#"{"type":"agent_job_stream","seq":4,"text":"token"}"#.utf8)
        )
        let completed = try JSONDecoder().decode(
            OrchestrationEvent.self,
            from: Data(#"{"type":"agent_job_completed","seq":5}"#.utf8)
        )

        XCTAssertTrue(stream.isTransientStream)
        XCTAssertFalse(completed.isTransientStream)
    }

    func testSessionStateReducerRunsAPlanLifecycle() {
        var state = SessionState.empty(workspacePath: "/tmp/project", modelID: "gpt-5.6-sol")
        let steps = [
            SessionPlanStep(id: "one", label: "Inspect", state: .pending),
            SessionPlanStep(id: "two", label: "Implement", state: .pending),
        ]
        state = SessionStateReducer.reduce(state, .planCreated(steps: steps, at: 1_000))
        state = SessionStateReducer.reduce(
            state,
            .stepState(stepID: "one", state: .running, at: 2_000)
        )
        state = SessionStateReducer.reduce(
            state,
            .stepState(stepID: "one", state: .done, at: 5_000)
        )

        XCTAssertEqual(state.plan[0].state, .done)
        XCTAssertEqual(state.plan[0].startedAt, 2_000)
        XCTAssertEqual(state.plan[0].endedAt, 5_000)
        XCTAssertEqual(state.plan[1].state, .pending)
    }

    func testSessionStateReducerDeduplicatesAndAccumulatesFiles() {
        var state = SessionState.empty()
        state = SessionStateReducer.reduce(
            state,
            .fileEdit(path: "Sources/App.swift", added: 10, removed: 2, at: 1)
        )
        state = SessionStateReducer.reduce(
            state,
            .fileEdit(path: "Sources/App.swift", added: 4, removed: 1, at: 2)
        )
        state = SessionStateReducer.reduce(
            state,
            .fileRead(path: "Sources/App.swift", at: 3)
        )

        XCTAssertEqual(state.files.count, 1)
        XCTAssertEqual(state.files[0].added, 14)
        XCTAssertEqual(state.files[0].removed, 3)
        XCTAssertEqual(state.files[0].kind, .edit)
        XCTAssertEqual(state.files[0].lastTouchedAt, 3)
    }

    func testSessionStateReducerUpdatesTokensAndPrefersReportedWindow() {
        let state = SessionStateReducer.reduce(
            SessionState.empty(modelID: "gpt-5.6-sol"),
            .tokens(used: 24_100, window: 64_000, costUsd: 0.42, at: 1)
        )

        XCTAssertEqual(state.resources.tokensUsed, 24_100)
        XCTAssertEqual(state.model.contextWindow, 64_000)
        XCTAssertEqual(state.resources.costUsd, 0.42)
    }

    func testSessionRunFinishedCreatesIdleSummaryAndSuggestions() {
        let summary = SessionRunSummary(
            completedSteps: 4,
            totalSteps: 4,
            durationMs: 372_000,
            endedAt: 10,
            summary: "Refactored retry logic with backoff; tests passing.",
            outcome: .completed
        )
        var state = SessionState.empty()
        state = SessionStateReducer.reduce(
            state,
            .status(status: .running, reason: nil, at: 1)
        )
        state = SessionStateReducer.reduce(
            state,
            .runFinished(
                summary: summary,
                suggestions: ["Add integration tests", "Review diff", "Ship", "Ignored"],
                at: 10
            )
        )

        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.lastRun, summary)
        XCTAssertEqual(state.suggestions, ["Add integration tests", "Review diff", "Ship"])
    }

    func testSessionEventRingKeepsTheNewestTwoHundred() {
        var state = SessionState.empty()
        for index in 0..<230 {
            state = SessionStateReducer.reduce(
                state,
                .message(role: .assistant, at: index)
            )
        }
        XCTAssertEqual(state.events.count, 200)
        XCTAssertEqual(state.events.first?.timestamp, 30)
        XCTAssertEqual(state.events.last?.timestamp, 229)
    }

    @MainActor
    func testSessionEmitterRestoresEachPersistedSession() throws {
        let suiteName = "LocusTests.sessionOverview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "session-state"

        let writer = SessionStateEmitter()
        writer.configurePersistence(enabled: true, defaults: defaults, key: key)
        writer.activate(
            sessionID: "one",
            initial: .empty(workspacePath: "/tmp/one", modelID: "gpt-5.6-sol")
        )
        writer.emit(.status(status: .running, reason: nil, at: 1))
        writer.activate(
            sessionID: "two",
            initial: .empty(workspacePath: "/tmp/two", modelID: "local-model")
        )
        writer.emit(.fileRead(path: "README.md", at: 2))
        // Writes are coalesced — every event re-encodes the whole store, and a
        // workspace watcher can deliver a batch of them. Session switches and
        // resets flush on their own; a trailing event needs this.
        writer.persistNow()

        let reader = SessionStateEmitter()
        reader.configurePersistence(enabled: true, defaults: defaults, key: key)

        XCTAssertEqual(reader.states["one"]?.status, .running)
        XCTAssertEqual(reader.states["two"]?.files.first?.path, "README.md")
    }

    @MainActor
    func testSwitchingSessionsFlushesWithoutWaitingForTheDebounce() throws {
        // The debounce must never cost a session switch: the previous chat's
        // last events have to be on disk before the next one takes over.
        let suiteName = "LocusTests.sessionOverviewFlush.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "session-state"

        let writer = SessionStateEmitter()
        writer.configurePersistence(enabled: true, defaults: defaults, key: key)
        writer.activate(sessionID: "one", initial: .empty(workspacePath: "/tmp/one"))
        writer.emit(.fileCreate(path: "report.pdf", at: 1))
        writer.activate(sessionID: "two", initial: .empty(workspacePath: "/tmp/two"))

        let reader = SessionStateEmitter()
        reader.configurePersistence(enabled: true, defaults: defaults, key: key)
        XCTAssertEqual(reader.states["one"]?.createdFiles.map(\.path), ["report.pdf"])
    }

    func testTwoProviderAdaptersFoldTheSameEventsWithoutUIKnowledge() {
        func folded(provider: String) -> SessionState {
            var state = SessionState.empty(
                workspacePath: "/tmp/project",
                modelID: provider == "openai" ? "gpt-5.6-sol" : "claude-test",
                provider: provider
            )
            state = SessionStateReducer.reduce(
                state,
                .fileEdit(path: "App.swift", added: 2, removed: 1, at: 1)
            )
            state = SessionStateReducer.reduce(
                state,
                .tokens(used: 100, window: 1_000, costUsd: 0.01, at: 2)
            )
            return state
        }

        let openAI = folded(provider: "openai")
        let secondProvider = folded(provider: "anthropic")
        XCTAssertEqual(openAI.files, secondProvider.files)
        XCTAssertEqual(openAI.resources, secondProvider.resources)
        XCTAssertNotEqual(openAI.model.provider, secondProvider.model.provider)
    }

    func testProxyConfigResolutionPrefersWorkspaceFilesAndCreatesFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        let config = workspace.appending(path: "config", directoryHint: .isDirectory)
        let fallback = root.appending(path: "app-config", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let existing = config.appending(path: "proxies.json")
        try Data("{}".utf8).write(to: existing)

        let found = try SessionQuickActionFiles.resolveProxyConfig(
            workspacePath: workspace.path,
            appConfigDirectory: fallback
        )
        XCTAssertEqual(found.url, existing)
        XCTAssertFalse(found.created)

        try FileManager.default.removeItem(at: existing)
        let created = try SessionQuickActionFiles.resolveProxyConfig(
            workspacePath: workspace.path,
            appConfigDirectory: fallback
        )
        XCTAssertTrue(created.created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.url.path))
        XCTAssertTrue(try String(contentsOf: created.url).contains("$schemaNote"))
        try FileManager.default.removeItem(at: root)
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

    func testMCPCallbackMustMatchTheExactRegisteredRedirect() throws {
        let expected = try XCTUnwrap(URLComponents(string: "locus://mcp/oauth"))
        let valid = try XCTUnwrap(URLComponents(string: "locus://mcp/oauth?code=one&state=two"))
        let wrongHost = try XCTUnwrap(URLComponents(string: "locus://attacker/oauth?code=one"))
        let wrongPath = try XCTUnwrap(URLComponents(string: "locus://mcp/other?code=one"))
        let fragment = try XCTUnwrap(URLComponents(string: "locus://mcp/oauth?code=one#leak"))

        XCTAssertTrue(MCPAuthCoordinator.callbackMatches(valid, expected: expected))
        XCTAssertFalse(MCPAuthCoordinator.callbackMatches(wrongHost, expected: expected))
        XCTAssertFalse(MCPAuthCoordinator.callbackMatches(wrongPath, expected: expected))
        XCTAssertFalse(MCPAuthCoordinator.callbackMatches(fragment, expected: expected))
        XCTAssertTrue(MCPAuthCoordinator.authorizationResponseIssuerIsValid(
            "https://auth.example/", expected: "https://auth.example/", required: true
        ))
        XCTAssertFalse(MCPAuthCoordinator.authorizationResponseIssuerIsValid(
            "https://auth.example", expected: "https://auth.example/", required: true
        ))
        XCTAssertFalse(MCPAuthCoordinator.authorizationResponseIssuerIsValid(
            nil, expected: "https://auth.example", required: true
        ))
        XCTAssertTrue(MCPAuthCoordinator.authorizationResponseIssuerIsValid(
            nil, expected: "https://auth.example", required: false
        ))
    }

    @MainActor
    func testMCPAutomaticOAuthDiscoversChallengeAndRegistersIssuerBoundClient() async throws {
        let serverID = "oauth-test-\(UUID().uuidString)"
        defer { MCPCredentialStore.remove(serverID: serverID) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPURLProtocol.self]
        MCPURLProtocol.handler = { request in
            let url = request.url!
            func json(_ value: [String: Any]) throws -> Data {
                try JSONSerialization.data(withJSONObject: value)
            }
            switch (url.host, url.path, request.httpMethod ?? "GET") {
            case ("mcp.test", let path, "GET")
                where path.hasPrefix("/.well-known/oauth-protected-resource"):
                return (404, [:], Data())
            case ("mcp.test", "/mcp", "POST"):
                return (
                    401,
                    ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.test/oauth-resource", scope="read""#],
                    Data()
                )
            case ("mcp.test", "/oauth-resource", "GET"):
                return (200, ["Content-Type": "application/json"], try json([
                    "resource": "https://mcp.test/mcp",
                    "authorization_servers": ["https://auth.test"],
                    "scopes_supported": ["read"],
                ]))
            case ("auth.test", "/.well-known/oauth-authorization-server", "GET"):
                return (200, ["Content-Type": "application/json"], try json([
                    "issuer": "https://auth.test",
                    "authorization_endpoint": "https://auth.test/authorize",
                    "token_endpoint": "https://auth.test/token",
                    "registration_endpoint": "https://auth.test/register",
                    "code_challenge_methods_supported": ["S256"],
                    "authorization_response_iss_parameter_supported": true,
                ]))
            case ("auth.test", "/register", "POST"):
                return (201, ["Content-Type": "application/json"], try json([
                    "client_id": "registered-client",
                    "client_secret": "native-only-secret",
                ]))
            default:
                throw NSError(
                    domain: "MCPURLProtocol",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected request \(request)"]
                )
            }
        }
        let server = try JSONDecoder().decode(
            ExtensionMCPServer.self,
            from: Data(#"""
            {"id":"\#(serverID)","name":"mock","transport":"streamable_http",
             "url":"https://mcp.test/mcp","auth":"auto"}
            """#.utf8)
        )
        let coordinator = MCPAuthCoordinator(configurationForTesting: configuration)
        let resolved = try await coordinator.resolvedConfigurationForTesting(server: server)

        XCTAssertEqual(resolved["issuer"] as? String, "https://auth.test")
        XCTAssertEqual(resolved["client_id"] as? String, "registered-client")
        XCTAssertEqual(resolved["resource"] as? String, "https://mcp.test/mcp")
        XCTAssertEqual(resolved["scopes"] as? [String], ["read"])
        let registration = try XCTUnwrap(MCPCredentialStore.get(serverID: serverID))
        XCTAssertEqual(registration["issuer"] as? String, "https://auth.test")
        XCTAssertEqual(registration["client_secret"] as? String, "native-only-secret")
    }

    @MainActor
    func testGitHubDeviceFlowShowsCodeValidatesAccountAndReturnsRefreshableCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPURLProtocol.self]
        MCPURLProtocol.handler = { request in
            let url = request.url!
            func json(_ value: [String: Any]) throws -> Data {
                try JSONSerialization.data(withJSONObject: value)
            }
            switch (url.host, url.path, request.httpMethod ?? "GET") {
            case ("github.com", "/login/device/code", "POST"):
                return (200, ["Content-Type": "application/json"], try json([
                    "device_code": "device-secret",
                    "user_code": "ABCD-1234",
                    "verification_uri": "https://github.com/login/device",
                    "expires_in": 30,
                    "interval": 1,
                ]))
            case ("github.com", "/login/oauth/access_token", "POST"):
                return (200, ["Content-Type": "application/json"], try json([
                    "access_token": "github-access",
                    "refresh_token": "github-refresh",
                    "expires_in": 28_800,
                    "scope": "",
                ]))
            case ("api.github.com", "/user", "GET"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-access")
                return (200, ["Content-Type": "application/json"], try json([
                    "login": "octocat",
                ]))
            default:
                throw NSError(
                    domain: "MCPURLProtocol",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected request \(request)"]
                )
            }
        }
        let server = try JSONDecoder().decode(
            ExtensionMCPServer.self,
            from: Data(#"""
            {"id":"github-device","name":"GitHub","transport":"streamable_http",
             "url":"https://api.githubcopilot.com/mcp/","auth":"oauth",
             "oauth_strategy":"github_device",
             "oauth":{"authorization_endpoint":"","token_endpoint":"",
                      "client_id":"public-github-client","scopes":[],
                      "redirect_uri":"locus://mcp/oauth"}}
            """#.utf8)
        )
        let codeShown = expectation(description: "device code shown")
        let completed = expectation(description: "device authorization completed")
        var prompt: MCPDeviceAuthorizationPrompt?
        var credentials: [String: Any]?
        var completionError: Error?
        let coordinator = MCPAuthCoordinator(configurationForTesting: configuration)

        coordinator.authorize(
            server: server,
            onDeviceCode: {
                prompt = $0
                codeShown.fulfill()
            },
            completion: { result in
                switch result {
                case let .success(value): credentials = value
                case let .failure(error): completionError = error
                }
                completed.fulfill()
            }
        )
        await fulfillment(of: [codeShown, completed], timeout: 4)

        XCTAssertNil(completionError)
        XCTAssertEqual(prompt?.userCode, "ABCD-1234")
        XCTAssertEqual(prompt?.verificationURL.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(credentials?["access_token"] as? String, "github-access")
        XCTAssertEqual(credentials?["refresh_token"] as? String, "github-refresh")
        XCTAssertEqual(credentials?["account_login"] as? String, "octocat")
        XCTAssertEqual(credentials?["auth_strategy"] as? String, "github_device")
        XCTAssertNil(credentials?["client_secret"])
    }

    @MainActor
    func testMCPAutomaticOAuthFallsBackToOIDCPathInsertion() async throws {
        let serverID = "oauth-oidc-test-\(UUID().uuidString)"
        defer { MCPCredentialStore.remove(serverID: serverID) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPURLProtocol.self]
        MCPURLProtocol.handler = { request in
            let url = request.url!
            func json(_ value: [String: Any]) throws -> Data {
                try JSONSerialization.data(withJSONObject: value)
            }
            switch (url.host, url.path, request.httpMethod ?? "GET") {
            case ("mcp.test", "/mcp", "POST"):
                return (
                    401,
                    ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.test/oauth-resource""#],
                    Data()
                )
            case ("mcp.test", "/oauth-resource", "GET"):
                return (200, ["Content-Type": "application/json"], try json([
                    "resource": "https://mcp.test/mcp",
                    "authorization_servers": ["https://auth.test/tenant"],
                ]))
            case ("auth.test", "/.well-known/oauth-authorization-server/tenant", "GET"):
                return (404, [:], Data())
            case ("auth.test", "/.well-known/openid-configuration/tenant", "GET"):
                return (200, ["Content-Type": "application/json"], try json([
                    "issuer": "https://auth.test/tenant",
                    "authorization_endpoint": "https://auth.test/tenant/authorize",
                    "token_endpoint": "https://auth.test/tenant/token",
                    "registration_endpoint": "https://auth.test/tenant/register",
                    "code_challenge_methods_supported": ["S256"],
                ]))
            case ("auth.test", "/tenant/register", "POST"):
                return (201, ["Content-Type": "application/json"], try json([
                    "client_id": "oidc-client",
                ]))
            default:
                throw NSError(
                    domain: "MCPURLProtocol",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected request \(request)"]
                )
            }
        }
        let server = try JSONDecoder().decode(
            ExtensionMCPServer.self,
            from: Data(#"""
            {"id":"\#(serverID)","name":"mock","transport":"streamable_http",
             "url":"https://mcp.test/mcp","auth":"auto"}
            """#.utf8)
        )

        let resolved = try await MCPAuthCoordinator(
            configurationForTesting: configuration
        ).resolvedConfigurationForTesting(server: server)

        XCTAssertEqual(resolved["issuer"] as? String, "https://auth.test/tenant")
        XCTAssertEqual(resolved["client_id"] as? String, "oidc-client")
    }

    @MainActor
    func testMCPAutomaticOAuthValidatesClientIDMetadataDocument() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPURLProtocol.self]
        MCPURLProtocol.handler = { request in
            let url = request.url!
            func json(_ value: [String: Any]) throws -> Data {
                try JSONSerialization.data(withJSONObject: value)
            }
            switch (url.host, url.path, request.httpMethod ?? "GET") {
            case ("mcp.test", "/mcp", "POST"):
                return (
                    401,
                    ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.test/oauth-resource""#],
                    Data()
                )
            case ("mcp.test", "/oauth-resource", "GET"):
                return (200, ["Content-Type": "application/json"], try json([
                    "resource": "https://mcp.test/mcp",
                    "authorization_servers": ["https://auth.test"],
                ]))
            case ("auth.test", "/.well-known/oauth-authorization-server", "GET"):
                return (200, ["Content-Type": "application/json"], try json([
                    "issuer": "https://auth.test",
                    "authorization_endpoint": "https://auth.test/authorize",
                    "token_endpoint": "https://auth.test/token",
                    "code_challenge_methods_supported": ["S256"],
                    "client_id_metadata_document_supported": true,
                ]))
            case ("client.test", "/locus.json", "GET"):
                return (200, ["Content-Type": "application/json"], try json([
                    "client_id": "https://client.test/locus.json",
                    "client_name": "Locus",
                    "redirect_uris": ["locus://mcp/oauth"],
                ]))
            default:
                throw NSError(
                    domain: "MCPURLProtocol",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected request \(request)"]
                )
            }
        }
        let server = try JSONDecoder().decode(
            ExtensionMCPServer.self,
            from: Data(#"""
            {"id":"client-metadata","name":"mock","transport":"streamable_http",
             "url":"https://mcp.test/mcp","auth":"auto",
             "oauth":{"authorization_endpoint":"","token_endpoint":"",
                      "client_id":"https://client.test/locus.json","scopes":[],
                      "redirect_uri":"locus://mcp/oauth"}}
            """#.utf8)
        )

        let resolved = try await MCPAuthCoordinator(
            configurationForTesting: configuration
        ).resolvedConfigurationForTesting(server: server)

        XCTAssertEqual(resolved["client_id"] as? String, "https://client.test/locus.json")
        XCTAssertEqual(resolved["issuer"] as? String, "https://auth.test")
    }

    @MainActor
    func testMCPRefreshRotatesTokenAndRuntimePayloadExcludesNativeSecrets() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPURLProtocol.self]
        MCPURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://auth.test/token")
            var bodyData = request.httpBody ?? Data()
            if bodyData.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bodyData.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("refresh_token=old-refresh"))
            XCTAssertTrue(body.contains("client_secret=native-secret"))
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": "new-access",
                "refresh_token": "new-refresh",
                "expires_in": 3600,
            ])
            return (200, ["Content-Type": "application/json"], data)
        }
        let coordinator = MCPAuthCoordinator(configurationForTesting: configuration)
        let refreshed = try await coordinator.refreshedCredentialsIfNeeded([
            "access_token": "old-access",
            "refresh_token": "old-refresh",
            "expires_at": 0,
            "token_endpoint": "https://auth.test/token",
            "client_id": "client",
            "client_secret": "native-secret",
            "issuer": "https://auth.test",
            "resource": "https://mcp.test/mcp",
            "headers": ["Sentry-Bearer": "manual"],
        ])
        XCTAssertEqual(refreshed["access_token"] as? String, "new-access")
        XCTAssertEqual(refreshed["refresh_token"] as? String, "new-refresh")

        let runtime = ExtensionsModel.runtimeMCPCredentials(refreshed)
        XCTAssertEqual(runtime["access_token"] as? String, "new-access")
        XCTAssertNotNil(runtime["headers"])
        XCTAssertNil(runtime["refresh_token"])
        XCTAssertNil(runtime["client_secret"])
        XCTAssertNil(runtime["issuer"])
    }

    @MainActor
    func testGitHubDeviceRefreshSendsNoSecretOrMCPResource() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPURLProtocol.self]
        MCPURLProtocol.handler = { request in
            var bodyData = request.httpBody ?? Data()
            if bodyData.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bodyData.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = String(decoding: bodyData, as: UTF8.self)
            XCTAssertTrue(body.contains("refresh_token=github-refresh"))
            XCTAssertTrue(body.contains("client_id=public-github-client"))
            XCTAssertFalse(body.contains("client_secret"))
            XCTAssertFalse(body.contains("resource="))
            let data = try JSONSerialization.data(withJSONObject: [
                "access_token": "rotated-github-access",
                "refresh_token": "rotated-github-refresh",
                "expires_in": 28_800,
            ])
            return (200, ["Content-Type": "application/json"], data)
        }

        let refreshed = try await MCPAuthCoordinator(
            configurationForTesting: configuration
        ).refreshedCredentialsIfNeeded([
            "access_token": "expired-github-access",
            "refresh_token": "github-refresh",
            "expires_at": 0,
            "token_endpoint": "https://github.com/login/oauth/access_token",
            "client_id": "public-github-client",
            "issuer": "https://github.com/login/oauth",
            "resource": "https://api.githubcopilot.com/mcp/",
            "auth_strategy": "github_device",
        ])

        XCTAssertEqual(refreshed["access_token"] as? String, "rotated-github-access")
        XCTAssertEqual(refreshed["refresh_token"] as? String, "rotated-github-refresh")
    }

    func testTelemetryDefaultsOffAndRoundTripsPlaintextAuthorization() throws {
        XCTAssertFalse(AppSettings().otlpExportEnabled)
        var settings = AppSettings()
        settings.otlpExportEnabled = true
        settings.otlpEndpoint = "https://collector.example"
        settings.otlpAuthorization = "Bearer local-setting"
        settings.otlpSamplingRate = 0.35

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(restored.otlpExportEnabled)
        XCTAssertEqual(restored.otlpEndpoint, settings.otlpEndpoint)
        XCTAssertEqual(restored.otlpAuthorization, "Bearer local-setting")
        XCTAssertEqual(restored.otlpSamplingRate, 0.35)
        XCTAssertTrue(encoded.contains("Bearer local-setting"))
    }

    func testBackgroundChatAndWorktreeSettingsDefaultClampAndRoundTrip() throws {
        let defaults = AppSettings()
        XCTAssertEqual(defaults.maximumActiveChats, 2)
        XCTAssertEqual(defaults.worktreeRetentionLimit, 15)
        XCTAssertTrue(defaults.newGitChatsUseWorktree)

        let tooLarge = Data(#"{"maximumActiveChats":99,"worktreeRetentionLimit":999,"otlpSamplingRate":4}"#.utf8)
        let high = try JSONDecoder().decode(AppSettings.self, from: tooLarge)
        XCTAssertEqual(high.maximumActiveChats, 4)
        XCTAssertEqual(high.worktreeRetentionLimit, 100)
        XCTAssertEqual(high.otlpSamplingRate, 1)

        let tooSmall = Data(#"{"maximumActiveChats":0,"worktreeRetentionLimit":-9,"otlpSamplingRate":-1}"#.utf8)
        let low = try JSONDecoder().decode(AppSettings.self, from: tooSmall)
        XCTAssertEqual(low.maximumActiveChats, 1)
        XCTAssertEqual(low.worktreeRetentionLimit, 0)
        XCTAssertEqual(low.otlpSamplingRate, 0)

        var chosen = defaults
        chosen.maximumActiveChats = 3
        chosen.worktreeRetentionLimit = 24
        chosen.newGitChatsUseWorktree = false
        let restored = try JSONDecoder().decode(
            AppSettings.self, from: JSONEncoder().encode(chosen)
        )
        XCTAssertEqual(restored.maximumActiveChats, 3)
        XCTAssertEqual(restored.worktreeRetentionLimit, 24)
        XCTAssertFalse(restored.newGitChatsUseWorktree)
    }

    func testBackgroundChatAdmissionQueueIsFIFOAndDeduplicated() {
        var queue = ChatAdmissionQueue()
        queue.enqueue("first")
        queue.enqueue("second")
        queue.enqueue("first")

        XCTAssertEqual(queue.sessionIDs, ["first", "second"])
        XCTAssertTrue(queue.isFirst("first"))
        XCTAssertFalse(queue.isFirst("second"))

        queue.move("second", action: "move_top")
        XCTAssertEqual(queue.sessionIDs, ["second", "first"])
        queue.move("second", action: "move_down")
        XCTAssertEqual(queue.sessionIDs, ["first", "second"])

        queue.remove("first")
        XCTAssertTrue(queue.isFirst("second"))
    }

    func testFaviconCandidateURLDecisionTable() {
        let page = URL(string: "https://docs.example.com/guide")!

        // A declared web icon wins, absolute or already resolved by the probe.
        XCTAssertEqual(
            FaviconLogic.candidateURL(
                declared: "https://cdn.example.com/icon.png", pageURL: page
            )?.absoluteString,
            "https://cdn.example.com/icon.png"
        )
        // Non-web declarations fall back to the origin's favicon.ico.
        for rejected in ["data:image/png;base64,AAAA", "javascript:alert(1)", "not a url at all"] {
            XCTAssertEqual(
                FaviconLogic.candidateURL(declared: rejected, pageURL: page)?.absoluteString,
                "https://docs.example.com/favicon.ico",
                rejected
            )
        }
        XCTAssertEqual(
            FaviconLogic.candidateURL(declared: nil, pageURL: page)?.absoluteString,
            "https://docs.example.com/favicon.ico"
        )
        // The fallback preserves the port — dev servers live on one.
        XCTAssertEqual(
            FaviconLogic.candidateURL(
                declared: nil, pageURL: URL(string: "http://localhost:3000/app")!
            )?.absoluteString,
            "http://localhost:3000/favicon.ico"
        )
        // No host, no icon.
        XCTAssertNil(FaviconLogic.candidateURL(declared: nil, pageURL: URL(string: "about:blank")!))

        // The cache key is the origin, port included: two dev servers on
        // localhost are different sites with different icons.
        XCTAssertEqual(
            FaviconLogic.cacheKey(for: URL(string: "http://localhost:3000/app")),
            "http://localhost:3000"
        )
        XCTAssertEqual(
            FaviconLogic.cacheKey(for: URL(string: "http://localhost:5173/app")),
            "http://localhost:5173"
        )
        XCTAssertEqual(
            FaviconLogic.cacheKey(for: URL(string: "https://docs.example.com/guide")),
            "https://docs.example.com:443"
        )
        XCTAssertNil(FaviconLogic.cacheKey(for: URL(string: "about:blank")))
        XCTAssertNil(FaviconLogic.cacheKey(for: nil))
    }

    func testComposerPrimaryActionCoversEveryState() {
        // Idle always sends, whatever the draft state — send itself guards.
        XCTAssertEqual(
            ComposerPrimaryAction.current(
                isBusy: false, canSubmit: true, isWaitingForTeamApproval: false
            ), .send
        )
        XCTAssertEqual(
            ComposerPrimaryAction.current(
                isBusy: false, canSubmit: false, isWaitingForTeamApproval: false
            ), .send
        )
        // Enter and the visible send button queue while a run is active.
        XCTAssertEqual(
            ComposerPrimaryAction.current(
                isBusy: true, canSubmit: true, isWaitingForTeamApproval: false
            ), .queue
        )
        // Busy with an empty composer: the slot that used to be a disabled
        // arrow is the stop control.
        XCTAssertEqual(
            ComposerPrimaryAction.current(
                isBusy: true, canSubmit: false, isWaitingForTeamApproval: false
            ), .stop
        )
        // A pending team-plan decision queues; stopping a team run belongs to
        // its run board, not this button.
        XCTAssertEqual(
            ComposerPrimaryAction.current(
                isBusy: true, canSubmit: true, isWaitingForTeamApproval: true
            ), .queue
        )
        XCTAssertEqual(
            ComposerPrimaryAction.current(
                isBusy: true, canSubmit: false, isWaitingForTeamApproval: true
            ), .queue
        )
    }

    func testComposerHeightGrowsWithDraftAndCapsAtReadableMaximum() {
        XCTAssertEqual(ComposerMetrics.editorHeight(for: "", width: 520), 58)

        let multiline = "First line\nSecond line\nThird line\nFourth line"
        XCTAssertGreaterThan(
            ComposerMetrics.editorHeight(for: multiline, width: 520),
            ComposerMetrics.editorHeight(for: "First line", width: 520)
        )
        XCTAssertEqual(
            ComposerMetrics.editorHeight(
                for: Array(repeating: "A deliberately long prompt line", count: 80)
                    .joined(separator: "\n"),
                width: 360
            ),
            180
        )
    }

    func testComposerReturnActionCoversSendQueueSteerAndNewlineStates() {
        XCTAssertEqual(
            ComposerReturnAction.current(
                hasPopup: false,
                isBusy: false,
                canSubmit: true,
                canSteer: true,
                modifiers: []
            ),
            .send
        )
        XCTAssertEqual(
            ComposerReturnAction.current(
                hasPopup: false,
                isBusy: false,
                canSubmit: true,
                canSteer: true,
                modifiers: .command
            ),
            .send
        )
        XCTAssertEqual(
            ComposerReturnAction.current(
                hasPopup: false,
                isBusy: true,
                canSubmit: true,
                canSteer: true,
                modifiers: []
            ),
            .queue
        )
        XCTAssertEqual(
            ComposerReturnAction.current(
                hasPopup: false,
                isBusy: true,
                canSubmit: true,
                canSteer: true,
                modifiers: .command
            ),
            .steer
        )
        XCTAssertEqual(
            ComposerReturnAction.current(
                hasPopup: false,
                isBusy: true,
                canSubmit: true,
                canSteer: false,
                modifiers: .command
            ),
            .queue
        )
        for modifiers: EventModifiers in [.shift, .option, .control, [.command, .shift]] {
            XCTAssertEqual(
                ComposerReturnAction.current(
                    hasPopup: false,
                    isBusy: false,
                    canSubmit: true,
                    canSteer: true,
                    modifiers: modifiers
                ),
                .newline,
                "text modifiers keep Return available for new lines"
            )
        }
        XCTAssertEqual(
            ComposerReturnAction.current(
                hasPopup: true,
                isBusy: true,
                canSubmit: true,
                canSteer: true,
                modifiers: .command
            ),
            .completePopup
        )
        XCTAssertEqual(
            ComposerReturnAction.current(
                hasPopup: false,
                isBusy: false,
                canSubmit: false,
                canSteer: true,
                modifiers: []
            ),
            .newline
        )
        XCTAssertEqual(
            ComposerReturnAction.current(
                hasPopup: false,
                isBusy: true,
                canSubmit: false,
                canSteer: true,
                modifiers: .command
            ),
            .stop
        )
    }

    func testPasteboardClassificationPrefersTextOverIncidentalImages() {
        let png = PastedImage(data: Data([0x89, 0x50]), mimeType: "image/png")

        // Copied rich text carries an image representation too; it must paste
        // as text, not attach.
        XCTAssertEqual(
            ChatPasteboardClassifier.classify(
                fileURLs: [], plainText: "some copied prose", images: [png]
            ),
            .passthrough
        )
        // A macOS clipboard screenshot is image data with no string at all.
        XCTAssertEqual(
            ChatPasteboardClassifier.classify(fileURLs: [], plainText: nil, images: [png]),
            .attachImages([png])
        )
        XCTAssertEqual(
            ChatPasteboardClassifier.classify(fileURLs: [], plainText: "", images: [png]),
            .attachImages([png])
        )
        // A Finder copy carries the filename as a string; files still win.
        let file = URL(fileURLWithPath: "/tmp/bug.png")
        XCTAssertEqual(
            ChatPasteboardClassifier.classify(
                fileURLs: [file], plainText: "bug.png", images: [png]
            ),
            .attachFiles([file])
        )
        // Nothing usable pastes normally.
        XCTAssertEqual(
            ChatPasteboardClassifier.classify(fileURLs: [], plainText: "plain", images: []),
            .passthrough
        )
    }

    func testPasteboardClassificationRefusesRemoteURLs() {
        let remote = URL(string: "https://example.com/screenshot.png")!
        XCTAssertEqual(
            ChatPasteboardClassifier.classify(
                fileURLs: [remote], plainText: nil, images: []
            ),
            .passthrough
        )
        let local = URL(fileURLWithPath: "/tmp/report.pdf")
        XCTAssertEqual(
            ChatPasteboardClassifier.classify(
                fileURLs: [remote, local], plainText: nil, images: []
            ),
            .attachFiles([local])
        )
    }

    func testPastedImagePayloadKeepsPNGAndDetectsSignature() {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        XCTAssertTrue(pngBytes.isPNG)
        XCTAssertFalse(Data([0xFF, 0xD8, 0xFF]).isPNG)
        let payload = ChatPasteboardClassifier.imagePayload(pngData: pngBytes, tiffData: nil)
        XCTAssertEqual(payload, PastedImage(data: pngBytes, mimeType: "image/png"))
        XCTAssertNil(ChatPasteboardClassifier.imagePayload(pngData: nil, tiffData: nil))
        XCTAssertNil(
            ChatPasteboardClassifier.imagePayload(pngData: Data(), tiffData: Data([0x00]))
        )
    }

    // MARK: - Highlighted-text search

    func testWebSearchQueryCollapsesMultiLineSelections() {
        XCTAssertEqual(
            WebSearchQuery.normalize("  swift\n  actor   isolation \n"),
            "swift actor isolation"
        )
        XCTAssertEqual(WebSearchQuery.normalize("   \n\t "), "")
    }

    func testWebSearchQueryTruncatesOnAWordBoundary() {
        let query = String(repeating: "alpha ", count: 40).trimmingCharacters(in: .whitespaces)
        let truncated = WebSearchQuery.truncate(query, limit: 12)
        XCTAssertEqual(truncated, "alpha alpha")
        // A single word longer than the limit has no boundary to cut on, so it
        // is cut where the limit falls rather than dropped entirely.
        XCTAssertEqual(WebSearchQuery.truncate("abcdefghij", limit: 4), "abcd")
        XCTAssertEqual(WebSearchQuery.truncate("short", limit: 64), "short")
    }

    func testWebSearchURLEncodesTheSelectionItself() {
        let url = WebSearchQuery.url(for: "swift c++ & rust")
        XCTAssertEqual(
            url?.absoluteString,
            "https://www.google.com/search?q=swift%20c%2B%2B%20%26%20rust"
        )
        // Round-tripping matters more than the exact escaping: a literal "+"
        // decoded back as a space would search for something else.
        XCTAssertEqual(
            URLComponents(url: url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value,
            "swift c++ & rust"
        )
    }

    func testWebSearchURLRefusesASelectionWithNoQueryInIt() {
        XCTAssertNil(WebSearchQuery.url(for: "   \n  "))
        XCTAssertNil(WebSearchQuery.url(for: ""))
    }

    func testWebSearchURLStaysWithinTheQueryLimit() {
        let selection = String(repeating: "locus ", count: 400)
        let url = WebSearchQuery.url(for: selection)
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertNotNil(query)
        XCTAssertLessThanOrEqual(query!.count, WebSearchQuery.characterLimit)
        XCTAssertTrue(query!.hasPrefix("locus locus"))
    }

    func testWebSearchDestinationDefaultsToTheDefaultBrowser() throws {
        XCTAssertEqual(AppSettings().resolvedWebSearchDestination, .defaultBrowser)

        // Settings written before this preference existed must decode without
        // losing the rest of the file.
        let legacy = Data(#"{"browserEnabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(decoded.resolvedWebSearchDestination, .defaultBrowser)
        XCTAssertFalse(decoded.browserEnabled)

        var settings = AppSettings()
        settings.webSearchDestinationRaw = WebSearchDestination.locusBrowser.rawValue
        XCTAssertEqual(settings.resolvedWebSearchDestination, .locusBrowser)

        // An unknown destination from a future version falls back rather than
        // failing the decode.
        settings.webSearchDestinationRaw = "quantumBrowser"
        XCTAssertEqual(settings.resolvedWebSearchDestination, .defaultBrowser)
    }

    // MARK: - Rich chat management

    func testSessionSummaryOrganizationFieldsRoundTripAndRemainOptional() throws {
        let organized = SessionSummary(
            id: "organized",
            name: "organized.jsonl",
            preview: "Research notes",
            mtime: 42,
            size: 100,
            cwd: "/tmp/project",
            folderID: "folder-1",
            sortOrder: 3
        )
        let decoded = try JSONDecoder().decode(
            SessionSummary.self,
            from: JSONEncoder().encode(organized)
        )
        XCTAssertEqual(decoded.folderID, "folder-1")
        XCTAssertEqual(decoded.sortOrder, 3)

        let legacy = try JSONDecoder().decode(
            SessionSummary.self,
            from: Data(#"{"id":"old","name":"old.jsonl","preview":"Hi","mtime":1,"size":2}"#.utf8)
        )
        XCTAssertNil(legacy.folderID)
        XCTAssertNil(legacy.sortOrder)
    }

    @MainActor
    func testFolderNameSearchIncludesDescendantChatsAndAncestors() {
        let model = AppModel(startImmediately: false)
        let workspace = "/tmp/locus-folder-search"
        model.sessions = [
            SessionSummary(
                id: "nested-chat", name: "nested.jsonl", preview: "Unrelated title",
                mtime: 1, size: 1, cwd: workspace, folderID: "child", sortOrder: 0
            ),
        ]
        model.chatFolders = [
            ChatFolderRecord(
                id: "parent", workspace: workspace, parentID: nil,
                name: "Research", order: 0
            ),
            ChatFolderRecord(
                id: "child", workspace: workspace, parentID: "parent",
                name: "Sources", order: 0
            ),
        ]
        model.searchQuery = "Research"

        XCTAssertEqual(model.filteredSessions.map(\.id), ["nested-chat"])
        let group = model.workspaceChatGroups.first { $0.path == workspace }
        XCTAssertNotNil(group)
        XCTAssertEqual(model.folders(in: group!).map(\.id), ["parent"])
    }

    func testSplitRestorationRoundTripPreservesFocusAndDivider() throws {
        let value = ChatSplitRestoration(
            primarySessionID: "left",
            secondarySessionID: "right",
            focusedPane: .secondary,
            dividerRatio: 0.62
        )
        let decoded = try JSONDecoder().decode(
            ChatSplitRestoration.self,
            from: JSONEncoder().encode(value)
        )
        XCTAssertEqual(decoded, value)
        XCTAssertTrue(decoded.isSplit)
        XCTAssertEqual(decoded.sessionID(for: .secondary), "right")
        XCTAssertEqual(ChatPaneID.primary.other, .secondary)
    }

    func testSplitWorkspaceAlwaysResolvesToSideBySidePresentation() {
        XCTAssertEqual(ChatWorkspacePresentation.resolve(isSplit: false), .single)
        XCTAssertEqual(ChatWorkspacePresentation.resolve(isSplit: true), .sideBySide)
    }

    // MARK: - RunWork

    /// Events arrive over the wire, so build them the way the app does rather
    /// than reaching past the decoder.
    private func runEvents(_ raw: [[String: Any]]) throws -> [OrchestrationEvent] {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode([OrchestrationEvent].self, from: data)
    }

    func testRunWorkReadsFilesAndCommandsFromToolResults() throws {
        let events = try runEvents([
            ["seq": 1, "type": "run_started"],
            [
                "seq": 2, "type": "tool_result", "tool": "write_file", "ok": true,
                "event_id": "a", "summary": "write app.py (20 lines)",
                "file_effects": [["path": "app.py", "effect": "create"]],
            ],
            [
                "seq": 3, "type": "tool_result", "tool": "bash", "ok": true,
                "event_id": "b", "summary": "$ pytest",
            ],
            [
                "seq": 4, "type": "tool_result", "tool": "multi_edit", "ok": true,
                "event_id": "c", "summary": "edit app.py",
                "file_effects": [
                    ["path": "app.py", "effect": "edit"],
                    ["path": "util.py", "effect": "edit"],
                ],
            ],
            ["seq": 5, "type": "turn_done"],
        ])

        let work = RunWork(events: events)

        XCTAssertEqual(work.toolSteps, 3)
        // A file created and later edited in the same run still reads as new.
        XCTAssertEqual(
            work.files,
            [
                RunWork.FileChange(path: "app.py", effect: "created"),
                RunWork.FileChange(path: "util.py", effect: "edited"),
            ]
        )
        XCTAssertEqual(work.commands.map(\.summary), ["$ pytest"])
        XCTAssertFalse(work.isEmpty)
        XCTAssertFalse(work.delegationUnavailable)
    }

    func testRunWorkIgnoresFailedEffectsAndDeletions() throws {
        let events = try runEvents([
            [
                "seq": 1, "type": "tool_result", "tool": "write_file", "ok": false,
                "event_id": "a", "summary": "write blocked.py",
                "file_effects": [["path": "blocked.py", "effect": "create"]],
            ],
            [
                "seq": 2, "type": "tool_result", "tool": "bash", "ok": false,
                "event_id": "b", "summary": "$ false",
            ],
            [
                "seq": 3, "type": "tool_result", "tool": "delete_file", "ok": true,
                "event_id": "c", "summary": "delete old.py",
                "file_effects": [["path": "old.py", "effect": "delete"]],
            ],
        ])

        let work = RunWork(events: events)

        // A call that did not succeed wrote nothing, and a deleted file is not
        // something to list and offer to open.
        XCTAssertTrue(work.files.isEmpty)
        XCTAssertEqual(work.toolSteps, 3)
        XCTAssertEqual(work.commands.map(\.ok), [false])
    }

    func testRunWorkDropsAFileCreatedAndThenDeletedInTheSameRun() throws {
        let work = RunWork(events: try runEvents([
            [
                "seq": 1, "type": "tool_result", "tool": "write_file", "ok": true,
                "event_id": "a", "summary": "write scratch.py",
                "file_effects": [["path": "scratch.py", "effect": "create"]],
            ],
            [
                "seq": 2, "type": "tool_result", "tool": "delete_file", "ok": true,
                "event_id": "b", "summary": "delete scratch.py",
                "file_effects": [["path": "scratch.py", "effect": "delete"]],
            ],
            [
                "seq": 3, "type": "tool_result", "tool": "write_file", "ok": true,
                "event_id": "c", "summary": "write kept.py",
                "file_effects": [["path": "kept.py", "effect": "create"]],
            ],
        ]))

        // "Created" must not survive the file's own deletion; a file that no
        // longer exists cannot be listed and offered to open.
        XCTAssertEqual(work.files, [RunWork.FileChange(path: "kept.py", effect: "created")])
    }

    func testRunWorkListsAFileRecreatedAfterDeletionAsCreated() throws {
        let work = RunWork(events: try runEvents([
            [
                "seq": 1, "type": "tool_result", "tool": "write_file", "ok": true,
                "event_id": "a", "summary": "write app.py",
                "file_effects": [["path": "app.py", "effect": "create"]],
            ],
            [
                "seq": 2, "type": "tool_result", "tool": "delete_file", "ok": true,
                "event_id": "b", "summary": "delete app.py",
                "file_effects": [["path": "app.py", "effect": "delete"]],
            ],
            [
                "seq": 3, "type": "tool_result", "tool": "write_file", "ok": true,
                "event_id": "c", "summary": "write app.py",
                "file_effects": [["path": "app.py", "effect": "create"]],
            ],
        ]))

        XCTAssertEqual(work.files, [RunWork.FileChange(path: "app.py", effect: "created")])
    }

    func testRunScopedEventsSeparateInterleavedRuns() throws {
        // While a historical run is open during a live turn, the shared array
        // holds both: the selected run's fetched history (including backend
        // events persisted without a run_id stamp) and the live run's stamped
        // stream. Scoping must keep the former and exclude the latter.
        let events = try runEvents([
            ["seq": 1, "type": "run_started", "event_id": "a1", "run_id": "run-a"],
            [
                "seq": 2, "type": "tool_result", "tool": "bash", "ok": true,
                "event_id": "a2", "summary": "$ pytest", "run_id": "run-a",
            ],
            ["seq": 3, "type": "orchestration_completed", "event_id": "a3"],
            ["seq": 1, "type": "run_started", "event_id": "b1", "run_id": "run-b"],
            [
                "seq": 2, "type": "tool_result", "tool": "write_file", "ok": true,
                "event_id": "b2", "summary": "write app.py", "run_id": "run-b",
                "file_effects": [["path": "app.py", "effect": "create"]],
            ],
        ])

        let scoped = AppModel.runScopedEvents(events, runID: "run-a")

        XCTAssertEqual(scoped.map(\.id), ["a1", "a2", "a3"])
        let work = RunWork(events: scoped)
        XCTAssertTrue(work.files.isEmpty)
        XCTAssertEqual(work.toolSteps, 1)
        XCTAssertEqual(work.commands.map(\.summary), ["$ pytest"])
    }

    func testRunWorkSeparatesUnavailableDelegationFromAnAgentDecliningIt() throws {
        let quiet = RunWork(events: try runEvents([
            ["seq": 1, "type": "note", "text": "Nothing to split here."],
        ]))
        XCTAssertFalse(quiet.delegationUnavailable)

        let broken = RunWork(events: try runEvents([[
            "seq": 1, "type": "note",
            "text": "The selected provider does not support Solo delegation.",
            "solo_swarm_unavailable": true,
        ]]))
        XCTAssertTrue(broken.delegationUnavailable)
    }

    func testRunWorkOfATurnThatOnlyTalkedIsEmpty() throws {
        let work = RunWork(events: try runEvents([
            ["seq": 1, "type": "run_started"],
            ["seq": 2, "type": "turn_done"],
        ]))
        XCTAssertTrue(work.isEmpty)
        XCTAssertEqual(work.toolSteps, 0)
    }

    func testDisplayUserTextDropsTheComposerDecoration() {
        let decorated = """
        [Locus mode: Build]

        Implement the request completely using the Get Shit Done method.

        User request:
        make a stock checker
        """
        XCTAssertEqual(ChatTranscriptBuilder.displayUserText(decorated), "make a stock checker")
        XCTAssertEqual(ChatTranscriptBuilder.displayUserText("plain ask"), "plain ask")
    }
}
