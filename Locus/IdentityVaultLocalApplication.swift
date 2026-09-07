import Foundation

extension IdentityVaultModel {
    /// Conservative local suggestions allow filling without sharing page text
    /// with a provider. Every resulting mapping still receives native review.
    static func localMappings(profile: IdentityVaultProfile, snapshot: IdentityBrowserSnapshot) -> [[String: String]] {
        func normalized(_ value: String) -> String {
            value.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let aliases: [String: Set<String>] = [
            "full_name": ["name", "full name", "your name"],
            "email": ["email", "email address", "e mail"],
            "phone": ["phone", "phone number", "telephone", "telephone number"],
            "business_name": ["company", "company name", "business name"],
            "legal_name": ["legal name", "legal business name"],
            "street_address": ["address", "street address", "address line 1"],
            "region": ["state", "province", "province state", "state province"],
            "postal_code": ["zip", "zip code", "postal code", "postal zip code"],
        ]
        return snapshot.fields.compactMap { target in
            guard !["file", "checkbox", "radio", "password"].contains(target.type) else { return nil }
            let label = normalized(target.label)
            let candidates = profile.fields.filter { field in
                !field.value.isEmpty && (normalized(field.label) == label || normalized(field.key) == label || aliases[field.key]?.contains(label) == true)
            }
            guard candidates.count == 1, let field = candidates.first else { return nil }
            return ["field_id": field.id.uuidString, "ref": target.id]
        }
    }

    func useApplicationLocally(session: String, browser: BrowserService, upload: Bool) async -> [String: Any] {
        let local = IdentityProviderIdentity(accountID: "native", provider: "native", endpoint: "This Mac", model: "", label: "Local application filling")
        guard identitySessions.contains(session), await ready() else { return ["error": "Open an Identity task first."] }
        do {
            if upload {
                let documents = store.documents
                guard !documents.isEmpty else { return ["error": "Import a document into Identity Vault first."] }
                let rows = documents.map { IdentityReviewItem(id: $0.id, label: $0.name, detail: "\($0.kind.title) · Version \($0.version)", selected: false) }
                guard let choice = await review(.init(sessionID: session, title: "Choose a document to attach", destination: "Private application",
                    explanation: "Choose one encrypted document version. You will review its website and upload control next.", items: rows, singleSelection: true, confirmation: "Choose document")),
                    let document = store.documents.first(where: { choice.contains($0.id) }) else { return ["error": "Cancelled."] }
                let snapshot = try await browser.snapshotIdentityApplication(sessionID: session)
                let inputs = snapshot.fields.filter { $0.type == "file" }
                guard !inputs.isEmpty else { return ["error": "No supported visible file input is available. Complete this step on the website."] }
                let inputRows = inputs.map { IdentityReviewItem(label: $0.label, detail: "File upload control", selected: false) }
                guard let choice = await review(.init(sessionID: session, title: "Choose an upload field", destination: snapshot.origin,
                    explanation: "Select the exact visible control that should receive this document.", items: inputRows, singleSelection: true, confirmation: "Choose upload field")),
                    let index = inputRows.firstIndex(where: { choice.contains($0.id) }) else { return ["error": "Cancelled."] }
                let ref = UUID().uuidString
                browserSnapshots[ref] = snapshot
                return await perform(arguments: ["action": "attach_document", "document_ref": documentReference(document, session: session),
                    "snapshot_ref": ref, "action_ref": inputs[index].id], session: session, provider: local, browser: browser)
            }
            if resolveProfile(nil, session: session) == nil {
                let result = await perform(arguments: ["action": "select"], session: session, provider: local, browser: browser)
                if result["error"] != nil { return result }
            }
            guard let profile = resolveProfile(nil, session: session) else { return ["error": "Select a profile first."] }
            let snapshot = try await browser.snapshotIdentityApplication(sessionID: session)
            let mappings = Self.localMappings(profile: profile, snapshot: snapshot)
            guard !mappings.isEmpty else { return ["error": "No clear field matches were found. Unknown controls stay blank; you can fill them yourself or choose Continue with AI."] }
            let ref = UUID().uuidString
            browserSnapshots[ref] = snapshot
            return await perform(arguments: ["action": "prepare_fill", "profile_ref": profileReference(profile, session: session),
                "snapshot_ref": ref, "mappings": mappings], session: session, provider: local, browser: browser)
        } catch { return ["error": "The page changed or this control is unsupported. Review the page and try again."] }
    }
}

extension AppModel {
    func useIdentityApplicationLocally(upload: Bool) {
        let session = currentSessionID
        Task {
            let result = await identityVault.useApplicationLocally(session: session, browser: browser, upload: upload)
            showToast(result["error"] as? String ?? result["text"] as? String ?? "Private application updated.")
        }
    }
}
