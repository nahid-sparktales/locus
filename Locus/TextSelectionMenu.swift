import AppKit
import SwiftUI

/// Where a web search started from highlighted text opens.
///
/// Stored as a raw string, like the browser viewport: a destination added by a
/// future version must not fail the whole settings decode.
enum WebSearchDestination: String, CaseIterable, Codable, Identifiable {
    case defaultBrowser
    case locusBrowser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultBrowser: "Default browser"
        case .locusBrowser: "Locus Browser tab"
        }
    }
}

/// Turns a text selection into the Google search it stands for.
enum WebSearchQuery {
    /// Google stops reading a query long before this, and a URL carrying a
    /// whole message is refused somewhere along the way. A longer selection
    /// searches its leading words rather than failing to search at all.
    static let characterLimit = 512

    /// Transcript selections routinely span several lines. Google reads a
    /// query as words, so newlines and runs of spaces collapse to one space —
    /// what gets searched is then what the menu said it would search.
    static func normalize(_ selection: String) -> String {
        selection
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Truncation lands on a word boundary when the query has one. Cutting
    /// mid-word would search for a fragment the user never highlighted.
    static func truncate(_ query: String, limit: Int = characterLimit) -> String {
        guard query.count > limit else { return query }
        let head = query.prefix(limit)
        if let lastSpace = head.lastIndex(of: " ") {
            let trimmed = head[..<lastSpace]
            if !trimmed.isEmpty { return String(trimmed) }
        }
        return String(head)
    }

    static func url(for selection: String) -> URL? {
        let query = truncate(normalize(selection))
        guard !query.isEmpty else { return nil }
        // `URLComponents` leaves a literal "+" in a query value, which Google
        // decodes back as a space — so a selection containing "+" would be
        // searched as something else. Percent-encoding everything outside the
        // unreserved set keeps the query byte-for-byte what was highlighted.
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}

/// The right-click menu for highlighted conversation text: Copy, and Search in
/// Google.
///
/// SwiftUI never exposes what `.textSelection(.enabled)` has selected, but it
/// draws that text as a non-editable `NSTextField`, so highlighting promotes
/// the window's field editor — a real `NSTextView` — to first responder. The
/// selection can be read straight off it, with no pasteboard round-trip to
/// clobber the user's clipboard.
///
/// A local right-mouse monitor is what makes replacing the menu possible: it
/// sees the click before AppKit reaches the field editor, which would
/// otherwise put up the system text menu (Look Up, Translate, Writing Tools,
/// Font, Speech…) and leave no room for ours.
@MainActor
final class TranscriptSelectionMenu {
    static let shared = TranscriptSelectionMenu()

    /// Scroll views whose highlighted text this menu covers — the conversation
    /// transcripts. Held weakly, so a torn-down transcript stops matching
    /// without anything having to deregister it.
    private let scopes = NSHashTable<NSScrollView>.weakObjects()
    private var monitor: Any?
    private var search: ((String) -> Void)?

    private init() {}

    /// Idempotent: the scene calls this on every appearance, and only the
    /// first one installs a monitor.
    func start(onSearch: @escaping (String) -> Void) {
        search = onSearch
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let target = self.target(for: event) else { return event }
            self.present(for: target, event: event)
            // Swallowing the click stops AppKit from following our menu with
            // the field editor's own.
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        search = nil
    }

    func registerScope(_ scrollView: NSScrollView) {
        scopes.add(scrollView)
    }

    // MARK: - Deciding whether the click is on a selection we own

    private struct Target {
        let editor: NSTextView
        let text: String
    }

    private func target(for event: NSEvent) -> Target? {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor,
              // The composer and the settings fields keep their editing menu,
              // which carries Cut and Paste. This one is for material being
              // read, not written.
              !editor.isEditable
        else { return nil }

        let range = editor.selectedRange()
        guard range.length > 0, Self.isInScope(editor, scopes: scopes) else { return nil }

        // Only a click on the highlight itself. Right-clicking anywhere else
        // in the message still gets the message's own menu.
        guard editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) else {
            return nil
        }

        let text = (editor.string as NSString).substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Target(editor: editor, text: text)
    }

    /// Scope is tested by ancestry rather than by `enclosingScrollView`: a code
    /// block's text sits inside its own horizontal scroll view, so the nearest
    /// enclosing scroll view is not the transcript's.
    private static func isInScope(_ view: NSView, scopes: NSHashTable<NSScrollView>) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if let scrollView = current as? NSScrollView, scopes.contains(scrollView) {
                return true
            }
            candidate = current.superview
        }
        return false
    }

    // MARK: - The menu

    private func present(for target: Target, event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copy = NSMenuItem(
            title: "Copy",
            action: #selector(copySelection(_:)),
            keyEquivalent: ""
        )
        copy.target = self
        copy.representedObject = target.text
        menu.addItem(copy)

        let search = NSMenuItem(
            title: "Search in Google",
            action: #selector(searchSelection(_:)),
            keyEquivalent: ""
        )
        search.target = self
        search.representedObject = target.text
        // A selection that cannot form a query — punctuation only, say — would
        // otherwise open a blank results page.
        search.isEnabled = WebSearchQuery.url(for: target.text) != nil
        menu.addItem(search)

        menu.popUp(
            positioning: nil,
            at: target.editor.convert(event.locationInWindow, from: nil),
            in: target.editor
        )
    }

    @objc private func copySelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func searchSelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        search?(text)
    }
}

/// Marks the conversation transcript as the region whose highlighted text gets
/// the selection menu. Sits in the transcript content's background so that
/// `enclosingScrollView` resolves to the transcript's own scroll view.
struct TranscriptSelectionScope: NSViewRepresentable {
    func makeNSView(context: Context) -> TranscriptSelectionScopeView {
        TranscriptSelectionScopeView(frame: .zero)
    }

    func updateNSView(_ nsView: TranscriptSelectionScopeView, context: Context) {
        nsView.registerScope()
    }
}

final class TranscriptSelectionScopeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerScope()
    }

    func registerScope() {
        guard let scrollView = enclosingScrollView else { return }
        TranscriptSelectionMenu.shared.registerScope(scrollView)
    }
}
