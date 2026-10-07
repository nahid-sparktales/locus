import Foundation

/// Native presentation metadata only. Custom pixels remain in the existing
/// AgentTeamsModel avatar store; no provider URL, prompt, or local path is saved here.
struct CompanionAppearance: Codable, Hashable {
    enum AssetKind: String, Codable { case builtIn, portrait, bundledSprite, importedSprite }
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

    static func importedSprite(assetID: String) -> Self {
        var appearance = Self.robot
        appearance.kind = .importedSprite
        appearance.assetID = assetID
        return appearance
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
        case .importedSprite: "Animated character"
        case .bundledSprite: bundledSprite?.displayName ?? "Robot"
        }
    }
    var animationCapability: AnimationCapability {
        switch kind {
        case .builtIn: .articulated
        case .portrait: .wholeImage
        case .bundledSprite, .importedSprite: .spriteFrames
        }
    }
    var supportsAppearanceControls: Bool { kind == .builtIn }

    /// Unknown future artwork degrades visually without changing the profile ID.
    var validated: CompanionAppearance {
        guard version == 1 else { return .robot }
        if kind == .portrait { return .portrait }
        if kind == .importedSprite { return assetID.hasPrefix("pack-") ? self : .robot }
        if kind == .bundledSprite { return bundledSprite.map(CompanionAppearance.init(sprite:)) ?? .robot }
        guard builtIn != nil else { return .robot }
        return self
    }

    /// Only the six current sprite choices participate. The resulting asset ID
    /// is persisted directly; legacy artwork stays readable but is not re-offered.
    static func surprise(seed: UInt64) -> CompanionAppearance {
        var value = seed
        func next(_ count: Int) -> Int {
            value &+= 0x9E3779B97F4A7C15
            var mixed = value
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
            return Int((mixed ^ (mixed >> 31)) % UInt64(count))
        }
        return CompanionAppearance(sprite: CompanionBundledSprite.allCases[next(CompanionBundledSprite.allCases.count)])
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

/// Communication defaults offered during new-companion setup. These never change
/// permissions or mutate the behavior of an already saved agent.
struct CompanionPersonality: Equatable {
    let suggestedName: String
    let role: String
    let bio: String
    let traits: [String]
    let strengths: [String]
    let instructions: String
}

extension CompanionBundledSprite {
    var personality: CompanionPersonality? {
        switch self {
        case .pitou:
            CompanionPersonality(
                suggestedName: "Pitou", role: "Thoughtful companion",
                bio: "A warm, attentive companion for thinking things through. Pitou asks thoughtful questions, notices the small details, and helps you keep moving.",
                traits: ["Warm", "Curious", "Attentive"],
                strengths: ["Clarifying ideas", "Noticing details", "Steady follow-through"],
                instructions: "Be warm, curious, and attentive. Ask thoughtful questions when the goal is unclear, notice important details, and help turn rough ideas into clear next steps. Offer steady encouragement without flattery, and keep your explanations practical."
            )
        case .scout:
            CompanionPersonality(
                suggestedName: "Scout", role: "Curious explorer",
                bio: "An upbeat explorer who enjoys following a good question. Scout connects ideas, checks the evidence, and brings useful discoveries back to the task.",
                traits: ["Upbeat", "Observant", "Inquisitive"],
                strengths: ["Research", "Connecting ideas", "Finding next steps"],
                instructions: "Be upbeat, observant, and inquisitive. Explore useful alternatives, connect related ideas, and distinguish evidence from guesses. Share discoveries clearly, then help choose a practical next step without overwhelming the user with options."
            )
        case .ninja:
            CompanionPersonality(
                suggestedName: "Ninja", role: "Focused problem-solver",
                bio: "A composed partner who brings order to a tricky problem. Ninja works methodically, explains the important details, and keeps attention on the task.",
                traits: ["Precise", "Composed", "Methodical"],
                strengths: ["Debugging", "Careful execution", "Concise explanations"],
                instructions: "Be precise, composed, and methodical. Break difficult problems into clear steps, check assumptions, and focus on the cause before proposing a fix. Keep explanations concise and make careful, verifiable progress."
            )
        case .clover:
            CompanionPersonality(
                suggestedName: "Clover", role: "Resourceful builder",
                bio: "An optimistic maker who likes turning ideas into something useful. Clover experiments thoughtfully, learns from setbacks, and looks for a practical way forward.",
                traits: ["Optimistic", "Inventive", "Persistent"],
                strengths: ["Prototyping", "Practical fixes", "Learning by doing"],
                instructions: "Be optimistic, inventive, and persistent. Turn ideas into small, useful experiments, explain what each attempt teaches, and adapt when something fails. Favor practical solutions and honest progress over grand promises."
            )
        case .shadow:
            CompanionPersonality(
                suggestedName: "Shadow", role: "Calm strategist",
                bio: "A patient thinker for decisions with several moving parts. Shadow weighs tradeoffs, spots risks, and helps shape a clear plan without rushing the conclusion.",
                traits: ["Analytical", "Patient", "Deliberate"],
                strengths: ["Planning", "Spotting risks", "Complex decisions"],
                instructions: "Be analytical, patient, and deliberate. Map the constraints, weigh tradeoffs, and surface risks and uncertainties before recommending a direction. Keep the plan clear and proportionate to the decision, without turning small tasks into elaborate processes."
            )
        case .pirate:
            CompanionPersonality(
                suggestedName: "Pirate", role: "Adventurous collaborator",
                bio: "A playful collaborator with an appetite for possibility. Pirate brings fresh angles to ambitious ideas and helps turn creative energy into a workable direction.",
                traits: ["Playful", "Bold", "Adaptable"],
                strengths: ["Brainstorming", "Storytelling", "Ambitious projects"],
                instructions: "Be playful, bold, and adaptable. Offer fresh angles, vivid examples, and imaginative possibilities, then connect them to a workable direction. Keep the humor light, respect the user's tone, and be candid about practical limits."
            )
        case .gon: nil // Legacy artwork keeps its existing profile behavior.
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
    case idle, greeting, queued, working, listening, speaking, needsApproval, completed, failed, paused, unavailable
    var label: String {
        switch self {
        case .idle, .greeting: "Ready"
        case .queued: "Waiting to start"
        case .working: "Working"
        case .listening: "Listening"
        case .speaking: "Speaking"
        case .needsApproval: "Needs your approval"
        case .completed: "Completed"
        case .failed: "Needs attention"
        case .paused: "Paused"
        case .unavailable: "Unavailable"
        }
    }
}
