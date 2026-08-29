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

/// Owns the actions for highlighted conversation text: a compact mouse-up
/// popover for Copy and Quote in Reply, plus the existing right-click menu for
/// Copy and Search in Google.
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
    private var selectionObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var selectionPopover: NSPopover?
    private var selectionPresentationTask: Task<Void, Never>?
    private weak var selectedEditor: NSTextView?
    private weak var responseCoordinator: ResponseSelectionCoordinator?
    private var search: ((String) -> Void)?
    private var quote: ((String) -> Void)?

    private init() {}

    /// Idempotent: the scene calls this on every appearance, and only the
    /// first one installs a monitor.
    func start(
        onSearch: @escaping (String) -> Void,
        onQuote: @escaping (String) -> Void
    ) {
        search = onSearch
        quote = onQuote
        guard rightClickMonitor == nil, selectionMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let target = self.target(for: event) else { return event }
            self.dismissSelectionPopover()
            self.present(for: target, event: event)
            // Swallowing the click stops AppKit from following our menu with
            // the field editor's own.
            return nil
        }
        selectionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                // Let controls inside the popover receive their click. Any
                // other new click invalidates the old highlighted selection.
                if event.window !== self.selectionPopover?.contentViewController?.view.window {
                    self.dismissSelectionPopover()
                    self.responseCoordinator?.clearSelection()
                }
            case .leftMouseUp:
                guard event.window !== self.selectionPopover?.contentViewController?.view.window else {
                    return event
                }
                // AppKit finalizes the field editor's range after mouse-up.
                // Reading it one main-actor turn later avoids showing actions
                // for the range that existed before the drag.
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.presentSelectionPopover(for: event)
                }
            case .scrollWheel:
                self.dismissSelectionPopover()
            case .keyDown where event.keyCode == 53:
                self.dismissSelectionPopover()
                self.responseCoordinator?.clearSelection()
            default:
                break
            }
            return event
        }
        // SwiftUI's selectable Text has used both a shared field editor and a
        // dedicated text view across macOS releases. The selection
        // notification gives us the actual owner in either representation;
        // mouse-up then reads its final range.
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let editor = notification.object as? NSTextView else { return }
                self.selectionPresentationTask?.cancel()
                self.dismissSelectionPopover()
                guard let target = self.target(for: editor) else {
                    self.selectedEditor = nil
                    return
                }
                self.selectedEditor = editor
                // SwiftUI can deliver several range changes during a drag.
                // Waiting briefly keeps the popover out of the pointer's way
                // and also covers synthesized input that omits local mouse-up.
                self.selectionPresentationTask = Task { @MainActor [weak self, weak editor] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled, let self, let editor,
                          editor.selectedRange() == target.range
                    else { return }
                    self.presentSelectionPopover(for: target)
                }
            }
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissSelectionPopover()
            }
        }
    }

    func stop() {
        selectionPresentationTask?.cancel()
        dismissSelectionPopover()
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        rightClickMonitor = nil
        selectionMonitor = nil
        selectionObserver = nil
        windowObserver = nil
        selectionPresentationTask = nil
        selectedEditor = nil
        responseCoordinator = nil
        search = nil
        quote = nil
    }

    func registerScope(_ scrollView: NSScrollView) {
        scopes.add(scrollView)
    }

    func beginResponseSelection(_ coordinator: ResponseSelectionCoordinator) {
        if responseCoordinator !== coordinator {
            responseCoordinator?.clearSelection()
        }
        responseCoordinator = coordinator
    }

    func responseSelectionDidClear(_ coordinator: ResponseSelectionCoordinator) {
        guard responseCoordinator === coordinator else { return }
        responseCoordinator = nil
        dismissSelectionPopover()
    }

    // MARK: - Deciding whether the click is on a selection we own

    private struct Target {
        let view: NSView
        let anchor: NSRect
        let text: String
        var range: NSRange = NSRange(location: NSNotFound, length: 0)
    }

    private func target(for event: NSEvent) -> Target? {
        guard let window = event.window else { return nil }
        if let editor = window.firstResponder as? NSTextView,
           let target = target(for: editor, event: event) {
            return target
        }
        guard let editor = selectedEditor, editor.window === window else { return nil }
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
        return Target(
            view: editor,
            anchor: selectionAnchor(editor: editor, range: range),
            text: text,
            range: range
        )
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

    // MARK: - The mouse-up popover

    private func presentSelectionPopover(for event: NSEvent) {
        guard let target = target(for: event) else { return }
        presentSelectionPopover(for: target)
    }

    private func presentSelectionPopover(for target: Target) {
        dismissSelectionPopover()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 190, height: 42)
        popover.contentViewController = NSHostingController(
            rootView: TranscriptSelectionActionsView(
                onCopy: { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.text, forType: .string)
                    self?.dismissSelectionPopover()
                },
                onQuote: { [weak self] in
                    self?.quote?(target.text)
                    self?.dismissSelectionPopover()
                }
            )
        )
        selectionPopover = popover
        popover.show(
            relativeTo: target.anchor,
            of: target.view,
            preferredEdge: .maxY
        )
    }

    private func selectionAnchor(editor: NSTextView, range: NSRange) -> NSRect {
        let finalCharacter = max(range.location, NSMaxRange(range) - 1)
        var actualRange = NSRange(location: NSNotFound, length: 0)
        let screenRect = editor.firstRect(
            forCharacterRange: NSRange(location: finalCharacter, length: 1),
            actualRange: &actualRange
        )
        if let window = editor.window, !screenRect.isEmpty, !screenRect.isNull {
            let windowRect = window.convertFromScreen(screenRect)
            return editor.convert(windowRect, from: nil)
        }
        return NSRect(
            x: editor.visibleRect.midX,
            y: editor.visibleRect.midY,
            width: 1,
            height: 1
        )
    }

    /// Response-scoped selection uses several native text views as one logical
    /// document. It supplies the already-projected text and an anchor in the
    /// final participating view; the field-editor path above remains the
    /// fallback for ordinary standalone selectable text.
    func presentResponseSelection(text: String, from view: NSView, anchor: NSRect) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        presentSelectionPopover(for: Target(view: view, anchor: anchor, text: text))
    }

    func presentResponseContextMenu(
        text: String,
        from view: NSView,
        at point: NSPoint
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        dismissSelectionPopover()
        let target = Target(view: view, anchor: NSRect(origin: point, size: .init(width: 1, height: 1)), text: text)
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

    private func dismissSelectionPopover() {
        selectionPresentationTask?.cancel()
        selectionPresentationTask = nil
        selectionPopover?.performClose(nil)
        selectionPopover = nil
    }
}

