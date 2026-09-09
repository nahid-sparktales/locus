import SwiftUI

struct UsageAccounting: Codable, Hashable {
    var invocations: Int
    var modelCalls: Int
    var totalTokens: Int
    var estimatedAPICost: Double?
    var costCoverage: String
    var pendingCalls: Int
    var uncertainCalls: Int
    var pricingVersions: [String]
    var byPurpose: [String: Int]
    var tokenCategories: [String: Int]?
    var coverageCounts: [String: Int]
    var byModel: [Group]?
    var byWorkspace: [Group]?
    var byDay: [Group]?
    var byAgent: [Group]?
    struct Group: Codable, Hashable, Identifiable {
        var name: String
        var invocations: Int
        var totalTokens: Int
        var estimatedAPICost: Double?
        var costCoverage: String
        var id: String { name }
        enum CodingKeys: String, CodingKey {
            case name, invocations
            case totalTokens = "total_tokens", estimatedAPICost = "estimated_api_cost", costCoverage = "cost_coverage"
        }
    }
    enum CodingKeys: String, CodingKey {
        case invocations
        case modelCalls = "model_calls", totalTokens = "total_tokens", estimatedAPICost = "estimated_api_cost"
        case costCoverage = "cost_coverage", pendingCalls = "pending_calls", uncertainCalls = "uncertain_calls"
        case pricingVersions = "pricing_versions", byPurpose = "by_purpose", tokenCategories = "token_categories"
        case coverageCounts = "coverage_counts", byModel = "by_model", byWorkspace = "by_workspace", byDay = "by_day", byAgent = "by_agent"
    }
    var activityText: String { "\(modelCalls) calls · \(totalTokens.formatted()) tokens" }
    var costText: String {
        guard let cost = estimatedAPICost else {
            return costCoverage == "local" ? "Local execution" : costCoverage == "subscription" ? "Subscription usage" : "API estimate unavailable"
        }
        return cost.formatted(.currency(code: "USD")) + (costCoverage == "known" ? " estimated" : " known subtotal · partial coverage")
    }
}

struct UsageAccountingView: View {
    let accounting: UsageAccounting
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(accounting.costText).font(.headline)
            Text(accounting.activityText).font(.caption)
            if accounting.pendingCalls + accounting.uncertainCalls > 0 {
                Text("\(accounting.pendingCalls) pending · \(accounting.uncertainCalls) unsettled calls").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Usage breakdown") {
                rows(accounting.byPurpose.mapValues(String.init))
                rows((accounting.tokenCategories ?? [:]).mapValues { $0.formatted() })
                Text("Reasoning tokens are included in output tokens.").font(.caption).foregroundStyle(.secondary)
                rows(accounting.coverageCounts.mapValues { "\($0) calls" })
                Text("Pricing: " + (accounting.pricingVersions.isEmpty ? "Unavailable" : accounting.pricingVersions.joined(separator: ", "))).font(.caption).textSelection(.enabled)
                groups("Models", accounting.byModel)
                groups("Projects", accounting.byWorkspace)
                groups("Agents", accounting.byAgent)
                groups("Days", accounting.byDay)
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func rows(_ values: [String: String]) -> some View {
        ForEach(values.keys.sorted(), id: \.self) { key in
            HStack { Text(key.replacingOccurrences(of: "_", with: " ").capitalized); Spacer(); Text(values[key] ?? "") }
        }
    }
    @ViewBuilder private func groups(_ title: String, _ values: [UsageAccounting.Group]?) -> some View {
        if let values, !values.isEmpty {
            DisclosureGroup(title) {
                ForEach(values) { row in
                    VStack(alignment: .leading) {
                        Text(row.name).textSelection(.enabled)
                        Text("\(row.totalTokens.formatted()) tokens · " + (row.estimatedAPICost.map { $0.formatted(.currency(code: "USD")) + " estimated" } ?? row.costCoverage.capitalized))
                    }.padding(.vertical, 2)
                }
            }
        }
    }
}
