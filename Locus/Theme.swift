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
        lineStrong: rgb(red: 0.773, green: 0.753, blue: 0.71),
        muted: rgb(red: 0.467, green: 0.475, blue: 0.435),
        signal: rgb(red: 0.788, green: 0.961, blue: 0.29),
        signalDeep: rgb(red: 0.655, green: 0.827, blue: 0.153),
        coral: rgb(red: 0.89, green: 0.435, blue: 0.314),
        danger: rgb(0xD92D20),
        blue: rgb(red: 0.322, green: 0.455, blue: 0.843),
        success: rgb(red: 0.259, green: 0.506, blue: 0.325),
        warning: rgb(red: 0.73, green: 0.49, blue: 0.13),
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
        lineStrong: rgb(0x5C584B),
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

extension View {
    func locusCard(radius: CGFloat = 10) -> some View {
        self
            .background(LocusTheme.white)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LocusTheme.line, lineWidth: 1)
            }
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
                    .font(.system(size: size * (text.count > 1 ? 0.32 : 0.48), weight: .bold, design: .rounded))
                    .foregroundStyle(style.foreground)
            case .symbol(let symbol):
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(style.foreground)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
        .accessibilityLabel("\(name) logo")
    }
}
