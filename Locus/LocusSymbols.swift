import SwiftUI

/// Glyphs Locus draws itself because SF Symbols has no equivalent. Each one
/// is a custom symbol in the asset catalog, so it takes `.font(_:)` sizing,
/// weights, and `foregroundStyle` exactly like a system symbol — which is
/// what lets it follow the accent instead of sitting there as fixed-colour
/// emoji.
enum LocusSymbol {
    /// The persistent-agent mark. SF Symbols only ships a robotic vacuum, and
    /// the 🤖 emoji ignores tint entirely.
    static let robot = "locus.robot"

    /// Every catalog symbol is namespaced so a name can be routed to the right
    /// initializer without a lookup table.
    private static let namespace = "locus."

    static func isCustom(_ name: String) -> Bool {
        name.hasPrefix(namespace)
    }
}

extension Image {
    /// Resolves either a catalog symbol or a system one from a single name,
    /// so call sites that store a symbol name (inspector tabs, rows) can carry
    /// the robot without special-casing it.
    init(locusSymbol name: String) {
        if LocusSymbol.isCustom(name) {
            self.init(name)
        } else {
            self.init(systemName: name)
        }
    }
}
