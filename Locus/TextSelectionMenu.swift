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

/// Owns the right-click menu for highlighted conversation text — Copy and
/// Search in Google — and clears a live transcript selection when a click or
/// Escape says the user is done with it.
///
/// There is deliberately no floating action bar. One used to appear on every
/// mouse-up: it covered the text just selected, closed itself on any scroll —
/// which is exactly what a selection longer than the window needs — and offered
/// nothing Command-C and this menu do not.
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
    private var rightClickMonitor: Any?
    private var selectionMonitor: Any?
    private weak var responseStore: TranscriptSelectionStore?
    private var search: ((String) -> Void)?

    private init() {}

    /// Idempotent: the scene calls this on every appearance, and only the
    /// first one installs a monitor.
    func start(onSearch: @escaping (String) -> Void) {
        search = onSearch
        guard rightClickMonitor == nil, selectionMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self] event in
            guard let self, let target = self.target(for: event) else { return event }
            self.present(for: target, event: event)
            // Swallowing the click stops AppKit from following our menu with
            // the field editor's own.
            return nil
        }
        selectionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                // A new click invalidates the old highlight — except a click on
                // a transcript leaf, which the store is about to interpret
                // itself. Clearing unconditionally ran before the view saw the
                // event, so shift-click extension could never work and every
                // re-anchoring click started from nothing.
                if !self.pointIsOnTranscriptLeaf(event) {
                    self.responseStore?.clearSelection()
                }
            case .keyDown where event.keyCode == 53:
                self.responseStore?.clearSelection()
            default:
                break
            }
            return event
        }
    }

    func stop() {
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }
        rightClickMonitor = nil
        selectionMonitor = nil
        responseStore = nil
        search = nil
    }

    func registerScope(_ scrollView: NSScrollView) {
        scopes.add(scrollView)
    }

    /// There is one store for the whole transcript now, so this only records
    /// which one is live — it no longer clears a rival selection, which is what
    /// stopped a drag ever crossing from one answer into the next.
    func attach(store: TranscriptSelectionStore) {
        responseStore = store
    }

    func storeDidClearSelection(_ store: TranscriptSelectionStore) {
        guard responseStore === store else { return }
        responseStore = nil
    }

    /// The transcript scroll view an in-transcript view belongs to. Used for
    /// drag autoscroll, which must move the transcript itself rather than
    /// whatever inner scroll view a code block happens to provide.
    func transcriptScrollView(containing view: NSView?) -> NSScrollView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let scrollView = current as? NSScrollView, scopes.contains(scrollView) {
                return scrollView
            }
            candidate = current.superview
        }
        return nil
    }

    /// Whether a click landed on a transcript leaf, which owns its own
    /// mouse-down handling.
    private func pointIsOnTranscriptLeaf(_ event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView else { return false }
        return content.hitTest(event.locationInWindow) is ResponseSelectableTextView
    }

    // MARK: - Deciding whether the click is on a selection we own

    private struct Target {
        let view: NSView
        let text: String
    }

    private func target(for event: NSEvent) -> Target? {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView
        else { return nil }
        return target(for: editor, event: event)
    }

    private func target(for editor: NSTextView, event: NSEvent) -> Target? {
        guard let target = target(for: editor) else { return nil }

        // Only a click on the selected text owner. Right-clicking anywhere
        // else in the message still gets the message's own menu.
        guard editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) else {
            return nil
        }
        return target
    }

    private func target(for editor: NSTextView) -> Target? {
        guard !(editor is ResponseSelectableTextView) else { return nil }
        // The composer and settings fields keep their editing actions. This
        // controller only owns material being read, not written.
        guard !editor.isEditable else { return nil }

        let range = editor.selectedRange()
        guard range.length > 0,
              Self.isInScope(editor, scopes: scopes)
        else { return nil }

        let text = (editor.string as NSString).substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Target(view: editor, text: text)
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
            at: target.view.convert(event.locationInWindow, from: nil),
            in: target.view
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

    func presentResponseContextMenu(
        text: String,
        from view: NSView,
        at point: NSPoint
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = Target(view: view, text: text)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let copy = NSMenuItem(title: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
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
        search.isEnabled = WebSearchQuery.url(for: target.text) != nil
        menu.addItem(search)
        menu.popUp(positioning: nil, at: point, in: view)
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

// MARK: - Response-scoped rich-text selection

/// A selectable leaf in the visual Markdown tree. `displayedText` is exactly
/// what the corresponding native text view shows. Copy-only structure lives
/// beside it so markers and table delimiters do not have to become visual
/// characters inside cards.
struct TranscriptSelectionSpan: Hashable, Identifiable, Sendable {
    let treePath: [Int]
    var displayedText: String
    var separatorBefore: String
    var copyPrefix: String
    /// Which transcript row this leaf belongs to. Trailing and defaulted so a
    /// single-row projection — and every existing caller — stays unchanged.
    /// Without it two rows' leaves collide on `treePath` alone.
    var rowID: String = ""

    var id: String {
        let path = treePath.map(String.init).joined(separator: ".")
        return rowID.isEmpty ? path : "\(rowID)#\(path)"
    }
    var utf16Length: Int { (displayedText as NSString).length }

    func displaying(_ text: String) -> Self {
        var copy = self
        copy.displayedText = text
        return copy
    }
}

struct TranscriptSelectionPosition: Hashable, Sendable {
    let spanID: String
    let utf16Offset: Int
}

struct TranscriptSelection: Hashable, Sendable {
    let anchor: TranscriptSelectionPosition
    let focus: TranscriptSelectionPosition
}

/// Pure projection helpers live outside the AppKit coordinator so reverse
/// ranges, Unicode offsets, and structural copy text can be unit-tested.
enum TranscriptSelectionProjection {
    /// Sorting entry point. The store keeps its own ordered array — leaves are
    /// ranked by row first, which `treePath` alone cannot express — and calls
    /// the `orderedSpans` variants directly.
    static func text(
        for selection: TranscriptSelection,
        spans: [TranscriptSelectionSpan]
    ) -> String {
        text(
            for: selection,
            orderedSpans: spans.sorted { pathIsBefore($0.treePath, $1.treePath) }
        )
    }

    static func ranges(
        for selection: TranscriptSelection,
        spans: [TranscriptSelectionSpan]
    ) -> [String: NSRange] {
        ranges(
            for: selection,
            orderedSpans: spans.sorted { pathIsBefore($0.treePath, $1.treePath) }
        )
    }

    /// Moves an endpoint that no longer exists onto the nearest surviving leaf.
    ///
    /// Returning an empty projection instead — which is what happened before —
    /// meant Copy silently produced nothing whenever a selected leaf's row was
    /// re-parsed or dropped.
    static func resolve(
        _ selection: TranscriptSelection,
        in ordered: [TranscriptSelectionSpan]
    ) -> TranscriptSelection? {
        guard let first = ordered.first, let last = ordered.last else { return nil }
        func snap(_ position: TranscriptSelectionPosition) -> TranscriptSelectionPosition {
            if ordered.contains(where: { $0.id == position.spanID }) { return position }
            return .init(spanID: first.id, utf16Offset: 0)
        }
        let anchor = snap(selection.anchor)
        var focus = selection.focus
        if !ordered.contains(where: { $0.id == focus.spanID }) {
            // A dropped focus is normally content that scrolled past, so the
            // end of the document is the honest place to land.
            focus = .init(spanID: last.id, utf16Offset: last.utf16Length)
        }
        return TranscriptSelection(anchor: anchor, focus: focus)
    }

    static func text(
        for selection: TranscriptSelection,
        orderedSpans ordered: [TranscriptSelectionSpan]
    ) -> String {
        guard let anchorIndex = ordered.firstIndex(where: { $0.id == selection.anchor.spanID }),
              let focusIndex = ordered.firstIndex(where: { $0.id == selection.focus.spanID })
        else { return "" }

        let anchor = clamped(selection.anchor, in: ordered[anchorIndex])
        let focus = clamped(selection.focus, in: ordered[focusIndex])
        let forward = anchorIndex < focusIndex
            || (anchorIndex == focusIndex && anchor.utf16Offset <= focus.utf16Offset)
        let lower = forward ? anchor : focus
        let upper = forward ? focus : anchor
        let lowerIndex = forward ? anchorIndex : focusIndex
        let upperIndex = forward ? focusIndex : anchorIndex

        var result = ""
        for index in lowerIndex...upperIndex {
            let span = ordered[index]
            let start = index == lowerIndex ? lower.utf16Offset : 0
            let end = index == upperIndex ? upper.utf16Offset : span.utf16Length
            guard end > start else { continue }

            if !result.isEmpty {
                append(span.separatorBefore, to: &result)
            }
            if start == 0 {
                result += span.copyPrefix
            }
            result += (span.displayedText as NSString).substring(
                with: NSRange(location: start, length: end - start)
            )
        }
        return result
    }

    /// A code block commonly owns its trailing newline already. Merge that
    /// newline with the logical block separator instead of producing three or
    /// four blank lines when selection continues into the next Markdown leaf.
    private static func append(_ separator: String, to result: inout String) {
        guard separator.first == "\n" else {
            result += separator
            return
        }
        let requested = separator.prefix(while: { $0 == "\n" }).count
        let existing = result.reversed().prefix(while: { $0 == "\n" }).count
        if existing < requested {
            result += String(repeating: "\n", count: requested - existing)
        }
        result += separator.dropFirst(requested)
    }

    static func ranges(
        for selection: TranscriptSelection,
        orderedSpans ordered: [TranscriptSelectionSpan]
    ) -> [String: NSRange] {
        guard let anchorIndex = ordered.firstIndex(where: { $0.id == selection.anchor.spanID }),
              let focusIndex = ordered.firstIndex(where: { $0.id == selection.focus.spanID })
        else { return [:] }

        let anchor = clamped(selection.anchor, in: ordered[anchorIndex])
        let focus = clamped(selection.focus, in: ordered[focusIndex])
        let forward = anchorIndex < focusIndex
            || (anchorIndex == focusIndex && anchor.utf16Offset <= focus.utf16Offset)
        let lower = forward ? anchor : focus
        let upper = forward ? focus : anchor
        let lowerIndex = forward ? anchorIndex : focusIndex
        let upperIndex = forward ? focusIndex : anchorIndex

        var result: [String: NSRange] = [:]
        for index in lowerIndex...upperIndex {
            let span = ordered[index]
            let start = index == lowerIndex ? lower.utf16Offset : 0
            let end = index == upperIndex ? upper.utf16Offset : span.utf16Length
            if end > start {
                result[span.id] = NSRange(location: start, length: end - start)
            }
        }
        return result
    }

    static func pathIsBefore(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right
        }
        return lhs.count < rhs.count
    }

    private static func clamped(
        _ position: TranscriptSelectionPosition,
        in span: TranscriptSelectionSpan
    ) -> TranscriptSelectionPosition {
        TranscriptSelectionPosition(
            spanID: position.spanID,
            utf16Offset: min(max(position.utf16Offset, 0), span.utf16Length)
        )
    }
}
