import Foundation

/// Presentation-only draft. No permissions, instructions, routing or memory
/// are inferred from character choices. A UUID is reserved before committing.
struct CompanionOnboardingDraft: Codable, Equatable {
    var reservedProfileID = UUID()
    var name = "Pitou"
    var appearance = CompanionAppearance.default
    /// Approved raster data uses the existing portrait store after commit.
    var avatarData: Data?
    var existingProfileID: UUID?
}

struct CompanionOnboardingProgress: Codable, Equatable {
    enum Status: String, Codable { case notOffered, inProgress, deferred, completed }
    enum Step: String, Codable { case welcome, appearance, name, introduction }
    var version = 1
    var status: Status = .notOffered
    var step: Step = .welcome
    var draft = CompanionOnboardingDraft()
    var completedProfileID: UUID?
    var showsSetup = true
}

enum CompanionValidationError: LocalizedError, Equatable {
    case emptyName, nameTooLong, controlCharacter, missingProfile, invalidPortrait

    var errorDescription: String? {
        switch self {
        case .emptyName: "Give your companion a name."
        case .nameTooLong: "Choose a name of 64 characters or fewer."
        case .controlCharacter: "Names cannot contain control characters."
        case .missingProfile: "This agent is no longer available. Choose another agent or create a new companion."
        case .invalidPortrait: "Choose a valid character image before continuing."
        }
    }

    static func validatedName(_ input: String) throws -> String {
        // Check the original input: trimming must not silently discard controls.
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Self.controlCharacter
        }
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Self.emptyName }
        guard name.count <= 64 else { throw Self.nameTooLong }
        return name
    }
}

/// A single presentation record extends the existing profile/portrait owner.
/// The short-lived journal closes the crash window between profile creation
/// and primary binding; it is removed after the canonical profile is saved.
struct AgentCompanionPresentation: Codable, Equatable {
    var version = 1
    var primaryProfileID: UUID?
    var appearances: [UUID: CompanionAppearance] = [:]
    var animationsEnabled = true
    var pendingCreation: AgentProfile?
    var pendingAvatarData: Data?
}
