import AppKit

extension NSAttributedString.Key {
    /// Fill colour for the rounded inline-code pill drawn by
    /// `LocusMarkdownLayoutManager`. The value is an `NSColor`.
    ///
    /// This exists because `.backgroundColor` cannot express a pill: AppKit
    /// paints it as a hard-edged rectangle flush against the glyphs and clipped
    /// to the line box, with no way to inset, pad, or round it.
    static let locusInlineCodePill = NSAttributedString.Key("locusInlineCodePill")
}

/// Draws the inline-code pill behind runs carrying `.locusInlineCodePill`.
///
/// The pill is painted before `super`, so the selection wash and any ordinary
/// `.backgroundColor` runs composite on top of it rather than being hidden by it.
final class LocusMarkdownLayoutManager: NSLayoutManager {
    private let horizontalInset: CGFloat = 3
    private let verticalInset: CGFloat = 1.5
    private let cornerRadius: CGFloat = 4

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawInlineCodePills(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawInlineCodePills(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard glyphsToShow.length > 0,
              let textStorage,
              let container = textContainer(
                  forGlyphAt: glyphsToShow.location,
                  effectiveRange: nil
              )
        else { return }

        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard characters.length > 0 else { return }

        textStorage.enumerateAttribute(
            .locusInlineCodePill,
            in: characters,
            options: []
        ) { value, range, _ in
            guard let fill = value as? NSColor else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            fill.setFill()
            // One pill per line fragment, so a code run that wraps gets a
            // correctly capped shape on each line instead of one tall box.
            self.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                let pill = NSRect(
                    x: rect.minX + origin.x - self.horizontalInset,
                    y: rect.minY + origin.y - self.verticalInset,
                    width: rect.width + self.horizontalInset * 2,
                    height: rect.height + self.verticalInset * 2
                )
                NSBezierPath(
                    roundedRect: pill,
                    xRadius: self.cornerRadius,
                    yRadius: self.cornerRadius
                ).fill()
            }
        }
    }
}

/// Shared base for the transcript's text leaves.
///
/// Two things every leaf needs and neither gets for free:
///
/// 1. **A TextKit 1 stack built by hand.** `NSTextView(frame:)` creates a
///    TextKit 2 stack on macOS 14, which has no `NSLayoutManager` to subclass.
///    The transcript already forces the TextKit 1 fallback by touching
///    `layoutManager` during hit-testing and sizing, so building the stack
///    explicitly changes construction only — and it is the sole way to install
///    `LocusMarkdownLayoutManager`.
/// 2. **A Locus selection wash.** Unset, `selectedTextAttributes` falls through
///    to the system highlight, which ignores the app accent and inverts the text
///    to white against warm paper. Setting a background *without* a foreground
///    keeps selected prose in its own colour.
class LocusSelectionTextView: NSTextView {
    /// Held explicitly: a layout manager keeps only a back-reference to its text
    /// storage, so a hand-built stack would otherwise deallocate its storage.
    /// Declared optional with a default so this class adds no designated
    /// initialiser and every subclass keeps inheriting `init(frame:textContainer:)`.
    private var locusRetainedStorage: NSTextStorage?
    private var selectionWashSignature: NSColor?
    private var appliedSelectionAttributes: [NSAttributedString.Key: Any] = [:]

    /// Builds the TextKit 1 stack a subclass should be constructed against.
    /// Pair with `adoptTextKit1(storage:)` once the view exists.
    static func makeTextKit1Stack() -> (storage: NSTextStorage, container: NSTextContainer) {
        let storage = NSTextStorage()
        let layout = LocusMarkdownLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        ))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return (storage, container)
    }

    func adoptTextKit1(storage: NSTextStorage) {
        locusRetainedStorage = storage
        refreshSelectionWash()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(
                self,
                selector: #selector(windowKeyStateChanged),
                name: name,
                object: window
            )
        }
        refreshSelectionWash()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowKeyStateChanged() {
        refreshSelectionWash()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSelectionWash()
        needsDisplay = true
    }

    /// Re-resolved rather than cached: the wash follows the accent, and the
    /// accent can change while this view is alive.
    func refreshSelectionWash() {
        let isKey = window?.isKeyWindow ?? true
        let dynamicColor = LocusTheme.selectionWash(forKeyWindow: isKey)
        var color = dynamicColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = dynamicColor.usingColorSpace(.deviceRGB) ?? dynamicColor
        }
        // AppKit invalidates glyph layout when this setter runs, even if the
        // selection appearance has not changed during a transcript update.
        if selectionWashSignature?.isEqual(color) == true,
           (selectedTextAttributes as NSDictionary).isEqual(to: appliedSelectionAttributes) { return }
        let attributes: [NSAttributedString.Key: Any] = [.backgroundColor: dynamicColor]
        selectionWashSignature = color
        appliedSelectionAttributes = attributes
        // Keep the assigned color dynamic so streaming text also follows an
        // accent change before its next representable update.
        selectedTextAttributes = attributes
    }
}
