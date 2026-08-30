import Foundation

/// Owns the cross-session transcript search: the debounced FTS request and
/// its hits/indexing state. Opening a hit stays with AppModel — it resumes
/// sessions and drives the in-conversation find bar. AppModel wires it via
/// configure(...) and bridges its publication; it never retains AppModel.
@MainActor
final class TranscriptSearchModel: ObservableObject {
    @Published var transcriptHits: [TranscriptSearchHit] = []
    @Published var isSearchingTranscripts = false
    @Published var transcriptSearchIndexing = false

    private var transcriptHitsTask: Task<Void, Never>?

    private var backend: BackendService?

    func configure(backend: BackendService) {
        self.backend = backend
    }

    func cancelAll() {
        transcriptHitsTask?.cancel()
        transcriptHitsTask = nil
    }

    func scheduleHitSearch(query rawQuery: String) {
        guard let backend else { return }
        transcriptHitsTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            transcriptHits = []
            isSearchingTranscripts = false
            transcriptSearchIndexing = false
            return
        }
        isSearchingTranscripts = true
        transcriptHitsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            let response = try? await backend.get(
                "/api/sessions/search",
                query: [
                    URLQueryItem(name: "query", value: query),
                    URLQueryItem(name: "limit", value: "20"),
                ],
                as: TranscriptSearchResponse.self
            )
            guard !Task.isCancelled else { return }
            isSearchingTranscripts = false
            transcriptSearchIndexing = response?.indexing ?? false
            transcriptHits = response?.results ?? []
        }
    }
}
