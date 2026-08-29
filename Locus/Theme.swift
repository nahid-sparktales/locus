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

/// The five ready-made Locus brand colours. A custom value is stored separately
/// so presets remain a small, stable set while the colour picker stays open-ended.
enum LocusAccentPreset: String, CaseIterable, Identifiable, Sendable {
    case lime
    case blue
    case purple
    case orange
    case pink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lime: "Lime"
        case .blue: "Blue"
        case .purple: "Purple"
        case .orange: "Orange"
        case .pink: "Pink"
        }
    }

    /// Bright fills preserve the friendly, high-energy character of the
    /// original lime. Foreground uses are contrast-adjusted independently.
    fileprivate var fillHex: UInt32 {
        switch self {
        case .lime: 0xC9F54A
        case .blue: 0x4A90FF
        case .purple: 0xA56EFF
        case .orange: 0xFF9F43
        case .pink: 0xFF5FA2
        }
    }

    /// The original app icon used a slightly softer lime than the workspace.
    /// Matching softer companions keep all five logo treatments equally vivid.
    fileprivate var logoHex: UInt32 {
        switch self {
        case .lime: 0xDAF66C
        case .blue: 0x67A9FF
        case .purple: 0xBC86FF
        case .orange: 0xFFB15F
        case .pink: 0xFF82B6
        }
    }
}

struct LocusAccentSelection: Hashable, Sendable {
    static let customRawValue = "custom"
    static let defaultCustomHex = "4A90FF"

    let preset: LocusAccentPreset?
    let customHex: String

    init(rawValue: String, customHex: String) {
        preset = LocusAccentPreset(rawValue: rawValue)
        self.customHex = Self.normalizedHex(customHex) ?? Self.defaultCustomHex
    }

    var rawValue: String { preset?.rawValue ?? Self.customRawValue }
    var title: String { preset?.title ?? "Custom" }

    var fillNSColor: NSColor {
        preset.map { Self.color(hex: $0.fillHex) }
            ?? Self.color(hexString: customHex)
            ?? Self.color(hex: LocusAccentPreset.lime.fillHex)
    }

    var logoNSColor: NSColor {
        preset.map { Self.color(hex: $0.logoHex) } ?? fillNSColor
    }

    var fillColor: Color { Color(nsColor: fillNSColor) }

    func actionNSColor(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = dark ? Self.color(hex: 0x171713) : Self.color(hex: 0xF3F1EA)
        let destination = dark ? NSColor.white : NSColor.black
        return Self.firstReadableMix(
            from: fillNSColor,
            toward: destination,
            over: background
        )
    }

    func brandInkNSColor() -> NSColor {
        let darkInk = Self.color(hex: 0x161814)
        let lightInk = Self.color(hex: 0xFFFDF8)
        return Self.contrast(darkInk, over: logoNSColor)
            >= Self.contrast(lightInk, over: logoNSColor)
            ? darkInk
            : lightInk
    }

    static func hexString(for color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let red = Int(round(rgb.redComponent * 255))
        let green = Int(round(rgb.greenComponent * 255))
        let blue = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    static func normalizedHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .uppercased()
        let hexDigits = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard trimmed.count == 6,
              trimmed.unicodeScalars.allSatisfy({ hexDigits.contains($0) })
        else { return nil }
        return trimmed
    }

    private static func color(hexString: String) -> NSColor? {
        normalizedHex(hexString)
            .flatMap { UInt32($0, radix: 16) }
            .map(color(hex:))
    }

    private static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func firstReadableMix(
        from source: NSColor,
        toward destination: NSColor,
        over background: NSColor
    ) -> NSColor {
        for step in 0...20 {
            let fraction = CGFloat(step) / 20
            let candidate = mix(source, destination, fraction: fraction)
            if contrast(candidate, over: background) >= 4.5 { return candidate }
        }
        return destination
    }

    private static func mix(_ lhs: NSColor, _ rhs: NSColor, fraction: CGFloat) -> NSColor {
        let lhs = lhs.usingColorSpace(.sRGB) ?? lhs
        let rhs = rhs.usingColorSpace(.sRGB) ?? rhs
        return NSColor(
            srgbRed: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * fraction,
            green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * fraction,
            blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * fraction,
            alpha: 1
        )
    }

