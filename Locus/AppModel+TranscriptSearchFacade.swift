import Foundation

/// Forwarders kept while consumers still reach transcript search through
/// AppModel; each is deleted once its last caller observes
/// `model.transcriptSearch` directly.
extension AppModel {
    var transcriptHits: [TranscriptSearchHit] {
        get { transcriptSearch.transcriptHits }
        set { transcriptSearch.transcriptHits = newValue }
    }

    var isSearchingTranscripts: Bool { transcriptSearch.isSearchingTranscripts }
    var transcriptSearchIndexing: Bool { transcriptSearch.transcriptSearchIndexing }
}
