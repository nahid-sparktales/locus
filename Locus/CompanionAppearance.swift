import Foundation

/// Native presentation metadata only. Custom pixels remain in the existing
/// AgentTeamsModel avatar store; no provider URL, prompt, or local path is saved here.
struct CompanionAppearance: Codable, Hashable {
    enum AssetKind: String, Codable { case builtIn, portrait, bundledSprite }
    enum AnimationCapability: String { case articulated, wholeImage, spriteFrames }

    var version = 1
    var kind: AssetKind = .builtIn
    var assetID: String
    var palette: CompanionPalette
    var accessory: CompanionAccessory
    var variationSeed: UInt64?

    init(character: CompanionCharacterKind = .robot, palette: CompanionPalette = .mint,
         accessory: CompanionAccessory = .none, variationSeed: UInt64? = nil) {
        assetID = character.rawValue
        self.palette = palette
        self.accessory = accessory
        self.variationSeed = variationSeed
    }

    init(sprite: CompanionBundledSprite) {
        self.init(character: .robot)
        kind = .bundledSprite
        assetID = sprite.rawValue
    }

    private enum CodingKeys: String, CodingKey { case version, kind, assetID, palette, accessory, variationSeed }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? values.decode(Int.self, forKey: .version)) ?? 1
        let storedKind = (try? values.decode(String.self, forKey: .kind)) ?? "builtIn"
        kind = AssetKind(rawValue: storedKind) ?? .builtIn
        assetID = (try? values.decode(String.self, forKey: .assetID)) ?? "robot"
        // An unsupported future asset must not make the entire profile presentation
        // record undecodable and lose its durable primary-companion binding.
        if AssetKind(rawValue: storedKind) == nil { assetID = "unsupported" }
        palette = (try? values.decode(CompanionPalette.self, forKey: .palette)) ?? .mint
        accessory = (try? values.decode(CompanionAccessory.self, forKey: .accessory)) ?? .none
        variationSeed = try? values.decode(UInt64.self, forKey: .variationSeed)
    }

    /// New drafts choose Pitou. Restored references retain their explicit asset ID.
    static let `default` = CompanionAppearance.pitou
    static let robot = CompanionAppearance(character: .robot)
    static let pitou = CompanionAppearance(sprite: .pitou)
    static var portrait: CompanionAppearance {
        var result = CompanionAppearance()
        result.kind = .portrait
        result.assetID = "profile-portrait"
        result.accessory = .none
        return result
    }

    var builtIn: CompanionCharacterKind? {
        kind == .builtIn ? CompanionCharacterKind(rawValue: assetID) : nil
    }
    var bundledSprite: CompanionBundledSprite? {
        kind == .bundledSprite ? CompanionBundledSprite(rawValue: assetID) : nil
    }
    var displayName: String {
        switch kind {
        case .builtIn: builtIn?.name ?? "Robot"
        case .portrait: "Custom character"
        case .bundledSprite: bundledSprite?.displayName ?? "Robot"
        }
    }
    var animationCapability: AnimationCapability {
        switch kind {
        case .builtIn: .articulated
        case .portrait: .wholeImage
        case .bundledSprite: .spriteFrames
        }
    }
    var supportsAppearanceControls: Bool { kind == .builtIn }

    /// Unknown future artwork degrades visually without changing the profile ID.
    var validated: CompanionAppearance {
        guard version == 1 else { return .robot }
        if kind == .portrait { return .portrait }
        if kind == .bundledSprite { return bundledSprite.map(CompanionAppearance.init(sprite:)) ?? .robot }
        guard builtIn != nil else { return .robot }
        return self
    }

    /// All choices are local and deterministic. The resulting reference is persisted,
    /// so a launch never re-rolls the character, even if the palette list later grows.
    static func surprise(seed: UInt64) -> CompanionAppearance {
        var value = seed
        func next(_ count: Int) -> Int {
            value &+= 0x9E3779B97F4A7C15
            var mixed = value
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
            return Int((mixed ^ (mixed >> 31)) % UInt64(count))
        }
        return CompanionAppearance(
            character: CompanionCharacterKind.allCases[next(CompanionCharacterKind.allCases.count)],
            palette: CompanionPalette.allCases[next(CompanionPalette.allCases.count)],
            accessory: CompanionAccessory.allCases[next(CompanionAccessory.allCases.count)],
            variationSeed: seed)
    }
}

/// Approved release resources, not user paths or remotely mutable URLs.
enum CompanionBundledSprite: String, Codable, CaseIterable, Identifiable {
    case pitou = "pitou-v2"
    case gon = "gon-v1", ninja = "ninja-v1", clover = "clover-v1", shadow = "shadow-v1", pirate = "pirate-v1"
    case scout = "scout-v2"

    /// Gon remains resolvable for saved appearances, while new selections use Scout.
    static let allCases: [Self] = [.pitou, .scout, .ninja, .clover, .shadow, .pirate]
    static let supportedAssets: [Self] = allCases + [.gon]
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .pitou: "Pitou"
        case .gon: "Gon"
        case .scout: "Scout"
        case .ninja: "Ninja"
        case .clover: "Clover"
        case .shadow: "Shadow"
        case .pirate: "Pirate"
        }
    }
    var resourceName: String { displayName }
    /// The earlier generated atlases have a larger transparent safety inset.
    /// Their common scale stays consistent across every pose, including gaze.
    var presentationScale: Double { self == .pitou || self == .scout ? 1 : 1.4 }
    var detail: String {
        switch self {
        case .pitou: "Your original Pitou"
        case .gon: "Gon × Jujutsu Kaisen · Hell’s Paradise details"
        case .scout: "My Hero Academia × Hunter x Hunter"
        case .ninja: "Naruto × Chainsaw Man"
        case .clover: "Black Clover × Fullmetal Alchemist"
        case .shadow: "Solo Leveling × Kaiju No. 8"
        case .pirate: "One Piece × Dragon Ball Z"
        }
    }
}

enum CompanionCharacterKind: String, Codable, CaseIterable, Identifiable {
    case robot, spark, cat, fox, frog, explorer
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .robot: "A little inventor with a curious antenna"
        case .spark: "A warm spark full of possibility"
        case .cat: "A soft, quietly curious cat"
        case .fox: "A bright explorer with a sweeping tail"
        case .frog: "A small pond companion with big ideas"
        case .explorer: "A tiny traveler ready for the next idea"
        }
    }
}

enum CompanionPalette: String, Codable, CaseIterable, Identifiable {
    case mint, sky, rose, amber, violet, slate
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

enum CompanionAccessory: String, Codable, CaseIterable, Identifiable {
    case none, scarf, glasses
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

/// A display pose, never an execution controller. Callers derive work poses from
/// authoritative activity. Greeting and breathing are purely decorative.
enum CompanionCharacterPose: String, Equatable {
    case idle, greeting, queued, working, needsApproval, completed, failed, paused, unavailable
    var label: String {
        switch self {
        case .idle, .greeting: "Ready"
        case .queued: "Waiting to start"
        case .working: "Working"
        case .needsApproval: "Needs your approval"
        case .completed: "Completed"
        case .failed: "Needs attention"
        case .paused: "Paused"
        case .unavailable: "Unavailable"
        }
    }
}
