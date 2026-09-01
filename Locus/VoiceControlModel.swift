import AppKit
@preconcurrency import AVFoundation
import Combine
import Foundation
import Speech

protocol VoiceAudioCapturing: AnyObject {
    func start(
        recordingTo url: URL?,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLimitReached: @escaping () -> Void
    ) throws
    func stop()
}

protocol VoiceRecognizing: AnyObject {
    func supportsOnDeviceRecognition(languageIdentifier: String) -> Bool
    func start(
        languageIdentifier: String,
        requiresOnDeviceRecognition: Bool,
        partialResult: @escaping (String) -> Void,
        finalResult: @escaping (String) -> Void,
        failure: @escaping (Error) -> Void
    ) throws
    func append(_ buffer: AVAudioPCMBuffer)
    func finish()
    func cancel()
}

@MainActor
protocol VoicePlaying: AnyObject {
    func speak(
        text: String,
        languageIdentifier: String,
        voiceIdentifier: String,
        completion: @escaping () -> Void
    )
    func play(data: Data, completion: @escaping () -> Void) throws
    func stop()
}

protocol VoiceAuthorizationProviding {
    func requestMicrophoneAccess() async -> Bool
    func requestSpeechRecognitionAccess() async -> Bool
}

struct SystemVoiceAuthorizationProvider: VoiceAuthorizationProviding {
    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        @unknown default: return false
        }
    }

    func requestSpeechRecognitionAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }
}

final class AVAudioEngineVoiceCapture: VoiceAudioCapturing {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var tapInstalled = false
    private var estimatedBytes = 0
    private var reachedLimit = false

    func start(
        recordingTo url: URL?,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLimitReached: @escaping () -> Void
    ) throws {
        stop()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceControlError.microphoneDenied
        }
        if let url {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        }
        estimatedBytes = 0
        reachedLimit = false
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            onBuffer(buffer)
            if let file = self.file {
                try? file.write(from: buffer)
                self.estimatedBytes += Int(buffer.frameLength) * Int(format.streamDescription.pointee.mBytesPerFrame)
                if self.estimatedBytes > OpenAICompatibleVoiceClient.maximumRecordingBytes,
                   !self.reachedLimit {
                    self.reachedLimit = true
                    DispatchQueue.main.async(execute: onLimitReached)
                }
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        file = nil
    }
}

final class SystemVoiceRecognizer: VoiceRecognizing {
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func supportsOnDeviceRecognition(languageIdentifier: String) -> Bool {
        recognizer(languageIdentifier: languageIdentifier)?.supportsOnDeviceRecognition == true
    }

    func start(
        languageIdentifier: String,
        requiresOnDeviceRecognition: Bool,
        partialResult: @escaping (String) -> Void,
        finalResult: @escaping (String) -> Void,
        failure: @escaping (Error) -> Void
    ) throws {
        cancel()
        guard let recognizer = recognizer(languageIdentifier: languageIdentifier),
              recognizer.isAvailable
        else { throw VoiceControlError.speechRecognizerUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        self.request = request
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    if result.isFinal { finalResult(text) }
                    else { partialResult(text) }
                }
            }
            if let error {
                DispatchQueue.main.async { failure(error) }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func finish() {
        request?.endAudio()
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
    }

    private func recognizer(languageIdentifier: String) -> SFSpeechRecognizer? {
        let identifier = languageIdentifier.isEmpty
            ? (Locale.preferredLanguages.first ?? Locale.current.identifier)
            : languageIdentifier
        return SFSpeechRecognizer(locale: Locale(identifier: identifier))
    }
}

@MainActor
final class VoicePlaybackService: NSObject, VoicePlaying, AVSpeechSynthesizerDelegate,
    AVAudioPlayerDelegate
{
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var pendingUtterances = 0
    private var completion: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        text: String,
        languageIdentifier: String,
        voiceIdentifier: String,
        completion: @escaping () -> Void
    ) {
        stop()
        let chunks = VoiceSpeechChunker.chunks(text)
        guard !chunks.isEmpty else {
            completion()
            return
        }
        self.completion = completion
        pendingUtterances = chunks.count
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            if !voiceIdentifier.isEmpty {
                utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            } else if !languageIdentifier.isEmpty {
                utterance.voice = AVSpeechSynthesisVoice(language: languageIdentifier)
            }
            synthesizer.speak(utterance)
        }
    }

    func play(data: Data, completion: @escaping () -> Void) throws {
        stop()
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        self.completion = completion
        audioPlayer = player
        guard player.prepareToPlay(), player.play() else {
            audioPlayer = nil
            self.completion = nil
            throw VoiceControlError.unsupportedAudio
        }
    }

    func stop() {
        completion = nil
        pendingUtterances = 0
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finishSpokenUtterance() }
    }

    private func finishSpokenUtterance() {
        pendingUtterances = max(pendingUtterances - 1, 0)
        guard pendingUtterances == 0 else { return }
        let completion = self.completion
        self.completion = nil
        completion?()
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in self?.finishAudioPlayback() }
    }

    private func finishAudioPlayback() {
        audioPlayer = nil
        let completion = completion
        self.completion = nil
        completion?()
    }
}

