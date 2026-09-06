import AppKit
import PDFKit
import Quartz
import SwiftUI

struct DocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: DocumentPreviewRequest
    @State private var page = 1
    @State private var pageCount = 0
    private var displayedRequest: DocumentPreviewRequest {
        guard pageCount > 0 else { return request }
        var copy = request
        var reference = request.reference ?? DocumentReference(workspace: "", path: request.url.path)
        if reference.location?.page != page { reference.location = DocumentLocation(kind: "pdf", page: page) }
        copy.reference = reference
        return copy
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(request.title).font(.headline).lineLimit(1)
                    if pageCount == 0, let location = request.reference?.location { Text(location.label).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Open in App") { NSWorkspace.shared.open(request.url) }
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([request.url]) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
            if pageCount > 0 {
                HStack {
                    Button { page = max(page - 1, 1) } label: { Label("Previous page", systemImage: "chevron.left") }
                        .disabled(page <= 1).accessibilityIdentifier("library.pdf.previous")
                    Text("Page \(page) of \(pageCount)").monospacedDigit().accessibilityIdentifier("library.pdf.page")
                    Button { page = min(page + 1, pageCount) } label: { Label("Next page", systemImage: "chevron.right") }
                        .disabled(page >= pageCount).accessibilityIdentifier("library.pdf.next")
                }.padding(.horizontal).padding(.bottom, 12)
            }
            if let warning = request.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading).padding().background(.yellow.opacity(0.12))
            }
            Divider()
            DocumentPreviewView(request: displayedRequest)
        }
        .frame(minWidth: 620, idealWidth: 860, minHeight: 500, idealHeight: 680)
        .onAppear {
            if request.url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: request.url) {
                pageCount = document.pageCount
                page = min(max(request.reference?.location?.page ?? ((request.reference?.location?.pageIndex ?? 0) + 1), 1), max(pageCount, 1))
            }
        }
    }
}

struct DocumentPreviewView: View {
    @EnvironmentObject private var library: WorkspaceLibraryModel
    let request: DocumentPreviewRequest
    @State private var text: String?
    @State private var textLoadedURL: URL?
    @State private var temporaryResult: DocumentExtractionResult?
    @State private var extractionError: String?
    @State private var extracting = false
    var body: some View {
        Group {
            if request.url.pathExtension.lowercased() == "pdf" {
                LibraryPDFPreview(url: request.url, location: request.reference?.location)
            } else if let result = request.result ?? temporaryResult, !result.segments.isEmpty {
                extracted(result)
            } else if let text, textLoadedURL == request.url {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                                    Text(line.isEmpty ? " " : line).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .padding(.horizontal).id(index + 1)
                                .background(index + 1 == request.reference?.location?.lineStart ? Color.accentColor.opacity(0.12) : .clear)
                            }
                        }.padding(.vertical)
                    }.onAppear { if let line = request.reference?.location?.lineStart { proxy.scrollTo(line, anchor: .center) } }
                }
            } else if OutputsLibraryStore.kind(request.url.path) == "text", textLoadedURL != request.url {
                ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if extracting { HStack { ProgressView().controlSize(.small); Text("Preparing searchable text…") }.padding() }
                    if let extractionError { Text(extractionError).font(.subheadline).foregroundStyle(.secondary).padding() }
                    LibraryQuickLookPreview(url: request.url)
                }
            }
        }.task(id: request.url) {
            let url = request.url
            text = nil
            textLoadedURL = nil
            temporaryResult = nil
            extractionError = nil
            extracting = false
            let loaded = await Task.detached(priority: .userInitiated) {
                guard OutputsLibraryStore.kind(url.path) == "text",
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000 else { return nil as String? }
                return try? String(contentsOf: url, encoding: .utf8)
            }.value
            guard !Task.isCancelled else { return }
            text = loaded
            textLoadedURL = url
            if request.result == nil, ["docx", "xlsx", "csv", "tsv"].contains(url.pathExtension.lowercased()) {
                extracting = true
                do {
                    let extracted = try await library.extractTemporary(url, workspace: request.reference?.workspace)
                    guard !Task.isCancelled else { return }
                    temporaryResult = extracted
                }
                catch { if !Task.isCancelled { extractionError = "Text preview unavailable: \(error.localizedDescription)" } }
                extracting = false
            }
        }
    }

    private func extracted(_ result: DocumentExtractionResult) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if result.truncated { Label("Partial extraction — some content could not be included", systemImage: "exclamationmark.triangle") }
                    ForEach(Array(result.segments.enumerated()), id: \.offset) { index, segment in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(segment.locator.label).font(.headline).foregroundStyle(.secondary)
                            Text(segment.text).font(segment.locator.kind == "sheet" ? .system(.body, design: .monospaced) : .body).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(matches(segment.locator) ? Color.accentColor.opacity(0.10) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8)).id(index)
                    }
                }.padding(20)
            }.onAppear {
                if let index = result.segments.firstIndex(where: { matches($0.locator) }) { proxy.scrollTo(index, anchor: .top) }
            }
        }
    }
    private func matches(_ location: DocumentLocation) -> Bool {
        guard let selected = request.reference?.location else { return false }
        return location == selected || (location.kind == selected.kind && location.label == selected.label)
    }
}

struct LibraryQuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        // SwiftUI owns this embedded view, including when it is replaced
        // without closing the containing window.
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem?.previewItemURL ?? nil) != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct LibraryPDFPreview: NSViewRepresentable {
    let url: URL
    let location: DocumentLocation?
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
        guard let location, location.kind == "pdf", let document = view.document else { return }
        let index = max((location.page ?? ((location.pageIndex ?? 0) + 1)) - 1, 0)
        guard index < document.pageCount, let page = document.page(at: index) else { return }
        view.go(to: page)
        if let bounds = location.bounds {
            let pageBounds = page.bounds(for: .mediaBox)
            let rectangle = CGRect(x: bounds.x * pageBounds.width, y: bounds.y * pageBounds.height,
                                   width: bounds.width * pageBounds.width, height: bounds.height * pageBounds.height)
            if let selection = page.selection(for: rectangle) { view.setCurrentSelection(selection, animate: false) }
        }
    }
}
