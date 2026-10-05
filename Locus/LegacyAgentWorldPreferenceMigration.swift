import Foundation
import CoreFoundation

/// One-way import of the retired bundled plugin's cosmetic settings. The old
/// defaults are retained for rollback. Canonical agent/chat/history keys are
/// deliberately absent; installed metadata owns all current presentation IDs.
enum LegacyAgentWorldPreferenceMigration {
    static func values(defaults: UserDefaults?, screenID: String,
                       presentation: PluginWorldPresentation?, authorizedAgentIDs: Set<String>) -> [String: Any] {
        guard let defaults, let presentation else { return [:] }
        var result: [String: Any] = [:]
        if defaults.string(forKey: "Locus.AgentWorld.theme.v1." + screenID) != nil {
            result["theme"] = presentation.worldID
        }
        if let area = defaults.string(forKey: "Locus.AgentWorld.sailingArea.v1." + screenID), ["whole", "left", "right"].contains(area) {
            result["sailing-area"] = area
        }
        if let appearance = defaults.string(forKey: "Locus.AgentWorld.quartersAppearance.v1"),
           presentation.appearances.contains(where: { $0.id == appearance }) {
            result[presentation.appearancePreferenceKey] = appearance
        }
        if let enabled = defaults.object(forKey: "Locus.AgentWorld.islandQuartersEnabled.v1") as? NSNumber,
           CFGetTypeID(enabled) == CFBooleanGetTypeID() {
            result[presentation.contextEnabledPreferenceKey] = enabled.boolValue
        }
        let allowedStyles = Set(presentation.styles.map(\.id))
        let savedStyles = defaults.dictionary(forKey: "Locus.AgentWorld.shipStyles.v1." + screenID) as? [String: String] ?? [:]
        var styles: [String: String] = [:]
        for key in savedStyles.keys.sorted() {
            guard let id = UUID(uuidString: key)?.uuidString, authorizedAgentIDs.contains(id),
                  let style = savedStyles[key], allowedStyles.contains(style) else { continue }
            styles[id] = style
            var candidate = result; candidate[presentation.stylePreferenceKey] = styles
            guard AgentWorldBridgeContract.validPreferences(candidate) else { styles[id] = nil; break }
        }
        if !styles.isEmpty { result[presentation.stylePreferenceKey] = styles }
        // Retired resident appearance has no meaning in an installed world.
        return AgentWorldBridgeContract.validPreferences(result) ? result : [:]
    }
}
