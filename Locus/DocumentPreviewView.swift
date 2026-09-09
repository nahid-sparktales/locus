import AppKit
import PDFKit
import Quartz
import SwiftUI

struct DocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: DocumentPreviewRequest
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(request.title).font(.headline).foregroundStyle(LocusTheme.ink).lineLimit(1)
                    if let location = request.reference?.location, location.kind != "pdf" { Text(location.label).font(.subheadline).foregroundStyle(LocusTheme.muted) }
                }
                Spacer()
                Button("Open in Default App") { NSWorkspace.shared.open(request.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([request.url]) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            if let warning = request.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.body)
                    .foregroundStyle(LocusTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding().background(LocusTheme.warning.opacity(0.12))
            }
            Divider()
            DocumentPreviewView(request: request)
        }
        .frame(minWidth: 620, idealWidth: 860, minHeight: 500, idealHeight: 680)
        .foregroundStyle(LocusTheme.inkSoft)
        .background(LocusTheme.panel)

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
    @State private var showSource = false
    @State private var showOriginal = true
    private var isMarkdown: Bool { ["md", "markdown"].contains(request.url.pathExtension.lowercased()) }
    private var isOfficeDocument: Bool { ["docx", "xlsx", "csv", "tsv"].contains(request.url.pathExtension.lowercased()) }
    var body: some View {
        VStack(spacing: 0) {
            if isMarkdown || isOfficeDocument {
                HStack {
                    if isMarkdown {
                        Picker("View", selection: $showSource) {
                            Text("Read").tag(false)
                            Text("Source").tag(true)
                        }.pickerStyle(.segmented).frame(width: 160)
                            .accessibilityIdentifier("preview.text.mode")
                    } else {
                        Picker("View", selection: $showOriginal) {
                            Text("Original").tag(true)
                            Text("Text").tag(false)
                        }.pickerStyle(.segmented).frame(width: 160)
                    }
                    Spacer()
                }.padding(10).background(LocusTheme.panel)
                Divider()
            }
        Group {
            if request.url.pathExtension.lowercased() == "pdf" {
                DocumentPDFReader(url: request.url, location: request.reference?.location)
                    .id(request.url)
            } else if request.url.pathExtension.lowercased() == "gif" {
                LibraryQuickLookPreview(url: request.url)
            } else if OutputsLibraryStore.kind(request.url.path) == "image" {
                DocumentImagePreview(url: request.url).id(request.url)
            } else if isOfficeDocument && showOriginal {
                LibraryQuickLookPreview(url: request.url)
            } else if let result = request.result ?? temporaryResult, !result.segments.isEmpty {
                extracted(result)
            } else if let text, textLoadedURL == request.url {
                if isMarkdown && !showSource {
                    ScrollView {
                        MarkdownBodyView(text: text, workspacePath: request.reference?.workspace)
                            .textSelection(.enabled).frame(maxWidth: 760, alignment: .leading)
                            .padding(24).frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(index + 1)").foregroundStyle(LocusTheme.muted).frame(width: 46, alignment: .trailing)
                                    Text(line.isEmpty ? " " : line).foregroundStyle(LocusTheme.inkSoft).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .padding(.horizontal).id(index + 1)
                                .background(index + 1 == request.reference?.location?.lineStart ? LocusTheme.contentLink.opacity(0.12) : .clear)
                            }
                        }.padding(.vertical)
                    }.onAppear { if let line = request.reference?.location?.lineStart { proxy.scrollTo(line, anchor: .center) } }
                }
                }
            } else if OutputsLibraryStore.kind(request.url.path) == "text", textLoadedURL != request.url {
                ProgressView("Loading preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if extracting { HStack { ProgressView().controlSize(.small); Text("Preparing searchable text…") }.padding() }
                    if let extractionError { Text(extractionError).font(.subheadline).foregroundStyle(LocusTheme.muted).padding() }
                    LibraryQuickLookPreview(url: request.url)
                }
            }
        }
        }.task(id: request.url) {
            let url = request.url
            showSource = request.reference?.location?.lineStart != nil
            showOriginal = request.reference?.location == nil
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
                    if result.truncated { Label("Partial extraction — some content could not be included", systemImage: "exclamationmark.triangle").foregroundStyle(LocusTheme.warning) }
                    ForEach(Array(result.segments.enumerated()), id: \.offset) { index, segment in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(segment.locator.label).font(.headline).foregroundStyle(LocusTheme.muted)
                            Text(segment.text).font(segment.locator.kind == "sheet" ? .system(.body, design: .monospaced) : .body).foregroundStyle(LocusTheme.inkSoft).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(matches(segment.locator) ? LocusTheme.contentLink.opacity(0.10) : .clear)
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

/// Private vault previews pass bytes directly; no decrypted file or thumbnail
/// is written to disk. The same controls are used by saved outputs.
struct DocumentImagePreview: View {
    var url: URL? = nil
    var data: Data? = nil
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image { ImageReader(image: image) }
            else if loaded {
                ContentUnavailableView("Image preview unavailable", systemImage: "photo",
                    description: Text("The image could not be read. Try opening it in its original app."))
            } else { ProgressView("Loading image…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: url) {
            loaded = false
            image = nil
            let bytes = data
            let source = url
            let result = await Task.detached(priority: .userInitiated) {
                bytes ?? source.flatMap { try? Data(contentsOf: $0) }
            }.value
            guard !Task.isCancelled else { return }
            image = result.flatMap(NSImage.init(data:))
            loaded = true
        }
    }
}

private enum ImageCanvasBackground: String, CaseIterable, Identifiable {
    case checkerboard = "Transparency", light = "Light", dark = "Dark"
    var id: String { rawValue }
}

private struct ImageReader: View {
    let image: NSImage
    @State private var zoom: CGFloat = 1
    @State private var fits = true
    @State private var background: ImageCanvasBackground = .checkerboard

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { zoomControls; Spacer(minLength: 8); backgroundControl }
                VStack(spacing: 8) { HStack { zoomControls; Spacer(minLength: 0) }; backgroundControl }
            }.padding(10).background(LocusTheme.panel)
            Divider()
            ImageScrollCanvas(image: image, zoom: $zoom, fits: $fits, canvasBackground: background)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Image preview. Pinch to zoom or drag to pan.")
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack { dimensions; Spacer(); Text("Pinch to zoom · Drag to pan") }
                dimensions
            }
            .font(.caption).foregroundStyle(LocusTheme.textSecondary).padding(10)
        }
    }

    private var dimensions: some View {
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        return Text("\(rep?.pixelsWide ?? Int(image.size.width)) × \(rep?.pixelsHigh ?? Int(image.size.height)) pixels")
            .monospacedDigit().accessibilityIdentifier("preview.image.dimensions")
    }

    private var backgroundControl: some View {
        Menu {
            Picker("Background", selection: $background) {
                ForEach(ImageCanvasBackground.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: { Label("Background", systemImage: "circle.lefthalf.filled") }
        .fixedSize().help("Choose a background for transparent images")
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { fits = false; zoom = max(zoom / 1.25, 0.01) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom <= 0.01).help("Zoom out").accessibilityLabel("Zoom out")
                .accessibilityIdentifier("preview.image.zoomOut")
            Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 42)
                .accessibilityIdentifier("preview.image.zoom")
            Button { fits = false; zoom = min(zoom * 1.25, 8) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(zoom >= 8).help("Zoom in").accessibilityLabel("Zoom in")
                .accessibilityIdentifier("preview.image.zoomIn")
            Button("Fit") { fits = true }.help("Fit image to the available space")
                .accessibilityIdentifier("preview.image.fit")
            Button("100%") { fits = false; zoom = 1 }.help("View at actual size")
                .accessibilityIdentifier("preview.image.actualSize")
        }.controlSize(.small).fixedSize()
    }
}

private struct ImageScrollCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var zoom: CGFloat
    @Binding var fits: Bool
    let canvasBackground: ImageCanvasBackground

    func makeNSView(context: Context) -> ImageReaderScrollView {
        let view = ImageReaderScrollView()
        view.hasHorizontalScroller = true
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.drawsBackground = false
        view.documentView = view.canvas
        return view
    }

    func updateNSView(_ view: ImageReaderScrollView, context: Context) {
        view.changedZoom = { [weak view] value, isFit in
            DispatchQueue.main.async {
                guard let view, view.fitImage == isFit, abs(view.imageZoom - value) < 0.0001 else { return }
                if abs(zoom - value) > 0.0001 { zoom = value }
                if fits != isFit { fits = isFit }
            }
        }
        view.canvas.image = image
        view.canvas.canvasBackground = canvasBackground
        view.fitImage = fits
        view.imageZoom = zoom
        view.layoutImage()
    }

    static func dismantleNSView(_ view: ImageReaderScrollView, coordinator: ()) {
        view.changedZoom = nil
        view.canvas.image = nil
    }
}

