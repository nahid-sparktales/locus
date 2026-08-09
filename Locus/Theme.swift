import SwiftUI

enum LocusTheme {
    static let ink = Color(red: 0.086, green: 0.094, blue: 0.078)
    static let inkSoft = Color(red: 0.145, green: 0.157, blue: 0.125)
    static let paper = Color(red: 0.953, green: 0.945, blue: 0.918)
    static let paperDeep = Color(red: 0.925, green: 0.914, blue: 0.878)
    static let panel = Color(red: 0.973, green: 0.965, blue: 0.941)
    static let white = Color(red: 1.0, green: 0.996, blue: 0.98)
    static let line = Color(red: 0.85, green: 0.835, blue: 0.792)
    static let lineStrong = Color(red: 0.773, green: 0.753, blue: 0.71)
    static let muted = Color(red: 0.467, green: 0.475, blue: 0.435)
    static let signal = Color(red: 0.788, green: 0.961, blue: 0.29)
    static let signalDeep = Color(red: 0.655, green: 0.827, blue: 0.153)
    static let coral = Color(red: 0.89, green: 0.435, blue: 0.314)
    static let blue = Color(red: 0.322, green: 0.455, blue: 0.843)
    static let success = Color(red: 0.259, green: 0.506, blue: 0.325)
    static let warning = Color(red: 0.73, green: 0.49, blue: 0.13)
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
                    .fill(LocusTheme.ink)
                    .frame(width: compact ? 3 : 3.5, height: compact ? 12.5 : 15)
                    .rotationEffect(.degrees(24))
                Capsule()
                    .fill(LocusTheme.ink)
                    .frame(width: compact ? 3 : 3.5, height: compact ? 12.5 : 15)
                    .rotationEffect(.degrees(24))
            }
        }
        .frame(width: compact ? 30 : 36, height: compact ? 30 : 36)
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .stroke(LocusTheme.ink, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 0, x: 2, y: 2)
        .rotationEffect(.degrees(-2.5))
        .accessibilityHidden(true)
    }
}
