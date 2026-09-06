import Foundation

enum WalletReleaseHistorySource {
    /// Parent locations are derived from a validated digest under the sealed
    /// endpoint directory, never from a URL supplied in a remote payload.
    static func fetch(from endpoint: URL, checkpoint: WalletReleaseAuthorityCheckpoint?) async throws -> WalletReleaseHistoryRequest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try await WalletReleaseActivationSource.fetch(from: endpoint)
        let supplied: WalletReleaseHistoryRequest
        if let request = try? decoder.decode(WalletReleaseHistoryRequest.self, from: data) {
            supplied = request
        } else {
            supplied = .init(schemaVersion: 1,
                transitions: [try decoder.decode(WalletSignedReleaseTransition.self, from: data)], admission: nil)
        }
        guard supplied.schemaVersion == 1, !supplied.transitions.isEmpty,
              supplied.transitions.count <= WalletReleaseHistoryVerifier.maximumTransitions else {
            throw WalletReleaseActivationError.malformed
        }
        var transitions = supplied.transitions
        var bytesRead = data.count
        var seen = Set(transitions.map(\.digest))
        guard seen.count == transitions.count else { throw WalletReleaseActivationError.historyRequired }
        // An unchanged head is a valid cached lease, not a request for its full
        // ancestors. Its installed checkpoint was authenticated by the signer.
        if transitions.count == 1, transitions[0].digest == checkpoint?.digest { return supplied }
        while let parent = transitions.first?.envelope.previousEnvelopeSHA256,
              parent != checkpoint?.digest {
            guard WalletAuthorityEncoding.hex(parent), !seen.contains(parent),
                  transitions.count < WalletReleaseHistoryVerifier.maximumTransitions else {
                throw WalletReleaseActivationError.historyRequired
            }
            let url = endpoint.deletingLastPathComponent().appendingPathComponent("history")
                .appendingPathComponent(parent + ".json")
            let parentBytes = try await WalletReleaseActivationSource.fetch(from: url)
            bytesRead += parentBytes.count
            guard bytesRead <= WalletReleaseHistoryVerifier.maximumHistoryBytes else {
                throw WalletReleaseActivationError.malformed
            }
            let record = try decoder.decode(WalletSignedReleaseTransition.self, from: parentBytes)
            guard record.digest == parent else { throw WalletReleaseActivationError.historyRequired }
            transitions.insert(record, at: 0); seen.insert(parent)
        }
        return .init(schemaVersion: 1, transitions: transitions, admission: supplied.admission)
    }
}
