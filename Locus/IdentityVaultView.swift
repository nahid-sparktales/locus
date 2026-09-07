import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct IdentityVaultPresentation: ViewModifier {
    @ObservedObject var vault: IdentityVaultModel
    @EnvironmentObject private var model: AppModel
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $vault.isPresented) {
                IdentityVaultView(vault: vault).environmentObject(model)
            }
            .sheet(item: Binding(get: { vault.pendingReview }, set: { value in
                if value == nil, let request = vault.pendingReview { vault.answerReview(id: request.id, selected: nil) }
            })) { request in
                IdentityVaultApprovalView(request: request) { selected in
                    vault.answerReview(id: request.id, selected: selected)
                }.id(request.id)
            }
    }
}

private struct IdentityPrivateSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { IdentityPrivacyGuard.shared.visiblePrivateViews += 1 }
            .onDisappear { IdentityPrivacyGuard.shared.visiblePrivateViews = max(0, IdentityPrivacyGuard.shared.visiblePrivateViews - 1) }
    }
}

struct IdentityVaultApprovalView: View {
    let request: IdentityVaultReview
    let answer: (Set<UUID>?) -> Void
    @State private var selection: Set<UUID>
    init(request: IdentityVaultReview, answer: @escaping (Set<UUID>?) -> Void) {
        self.request = request
        self.answer = answer
        _selection = State(initialValue: Set(request.items.filter(\.selected).map(\.id)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(request.title, systemImage: "lock.shield").font(.title2.bold())
            Text(request.destination).font(.headline).textSelection(.enabled)
            Text("Task \(request.sessionID.prefix(12))").font(.caption).foregroundStyle(LocusTheme.textTertiary)
            Text(request.explanation).foregroundStyle(LocusTheme.textTertiary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(request.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(item.label, isOn: Binding(get: { selection.contains(item.id) }, set: { include in
                                if request.singleSelection { selection = include ? [item.id] : [] }
                                else if include { selection.insert(item.id) } else { selection.remove(item.id) }
                            })).font(.headline)
                            Text(item.detail).font(.locus(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(minHeight: 120, maxHeight: 420)
            HStack {
                Button("Cancel", role: .cancel) { answer(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(selection.count) selected").foregroundStyle(LocusTheme.textTertiary)
                Button(request.confirmation) { answer(selection) }
                    .buttonStyle(.borderedProminent).tint(LocusTheme.ink)
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("identity.review.approve")
            }
        }.padding(24).frame(width: 650)
            .modifier(IdentityPrivateSurface())
            .accessibilityIdentifier("identity.review")
    }
}

struct IdentityVaultView: View {
    @ObservedObject var vault: IdentityVaultModel
    @ObservedObject private var store: IdentityVaultStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importReview: IdentityImportRequest?
    @State private var deleteDocument: IdentityVaultDocument?

    init(vault: IdentityVaultModel) { self.vault = vault; self.store = vault.store }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Identity Vault", systemImage: "person.text.rectangle").font(.title2.bold())
                    Text("Private profiles and documents, encrypted on this Mac.").foregroundStyle(LocusTheme.textTertiary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Picker("Identity Vault", selection: $vault.tab) {
                ForEach(IdentityVaultTab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 22).padding(.bottom, 16)
            Divider()
            if !store.isReady {
                ContentUnavailableView {
                    Label("Open your vault", systemImage: "lock")
                } description: {
                    Text(store.lastError ?? "Your Mac must be unlocked to use Identity Vault.")
                } actions: {
                    Button("Open Vault") { Task { _ = await vault.ready() } }
                }
            } else {
                toolbar
                if let notice = vault.notice {
                    HStack(alignment: .top) {
                        Text(notice).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        Button { vault.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.locus(.icon))
                    }.padding(12).background(LocusTheme.warningForeground.opacity(0.10)).padding(.horizontal)
                }
                if vault.isWorking { ProgressView("Processing locally…").padding(12) }
                switch vault.tab {
                case .profiles: profiles
                case .documents, .signatures: documents
                case .history: history
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 940, minHeight: 560, idealHeight: 700)
        .background(LocusTheme.paper).foregroundStyle(LocusTheme.ink)
        .modifier(IdentityPrivateSurface())
        .task { _ = await vault.ready() }
        .onChange(of: vault.lifecycleGeneration) { _, _ in
            importReview = nil
            deleteDocument = nil
        }
        .sheet(item: $vault.profileEditor) { profile in
            IdentityProfileEditor(profile: profile) { edited in
                do { _ = try store.saveProfile(edited); vault.profileEditor = nil }
                catch { vault.notice = error.localizedDescription }
            } onDelete: {
                do { try store.deleteProfile(profile.id); vault.profileEditor = nil }
                catch { vault.notice = error.localizedDescription }
            }
        }
        .sheet(item: $importReview) { request in
            IdentityDocumentImportView(request: request, profiles: store.profiles) { kind, profileID in
                do {
                    _ = try store.addDocument(name: request.document.name, kind: kind,
                        mimeType: request.document.mimeType, data: request.document.data,
                        extractedText: request.document.extractedText, profileID: profileID,
                        replacingDocumentID: request.replacingID)
                    importReview = nil
                    vault.notice = "Saved privately. Document text has not been added to chats or workspace search."
                } catch { vault.notice = error.localizedDescription }
            }
        }
        .sheet(item: $vault.previewDocument) { document in
            IdentityDocumentPreview(document: document, data: (try? store.documentData(id: document.id)) ?? Data())
        }
        .sheet(item: $vault.draftEditor) { draft in
            IdentityDraftEditor(draft: draft, profiles: store.profiles, vault: vault) { edited, createFiles, includeContact in
                vault.localWork = Task { await saveDraft(edited, createFiles: createFiles, includeContact: includeContact) }
            }
        }
        .alert("Delete this document version?", isPresented: Binding(get: { deleteDocument != nil }, set: { if !$0 { deleteDocument = nil } })) {
            Button("Cancel", role: .cancel) { deleteDocument = nil }
            Button("Delete", role: .destructive) {
                if let document = deleteDocument {
                    do { try store.deleteDocument(document.id) } catch { vault.notice = error.localizedDescription }
                }
                deleteDocument = nil
            }
        } message: { Text("Other versions remain available. Copies already exported or shared are unaffected.") }
        .accessibilityIdentifier("identity.vault")
    }

    private var toolbar: some View {
        HStack {
            TextField("Search this vault", text: $vault.query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("identity.search")
            if vault.tab == .profiles {
                Menu {
                    ForEach(IdentityVaultProfileKind.allCases) { kind in
                        Button(kind.title) { vault.profileEditor = .init(name: kind.title, kind: kind) }
                    }
                } label: { Label("New Profile", systemImage: "plus") }
            } else if vault.tab != .history {
                Button("Import", systemImage: "square.and.arrow.down") { beginImport() }.disabled(vault.isWorking)
                if vault.tab == .documents {
                    Menu("New Draft", systemImage: "doc.badge.plus") {
                        Button("Résumé") { vault.draftEditor = .init(title: "Résumé", kind: .resume) }
                        Button("Cover letter") { vault.draftEditor = .init(title: "Cover letter", kind: .coverLetter) }
                    }
                }
            }
        }.padding(16)
    }

    private func matches(_ text: String) -> Bool { vault.query.isEmpty || text.localizedCaseInsensitiveContains(vault.query) }

    private var profiles: some View {
        Group {
            if store.profiles.isEmpty {
                ContentUnavailableView("Make information reusable", systemImage: "person.crop.rectangle.badge.plus",
                    description: Text("Create a personal, business, or career profile. Every field stays private until you choose to share it."))
            } else {
                List(store.profiles.filter { matches($0.name + " " + $0.fields.map(\.value).joined(separator: " ")) }) { profile in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(profile.name, systemImage: profile.kind.symbol).font(.headline)
                            Spacer()
                            Text(profile.kind.title).foregroundStyle(LocusTheme.textTertiary)
                            Button("Edit") { vault.profileEditor = profile }
                        }
                        Text("\(profile.fields.filter { !$0.value.isEmpty }.count) saved fields · Private by default")
                            .font(.subheadline).foregroundStyle(LocusTheme.textTertiary)
                        HStack {
                            Button("Use in Private Task", systemImage: "lock.shield") { model.startIdentityTask(profileID: profile.id) }
                            if profile.kind == .career {
                                Menu("Write with AI", systemImage: "pencil") {
                                    Button("Résumé") { startWriting(profile, coverLetter: false) }
                                    Button("Cover letter") { startWriting(profile, coverLetter: true) }
                                }
                            }
                            Spacer()
                        }
                    }.padding(.vertical, 10)
                }.listStyle(.inset)
            }
        }
    }

    private var documents: some View {
        let items = store.documents.filter {
            ($0.kind == .signature) == (vault.tab == .signatures) && matches($0.name + " " + $0.extractedText)
        }.sorted { $0.createdAt > $1.createdAt }
        return List {
            if items.isEmpty {
                ContentUnavailableView(vault.tab == .signatures ? "Keep a signature image privately" : "Save résumés and documents",
                    systemImage: vault.tab == .signatures ? "signature" : "doc.text",
                    description: Text("Import a file to store an encrypted copy. Originals remain unchanged."))
            }
            ForEach(items) { document in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: document.kind == .signature ? "signature" : "doc.text").font(.title2).frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Button(document.name) { vault.previewDocument = document }.buttonStyle(.locus()).font(.headline)
                        Text("\(document.kind.title) · Version \(document.version) · \(ByteCountFormatter.string(fromByteCount: Int64(document.byteCount), countStyle: .file))")
                            .font(.subheadline).foregroundStyle(LocusTheme.textTertiary)
                    }
                    Spacer()
                    Menu {
                        Button("Preview") { vault.previewDocument = document }
                        Button("Export this version…") { exportDocument(document) }
                        Button("Import a new version…") { beginImport(replacing: document) }
                        if document.kind != .signature && !document.extractedText.isEmpty {
                            Button("Create career profile from text…") { profileFromDocument(document) }
                        }
                        Divider()
                        Button("Delete this version", role: .destructive) { deleteDocument = document }
                    } label: { Image(systemName: "ellipsis.circle") }
                }.padding(.vertical, 8)
            }
            if vault.tab == .documents, !store.drafts.isEmpty {
                Section("Editable drafts") {
                    ForEach(store.drafts.filter { matches($0.title) }) { draft in
                        HStack {
                            Label(draft.title, systemImage: "square.and.pencil")
                            Spacer()
                            Button("Edit & Create Files") { vault.draftEditor = draft }
                        }.padding(.vertical, 6)
                    }
                }
            }
        }.listStyle(.inset)
    }

    private var history: some View {
        List {
            if store.disclosures.isEmpty {
                ContentUnavailableView("Sharing stays inspectable", systemImage: "clock.arrow.circlepath",
                    description: Text("Approved AI sharing, website fills, attachments, and exports appear here."))
            }
            ForEach(store.disclosures.reversed().filter { matches($0.summary + " " + $0.recipientLabel) }) { disclosure in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(disclosure.recipientLabel).font(.headline)
                        Spacer()
                        Text(disclosure.createdAt, style: .date).foregroundStyle(LocusTheme.textTertiary)
                    }
                    Text(disclosure.summary)
                    Text("\(disclosure.outcome ?? "Completed") · \(disclosure.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                    if disclosure.kind == .provider && disclosure.snapshotID != nil {
                        Button("Revoke future access") { vault.revoke(disclosure) }.font(.callout)
                    }
                }.padding(.vertical, 8)
            }
        }.listStyle(.inset)
    }

    private func beginImport(replacing: IdentityVaultDocument? = nil) {
        let generation = vault.lifecycleGeneration
        let panel = NSOpenPanel()
        panel.title = "Import into Identity Vault"
        panel.message = "Locus stores an encrypted copy locally. This does not share the document with AI."
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["pdf", "docx", "txt", "png", "jpg", "jpeg"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url,
              vault.lifecycleGeneration == generation, store.isReady else { return }
        vault.isWorking = true
        vault.localWork = Task {
            defer { if vault.lifecycleGeneration == generation { vault.isWorking = false } }
            do {
                let imported = try await IdentityVaultDocuments.importDocument(url: url, runtimeRoot: model.settings.backendRoot)
                guard !Task.isCancelled, vault.lifecycleGeneration == generation, store.isReady else { return }
                importReview = .init(document: imported, kind: replacing?.kind ?? (vault.tab == .signatures ? .signature : .resume),
                                     profileID: replacing?.profileID, replacingID: replacing?.id)
            } catch {
                if !Task.isCancelled, vault.lifecycleGeneration == generation { vault.notice = error.localizedDescription }
            }
        }
    }

    private func exportDocument(_ document: IdentityVaultDocument) {
        let generation = vault.lifecycleGeneration
        let panel = NSSavePanel()
        panel.title = "Export a decrypted copy"
        panel.message = "The exported file is an ordinary, unencrypted document outside Identity Vault."
        panel.nameFieldStringValue = document.name
        guard panel.runModal() == .OK, let url = panel.url,
              vault.lifecycleGeneration == generation, store.isReady else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try store.documentData(id: document.id).write(to: url, options: .atomic)
            try store.recordDisclosure(.init(taskID: "native-export", recipientID: url.path, recipientLabel: url.lastPathComponent,
                kind: .export, summary: "Exported one document version", documentIDs: [document.id]))
            vault.notice = "Exported \(document.name)."
        } catch { vault.notice = error.localizedDescription }
    }

    private func profileFromDocument(_ document: IdentityVaultDocument) {
        var profile = IdentityVaultProfile(name: "Career profile", kind: .career)
        for suggestion in IdentityVaultDocuments.suggestedFields(from: document.extractedText) {
            if let index = profile.fields.firstIndex(where: { $0.key == suggestion.key }) { profile.fields[index].value = suggestion.value }
            else { profile.fields.append(suggestion) }
        }
        vault.notice = "Review the proposed fields before saving. The original document and its full text remain in the vault."
        vault.profileEditor = profile
    }

    private func startWriting(_ profile: IdentityVaultProfile, coverLetter: Bool) {
        let type = coverLetter ? "cover letter" : "resume"
        model.startIdentityTask(profileID: profile.id,
            prompt: "Help me write a \(type) using my selected career profile. Describe the profile, then request_context for relevant career fields. Keep contact details private; they will be inserted locally. Ask for any missing job details. Do not invent qualifications or experience. Propose the writing with save_draft when ready for my review.", sendImmediately: true)
    }

    private func saveDraft(_ draft: IdentityVaultDraft, createFiles: Bool, includeContact: Bool) async {
        let generation = vault.lifecycleGeneration
        guard !Task.isCancelled, store.isReady else { return }
        vault.isWorking = true
        defer { if vault.lifecycleGeneration == generation { vault.isWorking = false } }
        do {
            let saved = try store.saveDraft(draft)
            if createFiles {
                var sections = saved.sections
                var title = saved.title
                if includeContact, let profile = store.profiles.first(where: { $0.id == saved.profileID }) {
                    let keys: Set<String> = ["full_name", "email", "phone", "street_address", "city", "region", "postal_code", "country", "portfolio", "linkedin"]
                    let contact = profile.fields.filter { keys.contains($0.key) && !$0.value.isEmpty }
                    if let name = contact.first(where: { $0.key == "full_name" }) { title = name.value }
                    let details = contact.filter { $0.key != "full_name" }.map(\.value).joined(separator: " · ")
                    if !details.isEmpty { sections.insert(.init(heading: "", text: details), at: 0) }
                }
                let pdf = try IdentityVaultDocuments.generatePDF(title: title, sections: sections)
                let word = try await IdentityVaultDocuments.generateDOCX(title: title, sections: sections, runtimeRoot: model.settings.backendRoot)
                guard !Task.isCancelled, vault.lifecycleGeneration == generation, store.isReady else { return }
                for (extensionName, mimeType, data) in [
                    ("pdf", "application/pdf", pdf),
                    ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", word),
                ] {
                    let name = String(saved.title.prefix(180)).replacingOccurrences(of: "/", with: "-") + "." + extensionName
                    let previous = store.documents.filter { $0.name == name && $0.profileID == saved.profileID && $0.kind == saved.kind }.max { $0.version < $1.version }
                    let document = try store.addDocument(name: name, kind: saved.kind, mimeType: mimeType, data: data,
                        extractedText: ([title] + sections.map { $0.heading + "\n" + $0.text }).joined(separator: "\n\n"),
                        profileID: saved.profileID, replacingDocumentID: previous?.id)
                    if extensionName == "pdf" { vault.previewDocument = document }
                }
                vault.notice = "Created PDF and editable Word versions in the vault. Contact details were inserted locally."
            } else { vault.notice = "Draft saved privately." }
            vault.draftEditor = nil
        } catch {
            if !Task.isCancelled, vault.lifecycleGeneration == generation {
                vault.notice = error.localizedDescription
                vault.draftEditor = nil
            }
        }
    }
}

private struct IdentityProfileEditor: View {
    @State var profile: IdentityVaultProfile
    let save: (IdentityVaultProfile) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(profile.kind.title) profile").font(.title2.bold())
            Text("Fields stay private. You review exactly what is sent to a website or AI provider.").foregroundStyle(LocusTheme.textTertiary)
            TextField("Profile name", text: $profile.name).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach($profile.fields) { $field in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                if field.key.hasPrefix("custom_") { TextField("Field label", text: $field.label) }
                                else { Text(field.label).font(.headline) }
                                Spacer()
                                if field.key.hasPrefix("custom_") {
                                    Button { profile.fields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }
                                }
                            }
                            if field.kind == .multiline {
                                TextEditor(text: $field.value)
                                    .foregroundStyle(LocusTheme.inkSoft)
                                    .tint(LocusTheme.accentAction)
                                    .scrollContentBackground(.hidden)
                                    .background(LocusTheme.surfaceCard)
                                    .frame(minHeight: 70).border(LocusTheme.separator)
                            } else { TextField(field.label, text: $field.value).textFieldStyle(.roundedBorder) }
                        }
                    }
                    HStack {
                        Button("Add Custom Field") { profile.fields.append(.init(key: "custom_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), label: "Custom field", kind: .multiline)) }
                        if profile.kind == .career {
                            Button("Add Employment") { profile.appendCareerEntry(education: false) }
                            Button("Add Education") { profile.appendCareerEntry(education: true) }
                        }
                    }
                }.padding(2)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete Profile", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("Save Profile") { save(profile) }.buttonStyle(.borderedProminent).tint(LocusTheme.ink).disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("identity.profile.save")
            }
        }.padding(22).frame(width: 670, height: 650).modifier(IdentityPrivateSurface())
            .alert("Delete this profile?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { onDelete() }
            } message: { Text("Document versions remain in the vault.") }
    }
}

