import AppKit
import Foundation

/// How typed answer parts appear in an exported transcript. The backend
/// writes the Markdown fallback for an `image` part as
/// `![alt](quote(abs_path, safe='/'))`; export reproduces that exact link so
/// it can replace it with the sidecar copy instead of guessing at the text.
enum ResponseExportProjection {
    /// Wraps an interactive fragment in the sealed document shell before it
    /// is written beside an export, so the saved file keeps its Content
    /// Security Policy and stays offline in any browser. Exported pages are
    /// light paper even when the workspace is dark, like the PDF export.
    /// Settable so tests can observe the projection without WebKit.
    nonisolated(unsafe) static var wrapInteractiveHTML: (String) -> String = { fragment in
        InteractiveAnswerDocument.savedDocument(
            html: fragment,
            appearance: NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        )
    }

    /// Mirrors Python's `urllib.parse.quote(value, safe='/')`: every UTF-8
    /// byte outside `A-Za-z0-9_.-~/` becomes `%XX` with upper-case hex.
    static func pythonQuoted(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "~"), UInt8(ascii: "/"):
                output.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    /// Mirrors the label escaping of the backend's `_link` helper.
    static func markdownLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    static func imageParts(_ message: ChatExportMessage) -> [ResponsePart] {
        supportedParts(message).filter { $0.type == "image" }
    }

    static func interactiveParts(_ message: ChatExportMessage) -> [ResponsePart] {
        supportedParts(message).filter { $0.type == "interactive" }
    }

    private static func supportedParts(_ message: ChatExportMessage) -> [ResponsePart] {
        guard let document = message.responseParts, document.isSupported else { return [] }
        return document.parts
    }

    /// The alt text the backend used for the fallback link: `alt`, else the
    /// title, else the file name.
    static func imageLabel(for part: ResponsePart) -> String {
        part.alt?.nilIfEmpty ?? part.title?.nilIfEmpty ?? ((part.path ?? "") as NSString).lastPathComponent
    }

    /// `str(Path(workspace) / path)` for an already-normalised workspace and
    /// a workspace-relative path.
    static func absolutePath(for part: ResponsePart) -> String {
        var workspace = part.workspace ?? ""
        while workspace.count > 1, workspace.hasSuffix("/") { workspace.removeLast() }
        let path = part.path ?? ""
        if workspace.isEmpty { return path }
        return workspace + "/" + path
    }

    static func fallbackImageLink(for part: ResponsePart) -> String {
        "![" + markdownLabel(imageLabel(for: part)) + "](" + pythonQuoted(absolutePath(for: part)) + ")"
    }

    /// The image file re-contained in its own workspace, or nil when the part
    /// points outside it or the file is gone.
    static func imageFileURL(for part: ResponsePart) -> URL? {
        guard let workspace = part.workspace, let path = part.path,
              let url = OutputsLibraryStore.containedURL(path, workspace: workspace),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return nil }
        return url
    }

    static func plainTextImageLine(for part: ResponsePart) -> String {
        "[Image: \(part.imageTitle) — \(part.path ?? "")]"
    }

    static func unavailableImageLine(for part: ResponsePart) -> String {
        "[Image unavailable: \(part.path ?? "")]"
    }

    /// A file-name-safe form of an interactive answer's title.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let collapsed = folded.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(collapsed.prefix(48)).nilIfEmpty ?? "interactive"
    }

    static func interactiveFileName(for part: ResponsePart, index: Int) -> String {
        String(format: "%03d-%@.html", index, slug(part.interactiveTitle))
    }

    static func interactiveDocument(for part: ResponsePart) -> String {
        wrapInteractiveHTML(part.html ?? "")
    }

    static func interactiveLink(for part: ResponsePart, directory: String, name: String) -> String {
        "[Interactive: " + markdownLabel(part.interactiveTitle) + "](\(directory)/\(name))"
    }
}
