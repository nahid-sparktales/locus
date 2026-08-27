import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Baseline attributes for notes text. The plain `.txt` mirror stays the
/// canonical content the agent tools and older builds read, so every visual
/// default must be reconstructible from bare text.
enum NotesTextStyle {
    static let defaultFontSize: CGFloat = 13
    static let fontSizes: [CGFloat] = [11, 12, 13, 14, 16, 18, 21, 24]

    static var defaultFont: NSFont { .systemFont(ofSize: defaultFontSize) }

    /// `labelColor` matches what the previous plain `TextEditor` rendered and
    /// survives keyed archiving as a catalog color, so stored notes keep
    /// adapting to light and dark appearances.
    static var defaultColor: NSColor { .labelColor }

    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: defaultFont, .foregroundColor: defaultColor]
    }

    static func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: typingAttributes)
    }

    /// Accent colors are fixed mid-tones that stay readable on both paper
    /// appearances; dynamic provider colors cannot be archived.
    static let accents: [(name: String, color: NSColor)] = [
        ("Coral", fixed(0xC9573C)),
        ("Amber", fixed(0xB07A28)),
        ("Green", fixed(0x4E9A5E)),
        ("Blue", fixed(0x5B7FE0)),
        ("Purple", fixed(0x8B6BC8)),
        ("Gray", fixed(0x8A8678)),
    ]

    private static func fixed(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Line markers the insert menu writes. They are ordinary text so the plain
/// `.txt` mirror — the copy the agent's notes tools read — keeps its meaning.
enum NotesListKind {
    case bullet
    case numbered
    case checklist
}

enum NotesMarkers {
    static let bullet = "- "
    static let unchecked = "- [ ] "
    static let checked = "- [x] "
    static let divider = "\n———\n"

    /// Splits a line into its list marker, if any, and the rest. Checkbox
    /// markers are tested before the bullet they start with, and numbering is
    /// matched at any width so "12. " round-trips like "1. ".
    static func strippingMarker(_ line: String) -> (rest: String, kind: NotesListKind?) {
        for marker in [unchecked, checked] where line.hasPrefix(marker) {
            return (String(line.dropFirst(marker.count)), .checklist)
        }
        if line.hasPrefix(bullet) {
            return (String(line.dropFirst(bullet.count)), .bullet)
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return (String(line.dropFirst(digits.count + 2)), .numbered)
        }
        return (line, nil)
    }
}

/// One durable notes document. Workspace-scoped documents use their own
/// directory, while chat-scoped documents deliberately keep the original
/// key and `Chat Notes` location so notes created by older Locus builds remain
/// available when the user chooses the per-chat setting.
@MainActor
final class NotesStore: ObservableObject {
    static let maximumCharacters = 100_000
    static let maximumReadCharacters = 30_000

    private static var stores: [String: NotesStore] = [:]

    @Published private(set) var text = ""
    @Published private(set) var attributedText: NSAttributedString = NSAttributedString()
    /// Drives the editor's saved indicator. Saving is debounced, so without
    /// this the only feedback for an unwritten edit is the file itself.
    @Published private(set) var hasUnsavedChanges = false

    let scope: NotesScope
    let fileURL: URL
    /// Keyed-archive sibling that carries the formatting for `fileURL`'s
    /// content. It is honored only while its string matches the plain mirror,
    /// so a `.txt` written by an older build or edited elsewhere wins.
    let styledFileURL: URL
    private var pendingSave: DispatchWorkItem?

    static func shared(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> NotesStore {
        let descriptor = storageDescriptor(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        )
        if let existing = stores[descriptor.cacheKey] { return existing }
        let store = NotesStore(
            storageKey: descriptor.storageKey,
            directoryName: descriptor.directoryName,
            scope: scope,
            applicationSupport: applicationSupportDirectory
        )
        stores[descriptor.cacheKey] = store
        return store
    }

    static func storageIdentity(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> String {
        storageDescriptor(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        ).cacheKey
    }

    /// A non-shared store keeps persistence tests out of the user's real
    /// Application Support folder.
    static func testingStore(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope,
        applicationSupport: URL
    ) -> NotesStore {
        let descriptor = storageDescriptor(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        )
        return NotesStore(
            storageKey: descriptor.storageKey,
            directoryName: descriptor.directoryName,
            scope: scope,
            applicationSupport: applicationSupport
        )
    }

    private static var applicationSupportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    private static func storageDescriptor(
        workspacePath: String,
        sessionID: String,
        scope: NotesScope
    ) -> (cacheKey: String, storageKey: String, directoryName: String) {
        let canonicalWorkspace = SessionSummary.canonicalWorkspacePath(workspacePath)
        switch scope {
        case .workspace:
            return (
                "workspace\u{0}" + canonicalWorkspace,
                canonicalWorkspace,
                "Workspace Notes"
            )
        case .chat:
            let trimmedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalSession = trimmedSession.isEmpty ? "pending-chat" : trimmedSession
            // This is the exact pre-workspace-scope key.
            let legacyKey = canonicalWorkspace + "\u{0}" + canonicalSession
            return ("chat\u{0}" + legacyKey, legacyKey, "Chat Notes")
        case .global:
            // One document for the whole app: the key deliberately ignores
            // both the workspace and the chat.
            return ("global", "global", "Shared Notes")
        }
    }

    private init(
        storageKey: String,
        directoryName: String,
        scope: NotesScope,
        applicationSupport: URL
    ) {
        self.scope = scope
        let digest = SHA256.hash(data: Data(storageKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = applicationSupport
            .appendingPathComponent("Locus", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        fileURL = directory.appendingPathComponent("\(digest).txt")
        styledFileURL = directory.appendingPathComponent("\(digest).styled")
        let plain = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        text = plain
        if let data = try? Data(contentsOf: styledFileURL),
           let archived = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: NSAttributedString.self,
               from: data
           ),
           archived.string == plain
        {
            attributedText = archived
        } else {
            attributedText = NotesTextStyle.plain(plain)
        }
    }

    /// Plain-text update path. Kept for callers that have no formatting to
    /// offer; it deliberately resets styling to the defaults.
    func update(_ value: String) {
        guard text != value else { return }
        text = value
        attributedText = NotesTextStyle.plain(value)
        scheduleSave()
    }

    /// Editor update path: the attributed string is the source of truth and
    /// the plain mirror is derived from it.
    func updateAttributed(_ value: NSAttributedString) {
        guard !attributedText.isEqual(to: value) else { return }
        let copy = NSAttributedString(attributedString: value)
        attributedText = copy
        text = copy.string
        scheduleSave()
    }

    func exportPlainText(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func exportRichText(to url: URL) throws {
        let data = try attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try data.write(to: url, options: .atomic)
    }

    /// Execute the small native Notes tool family. The agent cannot select a
    /// path, workspace, or chat: AppModel resolves the owning store from the
    /// socket that made the request before this method is called.
    func perform(tool: String, arguments: [String: Any]) -> [String: Any] {
        switch tool {
        case "notes_read":
            let requestedLimit = arguments["max_chars"] as? Int ?? Self.maximumReadCharacters
            let limit = min(max(requestedLimit, 1), Self.maximumReadCharacters)
            let truncated = text.count > limit
            let visible = String(text.prefix(limit))
            let content = visible.isEmpty ? "Notes are empty." : visible
            let suffix = truncated ? "\n\n[Notes truncated at \(limit) characters.]" : ""
            return [
                "text": content + suffix,
                "scope": scope.rawValue,
                "truncated": truncated,
            ]

        case "notes_update":
            guard let incoming = arguments["text"] as? String else {
                return ["error": "notes_update requires text."]
            }
            let action = (arguments["action"] as? String) ?? "replace"
            let updated: String
            let updatedAttributed: NSAttributedString
            switch action {
            case "replace":
                updated = incoming
                updatedAttributed = NotesTextStyle.plain(incoming)
            case "append":
                // Build the appended tail once and reuse it for both strings:
                // deriving it from `updated` by character count would miscount
                // when the separator merges with a trailing "\r" into a single
                // "\r\n" grapheme, silently desynchronizing the two.
                let separator = (text.isEmpty || incoming.isEmpty || text.hasSuffix("\n"))
                    ? "" : "\n"
                updated = text + separator + incoming
                // Appending keeps the user's existing formatting; only the
                // agent's new lines arrive with default styling.
                let combined = NSMutableAttributedString(attributedString: attributedText)
                combined.append(NotesTextStyle.plain(separator + incoming))
                updatedAttributed = combined
            default:
                return ["error": "Unknown notes_update action: \(action)."]
            }
            guard updated.count <= Self.maximumCharacters else {
                return [
                    "error": "Notes are limited to \(Self.maximumCharacters) characters."
                ]
            }
            text = updated
            attributedText = updatedAttributed
            pendingSave?.cancel()
            pendingSave = nil
            hasUnsavedChanges = true
            if let error = save() {
                return ["error": "Could not save notes: \(error.localizedDescription)"]
            }
            return [
                "text": action == "append" ? "Appended to notes." : "Replaced notes.",
                "scope": scope.rawValue,
                "character_count": updated.count,
            ]

        default:
            return ["error": "Unknown Notes tool: \(tool)."]
        }
    }

    func flushForTesting() {
        pendingSave?.cancel()
        pendingSave = nil
        _ = save()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        hasUnsavedChanges = true
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in _ = self?.save() }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    @discardableResult
    private func save() -> Error? {
        pendingSave = nil
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            // Styling is best-effort: the plain mirror above already holds the
            // content, and a stale archive is ignored on load.
            if let styled = try? NSKeyedArchiver.archivedData(
                withRootObject: attributedText,
                requiringSecureCoding: true
            ) {
                try? styled.write(to: styledFileURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: styledFileURL.path
                )
            }
            hasUnsavedChanges = false
            return nil
        } catch {
            // UI edits retain the latest text in memory and retry next time.
            return error
        }
    }
}

/// Bridges the AppKit editor and the SwiftUI toolbar: formatting commands in
/// one direction, selection state in the other.
@MainActor
final class NotesEditorProxy: ObservableObject {
    weak var textView: NSTextView?

    @Published var isBold = false
    @Published var isItalic = false
    @Published var isUnderlined = false
    @Published var isStruckThrough = false
    @Published var fontSize: CGFloat = NotesTextStyle.defaultFontSize
    @Published var selectionColor: NSColor = NotesTextStyle.defaultColor

    func toggleBold() { toggleFontTrait(.boldFontMask, isActive: isBold) }
    func toggleItalic() { toggleFontTrait(.italicFontMask, isActive: isItalic) }

    func toggleUnderline() {
        toggleLine(.underlineStyle, isActive: isUnderlined)
    }

    func toggleStrikethrough() {
        toggleLine(.strikethroughStyle, isActive: isStruckThrough)
    }

    func setFontSize(_ size: CGFloat) {
        let manager = NSFontManager.shared
        mutateSelection { storage, range in
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = value as? NSFont ?? NotesTextStyle.defaultFont
                storage.addAttribute(.font, value: manager.convert(font, toSize: size), range: subrange)
            }
        } typing: { attributes in
            let font = attributes[.font] as? NSFont ?? NotesTextStyle.defaultFont
            attributes[.font] = manager.convert(font, toSize: size)
        }
    }

    func setTextColor(_ color: NSColor) {
        mutateSelection { storage, range in
            storage.addAttribute(.foregroundColor, value: color, range: range)
        } typing: { attributes in
            attributes[.foregroundColor] = color
        }
    }

    /// Insert text at the cursor with the current typing attributes, as if it
    /// had been typed — so undo, selection, and styling all behave normally.
    func insert(_ string: String) {
        guard let textView else { return }
        if textView.shouldChangeText(in: textView.selectedRange(), replacementString: string) {
            textView.insertText(string, replacementRange: textView.selectedRange())
            textView.didChangeText()
        }
        refreshState()
    }

    /// Apply `kind` to every line the selection touches, or strip the markers
    /// when those lines already are that kind of list. Markers are plain text
    /// so the `.txt` mirror the agent reads stays meaningful.
    func toggleList(_ kind: NotesListKind) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let lineRange = (storage.string as NSString).lineRange(
            for: NSRange(location: min(selection.location, storage.length), length: selection.length)
        )
        let text = (storage.string as NSString).substring(with: lineRange)
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        guard !lines.isEmpty else { return }
        let parsed = lines.map(NotesMarkers.strippingMarker)
        // Already this kind of list, so the same action turns it back off.
        let isAlreadyKind = parsed.allSatisfy { $0.kind == kind }
        let rewritten = parsed.enumerated().map { index, line -> String in
            guard !isAlreadyKind else { return line.rest }
            switch kind {
            case .bullet: return NotesMarkers.bullet + line.rest
            case .numbered: return "\(index + 1). " + line.rest
            case .checklist: return NotesMarkers.unchecked + line.rest
            }
        }
        let replacement = rewritten.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
        guard textView.shouldChangeText(in: lineRange, replacementString: replacement) else { return }
        storage.replaceCharacters(in: lineRange, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(
            NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
        refreshState()
    }

    /// A checklist line cycles unchecked → checked → plain, which is the
    /// behaviour people expect from a single button.
    func toggleChecklist() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let lineRange = (storage.string as NSString).lineRange(
            for: NSRange(location: min(selection.location, storage.length), length: selection.length)
        )
        let line = (storage.string as NSString).substring(with: lineRange)
        if line.hasPrefix(NotesMarkers.unchecked) {
            replaceLinePrefix(
                NotesMarkers.unchecked,
                with: NotesMarkers.checked,
                in: lineRange,
                textView: textView,
                storage: storage
            )
        } else if line.hasPrefix(NotesMarkers.checked) {
            replaceLinePrefix(
                NotesMarkers.checked,
                with: "",
                in: lineRange,
                textView: textView,
                storage: storage
            )
        } else {
            toggleList(.checklist)
        }
    }

    private func replaceLinePrefix(
        _ prefix: String,
        with replacement: String,
        in lineRange: NSRange,
        textView: NSTextView,
        storage: NSTextStorage
    ) {
        let target = NSRange(location: lineRange.location, length: (prefix as NSString).length)
        guard textView.shouldChangeText(in: target, replacementString: replacement) else { return }
        storage.replaceCharacters(in: target, with: replacement)
        textView.didChangeText()
        refreshState()
    }

    /// Opens the text view's own find bar, which the editor already enables.
    func showFindBar() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        // performTextFinderAction reads the action off the sender's tag.
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(sender)
    }

    func clearFormatting() {
        mutateSelection { storage, range in
            storage.setAttributes(NotesTextStyle.typingAttributes, range: range)
        } typing: { attributes in
            attributes = NotesTextStyle.typingAttributes
        }
    }

    func refreshState() {
        guard let textView else { return }
        let attributes: [NSAttributedString.Key: Any]
        let selection = textView.selectedRange()
        if selection.length > 0,
           let storage = textView.textStorage,
           selection.location < storage.length
        {
            attributes = storage.attributes(at: selection.location, effectiveRange: nil)
        } else {
            attributes = textView.typingAttributes
        }
        let font = attributes[.font] as? NSFont ?? NotesTextStyle.defaultFont
        let traits = NSFontManager.shared.traits(of: font)
        setIfChanged(\.isBold, traits.contains(.boldFontMask))
        setIfChanged(\.isItalic, traits.contains(.italicFontMask))
        setIfChanged(\.isUnderlined, (attributes[.underlineStyle] as? Int ?? 0) != 0)
        setIfChanged(\.isStruckThrough, (attributes[.strikethroughStyle] as? Int ?? 0) != 0)
        setIfChanged(\.fontSize, font.pointSize)
        let color = attributes[.foregroundColor] as? NSColor ?? NotesTextStyle.defaultColor
        if !selectionColor.isEqual(color) { selectionColor = color }
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<NotesEditorProxy, Value>,
        _ value: Value
    ) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func toggleFontTrait(_ mask: NSFontTraitMask, isActive: Bool) {
        let manager = NSFontManager.shared
        mutateSelection { storage, range in
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = value as? NSFont ?? NotesTextStyle.defaultFont
                let converted = isActive
                    ? manager.convert(font, toNotHaveTrait: mask)
                    : manager.convert(font, toHaveTrait: mask)
                storage.addAttribute(.font, value: converted, range: subrange)
            }
        } typing: { attributes in
            let font = attributes[.font] as? NSFont ?? NotesTextStyle.defaultFont
            attributes[.font] = isActive
                ? manager.convert(font, toNotHaveTrait: mask)
                : manager.convert(font, toHaveTrait: mask)
        }
    }

    private func toggleLine(_ key: NSAttributedString.Key, isActive: Bool) {
        mutateSelection { storage, range in
            if isActive {
                storage.removeAttribute(key, range: range)
            } else {
                storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        } typing: { attributes in
            if isActive {
                attributes[key] = nil
            } else {
                attributes[key] = NSUnderlineStyle.single.rawValue
            }
        }
    }

    /// Apply a formatting change to every selected range with undo support,
    /// and mirror it into the typing attributes so a collapsed cursor keeps
    /// the chosen style for the next characters.
    private func mutateSelection(
        _ body: (NSTextStorage, NSRange) -> Void,
        typing: (inout [NSAttributedString.Key: Any]) -> Void
    ) {
        guard let textView, let storage = textView.textStorage else { return }
        let ranges = textView.selectedRanges
            .map(\.rangeValue)
            .filter { $0.length > 0 && NSMaxRange($0) <= storage.length }
        if !ranges.isEmpty,
           textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil)
        {
            storage.beginEditing()
            for range in ranges { body(storage, range) }
            storage.endEditing()
            textView.didChangeText()
        }
        var attributes = textView.typingAttributes
        typing(&attributes)
        textView.typingAttributes = attributes
        refreshState()
    }
}

/// No menu item owns ⌘B/⌘I/⌘U in this app, so the notes editor claims them
/// itself while it is first responder; every other key path stays stock.
private final class NotesTextView: NSTextView {
    var toggleBoldCommand: (() -> Void)?
    var toggleItalicCommand: (() -> Void)?
    var toggleUnderlineCommand: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": toggleBoldCommand?(); return true
            case "i": toggleItalicCommand?(); return true
            case "u": toggleUnderlineCommand?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Rich-text replacement for the plain notes `TextEditor`. The scroll view
/// and text view come from AppKit so bold, italic, color, undo, and the
/// ⌘B/⌘I/⌘U key equivalents behave like every other Mac editor.
private struct RichNotesEditor: NSViewRepresentable {
    @ObservedObject var store: NotesStore
    let proxy: NotesEditorProxy
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, proxy: proxy)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NotesTextView.scrollableTextView()
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesFindBar = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.typingAttributes = NotesTextStyle.typingAttributes
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(store.attributedText)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityIdentifier("notes.editor")
        if let notesTextView = textView as? NotesTextView {
            notesTextView.toggleBoldCommand = { [weak proxy] in proxy?.toggleBold() }
            notesTextView.toggleItalicCommand = { [weak proxy] in proxy?.toggleItalic() }
            notesTextView.toggleUnderlineCommand = { [weak proxy] in proxy?.toggleUnderline() }
        }
        context.coordinator.textView = textView
        proxy.textView = textView
        // makeNSView runs inside a SwiftUI update pass; publishing toolbar
        // state here would be a publish-during-update violation.
        DispatchQueue.main.async { [weak proxy] in proxy?.refreshState() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.store = store
        proxy.textView = textView
        textView.setAccessibilityLabel(accessibilityLabel)
        // Only external updates (agent tools) can differ from the text view;
        // the editor's own edits already match the store. Applying them here
        // would mutate state and publish toolbar changes inside the current
        // update pass, so the coordinator defers the reconciliation.
        context.coordinator.scheduleExternalReconciliation()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var store: NotesStore
        let proxy: NotesEditorProxy
        weak var textView: NSTextView?
        private var reconciliationScheduled = false

        init(store: NotesStore, proxy: NotesEditorProxy) {
            self.store = store
            self.proxy = proxy
        }

        func scheduleExternalReconciliation() {
            guard !reconciliationScheduled else { return }
            reconciliationScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.reconciliationScheduled = false
                self?.applyExternalContentIfNeeded()
            }
        }

        private func applyExternalContentIfNeeded() {
            guard let textView, let storage = textView.textStorage else { return }
            let target = store.attributedText
            guard !storage.isEqual(to: target) else { return }
            let selection = textView.selectedRange()
            storage.setAttributedString(target)
            let location = min(selection.location, storage.length)
            let length = min(selection.length, storage.length - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            // The replacement bypassed the shouldChangeText/didChangeText
            // pair, so recorded undo operations point into the old text;
            // replaying one would splice stale content or raise a range
            // exception. Dropping the stack is the safe trade.
            textView.breakUndoCoalescing()
            textView.undoManager?.removeAllActions()
            proxy.refreshState()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            store.updateAttributed(storage)
            proxy.refreshState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            proxy.refreshState()
        }

        func textViewDidChangeTypingAttributes(_ notification: Notification) {
            proxy.refreshState()
        }
    }
}

/// SwiftUI's macOS `Menu` treats its symbol column as template artwork, which
/// strips the actual accent from colored SF Symbol swatches. A native pop-up
/// button keeps each menu item's image in original-color rendering while still
/// providing the standard keyboard, VoiceOver, selection, and dismissal behavior.
private struct NotesColorMenuButton: NSViewRepresentable {
    let selectionColor: NSColor
    let selectionName: String
    let onSelect: (NSColor) -> Void

    private var options: [(name: String, color: NSColor)] {
        [("Default", NotesTextStyle.defaultColor)] + NotesTextStyle.accents
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.toolTip = "Text color"
        button.setAccessibilityLabel("Text color")
        button.setAccessibilityIdentifier("notes.toolbar.textColor")
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.arrowPosition = .noArrow
            cell.imagePosition = .imageOnly
        }
        configure(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        configure(button)
    }

    private func configure(_ button: NSPopUpButton) {
        if button.numberOfItems != options.count {
            button.removeAllItems()
            for option in options {
                button.addItem(withTitle: option.name)
                button.lastItem?.representedObject = option.color
            }
        }

        for (index, option) in options.enumerated() {
            guard let item = button.item(at: index) else { continue }
            item.representedObject = option.color
            item.image = Self.swatchImage(
                color: option.color,
                appearance: button.effectiveAppearance
            )
        }
        let selectedIndex = options.firstIndex {
            selectionColor.isEqual($0.color)
        } ?? 0
        button.selectItem(at: selectedIndex)
        button.setAccessibilityValue(selectionName)
    }

    private static func swatchImage(color: NSColor, appearance: NSAppearance) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.25, dy: 1.25))
                color.setFill()
                path.fill()
                NSColor.separatorColor.withAlphaComponent(0.72).setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Color swatch"
        return image
    }

    final class Coordinator: NSObject {
        var onSelect: (NSColor) -> Void

        init(onSelect: @escaping (NSColor) -> Void) {
            self.onSelect = onSelect
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let color = sender.selectedItem?.representedObject as? NSColor else { return }
            onSelect(color)
        }
    }
}