@MainActor
final class VoiceControlModel: ObservableObject {
    static let maximumRecordingDuration: TimeInterval = 60

    @Published private(set) var state: VoiceSessionState = .idle
    @Published private(set) var partialTranscript = ""
    @Published private(set) var isVoiceModeActive = false
    @Published private(set) var capabilityTestMessage = ""
    @Published var networkRecognitionConsentRequested = false

    private let capture: VoiceAudioCapturing
    private let recognizer: VoiceRecognizing
    private let playback: VoicePlaying
    private let cloudClient: VoiceCloudClientProtocol
    private let authorization: VoiceAuthorizationProviding
    private var settingsProvider: () -> AppSettings = { AppSettings() }
    private var cloudConfigurationProvider: () -> VoiceCloudConfiguration? = { nil }
    private var sessionIDProvider: () -> String = { "" }
    private var transcriptHandler: (String, VoiceInputPurpose) -> Bool = { _, _ in false }
    private var consentHandler: (Bool) -> Void = { _ in }
    private var voiceSessionID: String?
    private var activePurpose: VoiceInputPurpose?
    private var pendingConsentPurpose: VoiceInputPurpose?
    private var temporaryRecordingURL: URL?
    private var maximumDurationTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var generation = UUID()
    private var announcedAttentionTokens: Set<String> = []
    private var deactivationObserver: NSObjectProtocol?

