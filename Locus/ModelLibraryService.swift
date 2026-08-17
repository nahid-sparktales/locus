import Foundation

struct HuggingFaceModel: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let tags: [String]?
    let pipelineTag: String?

    init(
        id: String,
        downloads: Int?,
        likes: Int?,
        lastModified: String?,
        tags: [String]?,
        pipelineTag: String? = nil
    ) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.lastModified = lastModified
        self.tags = tags
        self.pipelineTag = pipelineTag
    }

    var displayName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var owner: String {
        id.split(separator: "/").first.map(String.init) ?? "Hugging Face"
    }

    enum CodingKeys: String, CodingKey {
        case id, downloads, likes, lastModified, tags
        case pipelineTag = "pipeline_tag"
    }
}

struct HuggingFaceModelFile: Codable, Hashable, Sendable {
    let rfilename: String
    let size: Int64?

    var quantization: String? {
        let upper = rfilename.uppercased()
        let known = [
            "Q8_0", "Q6_K", "Q5_K_M", "Q5_K_S", "Q4_K_M", "Q4_K_S",
            "IQ4_NL", "IQ4_XS", "IQ3_M", "IQ2_M", "Q3_K_L", "Q3_K_M",
            "Q3_K_S", "Q2_K",
        ]
        return known.first { upper.contains($0) }
    }

    var isVisionProjector: Bool {
        rfilename.lowercased().contains("mmproj")
    }
}

struct HuggingFaceVariant: Hashable, Identifiable, Sendable {
    var id: String { quantization }
    let quantization: String
    let fileName: String
    let approximateSize: Int64

    var sizeLabel: String {
        guard approximateSize > 0 else { return "Size unavailable" }
        return ByteCountFormatter.string(
            fromByteCount: approximateSize,
            countStyle: .file
        )
    }

    var isRecommended: Bool { quantization == "Q4_K_M" }

    /// How this quantization sits in a machine's unified memory.
    enum MemoryFit {
        case fits
        case tight
        case exceeds
    }

    /// Metal can address roughly two-thirds to three-quarters of unified
    /// memory, and macOS plus the apps need the rest. A model past ~75% of
    /// RAM starves both the machine and the context window — the observed
    /// failure mode is Ollama shrinking the window until tool calls are cut
    /// off mid-generation. RAM arrives as a parameter so the classification
    /// is testable at any machine size. Static so installed models
    /// (ModelInfo.size) can be classified with the same rule.
    static func fit(bytes: Int64, physicalMemory: UInt64) -> MemoryFit {
        guard bytes > 0, physicalMemory > 0 else { return .fits }
        // The weights plus headroom for the KV cache and runtime buffers.
        let need = Double(bytes + 2_000_000_000)
        let memory = Double(physicalMemory)
        if need <= memory * 0.55 { return .fits }
        if need <= memory * 0.75 { return .tight }
        return .exceeds
    }

    func fit(physicalMemory: UInt64) -> MemoryFit {
        Self.fit(bytes: approximateSize, physicalMemory: physicalMemory)
    }

    /// The variant worth pre-selecting. The list arrives in quality-priority
    /// order (Q4_K_M first), so this is the best quant that comfortably
    /// fits, then the best tight fit, then the best there is — a 22 GB
    /// Q4_K_M must not be pre-selected on a 16 GB machine just because
    /// Q4_K_M is usually the right answer.
    static func recommendedVariant(
        in variants: [HuggingFaceVariant],
        physicalMemory: UInt64
    ) -> HuggingFaceVariant? {
        variants.first { $0.fit(physicalMemory: physicalMemory) == .fits }
            ?? variants.first { $0.fit(physicalMemory: physicalMemory) == .tight }
            ?? variants.first
    }
}

struct ModelPullProgress: Equatable, Sendable {
    let status: String
    let completed: Int64
    let total: Int64

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

enum ModelLibraryError: LocalizedError {
    case invalidRepository
    case invalidResponse
    case server(String)
    case noGGUFVariants

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            "Enter a Hugging Face model name such as owner/model or paste its URL."
        case .invalidResponse:
            "The model service returned an unreadable response."
        case .server(let message):
            message
        case .noGGUFVariants:
            "No Ollama-compatible GGUF quantizations were found in this repository."
        }
    }
}

enum LocalModelManagementError: LocalizedError {
    case invalidOllamaAddress
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidOllamaAddress:
            "The Ollama address is invalid."
        case .invalidResponse:
            "Ollama returned an unreadable response."
        case .server(let message):
            message
        }
    }
}

enum LocalModelManagement {
    static func deleteRequest(ollamaHost: String, model: String) throws -> URLRequest {
        let host = ollamaHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(host)/api/delete"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LocalModelManagementError.invalidOllamaAddress }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        return request
    }

