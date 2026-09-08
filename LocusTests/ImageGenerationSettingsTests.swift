import AppKit
import Foundation
import XCTest

@testable import Locus

/// The image provider handoff: which accounts qualify, what the app sends to
/// `/api/images/provider`, how the settings survive relaunch, and what
/// "Edit in chat" is allowed to attach.
@MainActor
final class ImageGenerationSettingsTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        BackendStub.reset()
    }

    override func tearDown() async throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        BackendStub.reset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeModel(
        credentialStore: InMemoryCredentialStore = InMemoryCredentialStore()
    ) -> AppModel {
        AppModel(
            startImmediately: false,
            backendOverride: stubbedBackendService(),
            credentialStore: credentialStore
        )
    }

    /// Adds an account through the real save path so the key lands in the
    /// model's private in-memory credential store.
    @discardableResult
    private func seedAccount(
        _ model: AppModel,
        kind: ProviderKind,
        name: String,
        baseURLOverride: String? = nil,
        key: String? = "sk-test"
    ) -> ProviderAccount {
        let account = ProviderAccount(kind: kind, name: name, baseURLOverride: baseURLOverride)
        XCTAssertTrue(model.saveProviderAccount(account, apiKey: key))
        return model.providerAccounts.first { $0.id == account.id } ?? account
    }

    /// Places an account and its key without the save path, whose background
    /// catalog refresh re-pushes the image provider on its own schedule and
    /// would blur a test that counts pushes.
    private func insertAccount(
        _ model: AppModel, kind: ProviderKind, name: String, key: String = "sk-test"
    ) -> ProviderAccount {
        let account = ProviderAccount(kind: kind, name: name)
        model.providerAccounts.append(account)
        model.credentialStore.set(key, account: account.credentialAccount)
        return account
    }

    private func pointWorkspace(_ model: AppModel, at root: URL) {
        model.sessionInfo = SessionInfo(
            model: "m", host: "h", cwd: root.path, session: "s", sessionID: "s",
            messages: 0, approxTokens: 0, promptTokens: 0, completionTokens: 0,
            contextLimit: 0, maxIterations: 40, hasProjectContext: false,
            permissions: SessionPermissions(skipAll: false, allowed: [])
        )
    }

    /// A workspace holding one real PNG under `Locus Images/`.
    private func makeWorkspace(imageName: String = "sunset.png") throws -> (root: URL, image: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-settings-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Locus Images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        let image = folder.appendingPathComponent(imageName)
        try Self.pngData().write(to: image)
        return (root, image)
    }

    private static func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// The JSON body of a recorded request; URLProtocol may hand it over as a
    /// stream rather than `httpBody`.
    private static func body(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static var imagePushes: [URLRequest] {
        BackendStub.requests.filter { $0.url?.path == "/api/images/provider" }
    }

    private static func imagePushes(host: String) -> [URLRequest] {
        imagePushes.filter { $0.url?.host == host }
    }

    /// A transport answered by BackendStub under its own host name, so a
    /// worker's traffic can be told from the main agent's.
    private func stubbedService(host: String) -> BackendService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendStub.self]
        return BackendService(
            baseURL: URL(string: "http://\(host)")!,
            authToken: "test-token",
            session: URLSession(configuration: configuration)
        )
    }

    /// A live chat worker whose service is the stub, keyed like the app keys
    /// the ones it spawns.
    @discardableResult
    private func addWorker(_ model: AppModel, sessionID: String, host: String) -> ChatWorkerRuntime {
        let runtime = ChatWorkerRuntime(
            requestedSessionID: sessionID, workspacePath: "/tmp", process: BackendProcess(),
            endpoint: URL(string: "http://\(host)")!, service: stubbedService(host: host)
        )
        model.taskWorkers[sessionID] = runtime
        return runtime
    }

    private static func configuredState(_ url: URL) -> [String: Any] {
        [
            "configured": true, "host": "https://api.openai.com/v1",
            "model": "gpt-image-1", "size": "auto", "quality": "auto",
            "account_id": "a", "account_label": "OpenAI API", "has_api_key": true,
        ]
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 5,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    // MARK: - Feature model

    func testConstructionAndConfigureAreInert() {
        let model = ImageGenerationModel()
        model.configure(backend: stubbedBackendService())
        XCTAssertNil(model.state)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isApplying)
        XCTAssertNoBackendTraffic()
    }

    func testApplyRecordsTheAgentsPublicStateAndClearsTheLastError() async throws {
        BackendStub.respond(toPath: "/api/images/provider") { _ in
            [
                "configured": true, "host": "https://api.openai.com/v1",
                "model": "gpt-image-1", "size": "auto", "quality": "auto",
                "account_id": "a", "account_label": "OpenAI API", "has_api_key": true,
            ]
        }
        let model = ImageGenerationModel()
        model.configure(backend: stubbedBackendService())
        model.recordFailure("earlier")
        let state = try await model.apply(body: ["enabled": true])
        XCTAssertTrue(state.configured)
        XCTAssertEqual(model.state?.model, "gpt-image-1")
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isApplying)
        XCTAssertEqual(BackendStub.requestPaths, ["/api/images/provider"])
    }

    func testFailedApplyRecordsTheErrorAndKeepsTheLastGoodState() async {
        let model = ImageGenerationModel()
        model.configure(backend: stubbedBackendService())
        model.record(ImageProviderStateResponse(configured: true, model: "gpt-image-1"))
        BackendStub.respond(toPath: "/api/images/provider", status: 422) { _ in
            ["detail": "base_url must use https"]
        }
        do {
            try await model.apply(body: ["enabled": true])
            XCTFail("a 422 must throw")
        } catch {
            XCTAssertNotNil(model.lastError)
            XCTAssertEqual(model.state?.model, "gpt-image-1")
        }
    }

    // MARK: - Request body

    func testRequestBodyIsBuiltOnlyForImageCapableAccountsAndNeverForChatGPT() throws {
        let store = InMemoryCredentialStore()
        let model = makeModel(credentialStore: store)
        defer { model.eventAutomations.stop() }
        XCTAssertEqual(model.imageProviderRequestBody() as NSDictionary, ["enabled": false])

        let openAI = seedAccount(model, kind: .codex, name: "Work", key: "sk-openai")
        let chatGPT = seedAccount(model, kind: .chatGPT, name: "Plan", key: nil)
        let claude = seedAccount(model, kind: .claude, name: "Claude", key: "sk-ant")
        let kimi = seedAccount(model, kind: .kimiCode, name: "Kimi", key: "kimi-key")
        let custom = seedAccount(
            model, kind: .custom, name: "Gateway",
            baseURLOverride: "https://gateway.example/v1", key: "gw-key"
        )

        XCTAssertEqual(
            Set(model.eligibleImageAccounts.map(\.id)), [openAI.id, custom.id],
            "only OpenAI API and compatible custom endpoints can serve the Images API"
        )

        model.settings.imageGenerationAccountID = openAI.id.uuidString
        model.settings.imageGenerationModel = "gpt-image-1-mini"
        model.settings.imageGenerationSize = "1024x1024"
        model.settings.imageGenerationQuality = "high"
        let body = model.imageProviderRequestBody()
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertEqual(body["account_id"] as? String, openAI.id.uuidString)
        XCTAssertEqual(body["account_label"] as? String, openAI.displayName)
        XCTAssertEqual(body["base_url"] as? String, "https://api.openai.com/v1")
        XCTAssertEqual(body["api_key"] as? String, "sk-openai")
        XCTAssertEqual(body["model"] as? String, "gpt-image-1-mini")
        XCTAssertEqual(body["size"] as? String, "1024x1024")
        XCTAssertEqual(body["quality"] as? String, "high")

        model.settings.imageGenerationAccountID = custom.id.uuidString
        let customBody = model.imageProviderRequestBody()
        XCTAssertEqual(customBody["enabled"] as? Bool, true)
        XCTAssertEqual(customBody["base_url"] as? String, "https://gateway.example/v1")
        XCTAssertEqual(customBody["api_key"] as? String, "gw-key")

        for ineligible in [chatGPT, claude, kimi] {
            model.settings.imageGenerationAccountID = ineligible.id.uuidString
            XCTAssertEqual(
                model.imageProviderRequestBody() as NSDictionary, ["enabled": false],
                "\(ineligible.kind) must never be pushed as an image provider"
            )
        }

        model.settings.imageGenerationAccountID = UUID().uuidString
        XCTAssertEqual(
            model.imageProviderRequestBody() as NSDictionary, ["enabled": false],
            "a removed account reads as off"
        )
    }

    func testRequestBodyOmitsTheKeyWhenTheStoreHasNoneAndRestoresTheDefaultModel() {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        // A local OpenAI-compatible server needs no key at all.
        let local = seedAccount(
            model, kind: .custom, name: "LM Studio",
            baseURLOverride: "http://127.0.0.1:1234/v1", key: nil
        )
        model.settings.imageGenerationAccountID = local.id.uuidString
        model.settings.imageGenerationModel = "   "
        let body = model.imageProviderRequestBody()
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertNil(body["api_key"], "an absent key is omitted, not sent as an empty string")
        XCTAssertEqual(body["model"] as? String, "gpt-image-1")
    }

    // MARK: - Settings persistence

    func testSettingsDecodeAnEmptyPayloadWithDefaultsAndRoundTripTheImageFields() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.imageGenerationAccountID)
        XCTAssertEqual(decoded.imageGenerationModel, "gpt-image-1")
        XCTAssertEqual(decoded.imageGenerationSize, "auto")
        XCTAssertEqual(decoded.imageGenerationQuality, "auto")
        XCTAssertTrue(decoded.interactiveAnswersEnabled)

        var chosen = decoded
        chosen.imageGenerationAccountID = UUID().uuidString
        chosen.imageGenerationModel = "gpt-image-1-mini"
        chosen.imageGenerationSize = "1536x1024"
        chosen.imageGenerationQuality = "low"
        chosen.interactiveAnswersEnabled = false
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(chosen)
        )
        XCTAssertEqual(restored, chosen)
        XCTAssertEqual(restored.imageGenerationAccountID, chosen.imageGenerationAccountID)
        XCTAssertEqual(restored.imageGenerationModel, "gpt-image-1-mini")
        XCTAssertEqual(restored.imageGenerationSize, "1536x1024")
        XCTAssertEqual(restored.imageGenerationQuality, "low")
        XCTAssertFalse(restored.interactiveAnswersEnabled)

        // The Settings window applies these live, like the voice choices.
        var live = AppSettings()
        live.applyImmediatePreferences(from: chosen)
        XCTAssertEqual(live.imageGenerationAccountID, chosen.imageGenerationAccountID)
        XCTAssertEqual(live.imageGenerationModel, "gpt-image-1-mini")
        XCTAssertEqual(live.imageGenerationQuality, "low")
        XCTAssertFalse(live.interactiveAnswersEnabled)
    }

    func testProviderStateDecodesNullFieldsAsOff() throws {
        let json = Data(#"{"configured": false, "host": null, "model": null, "account_id": null}"#.utf8)
        let state = try JSONDecoder().decode(ImageProviderStateResponse.self, from: json)
        XCTAssertFalse(state.configured)
        XCTAssertEqual(state.host, "")
        XCTAssertEqual(state.model, "")
        XCTAssertFalse(state.hasAPIKey)
    }

    // MARK: - Push sites

    func testRemovingTheImageAccountClearsTheChoiceAndPushesDisabled() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider") { _ in
            ["configured": false, "has_api_key": false]
        }
        let account = seedAccount(model, kind: .codex, name: "Work")
        model.settings.imageGenerationAccountID = account.id.uuidString
        XCTAssertEqual(model.imageProviderRequestBody()["enabled"] as? Bool, true)

        model.removeProviderAccount(account)

        XCTAssertNil(model.settings.imageGenerationAccountID)
        await waitUntil({ !Self.imagePushes.isEmpty }, "the agent is told")
        let request = Self.imagePushes.first
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(
            request.flatMap(Self.body(of:)).map { $0 as NSDictionary }, ["enabled": false],
            "the agent must drop the removed account's key"
        )
        await waitUntil({ model.imageGeneration.state != nil }, "the answer is recorded")
        XCTAssertEqual(model.imageGeneration.state?.configured, false)
    }

    func testRemovingAnotherAccountLeavesTheImageChoiceAlone() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider") { _ in ["configured": false] }
        let imageAccount = seedAccount(model, kind: .codex, name: "Images")
        let other = seedAccount(model, kind: .codex, name: "Other")
        model.removeProviderAccount(other)
        model.settings.imageGenerationAccountID = imageAccount.id.uuidString
        model.removeProviderAccount(ProviderAccount(kind: .codex, name: "Never saved"))
        XCTAssertEqual(model.settings.imageGenerationAccountID, imageAccount.id.uuidString)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(
            Self.imagePushes.allSatisfy { Self.body(of: $0)?["enabled"] as? Bool == true },
            "removing another account never pushes enabled:false"
        )
    }

    func testChangingAnImageSettingPushesTheProviderAndUnrelatedChangesDoNot() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider") { _ in
            [
                "configured": true, "host": "https://api.openai.com/v1",
                "model": "gpt-image-1", "size": "auto", "quality": "high",
                "account_id": "a", "account_label": "OpenAI API", "has_api_key": true,
            ]
        }
        let account = seedAccount(model, kind: .codex, name: "Work")

        var unrelated = model.settings
        unrelated.notifyOnCompletion.toggle()
        model.applySettings(unrelated, showConfirmation: false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(Self.imagePushes.isEmpty, "an unrelated change never pushes")

        var changed = model.settings
        changed.imageGenerationAccountID = account.id.uuidString
        changed.imageGenerationQuality = "high"
        model.applySettings(changed, showConfirmation: false)

        await waitUntil({ !Self.imagePushes.isEmpty }, "the image change pushes")
        let body = Self.imagePushes.first.flatMap(Self.body(of:))
        XCTAssertEqual(body?["enabled"] as? Bool, true)
        XCTAssertEqual(body?["quality"] as? String, "high")
        XCTAssertEqual(body?["api_key"] as? String, "sk-test")
        await waitUntil({ model.imageGeneration.state?.configured == true }, "state recorded")
    }

    // MARK: - Chat workers

    func testNewChatWorkerReceivesTheImageProviderWithItsKey() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider", with: Self.configuredState)
        let account = insertAccount(model, kind: .codex, name: "Work", key: "sk-worker")
        model.settings.imageGenerationAccountID = account.id.uuidString

        let outcome = await model.pushImageProvider(to: stubbedService(host: "chat-worker.test"))

        XCTAssertEqual(outcome, .applied)
        let pushes = Self.imagePushes(host: "chat-worker.test")
        XCTAssertEqual(pushes.count, 1, "one push per spawned worker")
        XCTAssertEqual(pushes.first?.httpMethod, "POST")
        let body = pushes.first.flatMap(Self.body(of:))
        XCTAssertEqual(body?["enabled"] as? Bool, true)
        XCTAssertEqual(body?["api_key"] as? String, "sk-worker")
        XCTAssertNil(model.toastMessage)
        XCTAssertNil(model.imageGeneration.state, "a worker's answer is not the state Settings shows")
    }

    func testNewChatWorkerIsToldOffWhenNoAccountIsChosen() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider") { _ in ["configured": false] }

        let outcome = await model.pushImageProvider(to: stubbedService(host: "chat-worker.test"))

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(
            Self.imagePushes(host: "chat-worker.test").first.flatMap(Self.body(of:)).map { $0 as NSDictionary },
            ["enabled": false]
        )
    }

    func testWorkerPushIsSkippedWhenTheCapabilityIsOff() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        model.backendCapabilities["image_generation_v1"] = false
        let outcome = await model.pushImageProvider(to: stubbedService(host: "chat-worker.test"))
        XCTAssertEqual(outcome, .skipped)
        XCTAssertNoBackendTraffic()
    }

    func testWorkerPushFailureCostsTheToolsNotTheWorkerAndIsAnnouncedOnce() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider", status: 500) { _ in
            ["detail": "images service exploded"]
        }
        let account = seedAccount(model, kind: .codex, name: "Work")
        model.settings.imageGenerationAccountID = account.id.uuidString

        let outcome = await model.pushImageProvider(to: stubbedService(host: "chat-worker.test"))

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(
            model.toastMessage,
            "Image generation is unavailable in this chat: images service exploded"
        )
        XCTAssertNil(model.imageGeneration.lastError, "the main agent's status is untouched")

        // A worker that could not be told "off" has nothing to announce.
        model.toast = nil
        model.settings.imageGenerationAccountID = nil
        let off = await model.pushImageProvider(to: stubbedService(host: "chat-worker.test"))
        XCTAssertEqual(off, .failed)
        XCTAssertNil(model.toastMessage)
    }

    func testApplyImageProviderReachesEveryLiveWorkerNotJustTheCurrentOne() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider") { _ in ["configured": false] }
        model.currentSessionID = "current"
        addWorker(model, sessionID: "current", host: "worker-current.test")
        addWorker(model, sessionID: "background", host: "worker-background.test")
        let account = seedAccount(model, kind: .codex, name: "Work")
        model.settings.imageGenerationAccountID = account.id.uuidString

        model.removeProviderAccount(account)

        for host in ["127.0.0.1", "worker-current.test", "worker-background.test"] {
            await waitUntil({ !Self.imagePushes(host: host).isEmpty }, "\(host) is told")
            XCTAssertEqual(
                Self.imagePushes(host: host).last.flatMap(Self.body(of:)).map { $0 as NSDictionary },
                ["enabled": false],
                "\(host) must drop the removed account's key"
            )
        }
    }

    func testRotatedKeyReachesEveryLiveWorker() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider", with: Self.configuredState)
        addWorker(model, sessionID: "a", host: "worker-a.test")
        addWorker(model, sessionID: "b", host: "worker-b.test")
        let account = insertAccount(model, kind: .codex, name: "Work", key: "sk-new")
        model.settings.imageGenerationAccountID = account.id.uuidString

        let ok = await model.applyImageProvider(announce: false)

        XCTAssertTrue(ok)
        for host in ["127.0.0.1", "worker-a.test", "worker-b.test"] {
            let pushes = Self.imagePushes(host: host)
            XCTAssertEqual(pushes.count, 1, host)
            XCTAssertEqual(pushes.first.flatMap(Self.body(of:))?["api_key"] as? String, "sk-new", host)
        }
    }

    func testPushRefusedWhileBusyIsRetriedOnceWhenTheTurnEnds() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider", status: 409) { _ in
            ["detail": "the agent is busy"]
        }
        let account = insertAccount(model, kind: .codex, name: "Work")
        model.settings.imageGenerationAccountID = account.id.uuidString

        let ok = await model.applyImageProvider(announce: true)

        XCTAssertFalse(ok)
        XCTAssertEqual(Self.imagePushes.count, 1)
        XCTAssertTrue(model.imageGeneration.pushDeferredUntilIdle)
        XCTAssertEqual(model.toastMessage, "Could not update image generation: the agent is busy")

        BackendStub.reset()
        BackendStub.respond(toPath: "/api/images/provider", with: Self.configuredState)
        model.handleEventForTesting(["type": "turn_done"])

        await waitUntil({ !Self.imagePushes.isEmpty }, "the turn ending re-pushes")
        XCTAssertFalse(model.imageGeneration.pushDeferredUntilIdle)
        XCTAssertEqual(Self.imagePushes.first.flatMap(Self.body(of:))?["enabled"] as? Bool, true)
        await waitUntil({ model.imageGeneration.state?.configured == true }, "the retry records state")
        XCTAssertNil(model.imageGeneration.lastError)

        model.handleEventForTesting(["type": "turn_done"])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Self.imagePushes.count, 1, "a retry happens exactly once")
    }

    func testABusyWorkerIsRetriedWhenTheTurnEndsEvenIfTheMainAgentAccepted() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider", with: Self.configuredState)
        addWorker(model, sessionID: "busy", host: "worker-busy.test")
        let account = seedAccount(model, kind: .codex, name: "Work")
        model.settings.imageGenerationAccountID = account.id.uuidString
        // The main agent answers 200 and the worker 409: BackendStub matches
        // the first route, so the worker refusal is expressed by a busy
        // refusal from the model's own classifier on a synthetic error.
        let refusal = NSError(domain: "Locus.Backend", code: 409, userInfo: [NSLocalizedDescriptionKey: "busy"])
        XCTAssertTrue(ImageGenerationModel.isBusyRefusal(refusal))
        XCTAssertFalse(ImageGenerationModel.isBusyRefusal(NSError(domain: "Locus.Backend", code: 422)))
        XCTAssertFalse(ImageGenerationModel.isBusyRefusal(NSError(domain: "Other", code: 409)))

        model.imageGeneration.deferPushUntilIdle()
        model.handleEventForTesting(["type": "slash_result", "command": "help"])

        await waitUntil({ !Self.imagePushes(host: "worker-busy.test").isEmpty }, "the worker is re-pushed")
        XCTAssertFalse(model.imageGeneration.pushDeferredUntilIdle)
    }

    func testNonBusyFailuresAreNotRetried() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/images/provider", status: 422) { _ in
            ["detail": "base_url must use https"]
        }
        let account = insertAccount(model, kind: .codex, name: "Work")
        model.settings.imageGenerationAccountID = account.id.uuidString

        let ok = await model.applyImageProvider(announce: false)

        XCTAssertFalse(ok)
        XCTAssertFalse(model.imageGeneration.pushDeferredUntilIdle, "a rejected body would fail again")
        model.handleEventForTesting(["type": "turn_done"])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(Self.imagePushes.count, 1)
    }

    func testPushIsSkippedWhenTheAgentReportsTheCapabilityOff() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        model.backendCapabilities["image_generation_v1"] = false
        let ok = await model.applyImageProvider(announce: false)
        XCTAssertTrue(ok)
        XCTAssertNoBackendTraffic()
    }

    func testSavingTheImageAccountRePushesItsKey() async {
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        BackendStub.respond(toPath: "/api/provider") { _ in
            ["provider": "remote", "host": "h", "model": "m",
             "remote_base_url": "h", "remote_model": "m", "has_api_key": true]
        }
        BackendStub.respond(toPath: "/api/images/provider") { _ in
            ["configured": true, "has_api_key": true]
        }
        BackendStub.respond(whenPathHasPrefix: "/") { _ in [:] }
        let account = seedAccount(model, kind: .codex, name: "Work", key: "sk-old")
        model.settings.imageGenerationAccountID = account.id.uuidString

        XCTAssertTrue(model.saveProviderAccount(account, apiKey: "sk-new"))

        // The catalog refresh that precedes the push may wait on a real DNS
        // failure for the fixture host, so allow for that.
        await waitUntil({ !Self.imagePushes.isEmpty }, timeout: 20, "the key is re-sent")
        let request = Self.imagePushes.last
        XCTAssertEqual(request.flatMap(Self.body(of:))?["api_key"] as? String, "sk-new")
    }

    // MARK: - Edit in chat

    func testEditInChatReContainsTheImageAttachesItAndPrefillsAnEmptyDraft() async throws {
        let (root, image) = try makeWorkspace()
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        pointWorkspace(model, at: root)
        let reference = try XCTUnwrap(WorkspaceArtifactReference.classify(
            "Locus Images/sunset.png", workspacePath: root.path
        ))
        XCTAssertEqual(reference.kind, .image)
        let focusBefore = model.composerFocusToken

        model.attachWorkspaceImageForEditing(reference)

        await waitUntil({ model.chatAttachments.count == 1 }, "the image is attached")
        XCTAssertEqual(
            model.chatAttachments.first?.url.standardizedFileURL.resolvingSymlinksInPath(),
            image.standardizedFileURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(model.chatAttachments.first?.kind, .image)
        XCTAssertEqual(model.draftText, "Edit `Locus Images/sunset.png`: ")
        XCTAssertNotEqual(model.composerFocusToken, focusBefore)
        XCTAssertTrue(AppModel.namesWorkspaceImagePath(model.draftText))
    }

    func testEditInChatRefusesEscapesAndOtherWorkspaces() async throws {
        let (root, _) = try makeWorkspace()
        let (otherRoot, otherImage) = try makeWorkspace(imageName: "elsewhere.png")
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        pointWorkspace(model, at: root)

        // A reference classified against another workspace: contained there,
        // not here.
        let foreign = try XCTUnwrap(WorkspaceArtifactReference.classify(
            "Locus Images/elsewhere.png", workspacePath: otherRoot.path
        ))
        model.attachWorkspaceImageForEditing(foreign)
        XCTAssertEqual(model.toastMessage, "That image is no longer available in this workspace")
        XCTAssertTrue(model.chatAttachments.isEmpty)
        XCTAssertEqual(model.draftText, "")

        // A hand-built reference whose relative path climbs out of the workspace.
        let escaping = WorkspaceArtifactReference(
            url: otherImage,
            relativePath: "../\(otherRoot.lastPathComponent)/Locus Images/elsewhere.png",
            kind: .image,
            byteCount: nil,
            sourceLocation: nil
        )
        model.attachWorkspaceImageForEditing(escaping)
        XCTAssertTrue(model.chatAttachments.isEmpty)
        XCTAssertEqual(model.draftText, "")

        // A relative path inside the workspace paired with a URL that is not:
        // the two must agree or nothing is attached.
        let mismatched = WorkspaceArtifactReference(
            url: otherImage,
            relativePath: "Locus Images/sunset.png",
            kind: .image,
            byteCount: nil,
            sourceLocation: nil
        )
        model.attachWorkspaceImageForEditing(mismatched)
        XCTAssertTrue(model.chatAttachments.isEmpty)

        // Not an image at all.
        let text = root.appendingPathComponent("notes.md")
        try Data("hi".utf8).write(to: text)
        let document = try XCTUnwrap(WorkspaceArtifactReference.classify(
            "notes.md", workspacePath: root.path
        ))
        model.attachWorkspaceImageForEditing(document)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.chatAttachments.isEmpty)
        XCTAssertEqual(model.draftText, "")
    }

    func testEditInChatPrefillsOnlyAnEmptyDraft() async throws {
        let (root, _) = try makeWorkspace()
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        pointWorkspace(model, at: root)
        model.draftText = "Make the sky purple"
        let reference = try XCTUnwrap(WorkspaceArtifactReference.classify(
            "Locus Images/sunset.png", workspacePath: root.path
        ))

        model.attachWorkspaceImageForEditing(reference)

        await waitUntil({ model.chatAttachments.count == 1 }, "the image is attached")
        XCTAssertEqual(model.draftText, "Make the sky purple", "a typed request is never overwritten")
    }

    func testEditInChatRespectsTheTenAttachmentCap() async throws {
        let (root, _) = try makeWorkspace()
        let model = makeModel()
        defer { model.eventAutomations.stop() }
        pointWorkspace(model, at: root)
        model.chatAttachments = (0..<10).map { index in
            ChatAttachment(
                url: root.appendingPathComponent("existing-\(index).txt"),
                kind: .text,
                textContent: "x"
            )
        }
        let reference = try XCTUnwrap(WorkspaceArtifactReference.classify(
            "Locus Images/sunset.png", workspacePath: root.path
        ))

        model.attachWorkspaceImageForEditing(reference)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.chatAttachments.count, 10)
        XCTAssertEqual(model.chatAttachmentNotice, "A chat message can include up to 10 attachments.")
        XCTAssertEqual(model.draftText, "", "no prefill for a request that cannot carry the image")
    }

    // MARK: - Prompt guidance

    func testDecoratedPromptTeachesTheWorkspacePathSourceOnlyWithAnImageAndAPath() throws {
        let (_, image) = try makeWorkspace()
        let attachment = ChatAttachment(
            url: image, kind: .image, imageData: try Self.pngData(), mimeType: "image/png"
        )
        let guidance = "pass the backticked workspace image path from the request as the source of edit_image"
        let named = "Edit `Locus Images/sunset.png`: make it dusk"

        let work = AppModel.decoratedPrompt(
            named, mode: .work, chatAttachments: [attachment], contextFiles: [],
            restoredTranscriptContext: nil
        )
        XCTAssertTrue(work.contains(guidance))
        XCTAssertTrue(work.contains("attachment:<name>"))

        // Edits land beside their source and `filename` can target any
        // folder, so any workspace-relative image path earns the guidance.
        for elsewhere in [
            "Edit `assets/logo-2.png`: sharpen it",
            "Edit `docs/Photo.JPG`: crop it",
            "Edit `hero.webp`: brighten it",
            "Edit `sprites/run.gif`: loop it",
        ] {
            let prompt = AppModel.decoratedPrompt(
                elsewhere, mode: .work, chatAttachments: [attachment], contextFiles: [],
                restoredTranscriptContext: nil
            )
            XCTAssertTrue(prompt.contains(guidance), elsewhere)
        }
        for notAWorkspaceImage in [
            "Edit `/Users/me/Desktop/photo.png`: crop it",
            "Edit `~/Pictures/photo.png`: crop it",
            "Edit `notes.md`: fix the typo",
            "Edit Locus Images/sunset.png without backticks",
        ] {
            XCTAssertFalse(AppModel.namesWorkspaceImagePath(notAWorkspaceImage), notAWorkspaceImage)
        }

        let noImage = AppModel.decoratedPrompt(
            named, mode: .work, chatAttachments: [], contextFiles: [],
            restoredTranscriptContext: nil
        )
        XCTAssertFalse(noImage.contains(guidance), "no attachment, nothing to disambiguate")

        let noPath = AppModel.decoratedPrompt(
            "Make it dusk", mode: .work, chatAttachments: [attachment], contextFiles: [],
            restoredTranscriptContext: nil
        )
        XCTAssertFalse(noPath.contains(guidance), "without a named path the attachment is the source")

        let ask = AppModel.decoratedPrompt(
            named, mode: .ask, chatAttachments: [attachment], contextFiles: [],
            restoredTranscriptContext: nil
        )
        XCTAssertFalse(ask.contains(guidance), "Just Chat has no edit_image tool")
    }

    // MARK: - Settings section

    func testCustomModelCommitsOnlyATrimmedChangedNonEmptyName() {
        var draft = AppSettings()
        draft.imageGenerationModel = "gpt-image-1"
        // Keystrokes never reach the draft; only the committed value does.
        XCTAssertTrue(ImageGenerationSettingsView.commitCustomModel("  my-model \n", into: &draft))
        XCTAssertEqual(draft.imageGenerationModel, "my-model")
        XCTAssertFalse(
            ImageGenerationSettingsView.commitCustomModel("my-model", into: &draft),
            "committing the same value again must not change the draft, so nothing is pushed"
        )
        XCTAssertFalse(ImageGenerationSettingsView.commitCustomModel("   ", into: &draft))
        XCTAssertEqual(draft.imageGenerationModel, "my-model", "a blank name keeps the last committed one")
    }

    func testInteractiveToggleFollowsItsOwnCapabilityNotTheImageOne() {
        XCTAssertTrue(ImageGenerationSettingsView.imageControlsDisabled(capabilities: ["image_generation_v1": false]))
        XCTAssertFalse(ImageGenerationSettingsView.interactiveToggleDisabled(capabilities: ["image_generation_v1": false]))
        XCTAssertTrue(ImageGenerationSettingsView.interactiveToggleDisabled(capabilities: ["interactive_answers_v1": false]))
        XCTAssertFalse(ImageGenerationSettingsView.imageControlsDisabled(capabilities: ["interactive_answers_v1": false]))
        XCTAssertFalse(ImageGenerationSettingsView.imageControlsDisabled(capabilities: [:]), "an older agent has both on")
        XCTAssertFalse(ImageGenerationSettingsView.interactiveToggleDisabled(capabilities: [:]))
    }

    // MARK: - Model lists

    func testChatModelFilterStillExcludesImageModelsWhileTheCuratedListKeepsThem() {
        let names = ["gpt-5", "gpt-image-1", "gpt-image-1-mini", "dall-e-3", "o3"]
        XCTAssertEqual(
            ProviderModelFilter.chatModels(kind: .codex, names: names),
            ["gpt-5", "o3"],
            "the chat picker keeps hiding image models"
        )
        XCTAssertEqual(ProviderKind.curatedImageModels, ["gpt-image-1", "gpt-image-1-mini"])
        for name in ProviderKind.curatedImageModels {
            XCTAssertFalse(
                ProviderModelFilter.matches(kind: .codex, name: name),
                "\(name) belongs to the image list, not the chat picker"
            )
        }
        XCTAssertTrue(ProviderKind.codex.supportsImageGeneration)
        XCTAssertTrue(ProviderKind.custom.supportsImageGeneration)
        for kind in [ProviderKind.chatGPT, .claude, .kimi, .kimiCode] {
            XCTAssertFalse(kind.supportsImageGeneration, "\(kind) has no Images API")
        }
        XCTAssertEqual(ImageGenerationSize.allCases.map(\.rawValue),
                       ["auto", "1024x1024", "1536x1024", "1024x1536"])
        XCTAssertEqual(ImageGenerationQuality.allCases.map(\.rawValue),
                       ["auto", "low", "medium", "high"])
    }
}
