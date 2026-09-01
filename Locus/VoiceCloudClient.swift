import Foundation

protocol VoiceCloudClientProtocol {
    func transcribe(
        recordingURL: URL,
        configuration: VoiceCloudConfiguration
    ) async throws -> String

    func synthesize(
        text: String,
        configuration: VoiceCloudConfiguration
    ) async throws -> Data
}

struct OpenAICompatibleVoiceClient: VoiceCloudClientProtocol {
    static let maximumRecordingBytes = 20 * 1_024 * 1_024
    static let maximumTranscriptionResponseBytes = 1 * 1_024 * 1_024
    static let maximumSpeechResponseBytes = 16 * 1_024 * 1_024

    private let sessionProvider: (String) -> URLSession

    init(session: URLSession) {
        sessionProvider = { _ in session }
    }

    init(sessionProvider: @escaping (String) -> URLSession) {
        self.sessionProvider = sessionProvider
    }

    static func endpoint(baseURL: URL, path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }
    }

    func transcribe(
        recordingURL: URL,
        configuration: VoiceCloudConfiguration
    ) async throws -> String {
        let values = try recordingURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= Self.maximumRecordingBytes else {
            throw VoiceControlError.recordingTooLarge
        }
        let audio = try Data(contentsOf: recordingURL, options: [.mappedIfSafe])
        guard audio.count <= Self.maximumRecordingBytes else {
            throw VoiceControlError.recordingTooLarge
        }
        let boundary = "LocusVoice-\(UUID().uuidString)"
        var body = Data()
        appendField("model", value: configuration.transcriptionModel, boundary: boundary, to: &body)
        if !configuration.languageIdentifier.isEmpty {
            appendField(
                "language",
                value: configuration.languageIdentifier,
                boundary: boundary,
                to: &body
            )
        }
        appendFile(
            audio,
            name: "file",
            filename: "locus-voice.wav",
            contentType: "audio/wav",
            boundary: boundary,
            to: &body
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(
            url: Self.endpoint(baseURL: configuration.baseURL, path: "audio/transcriptions")
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 75
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&request, key: configuration.apiKey)
        LocusClientIdentity.apply(to: &request)

        let (data, response) = try await sessionProvider(configuration.accountID).data(for: request)
        try validate(
            response: response,
            data: data,
            maximumBytes: Self.maximumTranscriptionResponseBytes,
            acceptedContentTypes: ["application/json"]
        )
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = payload["text"] as? String
        else {
            throw VoiceControlError.invalidResponse("The transcription response did not contain text.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceControlError.emptyTranscript }
        return trimmed
    }

    func synthesize(
        text: String,
        configuration: VoiceCloudConfiguration
    ) async throws -> Data {
        let payload: [String: Any] = [
            "model": configuration.speechModel,
            "voice": configuration.voiceIdentifier,
            "input": text,
            "response_format": "mp3",
        ]
        var request = URLRequest(
            url: Self.endpoint(baseURL: configuration.baseURL, path: "audio/speech")
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 75
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, key: configuration.apiKey)
        LocusClientIdentity.apply(to: &request)

        let (data, response) = try await sessionProvider(configuration.accountID).data(for: request)
        try validate(
            response: response,
            data: data,
            maximumBytes: Self.maximumSpeechResponseBytes,
            acceptedContentTypes: ["audio/", "application/octet-stream"]
        )
        guard !data.isEmpty else { throw VoiceControlError.unsupportedAudio }
        return data
    }

    private func authorize(_ request: inout URLRequest, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validate(
        response: URLResponse,
        data: Data,
        maximumBytes: Int,
        acceptedContentTypes: [String]
    ) throws {
        guard data.count <= maximumBytes else { throw VoiceControlError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else {
            throw VoiceControlError.invalidResponse("The speech service returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let providerMessage = Self.providerErrorMessage(data)
            throw VoiceControlError.invalidResponse(
                providerMessage.isEmpty
                    ? "The speech service returned HTTP \(http.statusCode)."
                    : "The speech service returned HTTP \(http.statusCode): \(providerMessage)"
            )
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
        guard acceptedContentTypes.contains(where: contentType.hasPrefix) else {
            throw VoiceControlError.invalidResponse("The speech service returned an unexpected content type.")
        }
    }

    private static func providerErrorMessage(_ data: Data) -> String {
        guard data.count <= maximumTranscriptionResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            return String(message.prefix(300))
        }
        return ""
    }

    private func appendField(
        _ name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private func appendFile(
        _ data: Data,
        name: String,
        filename: String,
        contentType: String,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
}