    init(
        capture: VoiceAudioCapturing = AVAudioEngineVoiceCapture(),
        recognizer: VoiceRecognizing = SystemVoiceRecognizer(),
        playback: VoicePlaying? = nil,
        cloudClient: VoiceCloudClientProtocol? = nil,
        authorization: VoiceAuthorizationProviding = SystemVoiceAuthorizationProvider()
    ) {
        self.capture = capture
        self.recognizer = recognizer
        self.playback = playback ?? VoicePlaybackService()
        self.authorization = authorization
        self.cloudClient = cloudClient ?? OpenAICompatibleVoiceClient { accountID in
            ProxyRuntime.shared.urlSession(
                for: .modelAndAgent,
                workspacePath: nil,
                providerAccountID: accountID
            )
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelRecording() }
        }
    }

    deinit {
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
        }
    }

    func configure(
        settings: @escaping () -> AppSettings,
        cloudConfiguration: @escaping () -> VoiceCloudConfiguration?,
        sessionID: @escaping () -> String,
        transcript: @escaping (String, VoiceInputPurpose) -> Bool,
        appleNetworkConsent: @escaping (Bool) -> Void
    ) {
        settingsProvider = settings
        cloudConfigurationProvider = cloudConfiguration
        sessionIDProvider = sessionID
        transcriptHandler = transcript
        consentHandler = appleNetworkConsent
    }

    var isListening: Bool { state == .listening }
    var isSpeaking: Bool { state == .speaking }
    var isDictating: Bool { activePurpose == .dictation && isListening }
    var isConversing: Bool { activePurpose == .conversation && isListening }
    var isCapabilityTesting: Bool { activePurpose == .capabilityTest }

    func startDictation() {
        beginInput(.dictation)
    }

    func toggleDictation() {
        guard activePurpose == .dictation else {
            beginInput(.dictation)
            return
        }
        isListening ? stopRecording() : cancelRecording()
    }

    func enterVoiceMode() {
        guard settingsProvider().voiceControlsEnabled else { return }
        voiceSessionID = sessionIDProvider()
        announcedAttentionTokens.removeAll()
        isVoiceModeActive = true
        if case .error = state { state = .idle }
    }

    func exitVoiceMode() {
        cancelRecording()
        stopPlayback()
        voiceSessionID = nil
        isVoiceModeActive = false
        announcedAttentionTokens.removeAll()
        state = .idle
        partialTranscript = ""
    }

    func toggleVoiceMode() {
        isVoiceModeActive ? exitVoiceMode() : enterVoiceMode()
    }

    func beginPushToTalk() {
        if !isVoiceModeActive { enterVoiceMode() }
        guard isVoiceModeActive, !isListening else { return }
        beginInput(.conversation)
    }

    func endPushToTalk() {
        guard activePurpose == .conversation else { return }
        isListening ? stopRecording() : cancelRecording()
    }

    func toggleVoiceRecording() {
        if activePurpose == .conversation {
            isListening ? stopRecording() : cancelRecording()
        } else {
            beginPushToTalk()
        }
    }

    func startCapabilityTest() {
        if activePurpose == .capabilityTest {
            isListening ? stopRecording() : cancelRecording()
        } else {
            capabilityTestMessage = ""
            beginInput(.capabilityTest)
        }
    }

    func invalidateCapabilityTest() {
        capabilityTestMessage = ""
        if activePurpose == .capabilityTest { cancelRecording() }
    }

    func respondToAppleNetworkConsent(allowed: Bool) {
        networkRecognitionConsentRequested = false
        consentHandler(allowed)
        guard allowed, let purpose = pendingConsentPurpose else {
            pendingConsentPurpose = nil
            fail(VoiceControlError.appleNetworkConsentRequired)
            return
        }
        pendingConsentPurpose = nil
        beginInput(purpose)
    }

    func stopSpeaking() {
        stopPlayback()
        state = .idle
    }

    func cancelRecording() {
        generation = UUID()
        inputTask?.cancel()
        inputTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        capture.stop()
        recognizer.cancel()
        activePurpose = nil
        cleanupTemporaryRecording()
        if isListening || state == .transcribing {
            state = .idle
            partialTranscript = ""
        }
    }

    func sessionDidChange() {
        if isVoiceModeActive, voiceSessionID != sessionIDProvider() {
            exitVoiceMode()
        } else {
            cancelRecording()
        }
    }

    func turnFailed() {
        if state == .waiting { state = .idle }
    }

    /// UI-test-only state seeding. It never starts capture or playback, which
    /// keeps accessibility fixtures deterministic on runners with no audio I/O.
    func seedUITestState(_ rawValue: String, sessionID: String) {
        voiceSessionID = sessionID
        isVoiceModeActive = true
        partialTranscript = rawValue == "listening" ? "A deterministic partial transcript" : ""
        activePurpose = rawValue == "listening" ? .conversation : nil
        state = switch rawValue {
        case "listening": .listening
        case "transcribing": .transcribing
        case "waiting": .waiting
        case "speaking": .speaking
        case "permission": .attention(.permission)
        case "error": .error("The microphone is unavailable in this fixture.")
        default: .idle
        }
    }

    func announceAttention(_ kind: VoiceAttentionKind, token: String) {
        guard isVoiceModeActive,
              voiceSessionID == sessionIDProvider(),
              announcedAttentionTokens.insert("\(kind.rawValue):\(token)").inserted
        else { return }
        cancelRecording()
        stopPlayback()
        state = .attention(kind)
        speakText(kind.announcement, finalState: .attention(kind))
    }

    func handleCompletedTurn(
        sessionID: String,
        blocks: [ChatBlock],
        attention: VoiceAttentionKind?,
        attentionToken: String? = nil
    ) {
        guard isVoiceModeActive, voiceSessionID == sessionID else { return }
        if let attention {
            announceAttention(attention, token: attentionToken ?? sessionID)
            return
        }
        guard let reply = VoiceReplyProjection.project(blocks: blocks) else {
            state = .idle
            return
        }
        speakText(reply.text, finalState: .idle)
    }

    private func beginInput(_ purpose: VoiceInputPurpose) {
        guard settingsProvider().voiceControlsEnabled else { return }
        if purpose == .conversation {
            guard isVoiceModeActive, voiceSessionID == sessionIDProvider() else { return }
        }
        cancelRecording()
        stopPlayback()
        partialTranscript = ""
        let token = UUID()
        generation = token
        activePurpose = purpose
        inputTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await self.authorization.requestMicrophoneAccess() else {
                    throw VoiceControlError.microphoneDenied
                }
                guard !Task.isCancelled, self.generation == token else { return }
                let settings = self.settingsProvider()
                if settings.resolvedVoiceSpeechEngine == .system {
                    guard await self.authorization.requestSpeechRecognitionAccess() else {
                        throw VoiceControlError.speechRecognitionDenied
                    }
                    guard !Task.isCancelled, self.generation == token else { return }
                }
                try self.startAuthorizedInput(purpose, settings: settings)
            } catch is CancellationError {
                return
            } catch {
                self.fail(error)
            }
        }
    }

    private func startAuthorizedInput(_ purpose: VoiceInputPurpose, settings: AppSettings) throws {
        guard activePurpose == purpose else { throw CancellationError() }
        switch settings.resolvedVoiceSpeechEngine {
        case .system:
            let supportsOnDevice = recognizer.supportsOnDeviceRecognition(
                languageIdentifier: settings.voiceLanguageIdentifier
            )
            if !supportsOnDevice, !settings.voiceAppleNetworkRecognitionAllowed {
                activePurpose = nil
                pendingConsentPurpose = purpose
                networkRecognitionConsentRequested = true
                state = .attention(.appleNetworkRecognition)
                throw VoiceControlError.appleNetworkConsentRequired
            }
            try recognizer.start(
                languageIdentifier: settings.voiceLanguageIdentifier,
                requiresOnDeviceRecognition: supportsOnDevice,
                partialResult: { [weak self] text in self?.partialTranscript = text },
                finalResult: { [weak self] text in self?.finishTranscript(text) },
                failure: { [weak self] error in
                    guard let self, self.activePurpose != nil else { return }
                    self.fail(error)
                }
            )
            try capture.start(
                recordingTo: nil,
                onBuffer: { [weak self] buffer in self?.recognizer.append(buffer) },
                onLimitReached: { [weak self] in self?.fail(VoiceControlError.recordingTooLarge) }
            )
        case .openAICompatible:
            guard cloudConfigurationProvider() != nil else {
                throw VoiceControlError.cloudAccountUnavailable
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("locus-voice-\(UUID().uuidString)")
                .appendingPathExtension("wav")
            temporaryRecordingURL = url
            try capture.start(
                recordingTo: url,
                onBuffer: { _ in },
                onLimitReached: { [weak self] in self?.fail(VoiceControlError.recordingTooLarge) }
            )
        }
        state = .listening
        scheduleMaximumDuration()
    }

    private func stopRecording() {
        guard let purpose = activePurpose else { return }
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        capture.stop()
        state = .transcribing
        switch settingsProvider().resolvedVoiceSpeechEngine {
        case .system:
            recognizer.finish()
        case .openAICompatible:
            guard let url = temporaryRecordingURL,
                  let configuration = cloudConfigurationProvider()
            else {
                fail(VoiceControlError.cloudAccountUnavailable)
                return
            }
            temporaryRecordingURL = nil
            inputTask = Task { [weak self] in
                defer { try? FileManager.default.removeItem(at: url) }
                do {
                    let transcript = try await self?.cloudClient.transcribe(
                        recordingURL: url,
                        configuration: configuration
                    ) ?? ""
                    guard !Task.isCancelled else { return }
                    self?.finishTranscript(transcript, expectedPurpose: purpose)
                } catch is CancellationError {
                    return
                } catch {
                    self?.fail(error)
                }
            }
        }
    }

    private func finishTranscript(
        _ text: String,
        expectedPurpose: VoiceInputPurpose? = nil
    ) {
        guard let purpose = activePurpose,
              expectedPurpose == nil || expectedPurpose == purpose
        else { return }
        recognizer.cancel()
        capture.stop()
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        inputTask = nil
        activePurpose = nil
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            fail(VoiceControlError.emptyTranscript)
            return
        }
        partialTranscript = transcript
        if purpose == .capabilityTest {
            capabilityTestMessage = "Transcribed successfully. Playing the result…"
            speakText(transcript, finalState: .idle) { [weak self] in
                self?.capabilityTestMessage = "Voice test passed."
            }
            return
        }
        let submitted = transcriptHandler(transcript, purpose)
        state = submitted && purpose == .conversation ? .waiting : .idle
        if purpose == .dictation || !submitted { partialTranscript = "" }
    }

    private func speakText(
        _ text: String,
        finalState: VoiceSessionState,
        completion: (() -> Void)? = nil
    ) {
        stopPlayback()
        state = .speaking
        let settings = settingsProvider()
        let finished = { [weak self] in
            guard let self else { return }
            self.speechTask = nil
            self.state = finalState
            completion?()
        }
        switch settings.resolvedVoiceSpeechEngine {
        case .system:
            playback.speak(
                text: text,
                languageIdentifier: settings.voiceLanguageIdentifier,
                voiceIdentifier: settings.voiceSystemVoiceIdentifier,
                completion: finished
            )
        case .openAICompatible:
            guard let configuration = cloudConfigurationProvider() else {
                fail(VoiceControlError.cloudAccountUnavailable)
                return
            }
            speechTask = Task { [weak self] in
                do {
                    guard let self else { return }
                    let data = try await self.cloudClient.synthesize(
                        text: text,
                        configuration: configuration
                    )
                    guard !Task.isCancelled else { return }
                    try self.playback.play(data: data, completion: finished)
                } catch is CancellationError {
                    return
                } catch {
                    self?.fail(error)
                }
            }
        }
    }

    private func scheduleMaximumDuration() {
        maximumDurationTask?.cancel()
        maximumDurationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumRecordingDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stopRecording()
        }
    }

    private func fail(_ error: Error) {
        inputTask?.cancel()
        inputTask = nil
        stopPlayback()
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        capture.stop()
        recognizer.cancel()
        activePurpose = nil
        cleanupTemporaryRecording()
        if error as? VoiceControlError == .appleNetworkConsentRequired,
           networkRecognitionConsentRequested {
            state = .attention(.appleNetworkRecognition)
        } else {
            state = .error(error.localizedDescription)
        }
    }

    private func cleanupTemporaryRecording() {
        guard let url = temporaryRecordingURL else { return }
        temporaryRecordingURL = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func stopPlayback() {
        speechTask?.cancel()
        speechTask = nil
        playback.stop()
    }

}
