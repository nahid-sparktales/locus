import AVFoundation
import XCTest
@testable import Locus

private final class VoiceURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler?(request)
                ?? (500, ["Content-Type": "application/json"], Data())
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

private final class FakeVoiceCapture: VoiceAudioCapturing {
    private(set) var started = false
    private(set) var stopCount = 0
    private(set) var recordingURL: URL?

    func start(
        recordingTo url: URL?,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLimitReached: @escaping () -> Void
    ) throws {
        started = true
        recordingURL = url
        if let url { try Data([0, 1, 2, 3]).write(to: url) }
    }

    func stop() {
        stopCount += 1
    }
}

private final class FakeVoiceRecognizer: VoiceRecognizing {
    var supportsOnDevice = true
    private(set) var lastRequiresOnDevice: Bool?
    private var partialResult: ((String) -> Void)?
    private var finalResult: ((String) -> Void)?
    private(set) var finishCount = 0

    func supportsOnDeviceRecognition(languageIdentifier: String) -> Bool {
        supportsOnDevice
    }

    func start(
        languageIdentifier: String,
        requiresOnDeviceRecognition: Bool,
        partialResult: @escaping (String) -> Void,
        finalResult: @escaping (String) -> Void,
        failure: @escaping (Error) -> Void
    ) throws {
        lastRequiresOnDevice = requiresOnDeviceRecognition
        self.partialResult = partialResult
        self.finalResult = finalResult
    }

    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() { finishCount += 1 }
    func cancel() {}
    func emitPartial(_ text: String) { partialResult?(text) }
    func emitFinal(_ text: String) { finalResult?(text) }
}

@MainActor
private final class FakeVoicePlayback: VoicePlaying {
    var completesImmediately = true
    private(set) var spoken: [String] = []
    private(set) var playedAudio: [Data] = []
    private(set) var stopCount = 0

    func speak(
        text: String,
        languageIdentifier: String,
        voiceIdentifier: String,
        completion: @escaping () -> Void
    ) {
        spoken.append(text)
        if completesImmediately { completion() }
    }

    func play(data: Data, completion: @escaping () -> Void) throws {
        playedAudio.append(data)
        if completesImmediately { completion() }
    }

    func stop() { stopCount += 1 }
}

private struct FakeVoiceAuthorization: VoiceAuthorizationProviding {
    var microphone = true
    var speech = true
    func requestMicrophoneAccess() async -> Bool { microphone }
    func requestSpeechRecognitionAccess() async -> Bool { speech }
}

private struct DelayedVoiceAuthorization: VoiceAuthorizationProviding {
    func requestMicrophoneAccess() async -> Bool {
        try? await Task.sleep(for: .milliseconds(50))
        return true
    }

    func requestSpeechRecognitionAccess() async -> Bool { true }
}

private final class FakeVoiceCloudClient: VoiceCloudClientProtocol {
    var transcript = "Cloud transcript"
    var audio = Data([7, 8, 9])
    private(set) var transcriptionURL: URL?

    func transcribe(
        recordingURL: URL,
        configuration: VoiceCloudConfiguration
    ) async throws -> String {
        transcriptionURL = recordingURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))
        return transcript
    }

    func synthesize(
        text: String,
        configuration: VoiceCloudConfiguration
    ) async throws -> Data {
        audio
    }
}

final class VoiceControlTests: XCTestCase {
    override func tearDown() {
        VoiceURLProtocol.handler = nil
        super.tearDown()
    }

