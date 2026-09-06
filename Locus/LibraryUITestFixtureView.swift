import AppKit
import PDFKit
import SwiftUI

/// Populated native UI coverage gets a disposable store; it never reads or
/// writes the person's Library, preferences, provider, or live workspace.
@MainActor
struct LibraryUITestFixtureView: View {
    @StateObject private var library = WorkspaceLibraryModel()
    @StateObject private var outputs: OutputsLibraryModel
    @State private var error: String?
    private let root: URL

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Locus-Library-UI-\(UUID().uuidString)")
        self.root = root
        _outputs = StateObject(wrappedValue: OutputsLibraryModel(store: OutputsLibraryStore(directory: root.appendingPathComponent("Store"))))
    }
    var body: some View {
        LibraryWorkspaceView()
            .environmentObject(library)
            .environmentObject(outputs)
            .overlay(alignment: .bottom) { if let error { Text(error).padding().background(.red.opacity(0.1)) } }
            .task { await seed() }
            .onDisappear { try? FileManager.default.removeItem(at: root) }
    }
    private func seed() async {
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else { return }
        do {
            let workspace = root.appendingPathComponent("Research")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let pdfURL = workspace.appendingPathComponent("Report.pdf")
            let summaryURL = workspace.appendingPathComponent("Summary.md")
            let source = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_LIBRARY_SOURCE"].map { URL(fileURLWithPath: $0) }
            if let source, FileManager.default.fileExists(atPath: source.appendingPathComponent("mixed.pdf").path) {
                try FileManager.default.copyItem(at: source.appendingPathComponent("mixed.pdf"), to: pdfURL)
            } else {
                let document = PDFDocument()
                for number in 1...2 {
                    let image = NSImage(size: NSSize(width: 612, height: 792))
                    image.lockFocus()
                    NSColor.white.setFill()
                    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 612, height: 792)).fill()
                    ("Research report" as NSString).draw(at: NSPoint(x: 48, y: 695), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
                    ("Page \(number) · \(number == 1 ? "Introduction" : "Evidence and findings")" as NSString).draw(at: NSPoint(x: 48, y: 645), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
                    image.unlockFocus()
                    if let page = PDFPage(image: image) { document.insert(page, at: document.pageCount) }
                }
                guard document.write(to: pdfURL) else { throw OutputsLibraryStore.StoreError("Could not prepare the PDF fixture") }
            }
            let original: Data
            if let source, let generated = try? Data(contentsOf: source.appendingPathComponent("summary.md")) { original = generated }
            else { original = Data("# Research summary\n\nThe initial review found three useful examples.\n".utf8) }
            try original.write(to: summaryURL)
            outputs.configure(emitter: SessionStateEmitter(), enabled: true)
            await outputs.flush()
            let illustration = NSImage(size: NSSize(width: 480, height: 320))
            illustration.lockFocus()
            NSColor(calibratedRed: 0.15, green: 0.42, blue: 0.55, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 480, height: 320)).fill()
            ("Research findings" as NSString).draw(at: NSPoint(x: 36, y: 220), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.white])
            illustration.unlockFocus()
            guard let tiff = illustration.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw OutputsLibraryStore.StoreError("Could not prepare the image fixture")
            }
            try png.write(to: workspace.appendingPathComponent("Findings.png"))
            _ = try await outputs.store.capture(OutputCapture(workspace: workspace.path, path: "Findings.png", sessionID: "seed-current", runID: "fixture-image"))
            let first = try await outputs.store.capture(OutputCapture(workspace: workspace.path, path: "Summary.md", sessionID: "seed-current", runID: "fixture-first"))!
            var updated = original
            updated.append(Data("\n## Revision\nAdditional finding from the second review.\n".utf8))
            try updated.write(to: summaryURL, options: .atomic)
            let second = try await outputs.store.capture(OutputCapture(workspace: workspace.path, path: "Summary.md", sessionID: "seed-current", runID: "fixture-second"))!
            // Saved previews and comparisons must survive this disappearance.
            try FileManager.default.removeItem(at: summaryURL)
            let data = try Data(contentsOf: pdfURL)
            let pdf = LibraryDocument(id: "fixture-pdf", path: "Report.pdf", title: "Report.pdf", format: "pdf",
                contentHash: OutputsLibraryStore.digest(data), status: "ready", jobID: nil, error: nil, warnings: [],
                truncated: false, excluded: false, segmentCount: PDFDocument(url: pdfURL)?.pageCount ?? 2,
                updatedAt: Date().timeIntervalSince1970, size: Int64(data.count))
            library.installUITestDocuments([pdf], workspace: workspace.path)
            outputs.activate(workspace: workspace.path)
            await outputs.refresh()
            outputs.open(itemID: first.id, versionID: second.latest?.id)
        } catch { self.error = error.localizedDescription }
    }
}
