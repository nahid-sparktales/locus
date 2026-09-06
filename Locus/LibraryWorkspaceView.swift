import SwiftUI

struct LibraryWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: WorkspaceLibraryModel
    @EnvironmentObject private var outputs: OutputsLibraryModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Library").font(.title2.weight(.semibold))
                    Text(URL(fileURLWithPath: library.workspace).lastPathComponent).foregroundStyle(LocusTheme.textSecondary)
                }
                Spacer()
                Picker("Library", selection: $library.tab) {
                    ForEach(WorkspaceLibraryTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            switch library.tab {
            case .documents: documents
            case .outputs: OutputsLibraryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 700, idealWidth: 1000, minHeight: 520, idealHeight: 700, alignment: .top)
        .background(LocusTheme.paper)
        .foregroundStyle(LocusTheme.ink)
        .sheet(item: $library.previewRequest) { DocumentPreviewSheet(request: $0) }
        .onChange(of: library.query) { _, _ in library.search() }
    }
    private var documents: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                TextField("Search document names and content", text: $library.query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("library.documentSearch")
                    .accessibilityLabel("Search document names and content")
                Button { library.importDocuments() } label: { Label("Import", systemImage: "plus") }
                    .disabled(library.pending.contains("import") || !library.documentsEnabled)
                Button { Task { await library.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh documents").accessibilityLabel("Refresh documents")
            }.padding()
            HStack(alignment: .top, spacing: 12) {
                Toggle("Document knowledge", isOn: Binding(get: { library.documentsEnabled }, set: { library.setEnabled($0) }))
                    .disabled(library.pending.contains("settings"))
                Text("Search PDF, Word, and spreadsheet content across this workspace's chats. Imported files are copied into Locus Documents.")
                    .font(.subheadline).foregroundStyle(LocusTheme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal).padding(.bottom)
            if let error = library.error { libraryError(error) }
            Divider()
            if library.documents.isEmpty && library.searchResults.isEmpty && !library.isLoading {
                if !library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("No matching documents", systemImage: "magnifyingglass",
                        description: Text("Try another filename or phrase from a document."))
                } else {
                    ContentUnavailableView(library.documentsEnabled ? "Build your document library" : "Enable document knowledge",
                        systemImage: "books.vertical", description: Text(library.documentsEnabled
                            ? "Import documents or add supported files to your workspace. Their content will be available in your chats."
                            : "Turn on document knowledge to index documents locally. Existing text and code knowledge keeps its current settings."))
                }
            } else {
                List {
                    if !library.query.isEmpty && !library.searchResults.isEmpty {
                        Section("Content matches") {
                            ForEach(library.searchResults) { hit in
                                Button { library.openSearchHit(hit) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text((hit.path as NSString).lastPathComponent).font(.headline)
                                        Text(hit.locator?.label ?? "Line \(hit.lineStart ?? 1)").font(.subheadline).foregroundStyle(LocusTheme.textSecondary)
                                        Text(hit.snippet ?? hit.text ?? "").lineLimit(3).foregroundStyle(LocusTheme.textSecondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }.buttonStyle(.locus())
                            }
                        }
                    }
                    Section("Documents · \(library.total)") {
                        ForEach(library.documents) { document in
                            documentRow(document)
                        }
                        if library.documents.count < library.total {
                            Button("Load more documents") { Task { await library.refresh(loadMore: true) } }
                        }
                    }
                }.listStyle(.inset)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func documentRow(_ document: LibraryDocument) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: document.format == "pdf" ? "doc.richtext" : "doc.text").font(.title2).foregroundStyle(LocusTheme.textSecondary).frame(width: 30)
            Button { library.open(document) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.title).font(.headline)
                    Text(document.path).font(.subheadline).foregroundStyle(LocusTheme.textSecondary).lineLimit(1)
                    HStack {
                        Text(document.excluded ? "Excluded" : document.stateLabel)
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file))
                        if document.status == "running" || document.status == "queued" { ProgressView().controlSize(.small) }
                    }.font(.subheadline).foregroundStyle(LocusTheme.textSecondary)
                    if let jobID = document.jobID, let job = library.jobs[jobID], job.isActive, job.total > 0 {
                        ProgressView(value: Double(job.progress), total: Double(job.total)) {
                            Text("\(job.progress) of \(job.total) processed").font(.subheadline)
                        }.accessibilityLabel("\(document.title), \(job.progress) of \(job.total) processed")
                    }
                    if let reason = document.error { Text(reason).font(.subheadline).foregroundStyle(LocusTheme.dangerForeground) }
                    if !document.warnings.isEmpty { Text(document.warnings.joined(separator: " · ")).font(.subheadline).foregroundStyle(LocusTheme.textSecondary).lineLimit(3) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.locus())
                .accessibilityIdentifier("library.document.\(document.id)")
            Menu {
                Button("Open") { library.open(document) }
                if document.status == "running" || document.status == "queued" {
                    Button("Cancel processing") { library.cancel(document) }
                } else {
                    Button("Reindex") { library.retry(document) }
                    if document.format == "pdf" { Button("Recognize all pages") { library.retry(document, recognizeAllPages: true) } }
                }
                Button(document.excluded ? "Include in knowledge" : "Exclude from knowledge") { library.exclude(document, excluded: !document.excluded) }
                Button("Remove from index", role: .destructive) { library.remove(document) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                .disabled(library.pending.contains(document.id)).help("Document actions")
                .accessibilityLabel("Actions for \(document.title)")
        }.padding(.vertical, 7)
    }
    private func libraryError(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle").font(.subheadline)
            Spacer()
            Button("Retry") { Task { await library.refresh() } }
        }.padding().background(.yellow.opacity(0.10))
    }
}