    static func delete(ollamaHost: String, model: String) async throws {
        let request = try deleteRequest(ollamaHost: ollamaHost, model: model)
        let (data, response) = try await ProxyRuntime.shared.urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelManagementError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (object?["error"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            throw LocalModelManagementError.server(
                detail?.isEmpty == false
                    ? detail!
                    : "Ollama could not delete \(model) (HTTP \(http.statusCode))."
            )
        }
    }
}

actor ModelLibraryService {
    private let decoder = JSONDecoder()

    func search(query: String, limit: Int = 30) async throws -> [HuggingFaceModel] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        var items = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "full", value: "true"),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "search", value: normalizeRepository(trimmed)))
        }
        components.queryItems = items
        guard let url = components.url else { throw ModelLibraryError.invalidRepository }
        let (data, response) = try await ProxyRuntime.shared.urlSession.data(from: url)
        try validate(response, data: data, service: "Hugging Face")
        let decoded = try decoder.decode([HuggingFaceModel].self, from: data)
        let chatPipelines = Set(["text-generation", "conversational", "image-text-to-text"])
        return decoded.filter {
            guard let pipeline = $0.pipelineTag else {
                let lowerID = $0.id.lowercased()
                return !lowerID.contains("embedding") && !lowerID.contains("-embed")
            }
            return chatPipelines.contains(pipeline)
        }
    }

    func variants(for repository: String) async throws -> [HuggingFaceVariant] {
        let repoID = normalizeRepository(repository)
        guard repoID.split(separator: "/").count == 2 else {
            throw ModelLibraryError.invalidRepository
        }
        let escaped = repoID
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/api/models/\(escaped)?blobs=true") else {
            throw ModelLibraryError.invalidRepository
        }
        let (data, response) = try await ProxyRuntime.shared.urlSession.data(from: url)
        try validate(response, data: data, service: "Hugging Face")
        let detail = try decoder.decode(HuggingFaceModelDetail.self, from: data)

        let files = detail.siblings.filter {
            $0.rfilename.lowercased().hasSuffix(".gguf")
                && !$0.isVisionProjector
                && $0.quantization != nil
        }
        var grouped: [String: HuggingFaceModelFile] = [:]
        var groupedSizes: [String: Int64] = [:]
        for file in files {
            guard let quantization = file.quantization else { continue }
            // Sharded repos publish several .gguf files per quantization; the
            // download covers all shards, so the size shown must sum them.
            groupedSizes[quantization, default: 0] += file.size ?? 0
            if let existing = grouped[quantization] {
                let repositoryMentionsMTP = repoID.uppercased().contains("MTP")
                let fileMentionsMTP = file.rfilename.uppercased().contains("MTP")
                let existingMentionsMTP = existing.rfilename.uppercased().contains("MTP")
                if repositoryMentionsMTP && fileMentionsMTP && !existingMentionsMTP {
                    grouped[quantization] = file
                }
            } else {
                grouped[quantization] = file
            }
        }
        guard !grouped.isEmpty else { throw ModelLibraryError.noGGUFVariants }
        let priority = [
            "Q4_K_M", "Q4_K_S", "IQ4_NL", "IQ4_XS", "Q5_K_M", "Q5_K_S",
            "Q6_K", "Q8_0", "IQ3_M", "Q3_K_M", "Q3_K_S", "IQ2_M", "Q2_K",
        ]
        return grouped.map { quantization, file in
            HuggingFaceVariant(
                quantization: quantization,
                fileName: file.rfilename,
                approximateSize: groupedSizes[quantization] ?? file.size ?? 0
            )
        }
        .sorted {
            (priority.firstIndex(of: $0.quantization) ?? priority.count)
                < (priority.firstIndex(of: $1.quantization) ?? priority.count)
        }
    }

    func pull(
        repository: String,
        quantization: String,
        ollamaHost: String,
        onProgress: @escaping @Sendable (ModelPullProgress) -> Void
    ) async throws -> String {
        let repoID = normalizeRepository(repository)
        guard repoID.split(separator: "/").count == 2 else {
            throw ModelLibraryError.invalidRepository
        }
        let reference = "hf.co/\(repoID):\(quantization)"
        guard let url = URL(string: "\(ollamaHost.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/pull") else {
            throw ModelLibraryError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Idle timeout: fail within minutes if the stream stalls (dead
        // connection), while the overall download may take as long as needed.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": reference,
            "stream": true,
        ])

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        // The pull talks to Ollama, which the bypass list keeps direct; the
        // proxy is applied anyway so a deliberately proxied remote Ollama
        // behaves like every other endpoint.
        let session = URLSession(configuration: ProxyRuntime.shared.configuration(base: configuration))
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Surface Ollama's own reason instead of a generic message.
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 500 { break }
            }
            if let data = body.data(using: .utf8),
               let chunk = try? decoder.decode(OllamaPullChunk.self, from: data),
               let message = chunk.error, !message.isEmpty
            {
                throw ModelLibraryError.server(message)
            }
            throw ModelLibraryError.server(
                body.isEmpty ? "Ollama could not start this download." : String(body.prefix(300))
            )
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let chunk = try? decoder.decode(OllamaPullChunk.self, from: data)
            else { continue }
            if let error = chunk.error, !error.isEmpty {
                throw ModelLibraryError.server(error)
            }
            onProgress(
                ModelPullProgress(
                    status: chunk.status ?? "Downloading",
                    completed: chunk.completed ?? 0,
                    total: chunk.total ?? 0
                )
            )
        }
        return reference
    }

    nonisolated func normalizeRepository(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "hf.co/"] {
            if normalized.lowercased().hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count))
                break
            }
        }
        normalized = normalized.split(separator: "?", maxSplits: 1).first.map(String.init) ?? normalized
        normalized = normalized.split(separator: "#", maxSplits: 1).first.map(String.init) ?? normalized
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func validate(_ response: URLResponse, data: Data, service: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let message = body.isEmpty
                ? "\(service) returned an error."
                : String(body.prefix(300))
            throw ModelLibraryError.server(message)
        }
    }
}

private struct HuggingFaceModelDetail: Codable {
    let siblings: [HuggingFaceModelFile]
}

private struct OllamaPullChunk: Codable {
    let status: String?
    let error: String?
    let digest: String?
    let total: Int64?
    let completed: Int64?
}
