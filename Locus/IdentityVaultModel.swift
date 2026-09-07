import AppKit
import Combine
import Foundation

/// Shared by native capture brokers. A vault review must never be readable by
/// another Locus task through Accessibility or a screen capture.
@MainActor
final class IdentityPrivacyGuard {
    static let shared = IdentityPrivacyGuard()
    var visiblePrivateViews = 0
    var applicationSessions = Set<String>()
    var blocksCapture: Bool { visiblePrivateViews > 0 || !applicationSessions.isEmpty }
}

struct IdentityProviderIdentity: Codable, Equatable, Sendable {
    let accountID: String
    let provider: String
    let endpoint: String
    let model: String
    let label: String
    var recipientID: String { [accountID, provider, endpoint, model].joined(separator: "|") }
}

struct IdentityReviewItem: Identifiable {
    var id = UUID()
    let label: String
    let detail: String
    var selected = true
}

struct IdentityVaultReview: Identifiable {
    let id = UUID()
    let sessionID: String
    let title: String
    let destination: String
    let explanation: String
    var items: [IdentityReviewItem]
    var singleSelection = false
    var confirmation = "Approve selected"
}

enum IdentityVaultTab: String, CaseIterable, Identifiable {
    case profiles = "Profiles", documents = "Documents", signatures = "Signatures", history = "Sharing History"
    var id: String { rawValue }
}

@MainActor
final class IdentityVaultModel: ObservableObject {
    let store: IdentityVaultStore
    @Published var isPresented = false
    @Published var tab: IdentityVaultTab = .profiles
    @Published var query = ""
    @Published var notice: String?
    @Published var isWorking = false
    @Published var profileEditor: IdentityVaultProfile?
    @Published var draftEditor: IdentityVaultDraft?
    @Published var previewDocument: IdentityVaultDocument?
    @Published var pendingReview: IdentityVaultReview?
    @Published private(set) var lifecycleGeneration: UInt64 = 0
    var localWork: Task<Void, Never>?
    @Published private(set) var selectedProfiles: [String: UUID] = [:]
    @Published private(set) var identitySessions: Set<String>
    var backendRoot = ""
    private let defaults: UserDefaults?
    private var observers: [NSObjectProtocol] = []
    private var screenObservers: [NSObjectProtocol] = []
    private var blocked = false
    private var reviewGeneration: UInt64 = 0
    private var sessionReviewGenerations: [String: UInt64] = [:]
    private struct Pending {
        let review: IdentityVaultReview
        let continuation: CheckedContinuation<Set<UUID>?, Never>
    }
    private var reviews: [Pending] = []
    private var profileRefs: [String: (session: String, id: UUID)] = [:]
    private var documentRefs: [String: (session: String, id: UUID)] = [:]
    private var sourceRefs: [String: (session: String, snapshot: UUID)] = [:]
    private var grants: [String: String] = [:]
    var browserSnapshots: [String: IdentityBrowserSnapshot] = [:]
    var onLock: (() -> Void)?

