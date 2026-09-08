import AppKit
import PDFKit
import Foundation

extension AppModel {
    /// Real files in the same disposable root as test writing drafts. This
    /// fixture never opens a provider, user workspace, or persistent library.
    func seedResponseOutputFixture() {
        guard isUITesting, ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_RESPONSE_OUTPUT"] == "1" else { return }
        let root = NotesStore.applicationSupportDirectory.appendingPathComponent("ResponseWorkspace", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files: [(String, String)] = [
                ("AGENTS.md", "Workspace instructions"),
                ("audit_findings_report.pdf", "Audit report document"),
                ("code_audit_report.pdf", "Code audit report"),
                ("generate_audit_report.py", "Generates audit reports"),
                ("pokemoncenter_stock.py", "Pokémon Center stock-checking script"),
                ("reddit_latest.py", "Reddit latest-posts script"),
                ("requirements.txt", "Python dependencies"),
                ("storyboobible-influencer-intro-email.pdf", "Influencer outreach email"),
                ("test_pokemoncenter_stock.py", "Tests for the Pokémon Center script"),
                ("test_reddit_latest.py", "Tests for the Reddit script"),
            ]
            for (name, description) in files {
                let url = root.appendingPathComponent(name)
                if url.pathExtension == "pdf" {
                    let image = NSImage(size: NSSize(width: 420, height: 260))
                    image.lockFocus()
                    NSColor.white.setFill()
                    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 420, height: 260)).fill()
                    (description as NSString).draw(at: NSPoint(x: 24, y: 180), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black,
                    ])
                    image.unlockFocus()
                    let document = PDFDocument()
                    if let page = PDFPage(image: image) { document.insert(page, at: 0) }
                    guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
                } else {
                    let content = name == "AGENTS.md" ? "# Workspace instructions\n\nFixture content only.\n"
                        : name == "requirements.txt" ? "requests\npytest\n" : "# \(description)\nprint(\"Response fixture\")\n"
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            // A real PNG where generate_image would put one, so the card,
            // Outputs capture and Edit in chat all see an ordinary workspace file.
            let imagesDirectory = root.appendingPathComponent("Locus Images", isDirectory: true)
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            let illustration = NSImage(size: NSSize(width: 480, height: 320))
            illustration.lockFocus()
            NSColor(calibratedRed: 0.15, green: 0.42, blue: 0.55, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 480, height: 320)).fill()
            ("Harbour at dusk" as NSString).draw(at: NSPoint(x: 36, y: 220), withAttributes: [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.white,
            ])
            illustration.unlockFocus()
            guard let tiff = illustration.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let imagePath = "Locus Images/fixture.png"
            try png.write(to: root.appendingPathComponent(imagePath))
            let workspace = root.standardizedFileURL.resolvingSymlinksInPath().path
            let sessionID = "seed-response-output"
            sessionInfo = SessionInfo(model: "qwen3:8b", host: "http://localhost:11434", cwd: workspace,
                session: root.appendingPathComponent("fixture.jsonl").path, sessionID: sessionID,
                messages: 2, approxTokens: 420, promptTokens: 20, completionTokens: 400,
                contextLimit: 32_768, maxIterations: 40, hasProjectContext: false,
                provider: "ollama", permissions: SessionPermissions(skipAll: false, allowed: []))
            currentSessionID = sessionID
            sessions = [SessionSummary(id: sessionID, name: "fixture.jsonl", preview: "Response output review",
                mtime: Date().timeIntervalSince1970, size: 1_000, title: "Response output review", pinned: true, cwd: workspace)]
            expandedWorkspaceIDs = [SessionSummary.canonicalWorkspacePath(workspace)]
            workspaceProfiles = [WorkspaceProfile(path: workspace, lastOpened: Date(), model: "qwen3:8b",
                accountID: nil, mode: .work, previewURL: "", contextFiles: [], draft: "")]
            workspaceFiles.seed(files.map { root.appendingPathComponent($0.0) }
                .filter { ContextFileTypes.allowedExtensions.contains($0.pathExtension) }, workspacePath: workspace)
            activateWorkspaceBrowser()
            let entries = files.map { name, description in
                let url = root.appendingPathComponent(name)
                return ResponseFileEntry(path: name, name: name,
                    kind: url.pathExtension == "pdf" ? "pdf" : "source",
                    size: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                    exists: true, description: description)
            }
            let writing = ResponsePart(type: "writing", id: "writing-intro", title: "Outreach email",
                variant: "email", subject: "An invitation to collaborate",
                body: "Hi Morgan,\n\nI enjoyed your recent videos and would love to discuss a small collaboration.\n\nBest,\nThe team")
            let table = "| File | Status | Size |\n| --- | --- | ---: |\n" +
                (1...24).map { "| Example \($0) | Reviewed | \($0 * 10) KB |" }.joined(separator: "\n")
            let collection = ResponsePart(type: "file_collection", id: "directory-files", workspace: workspace,
                entries: entries, totalCount: 10, complete: true)
            let artifact = ResponsePart(type: "artifact", id: "audit-artifact", title: "Audit findings report",
                workspace: workspace, path: "audit_findings_report.pdf", description: "The completed audit document.")
            let sources = ResponsePart(type: "sources", id: "sources", references: [
                ResponseSource(id: "python-docs", title: "Python documentation", url: "https://docs.python.org/3/"),
            ])
            let tablePart = ResponsePart(type: "markdown", id: "long-table", text: table)
            let image = ResponsePart(type: "image", id: "generated-image", title: "Harbour at dusk", workspace: workspace,
                path: imagePath, alt: "Harbour at dusk", prompt: "A quiet harbour at dusk with warm lights on the water.",
                width: 480, height: 320, format: "png", byteSize: png.count)
            // All variants contain all parts. Put the tested control near the
            // tail so launch scroll position is deterministic at small sizes.
            let focus = ProcessInfo.processInfo.environment["LOCUS_UI_TESTING_RESPONSE_FOCUS"] ?? "files"
            let ordered: [ResponsePart]
            switch focus {
            case "writing": ordered = [image, collection, tablePart, artifact, sources, writing]
            case "table": ordered = [image, collection, writing, artifact, sources, tablePart]
            case "artifact": ordered = [image, collection, writing, tablePart, sources, artifact]
            case "image": ordered = [collection, writing, tablePart, artifact, sources, image]
            default: ordered = [image, writing, tablePart, artifact, sources, collection]
            }
            let fallback = files.map { "- [\($0.0)](\($0.0)) — \($0.1)" }.joined(separator: "\n")
                + "\n\n" + writing.originalWriting + "\n\n" + table
                + "\n\n[Audit findings report](audit_findings_report.pdf)\n\n[Python documentation](https://docs.python.org/3/)"
                + "\n\n" + ResponseExportProjection.fallbackImageLink(for: image) + "\n\nHarbour at dusk"
            blocks = [
                ChatBlock(id: UUID(uuidString: "00000000-0000-0000-0000-000000004001")!, kind: .user,
                    text: "Show the workspace files, outreach draft, and audit results."),
                ChatBlock(id: UUID(uuidString: "00000000-0000-0000-0000-000000004002")!, kind: .assistant,
                    text: fallback, assistantPhase: .finalAnswer, sourceItemID: "response-output-fixture",
                    responseParts: ResponseDocument(version: 1, parts: ordered), runID: "response-output-fixture-run"),
            ]
            outputsLibrary.configure(emitter: SessionStateEmitter(), enabled: true)
            outputsLibrary.activate(workspace: workspace)
            outputsLibrary.capture(workspace: workspace, path: "audit_findings_report.pdf",
                sessionID: sessionID, runID: "response-output-fixture-run")
            outputsLibrary.capture(workspace: workspace, path: imagePath,
                sessionID: sessionID, runID: "response-output-fixture-run")
            isBusy = false
            draftText = ""
            selectedMode = .work
            openInspectorTabs = [.files]
            inspectorTab = .files
            inspectorCollapsed = true
        } catch {
            blocks = [ChatBlock(kind: .error, text: "Response fixture failed: \(error.localizedDescription)")]
        }
    }
}
