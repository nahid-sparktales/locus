import Foundation

extension IdentityVaultModel {
    /// The only model-facing interface. Values are resolved here, on the Mac;
    /// the ordinary tool result is always references and status information.
    func perform(
        arguments: [String: Any], session: String,
        provider: IdentityProviderIdentity, browser: BrowserService
    ) async -> [String: Any] {
        guard identitySessions.contains(session), await ready() else {
            return ["error": "Open an Identity task from Identity Vault before using private information."]
        }
        do {
            switch arguments["action"] as? String ?? "select" {
            case "select":
                let kind = (arguments["profile_kind"] as? String).flatMap(IdentityVaultProfileKind.init(rawValue:))
                let profiles = store.profiles.filter { kind == nil || $0.kind == kind }
                guard !profiles.isEmpty else { return ["error": "Create a matching profile in Identity Vault first."] }
                let rows = profiles.map { IdentityReviewItem(id: $0.id, label: $0.name, detail: $0.kind.title, selected: false) }
                guard let choice = await review(.init(sessionID: session, title: "Choose a private profile",
                    destination: provider.label, explanation: "Only field types and private references will be available to this task. Values remain in the vault.",
                    items: rows, singleSelection: true, confirmation: "Use profile")),
                    let profile = profiles.first(where: { choice.contains($0.id) }),
                    store.profiles.contains(where: { $0.id == profile.id && $0.revision == profile.revision }) else { return denied() }
                return describe(profile, session: session)

            case "describe":
                guard let profile = resolveProfile(arguments["profile_ref"] as? String, session: session) else {
                    return ["error": "Select a profile first."]
                }
                return describe(profile, session: session)

            case "request_context":
                return try await shareContext(arguments, session: session, provider: provider)

            case "open_application":
                guard let raw = arguments["url"] as? String, let url = URL(string: raw),
                      url.scheme?.lowercased() == "https", url.host != nil,
                      url.user == nil, url.password == nil else {
                    return ["error": "Choose an HTTPS application URL."]
                }
                let row = IdentityReviewItem(label: "Open private application", detail: url.absoluteString)
                guard await review(.init(sessionID: session, title: "Open application privately?",
                    destination: url.host ?? "Website", explanation: "A fresh private browser session keeps application data separate from other tabs. You may need to sign in again.",
                    items: [row], confirmation: "Open private application"))?.contains(row.id) == true else { return denied() }
                let snapshot = try await browser.openIdentityApplication(sessionID: session, url: url)
                IdentityPrivacyGuard.shared.applicationSessions.insert(session)
                browserSnapshots[snapshot.tabID] = snapshot
                return safe(["status": "application_open", "snapshot_ref": snapshot.tabID,
                             "next": "request_page_snapshot; page contents require a separate native review"])

            case "request_page_snapshot":
                let snapshot = try await browser.snapshotIdentityApplication(sessionID: session)
                let form = snapshot.fields.map { "Field [\($0.id)] \($0.label) (\($0.type))" }
                let actions = snapshot.actions.map { "Action [\($0.id)] \($0.label) (\($0.type))" }
                let text = String(([snapshot.text] + form + actions).joined(separator: "\n").prefix(60_000))
                let row = IdentityReviewItem(label: "Page text and form controls", detail: text)
                guard await review(.init(sessionID: session, title: "Continue with AI",
                    destination: provider.label + " · " + snapshot.origin,
                    explanation: "Only this exact page snapshot will be shared. It may contain information already filled into the website. Future snapshots need their own review. AI replies follow normal chat history.",
                    items: [row], confirmation: "Share this snapshot"))?.contains(row.id) == true else { return denied() }
                // No recapture after consent: the approved bytes are immutable.
                let id = try store.saveSnapshot(text: text)
                try store.recordDisclosure(.init(taskID: session, recipientID: provider.recipientID,
                    recipientLabel: provider.label, kind: .provider, summary: "Shared a reviewed application snapshot", snapshotID: id))
                let ref = rememberSource(snapshotID: id, session: session, provider: provider)
                let snapshotRef = UUID().uuidString
                browserSnapshots[snapshotRef] = snapshot
                return withSource(ref, payload: ["status": "snapshot_approved", "snapshot_ref": snapshotRef])

            case "prepare_fill":
                guard let profile = resolveProfile(arguments["profile_ref"] as? String, session: session),
                      let snapshotRef = arguments["snapshot_ref"] as? String,
                      let snapshot = browserSnapshots[snapshotRef], snapshot.sessionID == session,
                      let mappings = arguments["mappings"] as? [[String: Any]], !mappings.isEmpty else {
                    return ["error": "Select a profile and a reviewed page snapshot, then map its exact field references."]
                }
                var bindings: [(IdentityReviewItem, IdentityBrowserBinding, UUID)] = []
                for mapping in mappings {
                    guard let id = mapping["field_id"] as? String,
                          let field = profile.fields.first(where: { $0.id.uuidString == id }),
                          let ref = mapping["ref"] as? String,
                          let target = snapshot.fields.first(where: { $0.id == ref }),
                          !field.value.isEmpty,
                          !bindings.contains(where: { $0.1.fieldID == ref }) else { return ["error": "A proposed field mapping is invalid."] }
                    bindings.append((IdentityReviewItem(label: target.label + " ← " + field.label, detail: field.value),
                                     IdentityBrowserBinding(fieldID: ref, value: field.value), field.id))
                }
                guard let selected = await review(.init(sessionID: session, title: "Fill selected fields locally",
                    destination: snapshot.origin,
                    explanation: "These values go directly to this website, without being included in the AI request. Websites can receive information as soon as a field is filled.",
                    items: bindings.map { $0.0 }, confirmation: "Fill selected fields")), !selected.isEmpty,
                      store.profiles.contains(where: { $0.id == profile.id && $0.revision == profile.revision }) else { return denied() }
                let chosen = bindings.filter { selected.contains($0.0.id) }
                let status = try await browser.fillIdentityApplication(snapshot: snapshot, bindings: chosen.map { $0.1 })
                try store.recordDisclosure(.init(taskID: session, recipientID: snapshot.origin,
                    recipientLabel: snapshot.origin, kind: .website, summary: "Local fill: \(chosen.count) fields", fieldIDs: chosen.map { $0.2 }))
                browserSnapshots = browserSnapshots.filter { $0.value.sessionID != session }
                return ["text": status]

            case "attach_document":
                guard let document = resolveDocument(arguments["document_ref"] as? String, session: session),
                      let ref = arguments["snapshot_ref"] as? String, let snapshot = browserSnapshots[ref],
                      snapshot.sessionID == session, let fieldID = arguments["action_ref"] as? String ?? arguments["ref"] as? String,
                      snapshot.fields.contains(where: { $0.id == fieldID && $0.type == "file" }) else {
                    return ["error": "Choose a document reference and the file input from a reviewed page snapshot."]
                }
                let row = IdentityReviewItem(label: document.name, detail: "Version \(document.version) · \(document.kind.title) · \(document.byteCount) bytes", selected: document.kind != .signature)
                guard await review(.init(sessionID: session,
                    title: document.kind == .signature ? "Share this signature image?" : "Attach this document?",
                    destination: snapshot.origin,
                    explanation: "The complete original file, including any metadata, will be available to this website immediately. Its contents are not sent to AI by this action.",
                    items: [row], confirmation: "Attach selected file"))?.contains(row.id) == true,
                      store.documents.contains(where: { $0.id == document.id && $0.contentHash == document.contentHash }) else { return denied() }
                let data = try store.documentData(id: document.id)
                let status = try await browser.uploadIdentityApplication(snapshot: snapshot, fieldID: fieldID, data: data, filename: document.name)
                try store.recordDisclosure(.init(taskID: session, recipientID: snapshot.origin,
                    recipientLabel: snapshot.origin, kind: .website, summary: "Attached one document version", documentIDs: [document.id]))
                browserSnapshots = browserSnapshots.filter { $0.value.sessionID != session }
                return ["text": status]

            case "browser_action":
                guard let ref = arguments["snapshot_ref"] as? String, let snapshot = browserSnapshots[ref],
                      snapshot.sessionID == session, let actionRef = arguments["action_ref"] as? String,
                      let action = snapshot.actions.first(where: { $0.id == actionRef }) else {
                    return ["error": "Choose an action from the current reviewed page snapshot."]
                }
                let row = IdentityReviewItem(label: action.label, detail: "Activate this exact website control.")
                guard await review(.init(sessionID: session, title: "Confirm website action",
                    destination: snapshot.origin,
                    explanation: "This action may submit the application or send information already entered. Review the page before continuing.",
                    items: [row], confirmation: "Confirm action"))?.contains(row.id) == true else { return denied() }
                let status = try await browser.clickIdentityApplication(snapshot: snapshot, actionID: actionRef)
                browserSnapshots = browserSnapshots.filter { $0.value.sessionID != session }
                return ["text": status]

            case "save_draft":
                let raw = arguments["sections"] as? [[String: Any]] ?? []
                guard (1...50).contains(raw.count) else { return ["error": "Provide between 1 and 50 document sections."] }
                let sections = raw.map { IdentityVaultDocumentSection(heading: String(($0["heading"] as? String ?? "").prefix(200)), text: String(($0["text"] as? String ?? "").prefix(20_000))) }
                let rows = sections.map { IdentityReviewItem(id: $0.id, label: $0.heading.isEmpty ? "Draft text" : $0.heading, detail: $0.text) }
                guard let selected = await review(.init(sessionID: session, title: "Review the writing draft",
                    destination: "Identity Vault on this Mac", explanation: "Check names, dates, qualifications, and claims. Saving this draft does not change your profile. Private contact details are inserted locally when you create PDF and Word files.",
                    items: rows, confirmation: "Save reviewed draft")), !selected.isEmpty else { return denied() }
                let profile = resolveProfile(arguments["profile_ref"] as? String, session: session)
                let draft = IdentityVaultDraft(profileID: profile?.id,
                    title: String((arguments["title"] as? String ?? "Writing draft").prefix(200)),
                    kind: arguments["draft_kind"] as? String == "cover_letter" ? .coverLetter : .resume,
                    sections: sections.filter { selected.contains($0.id) })
                try store.saveDraft(draft)
                draftEditor = draft
                tab = .documents
                isPresented = true
                return safe(["status": "draft_saved", "next": "The user can edit, preview, and generate PDF and Word files in Identity Vault."])

            case "status":
                return safe(["status": "ready", "profile_selected": resolveProfile(nil, session: session) != nil,
                             "private_application_open": browser.isIdentityApplication(sessionID: session)])
            default: return ["error": "Unsupported Identity Vault operation."]
            }
        } catch {
            // Never forward page/helper errors: they may echo private values.
            return ["error": "The private operation could not finish. The page or vault item may have changed; review it again."]
        }
    }