private final class ImageReaderScrollView: NSScrollView {
    let canvas = ImageReaderCanvas()
    var imageZoom: CGFloat = 1
    var fitImage = true
    var changedZoom: ((CGFloat, Bool) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutImage()
    }

    override func layout() {
        super.layout()
        layoutImage()
    }

    func layoutImage() {
        guard let image = canvas.image, image.size.width > 0, image.size.height > 0 else { return }
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let previousSize = canvas.frame.size
        let center = NSPoint(x: contentView.bounds.midX / max(previousSize.width, 1),
                             y: contentView.bounds.midY / max(previousSize.height, 1))
        if fitImage {
            imageZoom = min(max((viewport.width - 40) / image.size.width, 0.01),
                            max((viewport.height - 40) / image.size.height, 0.01), 1)
            changedZoom?(imageZoom, true)
        }
        let size = NSSize(width: image.size.width * imageZoom, height: image.size.height * imageZoom)
        let canvasSize = NSSize(width: max(viewport.width, size.width + 40), height: max(viewport.height, size.height + 40))
        canvas.setFrameSize(canvasSize)
        canvas.imageRect = NSRect(x: (canvasSize.width - size.width) / 2, y: (canvasSize.height - size.height) / 2,
                                  width: size.width, height: size.height)
        if previousSize != canvasSize {
            contentView.scroll(to: NSPoint(x: max(0, center.x * canvasSize.width - viewport.width / 2),
                                          y: max(0, center.y * canvasSize.height - viewport.height / 2)))
            reflectScrolledClipView(contentView)
        }
        canvas.needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        fitImage = false
        imageZoom = min(max(imageZoom * (1 + event.magnification), 0.01), 8)
        layoutImage()
        changedZoom?(imageZoom, false)
    }
}

