import AppKit

extension LocusTheme {
    /// The CSS custom properties an interactive answer is told to style with.
    /// Order is part of the contract: the model's instructions name these
    /// exact variables, and the exported document keeps them.
    static let cssVariableNames = [
        "--locus-ink", "--locus-ink-soft", "--locus-paper", "--locus-paper-deep",
        "--locus-panel", "--locus-line", "--locus-muted", "--locus-accent",
        "--locus-danger", "--locus-success", "--locus-warning",
        "--locus-font", "--locus-mono",
    ]

    static let cssFontStack =
        "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', Helvetica, Arial, sans-serif"
    static let cssMonoStack = "ui-monospace, 'SF Mono', Menlo, Monaco, monospace"

    /// One `:root{…}` rule serialising the palette for `appearance` as sRGB
    /// hex. Every colour is derived from `palette(for:)` and the accent
    /// resolver, so the web view and the native transcript can never drift.
    static func cssVariables(for appearance: NSAppearance) -> String {
        let palette = palette(for: appearance)
        let accent = LocusAccentRuntime.shared.currentSelection().actionNSColor(for: appearance)
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colours: [(String, NSColor)] = [
            ("--locus-ink", palette.ink),
            ("--locus-ink-soft", palette.inkSoft),
            ("--locus-paper", palette.paper),
            ("--locus-paper-deep", palette.paperDeep),
            ("--locus-panel", palette.panel),
            ("--locus-line", palette.line),
            ("--locus-muted", palette.muted),
            ("--locus-accent", accent),
            ("--locus-danger", palette.danger),
            ("--locus-success", palette.success),
            ("--locus-warning", palette.warning),
        ]
        var declarations = colours.map { name, colour in
            "\(name):\(cssHex(colour, fallback: palette.ink))"
        }
        declarations.append("--locus-font:\(cssFontStack)")
        declarations.append("--locus-mono:\(cssMonoStack)")
        declarations.append("color-scheme:\(dark ? "dark" : "light")")
        return ":root{" + declarations.joined(separator: ";") + "}"
    }

    /// `#RRGGBB` in sRGB. A colour that cannot be converted (a pattern colour,
    /// say) falls back to `fallback` — the appearance's ink in
    /// `cssVariables` — so the page stays readable rather than inheriting a
    /// browser default. Every palette colour converts, so the closing black
    /// is a guard against a caller passing something exotic as the fallback
    /// too, never a colour the app draws.
    static func cssHex(_ colour: NSColor, fallback: NSColor) -> String {
        let hex = LocusAccentSelection.hexString(for: colour)
            ?? LocusAccentSelection.hexString(for: fallback)
            ?? LocusAccentSelection.hexString(for: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ?? "000000"
        return "#" + hex
    }
}