    private func describe(_ profile: IdentityVaultProfile, session: String) -> [String: Any] {
        let documents = store.documents.filter { $0.profileID == profile.id }
        return safe([
            "profile_ref": profileReference(profile, session: session), "profile_kind": profile.kind.rawValue,
            "fields": profile.fields.filter { !$0.value.isEmpty }.map {
                ["field_id": $0.id.uuidString, "key": $0.key.hasPrefix("custom_") ? "custom" : $0.key, "type": $0.kind.rawValue]
            },
            "documents": documents.map { ["document_ref": documentReference($0, session: session), "kind": $0.kind.rawValue, "version": String($0.version)] },
        ])
    }

    private func shareContext(_ arguments: [String: Any], session: String, provider: IdentityProviderIdentity) async throws -> [String: Any] {
        var rows: [IdentityReviewItem] = []
        var fieldIDs: [UUID] = []
        var documentIDs: [UUID] = []
        var profileRevision: (UUID, Int)?
        if let document = resolveDocument(arguments["document_ref"] as? String, session: session) {
            guard !document.extractedText.isEmpty else { return ["error": "This file has no extracted text. Open it in the vault to review it."] }
            documentIDs = [document.id]
            let chunks = document.extractedText.components(separatedBy: "\n\n").flatMap { paragraph -> [String] in
                var pieces: [String] = []
                var remaining = paragraph[...]
                while !remaining.isEmpty {
                    let end = remaining.index(remaining.startIndex, offsetBy: min(remaining.count, 4_000))
                    pieces.append(String(remaining[..<end]))
                    remaining = remaining[end...]
                }
                return pieces
            }
            var remaining = 60_000
            for (index, chunk) in chunks.enumerated() where !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remaining > 0 {
                let text = String(chunk.prefix(min(remaining, 12_000)))
                rows.append(IdentityReviewItem(label: "Document excerpt \(index + 1)", detail: text, selected: false))
                remaining -= text.count
            }
        } else if let profile = resolveProfile(arguments["profile_ref"] as? String, session: session) {
            let requested = Set(arguments["field_ids"] as? [String] ?? [])
            let fields = profile.fields.filter { !$0.value.isEmpty }
            fieldIDs = fields.map(\.id)
            profileRevision = (profile.id, profile.revision)
            rows = fields.map { IdentityReviewItem(id: $0.id, label: $0.label, detail: $0.value, selected: requested.contains($0.id.uuidString)) }
        } else { return ["error": "Select a profile or document first."] }
        guard let selection = await review(.init(sessionID: session, title: "Choose what AI may read",
            destination: provider.label + " · " + provider.endpoint,
            explanation: "Only checked content will be sent to this provider for this task. Source excerpts stay encrypted in the vault; AI replies follow ordinary chat history. Unchecked information stays private.",
            items: rows, confirmation: "Share selected content")), !selection.isEmpty else { return denied() }
        if let (id, revision) = profileRevision,
           !store.profiles.contains(where: { $0.id == id && $0.revision == revision }) { return denied() }
        guard documentIDs.allSatisfy({ id in store.documents.contains { $0.id == id } }) else { return denied() }
        let text = rows.filter { selection.contains($0.id) }.map { "\($0.label)\n\($0.detail)" }.joined(separator: "\n\n")
        guard text.count <= 60_000 else { return ["error": "Select fewer excerpts; each disclosure is limited to 60,000 characters."] }
        let id = try store.saveSnapshot(text: text)
        try store.recordDisclosure(.init(taskID: session, recipientID: provider.recipientID,
            recipientLabel: provider.label, kind: .provider, summary: "Shared \(selection.count) selected items",
            fieldIDs: fieldIDs.filter { selection.contains($0) }, documentIDs: documentIDs, snapshotID: id))
        return withSource(rememberSource(snapshotID: id, session: session, provider: provider), payload: ["status": "content_approved"])
    }