    private static func contrast(_ foreground: NSColor, over background: NSColor) -> CGFloat {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let color = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channel(color.redComponent) * 0.2126
            + channel(color.greenComponent) * 0.7152
            + channel(color.blueComponent) * 0.0722
    }
}

/// Dynamic colours ask this small process-wide store for their current value.
/// The app's published settings still own invalidation and persistence.
final class LocusAccentRuntime: @unchecked Sendable {
    static let shared = LocusAccentRuntime()

    private let lock = NSLock()
    private var selection = LocusAccentSelection(
        rawValue: LocusAccentPreset.lime.rawValue,
        customHex: LocusAccentSelection.defaultCustomHex
    )

    private init() {}

    func configure(_ selection: LocusAccentSelection) {
        lock.lock()
        self.selection = selection
        lock.unlock()
    }

    func currentSelection() -> LocusAccentSelection {
        lock.lock()
        defer { lock.unlock() }
        return selection
    }
}

enum LocusBrandIcon {
    static func image(accent: NSColor, size: CGFloat = 1_024) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        context.saveGState()
        context.scaleBy(x: size / 1_024, y: size / 1_024)
        context.setShouldAntialias(true)

        let darkInk = NSColor(srgbRed: 0.075, green: 0.086, blue: 0.071, alpha: 1)
        darkInk.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: 1_024, height: 1_024),
            xRadius: 224,
            yRadius: 224
        ).fill()

        accent.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840),
            xRadius: 170,
            yRadius: 170
        ).fill()

        NSColor(srgbRed: 0.969, green: 0.949, blue: 0.886, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 136, y: 136, width: 752, height: 752),
            xRadius: 138,
            yRadius: 138
        ).fill()

        darkInk.setStroke()
        for offset in [-86.0, 86.0] {
            let slash = NSBezierPath()
            slash.lineWidth = 82
            slash.lineCapStyle = .round
            slash.move(to: NSPoint(x: 420 + offset, y: 312))
            slash.line(to: NSPoint(x: 604 + offset, y: 712))
            slash.stroke()
        }

        context.restoreGState()
        image.unlockFocus()
        image.isTemplate = false
        return image
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
    // Accent-backed colors must be recomputed when a view's body updates.
    // Keeping one static Color lets SwiftUI cache the first dynamic-provider
    // resolution in long-lived surfaces such as the composer.
    static var signal: Color {
        accentAdaptive { selection, _ in selection.fillNSColor }
    }
    /// Resolve from Locus's saved theme directly. `Color.accentColor` can fall
    /// back to the user's macOS accent inside nested panes, which made active
    /// folders, focus outlines, context labels, and Ready dots turn orange.
    static var signalDeep: Color {
        accentAdaptive { selection, appearance in
            selection.actionNSColor(for: appearance)
        }
    }
    static let coral = adaptive(\.coral)
    static let danger = adaptive(\.danger)
    static let blue = adaptive(\.blue)
    static var success: Color { signalDeep }
    static let warning = adaptive(\.warning)
    static let permissionInk = adaptive(\.permissionInk)
    static let permissionMuted = adaptive(\.permissionMuted)
    static var successSoft: Color { signal.opacity(0.18) }

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
    static var accentFill: Color { signal }
    static var accentAction: Color { signalDeep }
    static var successForeground: Color { success }
    static let warningForeground = warning
    static let dangerForeground = danger
    static var selectionFill: Color { signal }
    static let focusRing = blue

    /// Artwork drawn on the chosen signal colour automatically uses whichever
    /// ink has stronger contrast, including for arbitrary custom colours.
    static var brandInk: Color {
        accentAdaptive { selection, _ in
            selection.brandInkNSColor()
        }
    }

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

    private static func accentAdaptive(
        _ resolve: @escaping @Sendable (LocusAccentSelection, NSAppearance) -> NSColor
    ) -> Color {
        // Bind each newly evaluated view body to the selection that triggered
        // it. The NSColor remains appearance-aware, but an older SwiftUI Color
        // can no longer silently change identity underneath a cached view node.
        let selection = LocusAccentRuntime.shared.currentSelection()
        return Color(nsColor: NSColor(name: nil) { appearance in
            resolve(selection, appearance)
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
    let accent: LocusAccentSelection
    var compact = false

    private var fill: Color { accent.fillColor }
    private var ink: Color { Color(nsColor: accent.brandInkNSColor()) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .fill(fill)
            HStack(spacing: compact ? 2.5 : 3) {
                Capsule()
                    .fill(ink)
                    .frame(width: compact ? 3 : 3.5, height: compact ? 12.5 : 15)
                    .rotationEffect(.degrees(24))
                Capsule()
                    .fill(ink)
                    .frame(width: compact ? 3 : 3.5, height: compact ? 12.5 : 15)
                    .rotationEffect(.degrees(24))
            }
        }
        .frame(width: compact ? 30 : 36, height: compact ? 30 : 36)
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .stroke(ink, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 0, x: 2, y: 2)
        .rotationEffect(.degrees(-2.5))
        .accessibilityHidden(true)
    }
}

enum ThirdPartyProviderID: String, Hashable {
    case openAI
    case anthropic
    case kimi
    case ollama
    case huggingFace
    case lmStudio
    case vLLM
    case google
    case metaMask
    case phantom
    case slush
    case context7
    case github
    case sentry
    case supabase
    case custom
}

/// A single source of truth for third-party identity throughout Settings.
/// Marks are rendered locally so opening Settings never leaks provider names
/// through favicon requests or depends on the network.
struct ProviderBrandIdentity: Hashable {
    let id: ThirdPartyProviderID
    let displayName: String
    let aliases: [String]
    let fallbackMonogram: String

    static func resolve(
        name: String,
        url: String? = nil,
        presetID: String? = nil
    ) -> ProviderBrandIdentity {
        let identity = [presetID, name, url]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        let known: [(ThirdPartyProviderID, String, [String], String)] = [
            (.openAI, "OpenAI", ["openai", "chatgpt", "codex", "gpt-"], "AI"),
            (.anthropic, "Anthropic", ["anthropic", "claude"], "A"),
            (.kimi, "Moonshot AI", ["moonshot", "kimi"], "K"),
            (.ollama, "Ollama", ["ollama"], "O"),
            (.huggingFace, "Hugging Face", ["huggingface", "hf.co"], "HF"),
            (.lmStudio, "LM Studio", ["lm studio", "lmstudio"], "LM"),
            (.vLLM, "vLLM", ["vllm"], "vL"),
            (.google, "Google", ["google"], "G"),
            (.metaMask, "MetaMask", ["metamask"], "M"),
            (.phantom, "Phantom", ["phantom"], "P"),
            (.slush, "Slush", ["slush"], "S"),
            (.context7, "Context7", ["context7"], "7"),
            (.github, "GitHub", ["github", "githubcopilot"], "GH"),
            (.sentry, "Sentry", ["sentry"], "S"),
            (.supabase, "Supabase", ["supabase"], "S"),
        ]

        if let match = known.first(where: { candidate in
            candidate.2.contains(where: identity.contains)
        }) {
            return ProviderBrandIdentity(
                id: match.0,
                displayName: match.1,
                aliases: match.2,
                fallbackMonogram: match.3
            )
        }

        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        let value = letters.isEmpty ? Array(name.prefix(2)) : letters
        return ProviderBrandIdentity(
            id: .custom,
            displayName: name.isEmpty ? "Custom provider" : name,
            aliases: [],
            fallbackMonogram: String(value).uppercased()
        )
    }
}

struct ProviderLogo: View {
    let identity: ProviderBrandIdentity
    var size: CGFloat = 26

    init(name: String, url: String? = nil, presetID: String? = nil, size: CGFloat = 26) {
        self.identity = ProviderBrandIdentity.resolve(name: name, url: url, presetID: presetID)
        self.size = size
    }

    init(kind: ProviderKind, name: String? = nil, url: String? = nil, size: CGFloat = 26) {
        self.identity = ProviderBrandIdentity.resolve(
            name: name ?? kind.title,
            url: url ?? kind.defaultBaseURL,
            presetID: kind.rawValue
        )
        self.size = size
    }

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

    private var style: Style {
        switch identity.id {
        case .openAI:
            return Style(background: Color(red: 0.08, green: 0.09, blue: 0.09), foreground: .white, mark: .symbol("sparkles"))
        case .anthropic:
            return Style(background: Color(red: 0.83, green: 0.68, blue: 0.50), foreground: Color(red: 0.18, green: 0.12, blue: 0.08), mark: .text("A"))
        case .kimi:
            return Style(background: Color(red: 0.22, green: 0.36, blue: 0.88), foreground: .white, mark: .text("K"))
        case .ollama:
            return Style(background: Color(red: 0.11, green: 0.12, blue: 0.13), foreground: .white, mark: .symbol("circle.grid.2x2.fill"))
        case .huggingFace:
            return Style(background: Color(red: 1.00, green: 0.78, blue: 0.18), foreground: Color(red: 0.30, green: 0.21, blue: 0.03), mark: .text("HF"))
        case .lmStudio:
            return Style(background: Color(red: 0.22, green: 0.23, blue: 0.28), foreground: .white, mark: .text("LM"))
        case .vLLM:
            return Style(background: Color(red: 0.13, green: 0.53, blue: 0.74), foreground: .white, mark: .text("vL"))
        case .google:
            return Style(background: Color.white, foreground: Color(red: 0.18, green: 0.48, blue: 0.89), mark: .text("G"))
        case .metaMask:
            return Style(background: Color(red: 0.96, green: 0.47, blue: 0.20), foreground: .white, mark: .text("M"))
        case .phantom:
            return Style(background: Color(red: 0.38, green: 0.31, blue: 0.92), foreground: .white, mark: .text("P"))
        case .slush:
            return Style(background: Color(red: 0.17, green: 0.60, blue: 0.92), foreground: .white, mark: .text("S"))
        case .context7:
            return Style(background: Color(red: 0.34, green: 0.27, blue: 0.95), foreground: .white, mark: .text("7"))
        case .github:
            return Style(background: Color(red: 0.12, green: 0.13, blue: 0.15), foreground: .white, mark: .text("GH"))
        case .sentry:
            return Style(background: Color(red: 0.43, green: 0.35, blue: 0.69), foreground: .white, mark: .symbol("scope"))
        case .supabase:
            return Style(background: Color(red: 0.24, green: 0.81, blue: 0.56), foreground: Color(red: 0.04, green: 0.19, blue: 0.15), mark: .symbol("bolt.fill"))
        case .custom:
            let seed = identity.displayName.lowercased()
            let index = seed.utf8.reduce(0) {
            ($0 &* 31 &+ Int($1)) % Self.fallbackColors.count
            }
            return Style(
                background: Self.fallbackColors[index],
                foreground: .white,
                mark: .text(identity.fallbackMonogram)
            )
        }
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
        .accessibilityLabel("\(identity.displayName) logo")
        .accessibilityIdentifier("provider.logo.\(identity.id.rawValue)")
    }
}

/// Backward-compatible MCP wrapper. It deliberately shares the provider
/// registry so the same third-party has one mark throughout the app.
struct MCPLogo: View {
    let name: String
    var url: String? = nil
    var presetID: String? = nil
    var size: CGFloat = 26

    var body: some View {
        ProviderLogo(name: name, url: url, presetID: presetID, size: size)
    }
}

struct SettingsAdvancedLabel: View {
    var detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced")
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(LocusTheme.accentAction)
                .frame(width: 24)
        }
        .padding(.vertical, 3)
    }
}

struct SettingsAdvancedDisclosureRow: View {
    @Binding var isExpanded: Bool
    var detail: String

    var body: some View {
        Button {
            withAnimation(LocusMotion.content) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                SettingsAdvancedLabel(detail: detail)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Advanced")
        .accessibilityHint(detail)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