struct OutputsLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: WorkspaceLibraryModel
    @EnvironmentObject private var outputs: OutputsLibraryModel
    @State private var selectedURL: URL?
    @State private var comparison: OutputComparisonRequest?
    @State private var removeItem: LibraryOutput?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search outputs", text: $outputs.query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search outputs")
                Picker("Type", selection: $outputs.typeFilter) {
                    Text("All types").tag("all")
                    Text("Documents").tag("document")
                    Text("Spreadsheets").tag("spreadsheet")
                    Text("Images").tag("image")
                    Text("Text and code").tag("text")
                    Text("Media").tag("media")
                    Text("Websites").tag("website")
                }.frame(width: 180)
                Menu {
                    ForEach([1, 2, 5, 10, 20], id: \.self) { limit in
                        Button("\(limit) GB per workspace") { outputs.setStorageLimit(gigabytes: limit) }
                    }
                } label: { Label("Storage", systemImage: "externaldrive") }
            }.padding()
            if outputs.sourceSessionID != nil || outputs.sourceRunID != nil {
                HStack {
                    Text(outputs.sourceRunID == nil ? "Outputs from the selected chat" : "Outputs from the selected task").font(.subheadline)
                    Spacer()
                    Button("Show all outputs") { outputs.clearOriginFilter() }
                }.padding(.horizontal).padding(.bottom)
            }
            if let error = outputs.error { Label(error, systemImage: "exclamationmark.triangle").padding().frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            if outputs.visibleItems.isEmpty {
                ContentUnavailableView("Your finished work lives here", systemImage: "tray.full",
                    description: Text("Files and websites created in this workspace appear automatically. Saved versions stay available when the originals change."))
            } else {
                HSplitView {
                    List(selection: $outputs.selectedItemID) {
                        ForEach(outputs.visibleItems) { output in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(output.title).font(.headline).lineLimit(1)
                                Text(output.target).font(.subheadline).foregroundStyle(LocusTheme.textSecondary).lineLimit(1)
                                Text(output.isWebsite ? "Live website" : "\(output.versions.filter { $0.hash != nil }.count) saved versions")
                                    .font(.subheadline).foregroundStyle(LocusTheme.textSecondary)
                                if let reason = output.latest?.unavailableReason { Text(reason).font(.subheadline).foregroundStyle(.orange).lineLimit(2) }
                            }.padding(.vertical, 6).tag(output.id)
                                .accessibilityIdentifier("library.output.item.\(output.target)")
                        }
                    }.frame(minWidth: 235, idealWidth: 300, maxWidth: 370)
                    if let item = outputs.selectedItem, let version = outputs.selectedVersion { detail(item, version: version) }
                    else { ContentUnavailableView("Select an output", systemImage: "doc.viewfinder") }
                }
            }
            Divider()
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: outputs.storageUsed, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: outputs.storageLimit, countStyle: .file)) used")
                    .font(.subheadline).foregroundStyle(LocusTheme.textSecondary)
                Spacer()
                if outputs.isRefreshing { ProgressView().controlSize(.small) }
            }.padding(12)
        }
        .task(id: outputs.selectedVersion?.id) {
            selectedURL = nil
            if let item = outputs.selectedItem, let version = outputs.selectedVersion {
                let url = await outputs.store.versionURL(item, version: version)
                guard !Task.isCancelled, outputs.selectedItem?.id == item.id,
                      outputs.selectedVersion?.id == version.id else { return }
                selectedURL = url
            }
        }
        .sheet(item: $comparison) { OutputComparisonView(request: $0) }
        .alert("Remove saved history?", isPresented: Binding(get: { removeItem != nil }, set: { if !$0 { removeItem = nil } })) {
            Button("Cancel", role: .cancel) { removeItem = nil }
            Button("Remove history", role: .destructive) { if let item = removeItem { outputs.remove(item) }; removeItem = nil }
        } message: { Text("Saved versions will be removed from the library. The original workspace file will remain.") }
    }
    private func detail(_ item: LibraryOutput, version: OutputVersion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            if !item.isWebsite {
                Picker("Version", selection: Binding(get: { version.id }, set: { outputs.selectedVersionID = $0 })) {
                    ForEach(item.versions.reversed()) { version in
                        Text("\(version.label) · \(version.capturedAt.formatted(date: .abbreviated, time: .shortened))").tag(version.id)
                    }
                }.accessibilityIdentifier("library.output.versions")
            }
            HStack {
                Button("Source chat") { model.openOutputSourceChat(outputs.sourceSession(for: version)) }
                    .disabled(outputs.sourceSession(for: version).isEmpty)
                if item.isWebsite, let url = URL(string: item.target) {
                    Link("Open website", destination: url)
                    Button("Remove link", role: .destructive) { removeItem = item }
                }
                else {
                    Button("Revise") { model.reviseLibraryOutput(item, version: version) }.disabled(selectedURL == nil)
                    Menu("More") {
                        Button("Export this version") { outputs.export(item, version: version) }.disabled(selectedURL == nil)
                        if item.versions.filter({ $0.hash != nil }).count > 1 {
                            Button("Compare with previous version") { compare(item, version: version) }
                        }
                        Button("Remove saved history", role: .destructive) { removeItem = item }
                    }.accessibilityIdentifier("library.output.more")
                }
            }
            if outputs.sourceSession(for: version).isEmpty {
                Text("Created in this workspace. Its source task could not be confirmed.")
                    .font(.subheadline).foregroundStyle(LocusTheme.textSecondary)
            }
            if let reason = version.unavailableReason { Label(reason, systemImage: "exclamationmark.triangle").font(.body) }
            if let selectedURL {
                DocumentPreviewView(request: DocumentPreviewRequest(url: selectedURL, title: item.title))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if item.isWebsite {
                ContentUnavailableView("Live website", systemImage: "globe", description: Text("This link opens the current website. Deployment history is not stored in the library."))
            } else {
                ContentUnavailableView("No saved preview", systemImage: "doc.badge.ellipsis", description: Text("Earlier saved versions remain available in the version menu."))
            }
        }.padding().frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func compare(_ item: LibraryOutput, version: OutputVersion) {
        guard let index = item.versions.firstIndex(where: { $0.id == version.id }),
              let previous = item.versions.prefix(index).last(where: { $0.hash != nil }) else { return }
        Task {
            guard let left = await outputs.store.versionURL(item, version: previous),
                  let right = await outputs.store.versionURL(item, version: version) else { return }
            comparison = OutputComparisonRequest(title: item.title, left: left, right: right, leftLabel: previous.label, rightLabel: version.label)
        }
    }
}