private struct IdentityImportRequest: Identifiable {
    let id = UUID()
    let document: IdentityVaultImportedDocument
    var kind: IdentityVaultDocumentKind
    var profileID: UUID?
    var replacingID: UUID?
}

private struct IdentityDocumentImportView: View {
    let request: IdentityImportRequest
    let profiles: [IdentityVaultProfile]
    let save: (IdentityVaultDocumentKind, UUID?) -> Void
    @State private var kind: IdentityVaultDocumentKind
    @State private var profileID: UUID?
    @Environment(\.dismiss) private var dismiss
    init(request: IdentityImportRequest, profiles: [IdentityVaultProfile], save: @escaping (IdentityVaultDocumentKind, UUID?) -> Void) {
        self.request = request; self.profiles = profiles; self.save = save
        _kind = State(initialValue: request.kind); _profileID = State(initialValue: request.profileID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import privately").font(.title2.bold())
            Text(request.document.name).font(.headline)
            Picker("Document type", selection: $kind) { ForEach(IdentityVaultDocumentKind.allCases) { Text($0.title).tag($0) } }
            Picker("Link to profile", selection: $profileID) {
                Text("No linked profile").tag(Optional<UUID>.none)
                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            Text("Locally extracted text · review for OCR mistakes").font(.headline)
            ScrollView { Text(request.document.extractedText.isEmpty ? "No text was detected. The original file will still be saved." : String(request.document.extractedText.prefix(60_000)))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(minHeight: 180, maxHeight: 320)
            Text("Nothing here is sent to AI. You can create a profile from this text after import and review every proposed field.").foregroundStyle(LocusTheme.textTertiary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save in Vault") { save(kind, profileID) }.buttonStyle(.borderedProminent).tint(LocusTheme.ink)
            }
        }.padding(22).frame(width: 660).modifier(IdentityPrivateSurface())
    }
}

private struct IdentityDocumentPreview: View {
    let document: IdentityVaultDocument
    let data: Data
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(document.name, systemImage: "lock.doc").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if document.mimeType == "application/pdf" {
                IdentityPDFPreview(data: data)
            } else if document.mimeType.hasPrefix("image/"), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ScrollView { Text(document.extractedText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Text("Private preview · Version \(document.version)").font(.caption).foregroundStyle(LocusTheme.textTertiary)
        }.padding(20).frame(width: 760, height: 700).modifier(IdentityPrivateSurface())
    }
}

private struct IdentityPDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}

private struct IdentityDraftEditor: View {
    @State var draft: IdentityVaultDraft
    let profiles: [IdentityVaultProfile]
    @ObservedObject var vault: IdentityVaultModel
    let save: (IdentityVaultDraft, Bool, Bool) -> Void
    @State private var includeContact = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review and edit your draft").font(.title2.bold())
            TextField("Document title", text: $draft.title).textFieldStyle(.roundedBorder)
            Picker("Profile", selection: $draft.profileID) {
                Text("No profile").tag(Optional<UUID>.none)
                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            Toggle("Insert this profile's contact details locally", isOn: $includeContact).disabled(draft.profileID == nil)
            Text("Check every qualification and date. Editing this draft does not change your saved profile.").font(.callout).foregroundStyle(LocusTheme.textTertiary)
            if vault.isWorking { ProgressView("Creating documents locally…") }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($draft.sections) { $section in
                        VStack(alignment: .leading) {
                            HStack {
                                TextField("Section heading", text: $section.heading).textFieldStyle(.roundedBorder)
                                Button { draft.sections.removeAll { $0.id == section.id } } label: { Image(systemName: "minus.circle") }
                            }
                            TextEditor(text: $section.text)
                                .foregroundStyle(LocusTheme.inkSoft)
                                .tint(LocusTheme.accentAction)
                                .scrollContentBackground(.hidden)
                                .background(LocusTheme.surfaceCard)
                                .frame(minHeight: 110).border(LocusTheme.separator)
                        }
                    }
                    Button("Add Section") { draft.sections.append(.init(heading: "", text: "")) }
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Draft") { save(draft, false, includeContact) }.disabled(vault.isWorking)
                Button("Create PDF & Word") { save(draft, true, includeContact) }.buttonStyle(.borderedProminent).tint(LocusTheme.ink)
                    .disabled(vault.isWorking || draft.sections.isEmpty || draft.title.isEmpty)
            }
        }.padding(22).frame(width: 700, height: 650).modifier(IdentityPrivateSurface())
    }
}