private final class ImageReaderCanvas: NSView {
    var image: NSImage?
    var imageRect = NSRect.zero
    var canvasBackground: ImageCanvasBackground = .checkerboard
    private var dragPoint: NSPoint?
    private var dragOrigin = NSPoint.zero
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(LocusTheme.paperDeep).setFill()
        dirtyRect.fill()
        let visibleImage = imageRect.intersection(dirtyRect)
        guard !visibleImage.isEmpty else { return }
        (canvasBackground == .dark ? NSColor(white: 0.15, alpha: 1) : NSColor.white).setFill()
        visibleImage.fill()
        if canvasBackground == .checkerboard {
            NSColor(white: 0.9, alpha: 1).setFill()
            let tile: CGFloat = 12
            for row in Int(floor(visibleImage.minY / tile))...Int(ceil(visibleImage.maxY / tile)) {
                for column in Int(floor(visibleImage.minX / tile))...Int(ceil(visibleImage.maxX / tile)) where (row + column).isMultiple(of: 2) {
                    NSRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)
                        .intersection(visibleImage).fill()
                }
            }
        }
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        dragPoint = event.locationInWindow
        dragOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragPoint, let scroll = enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: dragOrigin.x - (event.locationInWindow.x - dragPoint.x),
                                              y: dragOrigin.y + (event.locationInWindow.y - dragPoint.y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func mouseUp(with event: NSEvent) {
        if dragPoint != nil { NSCursor.pop() }
        dragPoint = nil
    }
}

struct DocumentPDFReader: View {
    var url: URL? = nil
    var data: Data? = nil
    var location: DocumentLocation? = nil
    @StateObject private var reader = PDFReaderModel()
    @State private var requestedPage = ""

