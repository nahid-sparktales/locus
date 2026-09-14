import XCTest

@testable import Locus

final class AgentProfileModelOptionsTests: XCTestCase {
    func testSelectingAnotherProviderReplacesTheAccountAndModelTogether() {
        let claude = ProviderAccount(kind: .claudePlan, preferredModel: "opus[1m]")
        let chatGPT = ProviderAccount(kind: .chatGPT, preferredModel: "gpt-5.6-sol")
        let profile = AgentProfile(name: "Reviewer", route: .providerAccount(claude.id), model: "opus[1m]")
        let options = AgentProfileModelOptions(
            account: chatGPT, reportedModels: ["gpt-5.6-sol", "gpt-5.6-terra"],
            hasAuthoritativeCatalog: true
        )

        let selected = options.selecting(.providerAccount(chatGPT.id), in: profile)

        XCTAssertEqual(selected.route, .providerAccount(chatGPT.id))
        XCTAssertEqual(selected.model, "gpt-5.6-sol")
        XCTAssertEqual(selected.id, profile.id)
        XCTAssertFalse(options.choices.contains("opus[1m]"))
    }

    func testSameProviderAccountsKeepSeparateModelLists() {
        let first = ProviderAccount(kind: .chatGPT, name: "First", preferredModel: "gpt-5.6-sol")
        let second = ProviderAccount(kind: .chatGPT, name: "Second", preferredModel: "gpt-5.6-terra")
        let profile = AgentProfile(name: "Reviewer", route: .providerAccount(first.id), model: "gpt-5.6-sol")
        let options = AgentProfileModelOptions(
            account: second, reportedModels: ["gpt-5.6-terra"], hasAuthoritativeCatalog: true
        )

        let selected = options.selecting(.providerAccount(second.id), in: profile)

        XCTAssertEqual(selected.route, .providerAccount(second.id))
        XCTAssertEqual(selected.model, "gpt-5.6-terra")
        XCTAssertEqual(options.availability(of: "gpt-5.6-sol"), .unavailable)
    }

    func testFallbackAndIncompleteCatalogsNeverDeclareANewModelUnavailable() {
        let account = ProviderAccount(kind: .chatGPT, preferredModel: "gpt-5.3-codex")
        for reported in [[], ["gpt-5.3-codex"]] {
            let options = AgentProfileModelOptions(
                account: account, reportedModels: reported, hasAuthoritativeCatalog: false
            )
            XCTAssertEqual(options.availability(of: "gpt-5.6-sol"), .unverified)
        }
    }

    func testOnlyAConfirmedCatalogCanRejectAnUnlistedModel() {
        let account = ProviderAccount(kind: .chatGPT)
        let options = AgentProfileModelOptions(
            account: account, reportedModels: ["gpt-5.6-sol"], hasAuthoritativeCatalog: true
        )
        XCTAssertEqual(options.availability(of: "gpt-5.6-sol"), .available)
        XCTAssertEqual(options.availability(of: "gpt-5.6-terra"), .unavailable)
    }

    func testFallbackHistoryCannotMixChatGPTAndClaudeChoices() {
        let chatGPT = ProviderAccount(kind: .chatGPT, preferredModel: "opus[1m]")
        let claude = ProviderAccount(kind: .claudePlan, preferredModel: "gpt-5.6-sol")
        for (account, rejected) in [(chatGPT, "opus[1m]"), (claude, "gpt-5.6-sol")] {
            let options = AgentProfileModelOptions(
                account: account, reportedModels: [], hasAuthoritativeCatalog: false
            )
            XCTAssertFalse(options.choices.contains(rejected))
            XCTAssertEqual(options.availability(of: rejected), .unavailable)
            let section = ModelPickerSection.build(
                localModels: [], accounts: [account], accountModels: [:], accountStatus: [:]
            )[1]
            XCTAssertFalse(section.models.contains(rejected))
        }
    }

    func testManagedCatalogCanIntroduceNewAliasesWithoutFallbackFiltering() {
        let account = ProviderAccount(kind: .claudePlan)
        let options = AgentProfileModelOptions(
            account: account, reportedModels: ["new-runtime-alias", "opus[1m]"],
            hasAuthoritativeCatalog: true
        )
        XCTAssertEqual(options.choices, ["new-runtime-alias", "opus[1m]"])
        XCTAssertEqual(options.availability(of: "new-runtime-alias"), .available)
    }

    func testCachedCrossProviderModelsAreExcludedFromEditorAndToolbar() {
        let accounts = [ProviderAccount(kind: .chatGPT), ProviderAccount(kind: .claudePlan)]
        let cached: [UUID: [String]] = [
            accounts[0].id: ["claude-opus-5", "gpt-5.6-sol", "future-openai-alias"],
            accounts[1].id: ["gpt-5.6-sol", "opus[1m]", "future-claude-alias"],
        ]
        let sections = ModelPickerSection.build(
            localModels: [], accounts: accounts, accountModels: cached, accountStatus: [:]
        )
        XCTAssertEqual(sections[1].models, ["gpt-5.6-sol", "future-openai-alias"])
        XCTAssertEqual(sections[2].models, ["opus[1m]", "future-claude-alias"])
        for account in accounts {
            let options = AgentProfileModelOptions(
                account: account, reportedModels: cached[account.id] ?? [], hasAuthoritativeCatalog: false
            )
            XCTAssertEqual(options.choices, sections.first { $0.account?.id == account.id }?.models)
        }
    }

    func testCustomEndpointAndLocalModelsStayScopedWithoutNameFiltering() {
        let account = ProviderAccount(kind: .custom, preferredModel: "private/model")
        let customOptions = AgentProfileModelOptions(
            account: account, reportedModels: ["private/model"], hasAuthoritativeCatalog: true
        )
        XCTAssertEqual(customOptions.availability(of: "private/model"), .available)

        let localOptions = AgentProfileModelOptions(
            account: nil, reportedModels: ["qwen3:27b"], hasAuthoritativeCatalog: true
        )
        let selected = localOptions.selecting(
            .localOllama,
            in: AgentProfile(name: "Local", route: .providerAccount(account.id), model: "private/model")
        )
        XCTAssertEqual(selected.route, .localOllama)
        XCTAssertEqual(selected.model, "qwen3:27b")
    }

    func testChoicesTrimAndDeduplicateModelIDs() {
        let options = AgentProfileModelOptions(
            account: ProviderAccount(kind: .chatGPT),
            reportedModels: [" gpt-5.6-sol ", "GPT-5.6-SOL", "", "gpt-5.6-terra"],
            hasAuthoritativeCatalog: true
        )
        XCTAssertEqual(options.choices, ["gpt-5.6-sol", "gpt-5.6-terra"])
    }
}