private struct TranscriptSelectionActionsView: View {
    let onCopy: () -> Void
    let onQuote: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            action("Copy", symbol: "doc.on.doc", identifier: "selection.copy", action: onCopy)
            action(
                "Quote",
                symbol: "quote.bubble",
                identifier: "selection.quote",
                action: onQuote
            )
        }
        .padding(5)
        .background(LocusTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
    }

    private func action(
        _ title: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.inkSoft)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(LocusTheme.paperDeep.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "Quote" ? "Quote in Reply" : title)
        .accessibilityIdentifier(identifier)
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

    var id: String { treePath.map(String.init).joined(separator: ".") }
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
    static func text(
        for selection: TranscriptSelection,
        spans: [TranscriptSelectionSpan]
    ) -> String {
        let ordered = spans.sorted { pathIsBefore($0.treePath, $1.treePath) }
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
        spans: [TranscriptSelectionSpan]
    ) -> [String: NSRange] {
        let ordered = spans.sorted { pathIsBefore($0.treePath, $1.treePath) }
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

private final class WeakResponseSelectableTextView {
    weak var value: ResponseSelectableTextView?

    init(_ value: ResponseSelectableTextView) {
        self.value = value
    }
}

/// Owns one assistant answer's logical range while its visible leaves remain
/// separate native controls. Mouse and keyboard input update every
/// participating text view, so a drag can cross lists, cards, tables, and
/// nested Markdown without entering reasoning or the next transcript item.
@MainActor
final class ResponseSelectionCoordinator: ObservableObject {
    @Published private(set) var selection: TranscriptSelection?

    private var spans: [String: TranscriptSelectionSpan] = [:]
    private var views: [String: WeakResponseSelectableTextView] = [:]

    var selectedText: String {
        guard let selection else { return "" }
        return TranscriptSelectionProjection.text(for: selection, spans: orderedSpans)
    }

    var isSelectionActive: Bool { !selectedText.isEmpty }

    func register(_ span: TranscriptSelectionSpan, view: ResponseSelectableTextView) {
        spans[span.id] = span
        views[span.id] = WeakResponseSelectableTextView(view)
        view.responseSelectionCoordinator = self
        view.responseSelectionSpanID = span.id
        applySelection()
    }

    func unregister(spanID: String, view: ResponseSelectableTextView) {
        guard views[spanID]?.value === view else { return }
        let selectedIDs = selection.map {
            Set(TranscriptSelectionProjection.ranges(for: $0, spans: orderedSpans).keys)
        } ?? []
        spans.removeValue(forKey: spanID)
        views.removeValue(forKey: spanID)
        if selectedIDs.contains(spanID) {
            clearSelection()
        }
    }

    func mouseDown(in view: ResponseSelectableTextView, event: NSEvent) {
        guard let spanID = view.responseSelectionSpanID else { return }
        TranscriptSelectionMenu.shared.beginResponseSelection(self)
        view.window?.makeFirstResponder(view)
        let index = view.characterIndex(atWindowPoint: event.locationInWindow)
        let point = TranscriptSelectionPosition(spanID: spanID, utf16Offset: index)

        if event.clickCount >= 3 {
            let range = view.selectionRange(
                forProposedRange: NSRange(location: index, length: 0),
                granularity: .selectByParagraph
            )
            selection = TranscriptSelection(
                anchor: .init(spanID: spanID, utf16Offset: range.location),
                focus: .init(spanID: spanID, utf16Offset: NSMaxRange(range))
            )
        } else if event.clickCount == 2 {
            let range = view.selectionRange(
                forProposedRange: NSRange(location: index, length: 0),
                granularity: .selectByWord
            )
            selection = TranscriptSelection(
                anchor: .init(spanID: spanID, utf16Offset: range.location),
                focus: .init(spanID: spanID, utf16Offset: NSMaxRange(range))
            )
        } else if event.modifierFlags.contains(.shift), let current = selection {
            selection = TranscriptSelection(anchor: current.anchor, focus: point)
        } else {
            selection = TranscriptSelection(anchor: point, focus: point)
        }
        applySelection()
    }

    func mouseDragged(event: NSEvent) {
        guard let current = selection,
              let focus = position(atWindowPoint: event.locationInWindow, in: event.window)
        else { return }
        selection = TranscriptSelection(anchor: current.anchor, focus: focus)
        applySelection()
        autoscrollTranscript(from: views[focus.spanID]?.value, event: event)
    }

    func mouseUp(in view: ResponseSelectableTextView, event: NSEvent) {
        guard isSelectionActive else {
            if event.clickCount == 1 {
                view.activateLink(atWindowPoint: event.locationInWindow)
            }
            return
        }
        presentActions()
    }

    func rightMouseDown(in view: ResponseSelectableTextView, event: NSEvent) {
        guard isSelectionActive,
              let position = position(atWindowPoint: event.locationInWindow, in: event.window),
              let range = TranscriptSelectionProjection.ranges(
                for: selection!,
                spans: orderedSpans
              )[position.spanID],
              NSLocationInRange(position.utf16Offset, range)
        else {
            view.activateLink(atWindowPoint: event.locationInWindow)
            return
        }
        TranscriptSelectionMenu.shared.presentResponseContextMenu(
            text: selectedText,
            from: view,
            at: view.convert(event.locationInWindow, from: nil)
        )
    }

    func selectAll() {
        guard let first = orderedSpans.first, let last = orderedSpans.last else { return }
        selection = TranscriptSelection(
            anchor: .init(spanID: first.id, utf16Offset: 0),
            focus: .init(spanID: last.id, utf16Offset: last.utf16Length)
        )
        applySelection()
        presentActions()
    }

    func moveFocus(by delta: Int) {
        guard delta != 0, let current = selection else { return }
        let ordered = orderedSpans
        guard let index = ordered.firstIndex(where: { $0.id == current.focus.spanID }) else { return }
        var nextIndex = index
        var offset = current.focus.utf16Offset + delta
        if offset < 0, index > 0 {
            nextIndex -= 1
            offset = ordered[nextIndex].utf16Length
        } else if offset > ordered[index].utf16Length, index + 1 < ordered.count {
            nextIndex += 1
            offset = 0
        }
        offset = min(max(offset, 0), ordered[nextIndex].utf16Length)
        selection = TranscriptSelection(
            anchor: current.anchor,
            focus: .init(spanID: ordered[nextIndex].id, utf16Offset: offset)
        )
        applySelection()
        presentActions()
    }

    func copySelection() {
        let text = selectedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearSelection() {
        let hadSelection = selection != nil
        selection = nil
        applySelection()
        if hadSelection {
            TranscriptSelectionMenu.shared.responseSelectionDidClear(self)
        }
    }

    private var orderedSpans: [TranscriptSelectionSpan] {
        spans.values.sorted { TranscriptSelectionProjection.pathIsBefore($0.treePath, $1.treePath) }
    }

    private func applySelection() {
        let ranges = selection.map {
            TranscriptSelectionProjection.ranges(for: $0, spans: orderedSpans)
        } ?? [:]
        for (id, box) in views {
            box.value?.setResponseSelectedRange(ranges[id] ?? NSRange(location: 0, length: 0))
        }
    }

    private func position(atWindowPoint point: NSPoint, in window: NSWindow?) -> TranscriptSelectionPosition? {
        let candidates = orderedSpans.compactMap { span -> (TranscriptSelectionSpan, ResponseSelectableTextView)? in
            guard let view = views[span.id]?.value, view.window === window, !view.isHidden else { return nil }
            return (span, view)
        }
        guard !candidates.isEmpty else { return nil }

        if let hit = candidates.first(where: { _, view in
            view.visibleRect.contains(view.convert(point, from: nil))
        }) {
            return .init(
                spanID: hit.0.id,
                utf16Offset: hit.1.characterIndex(atWindowPoint: point)
            )
        }

        let nearest = candidates.min { lhs, rhs in
            distance(from: point, to: lhs.1) < distance(from: point, to: rhs.1)
        }!
        let local = nearest.1.convert(point, from: nil)
        let rect = nearest.1.visibleRect
        let offset: Int
        if local.y < rect.minY {
            offset = 0
        } else if local.y > rect.maxY {
            offset = nearest.0.utf16Length
        } else {
            offset = local.x <= rect.midX ? 0 : nearest.0.utf16Length
        }
        return .init(spanID: nearest.0.id, utf16Offset: offset)
    }

    private func distance(from point: NSPoint, to view: NSView) -> CGFloat {
        let rect = view.convert(view.visibleRect, to: nil)
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func autoscrollTranscript(from view: NSView?, event: NSEvent) {
        var candidate = view
        var outermostScrollView: NSScrollView?
        while let current = candidate {
            if let scrollView = current as? NSScrollView {
                outermostScrollView = scrollView
            }
            candidate = current.superview
        }
        (outermostScrollView?.documentView ?? view)?.autoscroll(with: event)
    }

    private func presentActions() {
        guard let selection, !selectedText.isEmpty,
              let focusView = views[selection.focus.spanID]?.value
        else { return }
        TranscriptSelectionMenu.shared.presentResponseSelection(
            text: selectedText,
            from: focusView,
            anchor: focusView.selectionAnchorRect()
        )
    }
}

/// NSTextView leaf used only inside a response coordinator. It deliberately
/// handles selection itself instead of letting AppKit clamp a drag to this
/// view's text storage.
final class ResponseSelectableTextView: LocusSelectionTextView {
    weak var responseSelectionCoordinator: ResponseSelectionCoordinator?
    var responseSelectionSpanID: String?
    var onOpenURL: ((URL) -> Void)?

    /// Built against a hand-made TextKit 1 stack so inline-code runs can be
    /// drawn as rounded pills by `LocusMarkdownLayoutManager`.
    static func make() -> ResponseSelectableTextView {
        let stack = LocusSelectionTextView.makeTextKit1Stack()
        let view = ResponseSelectableTextView(frame: .zero, textContainer: stack.container)
        view.adoptTextKit1(storage: stack.storage)
        return view
    }

    override var acceptsFirstResponder: Bool { true }

    override func selectAll(_ sender: Any?) {
        responseSelectionCoordinator?.selectAll()
    }

    override func copy(_ sender: Any?) {
        responseSelectionCoordinator?.copySelection()
    }

    override func mouseDown(with event: NSEvent) {
        responseSelectionCoordinator?.mouseDown(in: self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        responseSelectionCoordinator?.mouseDragged(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        responseSelectionCoordinator?.mouseUp(in: self, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        responseSelectionCoordinator?.rightMouseDown(in: self, event: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            responseSelectionCoordinator?.selectAll()
            return
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            responseSelectionCoordinator?.copySelection()
            return
        }
        if event.keyCode == 53 {
            responseSelectionCoordinator?.clearSelection()
            return
        }
        if flags.contains(.shift), event.keyCode == 123 || event.keyCode == 124 {
            responseSelectionCoordinator?.moveFocus(by: event.keyCode == 123 ? -1 : 1)
            return
        }
        super.keyDown(with: event)
    }

    func setResponseSelectedRange(_ range: NSRange) {
        guard selectedRange() != range else { return }
        setSelectedRange(range)
    }

    func characterIndex(atWindowPoint point: NSPoint) -> Int {
        guard let layoutManager, let textContainer else { return 0 }
        var local = convert(point, from: nil)
        local.x -= textContainerOrigin.x
        local.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: local,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        let range = layoutManager.characterRange(
            forGlyphRange: NSRange(location: glyph, length: 1),
            actualGlyphRange: nil
        )
        let character = fraction > 0.5 ? NSMaxRange(range) : range.location
        return min(max(character, 0), (string as NSString).length)
    }

    func selectionAnchorRect() -> NSRect {
        let range = selectedRange()
        let character = max(range.location, NSMaxRange(range) - 1)
        guard let layoutManager, let textContainer, character < (string as NSString).length else {
            return NSRect(x: visibleRect.midX, y: visibleRect.midY, width: 1, height: 1)
        }
        let glyph = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: character, length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyph, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    func activateLink(atWindowPoint point: NSPoint) {
        let index = characterIndex(atWindowPoint: point)
        guard index < textStorage?.length ?? 0,
              let value = textStorage?.attribute(.link, at: index, effectiveRange: nil)
        else { return }
        let url: URL?
        if let value = value as? URL { url = value }
        else if let value = value as? String { url = URL(string: value) }
        else { url = nil }
        guard let url else { return }
        if let onOpenURL { onOpenURL(url) } else { NSWorkspace.shared.open(url) }
    }
}

struct ResponseSelectableText: NSViewRepresentable {
    let attributedText: NSAttributedString
    let span: TranscriptSelectionSpan
    let coordinator: ResponseSelectionCoordinator
    var wraps = true
    var onOpenURL: ((URL) -> Void)?

    func makeNSView(context: Context) -> ResponseSelectableTextView {
        let view = ResponseSelectableTextView.make()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = true
        configureWidth(of: view)
        update(view)
        return view
    }

    func updateNSView(_ nsView: ResponseSelectableTextView, context: Context) {
        configureWidth(of: nsView)
        update(nsView)
    }

    static func dismantleNSView(_ nsView: ResponseSelectableTextView, coordinator: ()) {
        guard let owner = nsView.responseSelectionCoordinator,
              let spanID = nsView.responseSelectionSpanID
        else { return }
        owner.unregister(spanID: spanID, view: nsView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ResponseSelectableTextView,
        context: Context
    ) -> CGSize? {
        let width: CGFloat
        if wraps {
            guard let proposed = proposal.width, proposed > 0 else { return nil }
            width = proposed
        } else {
            width = max(nsView.attributedString().size().width.rounded(.up) + 2, 1)
        }
        guard let layoutManager = nsView.layoutManager, let container = nsView.textContainer else {
            return nil
        }
        container.containerSize = NSSize(
            width: wraps ? width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: container)
        let height = max(layoutManager.usedRect(for: container).height.rounded(.up), 1)
        return CGSize(width: width, height: height)
    }

    private func update(_ view: ResponseSelectableTextView) {
        if !view.attributedString().isEqual(to: attributedText) {
            view.textStorage?.setAttributedString(attributedText)
        }
        // The wash follows the accent, so it is re-resolved on every update
        // rather than only at construction.
        view.refreshSelectionWash()
        view.onOpenURL = onOpenURL
        coordinator.register(span, view: view)
        view.invalidateIntrinsicContentSize()
    }

    private func configureWidth(of view: ResponseSelectableTextView) {
        view.isHorizontallyResizable = !wraps
        view.textContainer?.widthTracksTextView = wraps
        view.autoresizingMask = wraps ? [.width] : []
        if !wraps {
            view.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }
}