    var body: some View {
        VStack(spacing: 0) {
            if reader.pageCount > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack { pageControls; Spacer(minLength: 12); zoomControls }
                    VStack(spacing: 8) { pageControls; zoomControls }
                }.padding(10).background(LocusTheme.panel)
                Divider()
                PDFReaderSurface(reader: reader)
            } else {
                ContentUnavailableView("PDF preview unavailable", systemImage: "doc.richtext",
                    description: Text("This PDF could not be read or has no pages."))
            }
        }
        .task(id: url) { reader.load(url: url, data: data, location: location) }
        .onChange(of: location) { _, next in reader.go(to: next) }
    }

    private var pageControls: some View {
        HStack(spacing: 8) {
            Button { reader.view.goToPreviousPage(nil) } label: { Image(systemName: "chevron.left") }
                .disabled(reader.page <= 1).accessibilityLabel("Previous page").help("Previous page")
                .accessibilityIdentifier("library.pdf.previous")
            Text("Page \(reader.page) of \(reader.pageCount)").monospacedDigit()
                .accessibilityIdentifier("library.pdf.page")
            Button { reader.view.goToNextPage(nil) } label: { Image(systemName: "chevron.right") }
                .disabled(reader.page >= reader.pageCount).accessibilityLabel("Next page").help("Next page")
                .accessibilityIdentifier("library.pdf.next")
            TextField("Go to", text: $requestedPage).textFieldStyle(.roundedBorder).frame(width: 52)
                .accessibilityLabel("Go to page").accessibilityIdentifier("preview.pdf.goToPage")
                .onSubmit {
                    if let page = Int(requestedPage), let document = reader.view.document,
                       let target = document.page(at: min(max(page, 1), document.pageCount) - 1) { reader.view.go(to: target) }
                    requestedPage = ""
                }
        }.fixedSize().controlSize(.small)
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { reader.view.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out").accessibilityLabel("Zoom out").disabled(!reader.view.canZoomOut)
            Text("\(Int((reader.scale * 100).rounded()))%").monospacedDigit().frame(minWidth: 42)
            Button { reader.view.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in").accessibilityLabel("Zoom in").disabled(!reader.view.canZoomIn)
            Button("Fit") { reader.view.autoScales = true }
                .help("Fit PDF to the viewer").accessibilityIdentifier("preview.pdf.fit")
        }.fixedSize().controlSize(.small)
    }
}

@MainActor
private final class PDFReaderModel: ObservableObject {
    let view = PDFView()
    @Published var page = 1
    @Published var pageCount = 0
    @Published var scale: CGFloat = 1
    private var observers: [NSObjectProtocol] = []

    init() {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(LocusTheme.paperDeep)
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.sync() }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func load(url: URL?, data: Data?, location: DocumentLocation?) {
        view.document = data.flatMap(PDFDocument.init(data:)) ?? url.flatMap(PDFDocument.init(url:))
        pageCount = view.document?.pageCount ?? 0
        go(to: location)
        sync()
    }
    func sync() {
        if let current = view.currentPage, let document = view.document { page = document.index(for: current) + 1 }
        scale = view.scaleFactor
    }
    func go(to location: DocumentLocation?) {
        guard let location, location.kind == "pdf", let document = view.document, document.pageCount > 0 else { return }
        let index = min(max((location.page ?? ((location.pageIndex ?? 0) + 1)) - 1, 0), document.pageCount - 1)
        guard let page = document.page(at: index) else { return }
        view.go(to: page)
        if let bounds = location.bounds {
            let pageBounds = page.bounds(for: .mediaBox)
            let rectangle = CGRect(x: bounds.x * pageBounds.width, y: bounds.y * pageBounds.height,
                                   width: bounds.width * pageBounds.width, height: bounds.height * pageBounds.height)
            if let selection = page.selection(for: rectangle) { view.setCurrentSelection(selection, animate: false) }
        }
        sync()
    }
}

private struct PDFReaderSurface: NSViewRepresentable {
    let reader: PDFReaderModel
    func makeNSView(context: Context) -> PDFView { reader.view }
    func updateNSView(_ view: PDFView, context: Context) {}
}