struct OutputComparisonRequest: Identifiable {
    let id = UUID()
    let title: String
    let left: URL
    let right: URL
    let leftLabel: String
    let rightLabel: String
}
struct OutputComparisonView: View {
    let request: OutputComparisonRequest
    @Environment(\.dismiss) private var dismiss
    @State private var differences: [String]?
    var body: some View {
        VStack {
            HStack { Text("Compare · \(request.title)").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
            if let differences {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(differences.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .foregroundStyle(line.hasPrefix("+ ") ? LocusTheme.success : line.hasPrefix("− ") ? LocusTheme.dangerForeground : LocusTheme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                }
            } else {
                HSplitView {
                    VStack { Text(request.leftLabel).font(.headline); DocumentPreviewView(request: DocumentPreviewRequest(url: request.left, title: request.title)) }
                    VStack { Text(request.rightLabel).font(.headline); DocumentPreviewView(request: DocumentPreviewRequest(url: request.right, title: request.title)) }
                }
            }
        }.frame(minWidth: 800, idealWidth: 1100, minHeight: 550, idealHeight: 720)
        .task {
            differences = await Task.detached(priority: .userInitiated) {
                guard OutputsLibraryStore.kind(request.left.path) == "text",
                      let left = try? String(contentsOf: request.left, encoding: .utf8),
                      let right = try? String(contentsOf: request.right, encoding: .utf8),
                      left.utf8.count + right.utf8.count <= 2_000_000 else { return nil as [String]? }
                return OutputTextComparison.lines(before: left, after: right)
            }.value
        }
    }
}
enum OutputTextComparison {
    static func lines(before: String, after: String) -> [String] {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        let diff = new.difference(from: old)
        var removed: [Int: String] = [:], added: [Int: String] = [:]
        for change in diff {
            switch change { case .remove(let offset, let value, _): removed[offset] = value
            case .insert(let offset, let value, _): added[offset] = value }
        }
        var result: [String] = [], oldIndex = 0, newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if let value = removed[oldIndex] { result.append("− " + value); oldIndex += 1 }
            else if let value = added[newIndex] { result.append("+ " + value); newIndex += 1 }
            else if newIndex < new.count { result.append("  " + new[newIndex]); newIndex += 1; oldIndex += 1 }
            else { break }
        }
        return result
    }
}