/// The formatting and export bar above the notes editor.
private struct NotesFormatToolbar: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var proxy: NotesEditorProxy
    let workspacePath: String

    var body: some View {
        HStack(spacing: 2) {
            traitButton(
                symbol: "bold",
                active: proxy.isBold,
                help: "Bold (⌘B)",
                identifier: "notes.toolbar.bold"
            ) { proxy.toggleBold() }
            traitButton(
                symbol: "italic",
                active: proxy.isItalic,
                help: "Italic (⌘I)",
                identifier: "notes.toolbar.italic"
            ) { proxy.toggleItalic() }
            traitButton(
                symbol: "underline",
                active: proxy.isUnderlined,
                help: "Underline (⌘U)",
                identifier: "notes.toolbar.underline"
            ) { proxy.toggleUnderline() }
            traitButton(
                symbol: "strikethrough",
                active: proxy.isStruckThrough,
                help: "Strikethrough",
                identifier: "notes.toolbar.strikethrough"
            ) { proxy.toggleStrikethrough() }

            toolbarDivider

            sizeMenu
            colorMenu

            toolbarDivider

            insertMenu

            Spacer(minLength: 2)

            overflowMenu
        }
        .padding(.horizontal, 7)
        .frame(height: 34)
        .background(LocusTheme.paperDeep.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes.toolbar")
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(LocusTheme.line)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }

    private func traitButton(
        symbol: String,
        active: Bool,
        help: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(active ? LocusTheme.paper : LocusTheme.muted)
                .frame(width: 24, height: 24)
                .background(active ? LocusTheme.ink : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.locus(.icon))
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityIdentifier(identifier)
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(NotesTextStyle.fontSizes, id: \.self) { size in
                Button {
                    proxy.setFontSize(size)
                } label: {
                    Label(
                        "\(Int(size)) pt",
                        systemImage: abs(proxy.fontSize - size) < 0.5 ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "textformat.size")
                    .font(.locus(size: 10, weight: .semibold))
                Text("\(Int(proxy.fontSize))")
                    .font(.locus(size: 9, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(LocusTheme.muted)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Text size")
        .accessibilityLabel("Text size")
        .accessibilityValue("\(Int(proxy.fontSize)) points")
        .accessibilityIdentifier("notes.toolbar.fontSize")
    }

    private var colorMenu: some View {
        NotesColorMenuButton(
            selectionColor: proxy.selectionColor,
            selectionName: currentColorName,
            onSelect: proxy.setTextColor
        )
        .frame(width: 24, height: 24)
        .help("Text color")
        .accessibilityLabel("Text color")
        .accessibilityValue(currentColorName)
    }

    private var currentColorName: String {
        if proxy.selectionColor.isEqual(NotesTextStyle.defaultColor) { return "Default" }
        return NotesTextStyle.accents.first {
            proxy.selectionColor.isEqual($0.color)
        }?.name ?? "Custom"
    }

    private var insertMenu: some View {
        Menu {
            Button("Checklist Item", systemImage: "checklist") { proxy.toggleChecklist() }
                .accessibilityIdentifier("notes.insert.checklist")
            Button("Bulleted List", systemImage: "list.bullet") { proxy.toggleList(.bullet) }
                .accessibilityIdentifier("notes.insert.bullet")
            Button("Numbered List", systemImage: "list.number") { proxy.toggleList(.numbered) }
                .accessibilityIdentifier("notes.insert.numbered")
            Divider()
            Button("Date & Time", systemImage: "clock") { proxy.insert(timestamp()) }
                .accessibilityIdentifier("notes.insert.timestamp")
            Button("Divider", systemImage: "minus") { proxy.insert(NotesMarkers.divider) }
                .accessibilityIdentifier("notes.insert.divider")
        } label: {
            Image(systemName: "list.bullet.indent")
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a list, checklist, timestamp, or divider")
        .accessibilityLabel("Insert")
        .accessibilityIdentifier("notes.toolbar.insert")
    }

    /// Everything that acts on the document as a whole. Keeping it behind one
    /// glyph leaves the formatting controls uncrowded at every panel width.
    private var overflowMenu: some View {
        Menu {
            Button("Clear Formatting", systemImage: "eraser") { proxy.clearFormatting() }
                .accessibilityIdentifier("notes.toolbar.clearFormatting")
            Button("Find in Notes…", systemImage: "magnifyingglass") { proxy.showFindBar() }
                .accessibilityIdentifier("notes.find")
            Divider()
            Button("Copy All", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.text, forType: .string)
            }
            .disabled(store.text.isEmpty)
            .accessibilityIdentifier("notes.copyAll")
            Button("Export as Text File…", systemImage: "arrow.down.document") {
                export(rich: false)
            }
            .disabled(store.text.isEmpty)
            .accessibilityIdentifier("notes.export.text")
            Button("Export as Rich Text…", systemImage: "arrow.down.document") {
                export(rich: true)
            }
            .disabled(store.text.isEmpty)
            .accessibilityIdentifier("notes.export.rtf")
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More note actions")
        .accessibilityLabel("More note actions")
        .accessibilityIdentifier("notes.toolbar.more")
    }

    private func timestamp() -> String {
        Date().formatted(date: .abbreviated, time: .shortened) + " — "
    }

    private func export(rich: Bool) {
        let panel = NSSavePanel()
        panel.title = rich ? "Export Notes as Rich Text" : "Export Notes as Text"
        panel.nameFieldStringValue = rich ? "Notes.rtf" : "Notes.txt"
        panel.allowedContentTypes = [rich ? .rtf : .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if FileManager.default.fileExists(atPath: workspacePath) {
            panel.directoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if rich {
                try store.exportRichText(to: url)
            } else {
                try store.exportPlainText(to: url)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not export notes"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// Identity strip above the toolbar: which document is open, whether the last
/// keystroke has landed on disk, and how much is in it.
private struct NotesHeaderBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: NotesStore
    let workspaceName: String

    /// List markers are punctuation, not words: counting the raw text would
    /// report three extra "words" for every checklist line.
    private var wordCount: Int {
        store.text
            .components(separatedBy: "\n")
            .map { NotesMarkers.strippingMarker($0).rest }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .count
    }

    /// Checklists are a first-class insert action, so a note that has them
    /// gets its progress read back at a glance.
    private var checklistProgress: (done: Int, total: Int)? {
        var done = 0
        var total = 0
        for line in store.text.components(separatedBy: "\n") {
            if line.hasPrefix(NotesMarkers.checked) {
                done += 1
                total += 1
            } else if line.hasPrefix(NotesMarkers.unchecked) {
                total += 1
            }
        }
        return total > 0 ? (done, total) : nil
    }

    /// Only worth showing as the 100,000-character ceiling comes into view.
    private var nearsLimit: Bool {
        store.text.count > Int(Double(NotesStore.maximumCharacters) * 0.8)
    }

    private var subtitle: String {
        switch store.scope {
        case .workspace: workspaceName
        case .chat: "This chat only"
        case .global: "Every chat, every workspace"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(NotesScope.allCases) { scope in
                    Button {
                        model.settings.notesScopeRaw = scope.rawValue
                    } label: {
                        Label(
                            scope.title,
                            systemImage: scope == store.scope ? "checkmark" : scope.symbol
                        )
                    }
                    .accessibilityIdentifier("notes.scope.\(scope.rawValue)")
                }
            } label: {
                // One line of glyph and text: a borderless menu flattens a
                // stacked label down to its first row.
                HStack(spacing: 6) {
                    Image(systemName: store.scope.symbol)
                        .font(.locus(size: 10, weight: .medium))
                        .foregroundStyle(LocusTheme.muted)
                    Text(store.scope.documentTitle)
                        .font(.locus(size: 10, weight: .semibold))
                        .foregroundStyle(LocusTheme.ink)
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            // A trailing chevron inside the label is dropped along with
            // everything after the first text, so use the native indicator.
            .menuIndicator(.visible)
            .fixedSize()
            .help("Choose which conversations share these notes")
            .accessibilityLabel("Notes scope")
            .accessibilityValue(store.scope.accessibilityLabel)
            .accessibilityIdentifier("notes.scopeMenu")

            Text(subtitle)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .accessibilityIdentifier("notes.scopeDetail")

            Spacer(minLength: 4)

            if let progress = checklistProgress {
                HStack(spacing: 4) {
                    Image(systemName: progress.done == progress.total
                        ? "checkmark.circle.fill" : "checklist")
                        .font(.locus(size: 9, weight: .medium))
                    Text("\(progress.done)/\(progress.total)")
                        .font(.locus(size: 8, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(progress.done == progress.total
                    ? LocusTheme.success : LocusTheme.muted)
                .help("\(progress.done) of \(progress.total) checklist items done")
                .accessibilityLabel(
                    "\(progress.done) of \(progress.total) checklist items done"
                )
                .accessibilityIdentifier("notes.checklistProgress")
            }

            if !store.text.isEmpty {
                Text(nearsLimit
                    ? "\(store.text.count.formatted()) / \(NotesStore.maximumCharacters.formatted()) characters"
                    : "\(wordCount.formatted()) \(wordCount == 1 ? "word" : "words")")
                    .font(.locus(size: 8))
                    .foregroundStyle(nearsLimit ? LocusTheme.warning : LocusTheme.muted)
                    .accessibilityIdentifier("notes.wordCount")
            }

            Image(systemName: store.hasUnsavedChanges ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .font(.locus(size: 9, weight: .medium))
                .foregroundStyle(store.hasUnsavedChanges ? LocusTheme.muted : LocusTheme.success)
                .help(store.hasUnsavedChanges ? "Saving…" : "Saved")
                .accessibilityLabel(store.hasUnsavedChanges ? "Saving" : "Saved")
                .accessibilityIdentifier("notes.saveState")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(LocusTheme.paperDeep.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes.header")
    }
}

struct InspectorNotesTab: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var store: NotesStore
    @StateObject private var proxy = NotesEditorProxy()
    private let workspacePath: String

    init(workspacePath: String, sessionID: String, scope: NotesScope) {
        self.workspacePath = workspacePath
        _store = StateObject(wrappedValue: NotesStore.shared(
            workspacePath: workspacePath,
            sessionID: sessionID,
            scope: scope
        ))
    }

    private var workspaceName: String {
        URL(fileURLWithPath: workspacePath).lastPathComponent.nilIfEmpty ?? "This workspace"
    }

    var body: some View {
        VStack(spacing: 0) {
            NotesHeaderBar(store: store, workspaceName: workspaceName)
            NotesFormatToolbar(store: store, proxy: proxy, workspacePath: workspacePath)
            RichNotesEditor(
                store: store,
                proxy: proxy,
                accessibilityLabel: store.scope.accessibilityLabel
            )
            .overlay(alignment: .topLeading) {
                if store.text.isEmpty {
                    // A hint rather than a placeholder string in the document:
                    // the editor stays genuinely empty underneath it.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing here yet")
                            .font(.locus(size: 11, weight: .semibold))
                            .foregroundStyle(LocusTheme.inkSoft)
                        Text("Jot down anything worth keeping. The agent can read and append to these notes when you ask it to.")
                            .font(.locus(size: 9))
                            .foregroundStyle(LocusTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                    // The editor's own accessibility label already says which
                    // notes these are, so the hint is decorative.
                    .accessibilityHidden(true)
                }
            }
        }
        .background(LocusTheme.paper)
    }
}
