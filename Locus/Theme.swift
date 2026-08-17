import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` deliberately leaves the scene under macOS appearance control.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum LocusTheme {
    struct Palette {
        let ink: NSColor
        let inkSoft: NSColor
        let paper: NSColor
        let paperDeep: NSColor
        let panel: NSColor
        let white: NSColor
        let line: NSColor
        let lineStrong: NSColor
        let muted: NSColor
        let signal: NSColor
        let signalDeep: NSColor
        let coral: NSColor
        let danger: NSColor
        let blue: NSColor
        let success: NSColor
        let warning: NSColor
        let permissionInk: NSColor
        let permissionMuted: NSColor
        let successSoft: NSColor
    }

    /// Keep the established light appearance byte-for-byte equivalent to the
    /// original SwiftUI colors. Only the backing type is now dynamic.
    static let lightPalette = Palette(
        ink: rgb(red: 0.086, green: 0.094, blue: 0.078),
        inkSoft: rgb(red: 0.145, green: 0.157, blue: 0.125),
        paper: rgb(red: 0.953, green: 0.945, blue: 0.918),
        paperDeep: rgb(red: 0.925, green: 0.914, blue: 0.878),
        panel: rgb(red: 0.973, green: 0.965, blue: 0.941),
        white: rgb(red: 1.0, green: 0.996, blue: 0.98),
        line: rgb(red: 0.85, green: 0.835, blue: 0.792),
        lineStrong: rgb(0x77766D),
        // Secondary copy used to sit between 3.6:1 and 4.4:1 on the paper
        // surfaces. Keep the warm gray character, but make it readable at the
        // compact sizes a desktop workspace needs.
        muted: rgb(0x5F6258),
        signal: rgb(red: 0.788, green: 0.961, blue: 0.29),
        // `signal` remains the bright brand fill. This deeper olive is the
        // accessible foreground/link partner for light surfaces.
        signalDeep: rgb(0x526800),
        coral: rgb(0xA33A24),
        danger: rgb(0xB42318),
        blue: rgb(red: 0.322, green: 0.455, blue: 0.843),
        success: rgb(0x2F6D3F),
        warning: rgb(0x7D5106),
        permissionInk: rgb(red: 0.42, green: 0.31, blue: 0.25),
        permissionMuted: rgb(red: 0.52, green: 0.42, blue: 0.36),
        successSoft: rgb(red: 0.906, green: 0.949, blue: 0.792)
    )

    static let darkPalette = Palette(
        ink: rgb(0xF2EEE4),
        inkSoft: rgb(0xD5CFC1),
        paper: rgb(0x171713),
        paperDeep: rgb(0x20201B),
        panel: rgb(0x1B1B17),
        white: rgb(0x292820),
        line: rgb(0x3D3B32),
        lineStrong: rgb(0x858074),
        muted: rgb(0x9C988A),
        signal: rgb(0xC9F54A),
        signalDeep: rgb(0xB6E33B),
        coral: rgb(0xF18364),
        danger: rgb(0xFF5A52),
        blue: rgb(0x7998FF),
        success: rgb(0x6DBB7B),
        warning: rgb(0xE1A54B),
        permissionInk: rgb(0xD7A77E),
        permissionMuted: rgb(0xB9927B),
        successSoft: rgb(0x2A3320)
    )

    static let ink = adaptive(\.ink)
    static let inkSoft = adaptive(\.inkSoft)
    static let paper = adaptive(\.paper)
    static let paperDeep = adaptive(\.paperDeep)
    static let panel = adaptive(\.panel)
    static let white = adaptive(\.white)
    static let line = adaptive(\.line)
    static let lineStrong = adaptive(\.lineStrong)
    static let muted = adaptive(\.muted)
    static let signal = adaptive(\.signal)
    static let signalDeep = adaptive(\.signalDeep)
    static let coral = adaptive(\.coral)
    static let danger = adaptive(\.danger)
    static let blue = adaptive(\.blue)
    static let success = adaptive(\.success)
    static let warning = adaptive(\.warning)
    static let permissionInk = adaptive(\.permissionInk)
    static let permissionMuted = adaptive(\.permissionMuted)
    static let successSoft = adaptive(\.successSoft)

    // Semantic roles. The legacy names above remain source-compatible while
    // screens migrate; new UI should describe the purpose of a color rather
    // than the swatch it happens to use.
    static let textPrimary = ink
    static let textSecondary = inkSoft
    static let textTertiary = muted
    static let surfaceCanvas = paper
    static let surfaceStructural = paperDeep
    static let surfacePanel = panel
    static let surfaceCard = white
    static let separator = line
    static let separatorStrong = lineStrong
    static let accentFill = signal
    static let accentAction = signalDeep
    static let successForeground = success
    static let warningForeground = warning
    static let dangerForeground = danger
    static let selectionFill = signal
    static let focusRing = blue

    /// Artwork drawn on the lime signal color must stay dark in both modes.
    static let brandInk = Color(nsColor: rgb(red: 0.086, green: 0.094, blue: 0.078))

    static func palette(for appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? darkPalette
            : lightPalette
    }

    private static func adaptive(_ keyPath: KeyPath<Palette, NSColor>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            palette(for: appearance)[keyPath: keyPath]
        })
    }

    private static func rgb(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        rgb(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255
        )
    }
}

/// Semantic type roles backed by the macOS preferred text styles. The legacy
/// adapter lets the large existing surface migrate mechanically while still
/// enforcing an 11-point floor for user-facing content.
enum LocusType {
    static let display = Font.system(size: 40, weight: .medium)
    static let title = Font.system(.title3, design: .default, weight: .bold)
    static let body = Font.system(.body, design: .default, weight: .regular)
    static let callout = Font.system(.callout, design: .default, weight: .regular)
    static let caption = Font.system(.subheadline, design: .default, weight: .regular)
    static let badge = Font.system(.subheadline, design: .default, weight: .semibold)
    static let mono = Font.system(.callout, design: .monospaced, weight: .regular)
    static let monoCaption = Font.system(.subheadline, design: .monospaced, weight: .regular)
}

extension Font {
    /// Compatibility bridge for existing point-sized call sites. Values at or
    /// below the old micro-copy range become preferred semantic styles, so
    /// accessibility sizing and the 11-point readability floor apply without
    /// flattening the deliberate display hierarchy.
    static func locus(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        switch size {
        case ..<11:
            .system(.subheadline, design: design, weight: weight)
        case ..<13:
            .system(.callout, design: design, weight: weight)
        case ..<15:
            .system(.body, design: design, weight: weight)
        case ..<17:
            .system(.title3, design: design, weight: weight)
        case ..<20:
            .system(.title2, design: design, weight: weight)
        case ..<26:
            .system(.title, design: design, weight: weight)
        default:
            .system(size: size, weight: weight, design: design)
        }
    }
}

enum LocusMotion {
    /// Spatial state changes are critically damped: quick, interruptible, and
    /// free of decorative overshoot.
    static let spatial = Animation.spring(response: 0.32, dampingFraction: 1.0)
    static let content = Animation.easeInOut(duration: 0.18)
    static let scroll = Animation.easeOut(duration: 0.14)
    static let press = Animation.easeOut(duration: 0.10)
    static let activityPulse = Animation.easeInOut(duration: 0.9)
        .repeatForever(autoreverses: true)

    static func allowsSpatialMotion(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func transition(edge: Edge, reduceMotion: Bool) -> AnyTransition {
        allowsSpatialMotion(reduceMotion: reduceMotion)
            ? .move(edge: edge).combined(with: .opacity)
            : .opacity
    }
}

enum LocusSurfaceKind {
    case structural
    case toolbar
    case floating
}

private struct LocusSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let kind: LocusSurfaceKind
    let radius: CGFloat

    private var solidColor: Color {
        switch kind {
        case .structural: LocusTheme.surfaceStructural
        case .toolbar: LocusTheme.surfacePanel
        case .floating: LocusTheme.surfaceCard
        }
    }

    private var tintOpacity: Double {
        switch kind {
        case .structural: 0.78
        case .toolbar: 0.70
        case .floating: 0.62
        }
    }

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.clear)
                .background {
                    if reduceTransparency || contrast == .increased {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(solidColor)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(kind == .structural ? .regularMaterial : .thinMaterial)
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(solidColor.opacity(tintOpacity))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

private struct LocusCardModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(LocusTheme.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        contrast == .increased
                            ? LocusTheme.separatorStrong
                            : LocusTheme.separator,
                        lineWidth: contrast == .increased ? 1.5 : 1
                    )
            }
    }
}

enum LocusButtonKind {
    case quiet
    case icon
    case card
    case primary
    case destructive
}

struct LocusButtonStyle: ButtonStyle {
    let kind: LocusButtonKind

    func makeBody(configuration: Configuration) -> some View {
        LocusButtonStyleBody(configuration: configuration, kind: kind)
    }
}

private struct LocusButtonStyleBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    let configuration: ButtonStyle.Configuration
    let kind: LocusButtonKind

    private var hoverColor: Color {
        switch kind {
        case .quiet, .icon: LocusTheme.textPrimary.opacity(0.055)
        case .card: LocusTheme.accentFill.opacity(0.10)
        case .primary: Color.white.opacity(0.12)
        case .destructive: LocusTheme.dangerForeground.opacity(0.10)
        }
    }

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .background(hovering && isEnabled ? hoverColor : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: kind == .icon ? 7 : 9, style: .continuous)
                    .stroke(
                        isFocused ? LocusTheme.focusRing : Color.clear,
                        lineWidth: contrast == .increased ? 3 : 2
                    )
                    .padding(-2)
            }
            .scaleEffect(
                reduceMotion || !configuration.isPressed
                    ? 1
                    : (kind == .icon ? 0.94 : 0.98)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.50)
            .animation(reduceMotion ? nil : LocusMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : LocusMotion.press, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == LocusButtonStyle {
    static func locus(_ kind: LocusButtonKind = .quiet) -> LocusButtonStyle {
        LocusButtonStyle(kind: kind)
    }
}

extension View {
    func locusCard(radius: CGFloat = 10) -> some View {
        modifier(LocusCardModifier(radius: radius))
    }

    func locusSurface(_ kind: LocusSurfaceKind, radius: CGFloat = 0) -> some View {
        modifier(LocusSurfaceModifier(kind: kind, radius: radius))
    }
}

/// Shared presentation for local task recommendations. The action stays with
/// the caller so the card remains usable in the empty workspace, inspector,
/// and future surfaces without coupling the design system to AppModel.
struct LocusRecommendationCard: View {
    let recommendation: LocusRecommendation
    let identifier: String
    var compact = false
    let action: () -> Void

    private var actionSymbol: String {
        switch recommendation.intent {
        case .prefill: "arrow.turn.down.left"
        case .openInspector, .openSettings, .openModelLibrary: "arrow.up.right"
        }
    }

    private var actionHint: String {
        switch recommendation.intent {
        case .prefill: "Places this suggestion in the message composer for review."
        case .openInspector: "Opens the relevant workspace panel."
        case .openSettings: "Opens the relevant Settings page."
        case .openModelLibrary: "Opens Model Library."
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: compact ? 9 : 11) {
                Image(systemName: recommendation.kind.symbol)
                    .font(.locus(size: compact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(LocusTheme.brandInk)
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                    .background(LocusTheme.accentFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendation.title)
                        .font(LocusType.caption.weight(.semibold))
                        .foregroundStyle(LocusTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(compact ? 2 : 1)
                    Text(recommendation.rationale)
                        .font(LocusType.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(compact ? 2 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: actionSymbol)
                    .font(.locus(size: 11, weight: .semibold))
                    .foregroundStyle(LocusTheme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 8 : 10)
            .frame(maxWidth: .infinity, minHeight: compact ? 54 : 60, alignment: .leading)
            .locusCard(radius: 9)
        }
        .buttonStyle(.locus(.card))
        .help(actionHint)
        .accessibilityLabel("\(recommendation.title). \(recommendation.rationale)")
        .accessibilityHint(actionHint)
        .accessibilityIdentifier(identifier)
    }
}

struct BrandMark: View {
    var compact = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .fill(LocusTheme.signal)
            HStack(spacing: compact ? 2.5 : 3) {
                Capsule()
                    .fill(LocusTheme.brandInk)
                    .frame(width: compact ? 3 : 3.5, height: compact ? 12.5 : 15)
                    .rotationEffect(.degrees(24))
                Capsule()
                    .fill(LocusTheme.brandInk)
                    .frame(width: compact ? 3 : 3.5, height: compact ? 12.5 : 15)
                    .rotationEffect(.degrees(24))
            }
        }
        .frame(width: compact ? 30 : 36, height: compact ? 30 : 36)
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .stroke(LocusTheme.brandInk, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 0, x: 2, y: 2)
        .rotationEffect(.degrees(-2.5))
        .accessibilityHidden(true)
    }
}

/// Local MCP brand marks. Known providers receive a recognizable color and
/// glyph; custom servers receive a deterministic monogram instead of the same
/// generic network icon everywhere. Keeping these local avoids fetching
/// favicons merely because Settings was opened.
struct MCPLogo: View {
    let name: String
    var url: String? = nil
    var presetID: String? = nil
    var size: CGFloat = 26

    private enum Mark {
        case text(String)
        case symbol(String)
    }

    private struct Style {
        let background: Color
        let foreground: Color
        let mark: Mark
    }

    private static let fallbackColors = [
        Color(red: 0.29, green: 0.42, blue: 0.78),
        Color(red: 0.46, green: 0.33, blue: 0.72),
        Color(red: 0.09, green: 0.55, blue: 0.48),
        Color(red: 0.73, green: 0.35, blue: 0.24),
        Color(red: 0.12, green: 0.48, blue: 0.65),
    ]

    private var identity: String {
        [presetID, name, url]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        let value = letters.isEmpty ? Array(name.prefix(2)) : letters
        return String(value).uppercased()
    }

    private var style: Style {
        if identity.contains("context7") {
            return Style(
                background: Color(red: 0.34, green: 0.27, blue: 0.95),
                foreground: .white,
                mark: .text("7")
            )
        }
        if identity.contains("github") || identity.contains("githubcopilot") {
            return Style(
                background: Color(red: 0.12, green: 0.13, blue: 0.15),
                foreground: .white,
                mark: .text("GH")
            )
        }
        if identity.contains("sentry") {
            return Style(
                background: Color(red: 0.43, green: 0.35, blue: 0.69),
                foreground: .white,
                mark: .symbol("scope")
            )
        }
        if identity.contains("supabase") {
            return Style(
                background: Color(red: 0.24, green: 0.81, blue: 0.56),
                foreground: Color(red: 0.04, green: 0.19, blue: 0.15),
                mark: .symbol("bolt.fill")
            )
        }
        if identity.contains("openai") {
            return Style(
                background: Color(red: 0.08, green: 0.09, blue: 0.09),
                foreground: .white,
                mark: .symbol("sparkles")
            )
        }

        let index = identity.utf8.reduce(0) {
            ($0 &* 31 &+ Int($1)) % Self.fallbackColors.count
        }
        return Style(
            background: Self.fallbackColors[index],
            foreground: .white,
            mark: .text(initials)
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(style.background)
            switch style.mark {
            case .text(let text):
                Text(text)
                    .font(.locus(size: size * (text.count > 1 ? 0.32 : 0.48), weight: .bold, design: .rounded))
                    .foregroundStyle(style.foreground)
            case .symbol(let symbol):
                Image(systemName: symbol)
                    .font(.locus(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(style.foreground)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) logo")
    }
}