    init(store: IdentityVaultStore, defaults: UserDefaults? = nil) {
        self.store = store
        self.defaults = defaults
        identitySessions = Set(defaults?.stringArray(forKey: "identityVault.sessions.v1") ?? [])
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.blocked = false }
            })
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            screenObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if locked { self?.suspend() } else { self?.blocked = false }
                }
            })
        }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        screenObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    func open() {
        isPresented = true
        Task { if !(await ready()) { notice = store.lastError ?? "Unlock your Mac to open Identity Vault." } }
    }

    func ready() async -> Bool {
        guard !blocked else { return false }
        return await store.load()
    }

    func registerSession(_ id: String, profileID: UUID? = nil) {
        identitySessions.insert(id)
        defaults?.set(Array(identitySessions), forKey: "identityVault.sessions.v1")
        if let profileID { selectedProfiles[id] = profileID }
    }

    func suspend() {
        blocked = true
        lifecycleGeneration &+= 1
        localWork?.cancel()
        localWork = nil
        isWorking = false
        isPresented = false
        notice = nil
        query = ""
        cancelReviews()
        grants.removeAll()
        browserSnapshots.removeAll()
        profileEditor = nil
        draftEditor = nil
        previewDocument = nil
        store.lock()
        onLock?()
    }

    func cancelReviews(sessionID: String? = nil) {
        if let sessionID { sessionReviewGenerations[sessionID, default: 0] &+= 1 }
        else { reviewGeneration &+= 1 }
        let cancelled = reviews.filter { sessionID == nil || $0.review.sessionID == sessionID }
        reviews.removeAll { sessionID == nil || $0.review.sessionID == sessionID }
        cancelled.forEach { $0.continuation.resume(returning: nil) }
        pendingReview = reviews.first?.review
        if let sessionID {
            grants = grants.filter { sourceRefs[$0.key]?.session != sessionID }
        } else { grants.removeAll() }
    }

    func review(_ request: IdentityVaultReview) async -> Set<UUID>? {
        guard !blocked, !Task.isCancelled else { return nil }
        let generation = reviewGeneration
        let sessionGeneration = sessionReviewGenerations[request.sessionID, default: 0]
        isPresented = false
        let selection: Set<UUID>? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reviews.append(Pending(review: request, continuation: continuation))
                if pendingReview == nil { pendingReview = request }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelReview(id: request.id) }
        }
        guard !blocked, !Task.isCancelled, reviewGeneration == generation,
              sessionReviewGenerations[request.sessionID, default: 0] == sessionGeneration else { return nil }
        return selection
    }

    private func cancelReview(id: UUID) {
        guard let index = reviews.firstIndex(where: { $0.review.id == id }) else { return }
        reviews.remove(at: index).continuation.resume(returning: nil)
        pendingReview = reviews.first?.review
    }

    func answerReview(id: UUID, selected: Set<UUID>?) {
        guard reviews.first?.review.id == id else { return }
        let pending = reviews.removeFirst()
        let allowed = Set(pending.review.items.map(\.id))
        let result = selected.map { $0.intersection(allowed) }
        pendingReview = reviews.first?.review
        pending.continuation.resume(returning: blocked ? nil : result)
    }

    func profileReference(_ profile: IdentityVaultProfile, session: String) -> String {
        if let match = profileRefs.first(where: { $0.value.session == session && $0.value.id == profile.id }) { return match.key }
        let ref = UUID().uuidString
        profileRefs[ref] = (session, profile.id)
        selectedProfiles[session] = profile.id
        return ref
    }

    func resolveProfile(_ ref: String?, session: String) -> IdentityVaultProfile? {
        let id: UUID?
        if let ref {
            guard let item = profileRefs[ref], item.session == session else { return nil }
            id = item.id
        } else { id = selectedProfiles[session] }
        return store.profiles.first { $0.id == id }
    }

    func documentReference(_ document: IdentityVaultDocument, session: String) -> String {
        if let match = documentRefs.first(where: { $0.value.session == session && $0.value.id == document.id }) { return match.key }
        let ref = UUID().uuidString
        documentRefs[ref] = (session, document.id)
        return ref
    }

    func resolveDocument(_ ref: String?, session: String) -> IdentityVaultDocument? {
        guard let ref, let item = documentRefs[ref], item.session == session else { return nil }
        return store.documents.first { $0.id == item.id }
    }

    func rememberSource(snapshotID: UUID, session: String, provider: IdentityProviderIdentity) -> String {
        let ref = snapshotID.uuidString
        sourceRefs[ref] = (session, snapshotID)
        grants[ref] = provider.recipientID
        return ref
    }

    func sourceIsApproved(_ ref: String, session: String, provider: IdentityProviderIdentity) -> Bool {
        sourceRefs[ref]?.session == session && grants[ref] == provider.recipientID && !blocked
    }

    func approveSource(_ ref: String, session: String, provider: IdentityProviderIdentity) {
        guard let snapshot = UUID(uuidString: ref) else { return }
        sourceRefs[ref] = (session, snapshot)
        grants[ref] = provider.recipientID
    }

    func revoke(_ disclosure: IdentityVaultDisclosure) {
        if let id = disclosure.snapshotID {
            grants.removeValue(forKey: id.uuidString)
            do { try store.deleteSnapshot(id: id) }
            catch { notice = error.localizedDescription; return }
        }
        notice = "Future access revoked. Information already shared cannot be recalled."
    }
}