    func resolveSources(_ refs: [String], session: String, provider: IdentityProviderIdentity) async -> [String: Any] {
        guard identitySessions.contains(session), await ready(), refs.count <= 32 else { return ["error": "Private context is unavailable."] }
        do {
            var sources: [[String: String]] = []
            var count = 0
            for ref in Set(refs).sorted() {
                guard let id = UUID(uuidString: ref),
                      store.disclosures.contains(where: { $0.taskID == session && $0.snapshotID == id && $0.kind == .provider }) else {
                    return ["error": "That source does not belong to this Identity task."]
                }
                let text = try store.snapshotText(id: id)
                count += text.count
                guard count <= 200_000 else { return ["error": "Too much private context. Start a new Identity task with fewer sources."] }
                if !sourceIsApproved(ref, session: session, provider: provider) {
                    let row = IdentityReviewItem(label: "Previously selected source", detail: text)
                    guard await review(.init(sessionID: session, title: "Restore private context?",
                        destination: provider.label + " · " + provider.endpoint,
                        explanation: "This task contains prior AI replies that may repeat shared information. Approve restoring this source and continuing the conversation with this provider, or cancel and start a clean task.",
                        items: [row], confirmation: "Approve this source"))?.contains(row.id) == true else { return denied() }
                    // A deletion/revocation while the review was open wins.
                    guard (try? store.snapshotText(id: id)) == text else { return denied() }
                    try store.recordDisclosure(.init(taskID: session, recipientID: provider.recipientID,
                        recipientLabel: provider.label, kind: .provider, summary: "Restored reviewed source context", snapshotID: id))
                    approveSource(ref, session: session, provider: provider)
                }
                sources.append(["reference": ref, "text": text])
            }
            // A later source can require a native review, which yields the
            // actor while already collected sources are revoked, locked, or
            // cancelled. Revalidate the whole batch at the final release point.
            guard !Task.isCancelled, store.isReady, sources.allSatisfy({ source in
                guard let ref = source["reference"], let id = UUID(uuidString: ref),
                      sourceIsApproved(ref, session: session, provider: provider),
                      store.disclosures.contains(where: { $0.taskID == session && $0.snapshotID == id && $0.kind == .provider })
                else { return false }
                return (try? store.snapshotText(id: id)) == source["text"]
            }) else { return denied() }
            return ["sources": sources]
        } catch { return ["error": "A private source was removed or revoked. Start a clean Identity task."] }
    }

    private func safe(_ object: [String: Any]) -> [String: Any] {
        guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8) else { return ["error": "The private operation could not be described."] }
        return ["text": text]
    }
    private func withSource(_ ref: String, payload: [String: Any]) -> [String: Any] {
        var result = safe(payload)
        result["source_refs"] = [ref]
        return result
    }
    private func denied() -> [String: Any] { ["error": "The private operation was cancelled or the selection changed. Nothing further was shared."] }
}