    func testVoiceSettingsDecodeOldPayloadAndRoundTrip() throws {
        let migrated = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(migrated.voiceControlsEnabled)
        XCTAssertEqual(migrated.resolvedVoiceSpeechEngine, .system)
        XCTAssertEqual(migrated.resolvedVoiceSendBehavior, .sendOnStop)
        XCTAssertFalse(migrated.voiceAppleNetworkRecognitionAllowed)

        let unknown = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"voiceSpeechEngineRaw":"future","voiceSendBehaviorRaw":"future"}"#.utf8)
        )
        XCTAssertEqual(unknown.resolvedVoiceSpeechEngine, .system)
        XCTAssertEqual(unknown.resolvedVoiceSendBehavior, .sendOnStop)

        var chosen = migrated
        chosen.voiceSpeechEngineRaw = VoiceSpeechEngine.openAICompatible.rawValue
        chosen.voiceCloudAccountID = UUID().uuidString
        chosen.voiceCloudTranscriptionModel = "whisper-custom"
        chosen.voiceCloudSpeechModel = "speak-custom"
        chosen.voiceCloudVoiceIdentifier = "calm"
        chosen.voiceSendBehaviorRaw = VoiceSendBehavior.reviewBeforeSend.rawValue
        let restored = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(chosen)
        )
        XCTAssertEqual(restored, chosen)
    }

    func testReplyProjectionIncludesOnlyFinalAnswerAndReplacesDenseDetails() throws {
        let blocks = [
            ChatBlock(kind: .user, text: "Question"),
            ChatBlock(kind: .assistant, text: "Working", assistantPhase: .commentary),
            ChatBlock(kind: .tool, text: "secret tool output"),
            ChatBlock(
                kind: .assistant,
                text: "Done.\n\n```swift\nprint(\"secret\")\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |",
                assistantPhase: .finalAnswer
            ),
        ]
        let projection = try XCTUnwrap(VoiceReplyProjection.project(blocks: blocks))
        XCTAssertTrue(projection.text.contains("Done"))
        XCTAssertTrue(projection.text.contains(VoiceReplyProjection.codeNotice))
        XCTAssertTrue(projection.text.contains(VoiceReplyProjection.tableNotice))
        XCTAssertFalse(projection.text.contains("Working"))
        XCTAssertFalse(projection.text.contains("secret"))
    }

    func testReplyProjectionCapsSpokenTextAndSpeechChunksPreserveContent() throws {
        let source = String(repeating: "word ", count: 1_200)
        let projection = try XCTUnwrap(VoiceReplyProjection.project(blocks: [
            ChatBlock(kind: .user, text: "Question"),
            ChatBlock(kind: .assistant, text: source, assistantPhase: .finalAnswer),
        ]))
        XCTAssertTrue(projection.wasTruncated)
        XCTAssertLessThanOrEqual(projection.text.count, VoiceReplyProjection.maximumCharacters)
        XCTAssertTrue(projection.text.hasSuffix(VoiceReplyProjection.remainderNotice))

        let chunks = VoiceSpeechChunker.chunks("One sentence. Two sentence. Three sentence.", maximumCharacters: 18)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 18 })
    }

    func testCloudClientBuildsEndpointsAndUsesBearerAuthentication() async throws {
        let session = voiceSession()
        let client = OpenAICompatibleVoiceClient(session: session)
        let configuration = cloudConfiguration()
        let recording = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-client-\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: recording)
        defer { try? FileManager.default.removeItem(at: recording) }

        var requests: [URLRequest] = []
        VoiceURLProtocol.handler = { request in
            requests.append(request)
            return (200, ["Content-Type": "application/json"], Data(#"{"text":"Hello"}"#.utf8))
        }
        let transcript = try await client.transcribe(
            recordingURL: recording,
            configuration: configuration
        )
        XCTAssertEqual(transcript, "Hello")
        XCTAssertEqual(requests.first?.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        VoiceURLProtocol.handler = { request in
            requests.append(request)
            return (200, ["Content-Type": "audio/mpeg"], Data([9, 8, 7]))
        }
        let speech = try await client.synthesize(text: "Hello", configuration: configuration)
        XCTAssertEqual(speech, Data([9, 8, 7]))
        XCTAssertEqual(requests.last?.url?.path, "/v1/audio/speech")
    }

    func testCloudClientRejectsOversizedAndMalformedResponses() async throws {
        let client = OpenAICompatibleVoiceClient(session: voiceSession())
        VoiceURLProtocol.handler = { _ in
            (
                200,
                ["Content-Type": "application/json"],
                Data(repeating: 0, count: OpenAICompatibleVoiceClient.maximumTranscriptionResponseBytes + 1)
            )
        }
        let recording = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-client-\(UUID().uuidString).wav")
        try Data([1]).write(to: recording)
        defer { try? FileManager.default.removeItem(at: recording) }
        do {
            _ = try await client.transcribe(
                recordingURL: recording,
                configuration: cloudConfiguration()
            )
            XCTFail("Expected the response limit to be enforced")
        } catch {
            XCTAssertEqual(error as? VoiceControlError, .responseTooLarge)
        }

        VoiceURLProtocol.handler = { _ in
            (200, ["Content-Type": "text/html"], Data("not audio".utf8))
        }
        do {
            _ = try await client.synthesize(text: "Hello", configuration: cloudConfiguration())
            XCTFail("Expected content-type validation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("content type"))
        }

        VoiceURLProtocol.handler = { _ in
            (
                401,
                ["Content-Type": "application/json"],
                Data(#"{"error":{"message":"credential rejected"}}"#.utf8)
            )
        }
        do {
            _ = try await client.synthesize(text: "Hello", configuration: cloudConfiguration())
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credential rejected"))
        }
    }

    @MainActor
    func testSystemDictationPublishesPartialAndFinalText() async {
        let capture = FakeVoiceCapture()
        let recognizer = FakeVoiceRecognizer()
        let playback = FakeVoicePlayback()
        let voice = VoiceControlModel(
            capture: capture,
            recognizer: recognizer,
            playback: playback,
            cloudClient: FakeVoiceCloudClient(),
            authorization: FakeVoiceAuthorization()
        )
        var received: [(String, VoiceInputPurpose)] = []
        voice.configure(
            settings: { AppSettings() },
            cloudConfiguration: { nil },
            sessionID: { "session" },
            transcript: { text, purpose in
                received.append((text, purpose))
                return false
            },
            appleNetworkConsent: { _ in }
        )

        voice.startDictation()
        await waitUntil { capture.started }
        XCTAssertEqual(voice.state, .listening)
        recognizer.emitPartial("Hello")
        XCTAssertEqual(voice.partialTranscript, "Hello")
        voice.toggleDictation()
        XCTAssertEqual(voice.state, .transcribing)
        recognizer.emitFinal("Hello world")
        XCTAssertEqual(received.first?.0, "Hello world")
        XCTAssertEqual(received.first?.1, .dictation)
        XCTAssertEqual(voice.state, .idle)
    }

    @MainActor
    func testPushToTalkReleaseCancelsPendingAuthorization() async {
        let capture = FakeVoiceCapture()
        let voice = VoiceControlModel(
            capture: capture,
            recognizer: FakeVoiceRecognizer(),
            playback: FakeVoicePlayback(),
            cloudClient: FakeVoiceCloudClient(),
            authorization: DelayedVoiceAuthorization()
        )
        voice.configure(
            settings: { AppSettings() },
            cloudConfiguration: { nil },
            sessionID: { "session" },
            transcript: { _, _ in false },
            appleNetworkConsent: { _ in }
        )
        voice.enterVoiceMode()

        voice.beginPushToTalk()
        voice.endPushToTalk()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(capture.started)
        XCTAssertEqual(voice.state, .idle)
    }

    @MainActor
    func testEmptySystemSpeechSurfacesAnError() async {
        let capture = FakeVoiceCapture()
        let recognizer = FakeVoiceRecognizer()
        let voice = VoiceControlModel(
            capture: capture,
            recognizer: recognizer,
            playback: FakeVoicePlayback(),
            cloudClient: FakeVoiceCloudClient(),
            authorization: FakeVoiceAuthorization()
        )
        voice.configure(
            settings: { AppSettings() },
            cloudConfiguration: { nil },
            sessionID: { "session" },
            transcript: { _, _ in false },
            appleNetworkConsent: { _ in }
        )
        voice.startDictation()
        await waitUntil { capture.started }
        voice.toggleDictation()
        recognizer.emitFinal("   ")

        if case .error(let message) = voice.state {
            XCTAssertTrue(message.contains("No speech"))
        } else {
            XCTFail("Expected an empty-speech error")
        }
    }

    @MainActor
    func testDeniedPermissionAndAttentionDeduplication() async {
        let playback = FakeVoicePlayback()
        let denied = VoiceControlModel(
            capture: FakeVoiceCapture(),
            recognizer: FakeVoiceRecognizer(),
            playback: playback,
            cloudClient: FakeVoiceCloudClient(),
            authorization: FakeVoiceAuthorization(microphone: false)
        )
        denied.startDictation()
        await waitUntil {
            if case .error = denied.state { return true }
            return false
        }
        if case .error(let message) = denied.state {
            XCTAssertTrue(message.contains("Microphone access"))
        } else {
            XCTFail("Expected a microphone permission error")
        }

        var sessionID = "voice-session"
        let voice = VoiceControlModel(
            capture: FakeVoiceCapture(),
            recognizer: FakeVoiceRecognizer(),
            playback: playback,
            cloudClient: FakeVoiceCloudClient(),
            authorization: FakeVoiceAuthorization()
        )
        voice.configure(
            settings: { AppSettings() },
            cloudConfiguration: { nil },
            sessionID: { sessionID },
            transcript: { _, _ in false },
            appleNetworkConsent: { _ in }
        )
        voice.enterVoiceMode()
        voice.announceAttention(.permission, token: "request-1")
        voice.announceAttention(.permission, token: "request-1")
        XCTAssertEqual(playback.spoken.filter { $0.contains("permission request") }.count, 1)
        voice.announceAttention(.permission, token: "request-2")
        XCTAssertEqual(playback.spoken.filter { $0.contains("permission request") }.count, 2)
        sessionID = "another-session"
        voice.sessionDidChange()
        XCTAssertFalse(voice.isVoiceModeActive)
    }

    @MainActor
    func testCloudCapabilityTestDeletesTemporaryRecording() async {
        let capture = FakeVoiceCapture()
        let cloud = FakeVoiceCloudClient()
        let playback = FakeVoicePlayback()
        let voice = VoiceControlModel(
            capture: capture,
            recognizer: FakeVoiceRecognizer(),
            playback: playback,
            cloudClient: cloud,
            authorization: FakeVoiceAuthorization()
        )
        var settings = AppSettings()
        settings.voiceSpeechEngineRaw = VoiceSpeechEngine.openAICompatible.rawValue
        voice.configure(
            settings: { settings },
            cloudConfiguration: { self.cloudConfiguration() },
            sessionID: { "session" },
            transcript: { _, _ in false },
            appleNetworkConsent: { _ in }
        )
        voice.startCapabilityTest()
        await waitUntil { capture.started }
        voice.startCapabilityTest()
        await waitUntil { voice.capabilityTestMessage == "Voice test passed." }
        XCTAssertEqual(playback.playedAudio, [cloud.audio])
        if let url = cloud.transcriptionURL {
            await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        } else {
            XCTFail("The cloud client did not receive a recording")
        }
    }

    @MainActor
    func testReviewVoiceTranscriptPreservesExistingDraft() {
        let model = AppModel(startImmediately: false)
        model.settings.voiceSendBehaviorRaw = VoiceSendBehavior.reviewBeforeSend.rawValue
        model.draftText = "Existing draft"
        XCTAssertFalse(model.acceptVoiceTranscript("voice addition", purpose: .conversation))
        XCTAssertEqual(model.draftText, "Existing draft voice addition")
    }

    @MainActor
    func testVoiceSendQueuesWithoutConsumingDraftOrRunningSlashCommand() {
        let model = AppModel(startImmediately: false)
        model.agentRuntimePhase = .online
        model.isBusy = true
        model.draftText = "/stop"

        XCTAssertTrue(model.acceptVoiceTranscript("/stop", purpose: .conversation))
        XCTAssertTrue(model.isBusy, "voice must not execute the local stop command")
        XCTAssertEqual(model.queuedMessages, ["/stop"])
        XCTAssertEqual(model.draftText, "/stop")
    }

    @MainActor
    func testAppleNetworkRecognitionRequiresConsentAndStillPrefersOnDevice() async {
        let capture = FakeVoiceCapture()
        let recognizer = FakeVoiceRecognizer()
        recognizer.supportsOnDevice = false
        var settings = AppSettings()
        let voice = VoiceControlModel(
            capture: capture,
            recognizer: recognizer,
            playback: FakeVoicePlayback(),
            cloudClient: FakeVoiceCloudClient(),
            authorization: FakeVoiceAuthorization()
        )
        voice.configure(
            settings: { settings },
            cloudConfiguration: { nil },
            sessionID: { "session" },
            transcript: { _, _ in false },
            appleNetworkConsent: { settings.voiceAppleNetworkRecognitionAllowed = $0 }
        )

        voice.startDictation()
        await waitUntil { voice.networkRecognitionConsentRequested }
        XCTAssertFalse(capture.started)
        XCTAssertEqual(voice.state, .attention(.appleNetworkRecognition))

        voice.respondToAppleNetworkConsent(allowed: true)
        await waitUntil { capture.started }
        XCTAssertEqual(recognizer.lastRequiresOnDevice, false)

        voice.cancelRecording()
        recognizer.supportsOnDevice = true
        voice.startDictation()
        await waitUntil { voice.state == .listening }
        XCTAssertEqual(
            recognizer.lastRequiresOnDevice,
            true,
            "prior network consent must not bypass available on-device recognition"
        )
    }

    @MainActor
    func testCancellingCloudCaptureDeletesTemporaryAudio() async {
        let capture = FakeVoiceCapture()
        var settings = AppSettings()
        settings.voiceSpeechEngineRaw = VoiceSpeechEngine.openAICompatible.rawValue
        let voice = VoiceControlModel(
            capture: capture,
            recognizer: FakeVoiceRecognizer(),
            playback: FakeVoicePlayback(),
            cloudClient: FakeVoiceCloudClient(),
            authorization: FakeVoiceAuthorization()
        )
        voice.configure(
            settings: { settings },
            cloudConfiguration: { self.cloudConfiguration() },
            sessionID: { "session" },
            transcript: { _, _ in false },
            appleNetworkConsent: { _ in }
        )

        voice.startDictation()
        await waitUntil { capture.started }
        let recordingURL = capture.recordingURL
        XCTAssertNotNil(recordingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL?.path ?? ""))
        voice.cancelRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL?.path ?? ""))
    }

    @MainActor
    func testStartingVoiceTurnInterruptsPlayback() async {
        let capture = FakeVoiceCapture()
        let playback = FakeVoicePlayback()
        playback.completesImmediately = false
        let voice = VoiceControlModel(
            capture: capture,
            recognizer: FakeVoiceRecognizer(),
            playback: playback,
            cloudClient: FakeVoiceCloudClient(),
            authorization: FakeVoiceAuthorization()
        )
        voice.configure(
            settings: { AppSettings() },
            cloudConfiguration: { nil },
            sessionID: { "session" },
            transcript: { _, _ in true },
            appleNetworkConsent: { _ in }
        )
        voice.enterVoiceMode()
        voice.handleCompletedTurn(
            sessionID: "session",
            blocks: [
                ChatBlock(kind: .user, text: "Question"),
                ChatBlock(kind: .assistant, text: "Final answer", assistantPhase: .finalAnswer),
            ],
            attention: nil
        )
        XCTAssertEqual(voice.state, .speaking)

        voice.beginPushToTalk()
        await waitUntil { capture.started }
        XCTAssertGreaterThan(playback.stopCount, 0)
        XCTAssertEqual(voice.state, .listening)
    }

    @MainActor
    func testRecordingCancellationDoesNotInterruptSpokenReply() {
        let playback = FakeVoicePlayback()
        playback.completesImmediately = false
        let voice = VoiceControlModel(
            capture: FakeVoiceCapture(),
            recognizer: FakeVoiceRecognizer(),
            playback: playback,
            cloudClient: FakeVoiceCloudClient(),
            authorization: FakeVoiceAuthorization()
        )
        voice.configure(
            settings: { AppSettings() },
            cloudConfiguration: { nil },
            sessionID: { "session" },
            transcript: { _, _ in true },
            appleNetworkConsent: { _ in }
        )
        voice.enterVoiceMode()
        voice.handleCompletedTurn(
            sessionID: "session",
            blocks: [
                ChatBlock(kind: .user, text: "Question"),
                ChatBlock(kind: .assistant, text: "Final answer", assistantPhase: .finalAnswer),
            ],
            attention: nil
        )
        let stopsBeforeCaptureCancellation = playback.stopCount

        voice.cancelRecording()

        XCTAssertEqual(voice.state, .speaking)
        XCTAssertEqual(playback.stopCount, stopsBeforeCaptureCancellation)
    }

    @MainActor
    func testPlaybackRejectsMalformedAudio() {
        let playback = VoicePlaybackService()
        XCTAssertThrowsError(try playback.play(data: Data([0, 1, 2, 3]), completion: {}))
    }

    func testVoiceSettingsSearchMetadataRoutesToChat() throws {
        let descriptor = try XCTUnwrap(
            SettingsSearchDescriptor.all.first(where: { $0.matches("push to talk") })
        )
        XCTAssertEqual(descriptor.id, "settings.voice")
        XCTAssertEqual(descriptor.page, .chat)
    }

    private func voiceSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func cloudConfiguration() -> VoiceCloudConfiguration {
        VoiceCloudConfiguration(
            accountID: "account",
            baseURL: URL(string: "https://example.com/v1")!,
            apiKey: "test-key",
            transcriptionModel: "transcribe-model",
            speechModel: "speech-model",
            voiceIdentifier: "calm",
            languageIdentifier: "en"
        )
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
    }
}
