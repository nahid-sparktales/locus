import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum WalletHubSection: String, CaseIterable, Identifiable {
    case portfolio = "Portfolio"
    case activity = "Activity"
    case send = "Send"
    case receive = "Receive"
    case swap = "Swap"
    case collectibles = "Collectibles"
    case connections = "Connections"
    case agentRules = "Agent Rules"
    case security = "Security"

    var id: String { rawValue }
}

enum WalletSendEligibility {
    static func supports(
        snapshot: WalletAccountSnapshot,
        assets: [WalletAsset]
    ) -> Bool {
        guard let network = WalletNetworkCatalog.descriptor(
            id: snapshot.networkID
        ), network.chain == snapshot.chain else { return false }
        if snapshot.assetID == network.nativeAssetID {
            return network.staticallyReviewedCapabilities.contains(.nativeTransfer)
        }
        guard let asset = assets.first(where: { $0.id == snapshot.assetID }),
              asset.networkID == network.id, asset.chain == network.chain,
              asset.isVisibleByDefault else { return false }
        switch network.chain {
        case .evm:
            guard let identity = WalletEVMAssetIdentity.parse(asset.id),
                  identity.networkID == network.id,
                  asset.reference?.caseInsensitiveCompare(
                      identity.contractAddress
                  ) == .orderedSame else { return false }
            switch identity.standard {
            case .erc20:
                return asset.kind == .fungibleToken
                    && asset.decimals.map({ (0...255).contains($0) }) == true
                    && network.staticallyReviewedCapabilities.contains(
                        .fungibleTokenTransfer
                    )
            case .erc721, .erc1155:
                return (asset.kind == .nft || asset.kind == .collectible)
                    && network.staticallyReviewedCapabilities.contains(.nftTransfer)
            }
        case .solana:
            if let identity = WalletSolanaAssetIdentity.parse(asset.id) {
                return identity.networkID == network.id
                    && asset.reference == identity.mint
                    && asset.kind == .fungibleToken
                    && asset.decimals.map({ (0...255).contains($0) }) == true
                    && network.staticallyReviewedCapabilities.contains(
                        .fungibleTokenTransfer
                    )
            }
            guard let identity = WalletSolanaCollectibleIdentity.parse(asset.id)
            else { return false }
            return identity.networkID == network.id
                && identity.standard == .core
                && asset.reference == identity.address
                && (asset.kind == .nft || asset.kind == .collectible)
                && asset.trust == .curated
                && network.staticallyReviewedCapabilities.contains(.nftTransfer)
        case .sui:
            if let identity = WalletSuiAssetIdentity.parse(asset.id) {
                return identity.networkID == network.id
                    && identity.coinType != WalletSuiAssetIdentity.nativeCoinType
                    && asset.reference == identity.coinType
                    && asset.kind == .fungibleToken
                    && asset.decimals.map({ (0...255).contains($0) }) == true
                    && asset.trust == .curated
                    && network.staticallyReviewedCapabilities.contains(
                        .fungibleTokenTransfer
                    )
            }
            guard let identity = WalletSuiObjectIdentity.parse(asset.id) else {
                return false
            }
            return identity.networkID == network.id
                && asset.reference == identity.objectID
                && (asset.kind == .nft || asset.kind == .collectible)
                && asset.trust == .curated
                && network.staticallyReviewedCapabilities.contains(.nftTransfer)
        }
    }
}

struct WalletSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var gateway: WalletGateway
    @Binding var rpcURL: String
    @Binding var alphaEnabled: Bool
    @Binding var browserEnabled: Bool
    @State private var deletePresented = false
    @State private var deleteRecoveryPresented = false
    @State private var policyPresented = false
    @State private var registryPresented = false
    @State private var contractPolicyEntry: WalletContractRegistryEntry?
    @State private var tokenPolicySnapshot: WalletAccountSnapshot?
    @State private var receiveSnapshot: WalletAccountSnapshot?
    @State private var sendSnapshot: WalletAccountSnapshot?
    @State private var alphaRiskPresented = false
    @State private var browserChangePresented = false
    @State private var requestedBrowserAccess = false
    @State private var advancedExpanded = false
    @State private var selectedSection: WalletHubSection = .portfolio
    @State private var walletConnectURI = ""
    @State private var selectedConnectorNetworks: [WalletExternalConnectorID: String] = [:]
    @State private var selectedConnectorMethods: [
        WalletExternalConnectorID: Set<WalletConnectionMethod>
    ] = [:]
    @State private var connectingConnector: WalletExternalConnectorID?
    @State private var pairingInProgress = false
    @State private var endingConnectionIDs: Set<String> = []
    @State private var swapAccountID = ""
    @State private var swapInputAssetID = ""
    @State private var swapOutputAssetID = ""
    @State private var swapAmount = ""
    @State private var swapSlippageBPS = 50
    @State private var swapMaximumFee = "0.01"
    @State private var preparingSwap = false
    @State private var swapQuoteTime = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch gateway.hubState {
                case .unavailableBuild:
                    unavailableBuildView
                case .alphaDisabled:
                    alphaDisabledView
                case .error:
                    errorView
                case .recoveryUnavailable, .setupRequired, .backupIncomplete,
                     .rotationRequired, .locked, .ready:
                    enabledHeader
                    hubNavigation
                    hubContent
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .task(id: gateway.walletEnabled) {
            gateway.configureRPCURL(rpcURL)
            await gateway.refreshStatus()
            if gateway.walletEnabled {
                await gateway.refreshAccountSnapshots()
                await gateway.checkRPCHealth()
                await gateway.refreshTransactionHistory()
            }
        }
        .onChange(of: rpcURL) { _, value in gateway.configureRPCURL(value) }
        .task(id: selectedSection) {
            guard selectedSection == .swap else { return }
            while !Task.isCancelled {
                swapQuoteTime = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(isPresented: $alphaRiskPresented) {
            WalletAlphaRiskSheet {
                alphaEnabled = true
            }
        }
        .sheet(isPresented: $deletePresented) { WalletVaultDeleteSheet(gateway: gateway) }
        .sheet(isPresented: $deleteRecoveryPresented) {
            WalletRecoveryVaultDeleteSheet(gateway: gateway)
        }
        .sheet(isPresented: $policyPresented) { WalletNativePolicySheet(gateway: gateway) }
        .sheet(isPresented: $registryPresented) { WalletContractRegistrySheet(gateway: gateway) }
        .sheet(item: $receiveSnapshot) { snapshot in
            WalletReceiveSheet(gateway: gateway, snapshot: snapshot)
        }
        .sheet(item: $sendSnapshot) { snapshot in
            WalletSendSheet(gateway: gateway, snapshot: snapshot)
        }
        .sheet(item: $contractPolicyEntry) { entry in
            WalletContractPolicySheet(gateway: gateway, entry: entry)
        }
        .sheet(item: $tokenPolicySnapshot) { snapshot in
            WalletSPLTokenPolicySheet(gateway: gateway, snapshot: snapshot)
        }
        .sheet(item: Binding(
            get: { gateway.pendingBrowserOriginGrant },
            set: { value in if value == nil { gateway.denyBrowserOrigin() } }
        )) { request in
            WalletBrowserOriginGrantSheet(gateway: gateway, request: request)
        }
        .sheet(item: Binding(
            get: { gateway.pendingConfirmation },
            set: { value in
                if value == nil, let pending = gateway.pendingConfirmation {
                    gateway.cancelConfirmation(intentID: pending.id)
                }
            }
        )) { transaction in
            WalletTransactionConfirmationSheet(gateway: gateway, transaction: transaction)
        }
        .sheet(item: Binding(
            get: { gateway.pendingConnectionProposal },
            set: { value in
                if value == nil, gateway.pendingConnectionProposal != nil {
                    gateway.resolveConnectionProposal(approved: false)
                }
            }
        )) { proposal in
            WalletConnectionProposalSheet(gateway: gateway, proposal: proposal)
        }
        .alert(
            requestedBrowserAccess ? "Enable browser wallet access?" : "Disable browser wallet access?",
            isPresented: $browserChangePresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button(requestedBrowserAccess ? "Enable and Reload" : "Disable and Reload") {
                browserEnabled = requestedBrowserAccess
            }
        } message: {
            Text(requestedBrowserAccess
                ? "Open browser tabs must reload before websites can discover Locus Vault. Connection still never authorizes a transaction."
                : "Pending website requests and approvals will be revoked immediately, then open browser tabs will reload to remove Locus Vault.")
        }
    }

    private var unavailableBuildView: some View {
        WalletSectionCard(title: "Locus Vault", symbol: "lock.shield.fill") {
            ContentUnavailableView(
                "Available in the Direct Download",
                systemImage: "arrow.down.app",
                description: Text("The self-custodial wallet uses separately signed signer and recovery components that are available only in the notarized direct download.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
            Text("No wallet setting can enable signing in this build.")
                .font(.callout)
                .foregroundStyle(LocusTheme.textTertiary)
        }
        .accessibilityIdentifier("settings.wallet.unavailable-build")
    }

    private var alphaDisabledView: some View {
        WalletSectionCard(title: "Locus Vault", symbol: "wallet.bifold.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("One recovery phrase. Ethereum, Solana, and Sui accounts.")
                    .font(.title3.weight(.semibold))
                Text("Create or restore a self-custodial wallet, review human and connected-app transactions, and give the Locus agent narrowly capped rules.")
                    .font(.body)
                    .foregroundStyle(LocusTheme.textSecondary)
                Label("Mainnet capabilities remain locked unless their signed audit, legal, and release gates pass", systemImage: "checkmark.shield")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(LocusTheme.success)
                Button("Review Security Model and Enable") { alphaRiskPresented = true }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .controlSize(.large)
                    .accessibilityIdentifier("settings.wallet.enable-alpha")
            }
            .padding(.vertical, 8)
        }
    }

    private var errorView: some View {
        WalletSectionCard(title: "Locus Vault Needs Attention", symbol: "exclamationmark.triangle.fill") {
            Text(gateway.lastError ?? "The wallet signer is unavailable in this build.")
                .font(.body)
                .foregroundStyle(LocusTheme.dangerForeground)
            Button("Try Again") { Task { await gateway.refreshStatus() } }
        }
    }

    private var enabledHeader: some View {
        HStack(spacing: 10) {
            Label("Locus Vault", systemImage: "wallet.bifold.fill")
                .font(.headline)
                .foregroundStyle(LocusTheme.textPrimary)
            Text(gateway.statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(gateway.hubState == .ready ? LocusTheme.success : LocusTheme.warning)
                .accessibilityIdentifier("settings.wallet.status")
            Spacer()
            Button("Turn Off Wallet", role: .destructive) {
                browserEnabled = false
                alphaEnabled = false
            }
            .accessibilityIdentifier("settings.wallet.disable-alpha")
        }
    }

    private var hubNavigation: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 7) {
                ForEach(WalletHubSection.allCases) { section in
                    Button(section.rawValue) { selectedSection = section }
                        .buttonStyle(.bordered)
                        .tint(selectedSection == section ? LocusTheme.ink : LocusTheme.textSecondary)
                        .controlSize(.small)
                        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                        .help("Show \(section.rawValue)")
                        .accessibilityIdentifier("wallet.hub.\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
                }
            }
        }
    }

    @ViewBuilder
    private var hubContent: some View {
        switch selectedSection {
        case .portfolio:
            accountCard
        case .activity:
            activityCard
        case .send:
            sendCard
        case .receive:
            receiveCard
        case .swap:
            swapCard
        case .collectibles:
            collectiblesCard
        case .connections:
            connectionsCard
        case .agentRules:
            spendingRulesCard
        case .security:
            accountCard
            advancedCard
        }
    }

    private var sendCard: some View {
        WalletSectionCard(title: "Send", symbol: "arrow.up.circle.fill") {
            if gateway.accountSnapshots.isEmpty {
                Text("Create or restore the vault before sending.")
                    .foregroundStyle(LocusTheme.textSecondary)
            } else {
            Text("Choose an asset, enter a recipient and amount, then review the transaction before sending.")
                    .foregroundStyle(LocusTheme.textSecondary)
                ForEach(gateway.accountSnapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.symbol).font(.headline)
                            Text(networkName(snapshot.networkID))
                                .font(.caption)
                                .foregroundStyle(LocusTheme.textTertiary)
                        }
                        Spacer()
                        if sendSupported(snapshot) {
                            Button("Send") { sendSnapshot = snapshot }
                                .buttonStyle(.borderedProminent)
                                .tint(LocusTheme.ink)
                                .disabled(
                                    snapshot.ownership == .locusVault
                                        ? gateway.status != .unlocked
                                        : !gateway.connectionHelperAvailable
                                )
                                .accessibilityIdentifier(
                                    "wallet.send.open.\(snapshot.id)"
                                )
                        } else {
                            Label("Release-gated", systemImage: "lock.shield")
                                .font(.caption)
                                .foregroundStyle(LocusTheme.warning)
                        }
                    }
                }
            }
        }
    }

    private var swapCard: some View {
        WalletSectionCard(title: "Swap", symbol: "arrow.left.arrow.right") {
            let accounts = gateway.availableSwapAccounts
            if accounts.isEmpty {
                Label("Release gate locked", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(LocusTheme.warning)
                Text("Swaps are not available for your accounts in this release. When a reviewed network and token pair are enabled, they will appear here.")
                    .foregroundStyle(LocusTheme.textSecondary)
            } else {
                Picker("Account", selection: $swapAccountID) {
                    ForEach(accounts) { account in
                        Text("\(account.label) · \(shortAddress(account.address))")
                            .tag(account.id)
                    }
                }
                .onAppear { initializeSwapSelection(accounts: accounts) }
                .onChange(of: accounts.map(\.id)) { _, _ in
                    initializeSwapSelection(accounts: accounts)
                }
                .onChange(of: swapAccountID) { _, _ in resetSwapAssets() }

                if let networkID = gateway.swapNetworkID(accountID: swapAccountID) {
                    let tokens = gateway.availableSwapAssets(networkID: networkID)
                    HStack {
                        Picker("From", selection: $swapInputAssetID) {
                            ForEach(tokens) { Text($0.symbol).tag($0.id) }
                        }
                        Picker("To", selection: $swapOutputAssetID) {
                            ForEach(tokens) { Text($0.symbol).tag($0.id) }
                        }
                    }
                    HStack {
                        TextField("Amount", text: $swapAmount)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Swap amount")
                        Stepper(
                            "Slippage \(Double(swapSlippageBPS) / 100, specifier: "%.2f")%",
                            value: $swapSlippageBPS, in: 0...500, step: 10
                        )
                        .help("The largest price change you accept between this quote and execution.")
                    }
                    LabeledContent("Maximum network fee (ETH)") {
                        TextField("0.01", text: $swapMaximumFee)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Maximum swap network fee in ETH")
                    }
                    if !swapAmount.isEmpty, swapInputAmountBaseUnits == nil {
                        Label("Enter an amount greater than zero using the token’s decimal precision.", systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(LocusTheme.dangerForeground)
                    }

                    if let quote = gateway.currentSwapQuote,
                       let route = quote.action.swapRoute,
                       let outputAsset = tokens.first(where: {
                           $0.id == quote.action.outputAssetID
                       }) {
                        Divider()
                        if !swapQuoteMatchesSelection {
                            Label("Your selections changed. Refresh the quote before reviewing this swap.", systemImage: "arrow.clockwise")
                                .font(.callout)
                                .foregroundStyle(LocusTheme.warning)
                        } else if quote.expiresAt <= swapQuoteTime {
                            Label("This quote expired. Refresh it to see the current price.", systemImage: "clock.badge.exclamationmark")
                                .font(.callout)
                                .foregroundStyle(LocusTheme.warning)
                        }
                        LabeledContent("Route") {
                            Text(route.pathAssetIDs.compactMap { id in
                                tokens.first(where: { $0.id == id })?.symbol
                            }.joined(separator: " → "))
                        }
                        LabeledContent("Protocol") {
                            Text("Uniswap \(route.protocolVersion.rawValue.uppercased()) · \(route.pathAssetIDs.count - 1) hop\(route.pathAssetIDs.count == 2 ? "" : "s")")
                        }
                        LabeledContent("Expected output") {
                            Text(formatSwapAmount(
                                route.quotedOutputBaseUnits, asset: outputAsset
                            ))
                        }
                        LabeledContent("Minimum output") {
                            Text(formatSwapAmount(
                                quote.action.minimumOutputBaseUnits ?? "0",
                                asset: outputAsset
                            ))
                        }
                        LabeledContent("Quote block") {
                            Text(route.quoteEvidence?.blockNumber ?? "Unavailable")
                        }
                        LabeledContent("Quote expires") {
                            Text(quote.expiresAt, style: .relative)
                        }
                        allowanceDisclosure(gateway.currentSwapAllowance)
                    }

                    HStack {
                        Button(gateway.currentSwapQuote == nil ? "Get Quote" : "Refresh Quote") {
                            Task {
                                guard let baseUnits = swapInputAmountBaseUnits else { return }
                                _ = await gateway.refreshUniswapQuote(
                                    accountID: swapAccountID, networkID: networkID,
                                    inputAssetID: swapInputAssetID,
                                    outputAssetID: swapOutputAssetID,
                                    amountInBaseUnits: baseUnits,
                                    slippageBPS: swapSlippageBPS
                                )
                            }
                        }
                        .disabled(
                            gateway.swapQuoteInProgress || swapInputAmountBaseUnits == nil
                                || swapInputAssetID.isEmpty
                                || swapInputAssetID == swapOutputAssetID
                        )
                        if gateway.swapQuoteInProgress { ProgressView().controlSize(.small) }
                        if gateway.currentSwapAllowance != .unchecked,
                           gateway.currentSwapAllowance != .sufficient {
                            Button("Review Allowance Setup") {
                                guard !preparingSwap, swapQuoteMatchesSelection,
                                      let feeUnits = swapMaximumFeeBaseUnits else { return }
                                preparingSwap = true
                                Task {
                                    defer { preparingSwap = false }
                                    _ = await gateway.prepareNextHumanSwapAllowance(
                                        maximumFeeBaseUnits: feeUnits
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LocusTheme.warning)
                            .disabled(preparingSwap || gateway.swapQuoteInProgress || !swapQuoteMatchesSelection || swapMaximumFeeBaseUnits == nil)
                        }
                        Button(preparingSwap ? "Preparing Review…" : "Review Swap") {
                            guard !preparingSwap, swapQuoteMatchesSelection,
                                  let feeUnits = swapMaximumFeeBaseUnits else { return }
                            preparingSwap = true
                            Task {
                                defer { preparingSwap = false }
                                _ = await gateway.prepareHumanSwap(
                                    maximumFeeBaseUnits: feeUnits
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
                        .disabled(
                            gateway.currentSwapQuote == nil
                                || gateway.currentSwapAllowance != .sufficient
                                || preparingSwap || gateway.swapQuoteInProgress
                                || !swapQuoteMatchesSelection
                                || swapMaximumFeeBaseUnits == nil
                                || (gateway.currentSwapQuote?.expiresAt ?? .distantPast) <= swapQuoteTime
                        )
                    }
                }
            }
            if let error = gateway.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.dangerForeground)
            }
        }
    }

    private var swapQuoteMatchesSelection: Bool {
        guard let quote = gateway.currentSwapQuote,
              let account = gateway.availableSwapAccounts.first(where: { $0.id == swapAccountID }),
              let amount = swapInputAmountBaseUnits else { return false }
        return quote.action.recipient?.caseInsensitiveCompare(account.address) == .orderedSame
            && quote.action.inputAssetID == swapInputAssetID
            && quote.action.outputAssetID == swapOutputAssetID
            && quote.action.amountBaseUnits == amount
            && quote.action.swapRoute?.slippageBPS == swapSlippageBPS
    }

    private var swapInputAmountBaseUnits: String? {
        guard let input = gateway.assets.first(where: { $0.id == swapInputAssetID }),
              let decimals = input.decimals,
              let amount = WalletAmountFormatter.baseUnits(
                from: swapAmount.trimmingCharacters(in: .whitespacesAndNewlines), decimals: decimals
              ), amount != "0" else { return nil }
        return amount
    }

    private var swapMaximumFeeBaseUnits: String? {
        guard let fee = WalletAmountFormatter.baseUnits(
            from: swapMaximumFee.trimmingCharacters(in: .whitespacesAndNewlines), decimals: 18
        ), fee != "0" else { return nil }
        return fee
    }

    @ViewBuilder
    private func allowanceDisclosure(_ state: WalletUniswapAllowanceState) -> some View {
        switch state {
        case .unchecked:
            Label("Allowance not checked", systemImage: "questionmark.circle")
                .foregroundStyle(LocusTheme.textSecondary)
        case .sufficient:
            Label("Finite allowances are sufficient", systemImage: "checkmark.shield")
                .foregroundStyle(LocusTheme.success)
        case .needsERC20Approval(_, _, let amount, let zeroFirst):
            Label(
                zeroFirst
                    ? "Token requires a reviewed zero-first approval, then finite approval of \(amount)."
                    : "Token requires a finite Permit2 approval of \(amount).",
                systemImage: "exclamationmark.shield"
            )
            .foregroundStyle(LocusTheme.warning)
        case .needsPermit2Approval(_, _, let amount, let expiration):
            Label(
                "Permit2 requires a finite router allowance of \(amount), expiring at \(expiration).",
                systemImage: "exclamationmark.shield"
            )
            .foregroundStyle(LocusTheme.warning)
        }
    }

    private func initializeSwapSelection(accounts: [WalletAccount]) {
        if !accounts.contains(where: { $0.id == swapAccountID }) {
            swapAccountID = accounts.first?.id ?? ""
        }
        resetSwapAssets()
    }

    private func resetSwapAssets() {
        guard let networkID = gateway.swapNetworkID(accountID: swapAccountID) else {
            swapInputAssetID = ""
            swapOutputAssetID = ""
            return
        }
        let tokens = gateway.availableSwapAssets(networkID: networkID)
        if !tokens.contains(where: { $0.id == swapInputAssetID }) {
            swapInputAssetID = tokens.first?.id ?? ""
        }
        if !tokens.contains(where: { $0.id == swapOutputAssetID })
            || swapOutputAssetID == swapInputAssetID {
            swapOutputAssetID = tokens.first(where: {
                $0.id != swapInputAssetID
            })?.id ?? ""
        }
    }

    private func formatSwapAmount(_ baseUnits: String, asset: WalletAsset) -> String {
        guard let decimals = asset.decimals else { return baseUnits }
        return WalletAmountFormatter.asset(
            baseUnits: baseUnits, decimals: decimals, symbol: asset.symbol
        ) ?? "\(baseUnits) \(asset.symbol)"
    }

    private var receiveCard: some View {
        WalletSectionCard(title: "Receive", symbol: "arrow.down.circle.fill") {
            ForEach(gateway.accountSnapshots) { snapshot in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(networkName(snapshot.networkID)).font(.headline)
                        Text(shortAddress(snapshot.address))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(LocusTheme.textSecondary)
                    }
                    Spacer()
                    Button("Copy") { copy(snapshot.address) }
                    Button("Show") { receiveSnapshot = snapshot }
                }
                if snapshot.id != gateway.accountSnapshots.last?.id { Divider() }
            }
        }
    }

    private func gatedCapabilityCard(title: String, symbol: String, detail: String) -> some View {
        WalletSectionCard(title: title, symbol: symbol) {
            Label("Release gate locked", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(LocusTheme.warning)
            Text(detail).foregroundStyle(LocusTheme.textSecondary)
            Text("A remote manifest may disable this capability but cannot widen the authority compiled into this build.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var collectiblesCard: some View {
        WalletSectionCard(title: "Collectibles", symbol: "photo.on.rectangle.angled") {
            let collectibles = gateway.assets.filter { $0.kind == .nft || $0.kind == .collectible }
            if collectibles.isEmpty {
                Text("No reviewed collectibles discovered.")
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            ForEach(collectibles) { asset in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.name).font(.headline)
                        Text(asset.canonicalID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(LocusTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(asset.trust == .quarantined ? "Quarantined" : "Trusted")
                        .font(.caption.weight(.semibold))
                    if asset.trust == .quarantined {
                        Button("Trust") { gateway.trustQuarantinedAsset(id: asset.id) }
                    }
                }
            }
            Text("Unknown NFTs stay quarantined. Active HTML, SVG, and script content is never rendered as trusted wallet UI.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var accountCard: some View {
        WalletSectionCard(title: "Account", symbol: "person.crop.circle") {
            switch gateway.hubState {
            case .recoveryUnavailable:
                recoveryUnavailableContent
            case .setupRequired:
                setupRequiredContent
            case .backupIncomplete:
                backupIncompleteContent
            case .rotationRequired:
                rotationRequiredContent
            default:
                if gateway.accountSnapshots.isEmpty {
                    Text("Your public accounts will appear after vault setup completes.")
                        .foregroundStyle(LocusTheme.textSecondary)
                } else {
                    ForEach(gateway.accountSnapshots) { snapshot in
                        accountContent(snapshot)
                        if snapshot.id != gateway.accountSnapshots.last?.id {
                            Divider()
                        }
                    }
                    sessionAuthorityContent
                }
            }
            if let error = gateway.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.dangerForeground)
            }
        }
    }

    private var setupRequiredContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create a separate vault")
                .font(.title3.weight(.semibold))
            Text("Create a new 24-word phrase or restore the one production Locus Vault phrase you already backed up.")
                .font(.body)
                .foregroundStyle(LocusTheme.textSecondary)
            if gateway.recoveryCeremonyActive {
                recoveryProgressContent
            } else {
                Button("Create Locus Vault") {
                    Task { _ = await gateway.beginVaultCreation() }
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(!gateway.canCreateVault)
                .accessibilityIdentifier("settings.wallet.create")
                Button("Restore from 24 Words") {
                    Task { _ = await gateway.beginVaultRestoration() }
                }
                    .buttonStyle(.bordered)
                    .disabled(!gateway.canCreateVault)
                    .accessibilityIdentifier("settings.wallet.restore")
            }
        }
    }

    private var recoveryUnavailableContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recovery helper unavailable", systemImage: "exclamationmark.shield.fill")
                .font(.title3.weight(.semibold))
            Text("This copy of Locus cannot open the signed recovery window. Reinstall the direct-download app before creating, rotating, or restoring a vault.")
                .foregroundStyle(LocusTheme.textSecondary)
            Text("Signing and existing public account information remain isolated from this error.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
        .accessibilityIdentifier("settings.wallet.recovery-unavailable")
    }

    private var recoveryProgressContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(
                gateway.recoveryPresentationState == .presented
                    ? "Recovery window is open."
                    : "Opening the secure recovery window…"
            )
            .controlSize(.small)
            .accessibilityIdentifier(
                gateway.recoveryPresentationState == .presented
                    ? "settings.wallet.recovery.presented"
                    : "settings.wallet.recovery.launching"
            )
            HStack {
                Button("Bring to Front") { gateway.bringRecoveryToFront() }
                    .disabled(gateway.recoveryPresentationState == .idle)
                    .accessibilityIdentifier("settings.wallet.recovery.bring-to-front")
                Button("Cancel", role: .cancel) { gateway.cancelRecoveryCeremony() }
                    .accessibilityIdentifier("settings.wallet.recovery.cancel")
            }
        }
    }

    private var backupIncompleteContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Confirm your recovery backup", systemImage: "key.viewfinder")
                .font(.title3.weight(.semibold))
            Text("The vault cannot be used until the requested recovery words are confirmed.")
                .foregroundStyle(LocusTheme.textSecondary)
            if gateway.recoveryCeremonyActive {
                recoveryProgressContent
            } else {
                Text("The earlier recovery window closed before confirmation. Clear its pending material, then create or restore again.")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.textSecondary)
                Button("Clear Pending Recovery") {
                    Task { await gateway.clearIncompleteRecovery() }
                }
                .accessibilityIdentifier("settings.wallet.recovery.clear-pending")
            }
        }
    }

    private var rotationRequiredContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Rotate for Mainnet", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3.weight(.semibold))
            Text("Your earlier preview vault remains encrypted and recovery-only. Mainnet signing stays disabled until you create and verify a new production recovery phrase.")
                .foregroundStyle(LocusTheme.textSecondary)
            if gateway.recoveryCeremonyActive {
                recoveryProgressContent
            } else {
                Button("Create Production Recovery Phrase") {
                    Task { _ = await gateway.beginMainnetRotation() }
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(!gateway.canRotateForMainnet)
            }
        }
    }

    @ViewBuilder
    private func accountContent(_ snapshot: WalletAccountSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(balanceText(snapshot))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .contentTransition(.numericText())
                    HStack(spacing: 6) {
                        Text(networkName(snapshot.networkID))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(LocusTheme.accentAction.opacity(0.14))
                            .clipShape(Capsule())
                        Text(freshnessText(snapshot))
                            .font(.caption)
                            .foregroundStyle(LocusTheme.textTertiary)
                        if let connector = snapshot.ownership.connectorID {
                            Text(connector.rawValue.capitalized)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(LocusTheme.warning.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
                Button {
                    Task { await gateway.refreshAccountSnapshots() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh \(networkName(snapshot.networkID)) balance")
            }

            HStack(spacing: 8) {
                Text(shortAddress(snapshot.address))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .textSelection(.enabled)
                Button("Copy") { copy(snapshot.address) }
                Button("Send") { sendSnapshot = snapshot }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(
                        !sendSupported(snapshot)
                            || (snapshot.ownership == .locusVault
                                ? gateway.status != .unlocked
                                : !gateway.connectionHelperAvailable)
                    )
                Button("Receive") { receiveSnapshot = snapshot }
                    .buttonStyle(.bordered)
                Spacer()
            }

        }
    }

    private var sessionAuthorityContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if gateway.status == .unlocked {
                Button("Lock Vault") { model.lockWalletSession() }
                    .accessibilityIdentifier("settings.wallet.lock")
            } else if gateway.canAuthorizeSession {
                Button("Unlock Vault") {
                    Task { await model.authorizeWalletSession() }
                }
                .accessibilityIdentifier("settings.wallet.unlock")
            }
            Text(gateway.status == .locked
                ? "Receiving remains available while locked. Signing authority, spending rules, prepared work, and website approvals are cleared."
                : "Unlocked for this Locus session. Sleep, screen lock, quit, update, signer interruption, or manual lock clears authority.")
                .font(.callout)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var activityCard: some View {
        WalletSectionCard(title: "Activity", symbol: "clock.arrow.circlepath") {
            if gateway.transactionHistory.isEmpty {
                Text("No wallet transactions yet.")
                    .font(.body)
                    .foregroundStyle(LocusTheme.textTertiary)
            } else {
                ForEach(gateway.transactionHistory.prefix(8)) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.summary)
                                .font(.headline)
                                .lineLimit(2)
                            Spacer()
                            Text(activityLabel(item.state))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(activityColor(item.state))
                        }
                        Text(item.submittedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(LocusTheme.textTertiary)
                        HStack {
                            Text(shortHash(item.transactionHash))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(LocusTheme.textSecondary)
                            Button("Copy Hash") { copy(item.transactionHash) }
                            if let url = WalletNetworkCatalog.descriptor(id: item.networkID)?
                                .explorerURL(transactionID: item.transactionHash) {
                                Link("View in Explorer", destination: url)
                            }
                        }
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(LocusTheme.warning)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 4)
                    if item.id != gateway.transactionHistory.prefix(8).last?.id {
                        Divider()
                    }
                }
            }
            Button("Refresh Activity") { Task { await gateway.refreshTransactionHistory() } }
        }
    }

    private var spendingRulesCard: some View {
        WalletSectionCard(title: "Agent Spending Rules", symbol: "shield.lefthalf.filled") {
            HStack {
                Text(gateway.activePolicies.isEmpty
                    ? "No active rule. Agent transactions require exact confirmation."
                    : "Rules live only in the current unlocked signer session.")
                    .font(.body)
                    .foregroundStyle(LocusTheme.textSecondary)
                Spacer()
                Button("New Native Rule") { policyPresented = true }
                    .disabled(gateway.status != .unlocked)
            }
            ForEach(gateway.accountSnapshots.filter { snapshot in
                snapshot.chain == .solana
                    && WalletSolanaAssetIdentity.parse(snapshot.assetID)?.program == .spl
            }) { snapshot in
                HStack {
                    Text("\(snapshot.symbol) · \(networkName(snapshot.networkID))")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Button("New Token Rule") { tokenPolicySnapshot = snapshot }
                        .disabled(gateway.status != .unlocked)
                }
            }
            ForEach(gateway.activePolicyStatuses) { status in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(policyLabel(status.policy)) → \(status.policy.allowedRecipients.sorted().joined(separator: ", "))")
                        .font(.headline)
                        .lineLimit(1)
                    if let network = WalletNetworkCatalog.descriptor(
                        id: status.policy.networkID
                    ), status.policy.allowedAssetIDs == [network.nativeAssetID] {
                        Text("Used \(WalletAmountFormatter.asset(baseUnits: status.spentBaseUnits, decimals: network.nativeDecimals, symbol: network.nativeSymbol) ?? status.spentBaseUnits) of \(WalletAmountFormatter.asset(baseUnits: status.policy.maximumSessionBaseUnits, decimals: network.nativeDecimals, symbol: network.nativeSymbol) ?? status.policy.maximumSessionBaseUnits)")
                            .font(.callout)
                            .accessibilityIdentifier("settings.wallet.rule.usage")
                    } else {
                        Text("Used \(status.spentBaseUnits) of \(status.policy.maximumSessionBaseUnits) raw token units")
                            .font(.callout)
                            .accessibilityIdentifier("settings.wallet.rule.usage")
                    }
                    Text("Expires \(status.policy.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                }
            }
            if !gateway.activePolicies.isEmpty {
                Button("Clear Active Rules", role: .destructive) {
                    Task { await gateway.clearPolicies() }
                }
            }
            ForEach(gateway.savedPolicyTemplates) { template in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.name).font(.headline)
                        Text("Saved template · no current authorization")
                            .font(.caption).foregroundStyle(LocusTheme.textTertiary)
                    }
                    Spacer()
                    Button("Authorize") {
                        Task { _ = await gateway.activatePolicyTemplate(id: template.id) }
                    }.disabled(gateway.status != .unlocked)
                    Button("Remove", role: .destructive) { gateway.removePolicyTemplate(id: template.id) }
                }
            }
        }
    }

    private var connectionsCard: some View {
        WalletSectionCard(title: "Connections", symbol: "network") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Browser Wallet Access")
                        .font(.headline)
                    Text("Websites request address access separately for each enabled network. Every transaction still requires exact confirmation.")
                        .font(.callout)
                        .foregroundStyle(LocusTheme.textTertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { gateway.browserProviderEnabled },
                    set: { value in
                        requestedBrowserAccess = value
                        browserChangePresented = true
                    }
                ))
                .labelsHidden()
                .disabled(gateway.status != .unlocked && !gateway.browserProviderEnabled)
                .accessibilityLabel("Browser wallet access")
            }
            ForEach(gateway.approvedBrowserOrigins, id: \.self) { origin in
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(LocusTheme.textTertiary)
                    Text(origin)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        gateway.revokeBrowserOrigin(origin)
                    }
                }
            }
            if gateway.approvedBrowserOrigins.isEmpty {
                Text("No websites are approved.")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.textTertiary)
            }
            Divider()
            Text("Connect an account").font(.headline)
            Text("Locus never imports recovery phrases. MetaMask and Slush show their own approval. Phantom-managed accounts use an exact Locus review and never run automatically.")
                .font(.callout)
                .foregroundStyle(LocusTheme.textTertiary)
            ForEach(WalletExternalConnectorCatalog.connectors) { descriptor in
                let networks = gateway.availableExternalConnectionNetworks(for: descriptor.kind)
                let selectedNetwork = selectedConnectorNetworks[descriptor.kind] ?? ""
                let connector = WalletConnectionConnector(rawValue: descriptor.kind.rawValue)!
                let allowedMethods = gateway.externalConnectionMethods(
                    connector: connector, networkID: selectedNetwork
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(descriptor.name).font(.body.weight(.medium))
                    Text(descriptor.kind == .phantom
                         ? "Managed by Phantom · approve each action in Locus"
                         : "Approve each action in Locus, then in \(descriptor.name)")
                        .font(.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                    Picker("Network", selection: Binding(
                        get: { selectedConnectorNetworks[descriptor.kind] ?? "" },
                        set: { value in
                            selectedConnectorNetworks[descriptor.kind] = value
                            selectedConnectorMethods[descriptor.kind] = value.isEmpty
                                ? [] : [.listAccounts, .sendTransaction]
                        }
                    )) {
                        Text("Select a reviewed network").tag("")
                        ForEach(networks, id: \.id) { network in
                            Text(network.displayName).tag(network.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(connectionOperationInProgress || networks.isEmpty)
                    .accessibilityIdentifier("wallet.connection.network.\(descriptor.kind.rawValue)")
                    if networks.isEmpty {
                        Text("No networks are enabled for \(descriptor.name) in this release.")
                            .font(.callout)
                            .foregroundStyle(LocusTheme.textSecondary)
                            .accessibilityIdentifier("wallet.connection.unavailable.\(descriptor.kind.rawValue)")
                    }
                    if !selectedNetwork.isEmpty {
                        Text("Allow Locus to see your account and request transactions. Connecting does not approve a transaction.")
                            .font(.caption)
                            .foregroundStyle(LocusTheme.textTertiary)
                        ForEach(
                            allowedMethods.subtracting([.listAccounts, .sendTransaction])
                                .sorted(by: { $0.rawValue < $1.rawValue }),
                            id: \.rawValue
                        ) { method in
                            Toggle(WalletConnectionPresentation.methodLabel(method),
                                   isOn: Binding(
                                    get: {
                                        selectedConnectorMethods[descriptor.kind, default: []]
                                            .contains(method)
                                    },
                                    set: { enabled in
                                        if enabled {
                                            selectedConnectorMethods[descriptor.kind, default: []]
                                                .insert(method)
                                        } else {
                                            selectedConnectorMethods[descriptor.kind, default: []]
                                                .remove(method)
                                        }
                                    }
                                   ))
                            .disabled(connectionOperationInProgress)
                        }
                    }
                    Button(connectingConnector == descriptor.kind
                           ? "Connecting to \(descriptor.name)…"
                           : "Connect \(descriptor.name)") {
                        guard !connectionOperationInProgress else { return }
                        connectingConnector = descriptor.kind
                        let methods = selectedConnectorMethods[
                            descriptor.kind, default: [.listAccounts, .sendTransaction]
                        ]
                        Task {
                            defer { connectingConnector = nil }
                            _ = await gateway.beginExternalWalletConnection(
                                descriptor.kind,
                                networkID: selectedNetwork,
                                methods: methods
                            )
                        }
                    }
                    .disabled(
                        !gateway.connectionHelperAvailable
                            || selectedNetwork.isEmpty
                            || !allowedMethods.contains(.sendTransaction)
                            || connectionOperationInProgress
                    )
                    .accessibilityIdentifier("wallet.connection.connect.\(descriptor.kind.rawValue)")
                    if connectingConnector == descriptor.kind {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Complete the connection, then review the account here.")
                                .font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    LocusTheme.surfaceStructural,
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            Divider()
            Text("Connect Locus Vault to a dapp").font(.headline)
            Text("Paste a WalletConnect link or scan its QR code. Review the dapp, accounts, networks, and permissions before connecting.")
                .font(.callout)
                .foregroundStyle(LocusTheme.textSecondary)
            #if LOCUS_DIRECT_DOWNLOAD
            HStack {
                Button("Choose QR Image…") { chooseWalletConnectQRImage() }
                    .disabled(!gateway.connectionHelperAvailable || connectionOperationInProgress)
                Button("Scan with Camera…") {
                    guard !connectionOperationInProgress else { return }
                    pairingInProgress = true
                    Task {
                        defer { pairingInProgress = false }
                        do {
                            let uri = try await WalletQRCodeCameraScanner().scan()
                            _ = await gateway.beginWalletConnectPairing(uri: uri)
                        } catch is CancellationError {
                        } catch let error as WalletPairingURIIntakeError
                            where error == .canceled {
                        } catch {
                            gateway.reportConnectionIntakeError(error)
                        }
                    }
                }
                .disabled(!gateway.connectionHelperAvailable || connectionOperationInProgress)
            }
            #endif
            HStack {
                SecureField("Paste WalletConnect link", text: $walletConnectURI)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .privacySensitive()
                    .accessibilityLabel("WalletConnect pairing link")
                    .disabled(pairingInProgress)
                    .accessibilityIdentifier("settings.wallet.wallet-connect-uri")
                Button(pairingInProgress ? "Waiting for Pairing…" : "Review Pairing") {
                    beginPastedWalletConnectPairing()
                }
                .disabled(
                    !gateway.connectionHelperAvailable
                        || connectionOperationInProgress
                        || !walletConnectURI.trimmingCharacters(in: .whitespacesAndNewlines)
                            .hasPrefix("wc:")
                )
                .accessibilityIdentifier("wallet.connection.review-pairing")
            }
            if pairingInProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the dapp’s connection request…").font(.callout)
                }
                .accessibilityElement(children: .combine)
            }
            if let error = gateway.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.dangerForeground)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wallet.connection.error")
            }
            Divider()
            Text("Connection history").font(.headline)
            if gateway.connections.isEmpty {
                Text("Your connected wallets and dapps will appear here. You can disconnect them at any time.")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.textSecondary)
            }
            ForEach(gateway.connections) { connection in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(connection.peerName).font(.body.weight(.medium))
                        Label(
                            WalletConnectionPresentation.status(connection),
                            systemImage: WalletConnectionPresentation.symbol(connection.state)
                        )
                            .font(.caption)
                            .foregroundStyle(LocusTheme.textTertiary)
                        Text(connection.networkIDs.sorted().map(networkName).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(LocusTheme.textTertiary)
                        if !connection.state.isTerminal {
                            Text("Expires \(connection.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(LocusTheme.textSecondary)
                        } else {
                            Text("Connect again above to start a new session.")
                                .font(.caption)
                                .foregroundStyle(LocusTheme.textSecondary)
                        }
                    }
                    Spacer()
                    if !connection.state.isTerminal {
                        Button(
                            connection.state == .connected ? "Disconnect" : "Cancel",
                            role: .destructive
                        ) {
                            guard endingConnectionIDs.insert(connection.id).inserted else { return }
                            Task {
                                defer { endingConnectionIDs.remove(connection.id) }
                                if connection.state == .connected {
                                    await gateway.disconnectWalletConnection(id: connection.id)
                                } else {
                                    await gateway.cancelConnectionPairing(id: connection.id)
                                }
                            }
                        }
                        .disabled(endingConnectionIDs.contains(connection.id))
                        .accessibilityLabel("\(connection.state == .connected ? "Disconnect" : "Cancel") \(connection.peerName)")
                    }
                }
            }
            if !gateway.connectionHelperAvailable {
                Text("The Direct wallet connector runtime is unavailable in this build.")
                    .font(.caption)
                    .foregroundStyle(LocusTheme.warning)
            }
        }
    }

    private var connectionOperationInProgress: Bool {
        connectingConnector != nil || pairingInProgress
    }

    private func beginPastedWalletConnectPairing() {
        guard !connectionOperationInProgress else { return }
        let uri = walletConnectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        pairingInProgress = true
        Task {
            defer { pairingInProgress = false }
            if await gateway.beginWalletConnectPairing(uri: uri), walletConnectURI.trimmingCharacters(in: .whitespacesAndNewlines) == uri {
                walletConnectURI = ""
            }
        }
    }

    #if LOCUS_DIRECT_DOWNLOAD
    private func chooseWalletConnectQRImage() {
        guard !connectionOperationInProgress else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a WalletConnect QR Image"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize, fileSize > 0,
                  fileSize <= 10 * 1_024 * 1_024 else {
                throw WalletPairingURIIntakeError.oversized
            }
            let imageData = try Data(contentsOf: url, options: .mappedIfSafe)
            guard imageData.count <= 10 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0,
                  width.intValue <= 8_192, height.intValue <= 8_192,
                  width.intValue * height.intValue <= 16_000_000 else {
                throw WalletPairingURIIntakeError.oversized
            }
            guard let image = NSImage(data: imageData) else {
                throw WalletPairingURIIntakeError.noQRCode
            }
            let uri = try WalletPairingURIIntake.decodeImage(image)
            pairingInProgress = true
            Task {
                defer { pairingInProgress = false }
                _ = await gateway.beginWalletConnectPairing(uri: uri)
            }
        } catch {
            gateway.reportConnectionIntakeError(error)
        }
    }
    #endif

    private var advancedCard: some View {
        WalletSectionCard(title: "Advanced", symbol: "slider.horizontal.3") {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    advancedConnection
                    Divider()
                    idleLockControl
                    Divider()
                    advancedContracts
                    Divider()
                    advancedAddresses
                    Divider()
                    futureCapabilities
                    Divider()
                    advancedDiagnostics
                    Divider()
                    walletHelpAndDisclosures
                    Divider()
                    Button("Delete Locus Vault", role: .destructive) { deletePresented = true }
                        .disabled(gateway.vaultState == .missing)
                        .accessibilityIdentifier("settings.wallet.delete")
                    Text("Deletion removes the encrypted vault from this Mac and requires the exact confirmation phrase. Receiving addresses are removed with it.")
                        .font(.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                    if gateway.recoveryOnlyVaultAvailable {
                        Button("Delete Earlier Recovery-Only Vault", role: .destructive) {
                            deleteRecoveryPresented = true
                        }
                        Text("The prior encrypted vault is retained only for deliberate recovery until you explicitly delete it.")
                            .font(.caption)
                            .foregroundStyle(LocusTheme.textTertiary)
                    }
                }
                .padding(.top, 14)
            } label: {
                Text("RPC, contracts, diagnostics, and future capabilities")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.textSecondary)
            }
        }
    }

    private var idleLockControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Automatic Lock").font(.headline)
            Picker(
                "Lock after inactivity",
                selection: Binding(
                    get: { gateway.idleLockMinutes },
                    set: { gateway.configureIdleLock(minutes: $0) }
                )
            ) {
                Text("5 minutes").tag(5)
                Text("10 minutes").tag(10)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
            }
            .pickerStyle(.segmented)
            Text("Sleep, screen lock, quit, update, or signer interruption still locks immediately.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var advancedConnection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sepolia RPC").font(.headline)
            TextField("HTTPS RPC URL", text: $rpcURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.wallet.rpc-url")
            HStack {
                Text(gateway.rpcHealthText)
                    .font(.callout)
                    .foregroundStyle(LocusTheme.textTertiary)
                Spacer()
                Button("Check Connection") { Task { await gateway.checkRPCHealth() } }
            }
            Text("The endpoint stays native and is never sent to Python or included in model context.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var walletHelpAndDisclosures: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Help and Disclosures").font(.headline)
            Link("Recovery guide", destination: walletDocumentURL("WalletRecoveryGuide.md"))
            Link("Wallet terms", destination: walletDocumentURL("WalletTerms.md"))
            Link("Wallet privacy", destination: walletDocumentURL("WalletPrivacy.md"))
            Link("Provider disclosures", destination: walletDocumentURL("WalletProviderDisclosures.md"))
            Link(
                "Support",
                destination: URL(string: "https://github.com/nahid-sparktales/locus/issues")!
            )
            Link(
                "Report a security issue privately",
                destination: URL(string: "https://github.com/nahid-sparktales/locus/security/advisories/new")!
            )
        }
    }

    private func walletDocumentURL(_ name: String) -> URL {
        URL(string: "https://github.com/nahid-sparktales/locus/blob/main/Docs/\(name)")!
    }

    private var advancedContracts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Contract Registry").font(.headline)
                Spacer()
                Button("Add Contract") { registryPresented = true }
                    .disabled(gateway.status != .unlocked)
            }
            Text("Contract and token rules use raw token units until authoritative metadata is available.")
                .font(.caption)
                .foregroundStyle(LocusTheme.warning)
            ForEach(gateway.contractRegistry) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(entry.label).font(.headline)
                        Spacer()
                        if entry.reviewedAdapterID != nil {
                            Button("New Raw-Unit Rule") { contractPolicyEntry = entry }
                                .disabled(gateway.status != .unlocked)
                        }
                        Button("Remove", role: .destructive) {
                            Task { await gateway.removeContractRegistryEntry(id: entry.id) }
                        }
                    }
                    Text(entry.checksumAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Code \(entry.runtimeCodeHash)\nABI \(entry.abiDigest)\nAdapter \(entry.reviewedAdapterID ?? "exact confirmation only")\nMethods \(entry.permittedFunctions.joined(separator: ", "))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(LocusTheme.textTertiary)
                        .textSelection(.enabled)
                }
            }
            if gateway.contractRegistry.isEmpty {
                Text("No registered contracts.")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.textTertiary)
            }
        }
    }

    private var advancedAddresses: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Multichain Addresses").font(.headline)
            ForEach(gateway.accountSnapshots.filter { snapshot in
                guard snapshot.chain != .evm,
                      let network = WalletNetworkCatalog.descriptor(
                          id: snapshot.networkID
                      ) else { return false }
                return snapshot.assetID == network.nativeAssetID
            }) { snapshot in
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.chain == .solana ? "Solana" : "Sui")
                        .font(.headline)
                    Text(snapshot.address)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text(snapshot.chain == .solana
                        ? "SOL and trusted classic SPL transfers use reviewed signing"
                        : "Public address only · signing release-gated")
                        .font(.caption)
                        .foregroundStyle(LocusTheme.warning)
                }
            }
            if gateway.accountSnapshots.allSatisfy({ $0.chain == .evm }) {
                Text("No additional public addresses are available.")
                    .foregroundStyle(LocusTheme.textTertiary)
            }
        }
    }

    private var futureCapabilities: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deferred Capabilities").font(.headline)
            Text("Token-2022 extensions, programmable or compressed NFTs, Sui batching/gRPC migration, Uniswap V4, Jupiter/Cetus swaps, arbitrary messages, broad typed data, and remote collectible media remain outside GA.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var advancedDiagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wallet Reliability Diagnostics").font(.headline)
            Button("Copy Diagnostics") {
                copy(gateway.diagnosticSnapshot().text())
            }
            Text("Includes build, signer, feature-gate, vault, RPC category, and activity counts. Excludes addresses, origins, policy contents, ABIs, signed transactions, recovery material, and unrestricted errors.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private func balanceText(_ snapshot: WalletAccountSnapshot) -> String {
        guard let balance = snapshot.balanceBaseUnits,
              let network = WalletNetworkCatalog.descriptor(
                  id: snapshot.networkID
              ) else { return "Balance unavailable" }
        let asset = gateway.assets.first { $0.id == snapshot.assetID }
        return WalletAmountFormatter.asset(
            baseUnits: balance,
            decimals: asset.map { $0.decimals ?? 0 } ?? network.nativeDecimals,
            symbol: snapshot.symbol
        ) ?? "Balance unavailable"
    }

    private func sendSupported(_ snapshot: WalletAccountSnapshot) -> Bool {
        WalletSendEligibility.supports(snapshot: snapshot, assets: gateway.assets)
    }

    private func freshnessText(_ snapshot: WalletAccountSnapshot) -> String {
        switch snapshot.freshness {
        case .notLoaded: "Not refreshed"
        case .stale: "Last known balance"
        case .current:
            snapshot.refreshedAt.map {
                "Updated \($0.formatted(date: .omitted, time: .shortened))"
            } ?? "Updated"
        }
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(8))…\(address.suffix(6))"
    }

    private func networkName(_ networkID: String) -> String {
        WalletNetworkCatalog.descriptor(id: networkID)?.displayName ?? networkID
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 18 else { return hash }
        return "\(hash.prefix(10))…\(hash.suffix(8))"
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func policyLabel(_ policy: WalletSessionPolicy) -> String {
        guard let adapterID = policy.allowedAdapterIDs.first else { return "Wallet rule" }
        return adapterLabel(adapterID)
    }

    private func adapterLabel(_ adapterID: String) -> String {
        switch adapterID {
        case WalletReviewedAdapters.ethereumNativeTransfer: "Native ETH"
        case WalletReviewedAdapters.solanaNativeTransfer: "Native SOL"
        case WalletReviewedAdapters.erc20: "ERC-20"
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
             WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn:
            "Uniswap exact input"
        default: "Reviewed adapter"
        }
    }

    private func activityLabel(_ state: WalletActivityState) -> String {
        switch state {
        case .submitted: "Pending"
        case .confirmed: "Confirmed"
        case .failed: "Failed"
        case .broadcastUnknown: "Broadcast uncertain"
        }
    }

    private func activityColor(_ state: WalletActivityState) -> Color {
        switch state {
        case .confirmed: LocusTheme.success
        case .submitted: LocusTheme.warning
        case .failed: LocusTheme.coral
        case .broadcastUnknown: LocusTheme.warning
        }
    }

}

private enum WalletConnectionPresentation {
    static func methodLabel(_ method: WalletConnectionMethod) -> String {
        switch method {
        case .listAccounts: "See account addresses"
        case .switchNetwork: "Request network changes"
        case .sendTransaction: "Request transactions"
        case .signInWithEthereum: "Sign in with Ethereum"
        case .signInWithSolana: "Sign in with Solana"
        }
    }

    static func status(_ connection: WalletConnectionRecord) -> String {
        switch connection.state {
        case .pairing: "Connecting"
        case .proposalPending: "Review requested in Locus"
        case .approvalPending:
            switch connection.accountOwnership {
            case .locusVault: "Finishing connection"
            case .connectorManaged: "Waiting for Locus review"
            case .external: "Waiting for wallet approval"
            }
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .expired: "Session expired"
        case .revoked: "Disconnected"
        case .failed: "Connection failed"
        }
    }

    static func symbol(_ state: WalletConnectionLifecycleState) -> String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .expired: "clock.badge.exclamationmark"
        case .revoked: "link.badge.plus"
        case .pairing, .proposalPending, .approvalPending, .reconnecting: "clock"
        }
    }
}

private struct WalletConnectionProposalSheet: View {
    @ObservedObject var gateway: WalletGateway
    let proposal: WalletConnectionProposalReview
    @State private var currentTime = Date()
    @State private var resolved = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
            Label(
                proposal.accounts.isEmpty
                    ? "Review WalletConnect pairing" : "Review connected account",
                systemImage: "network.badge.shield.half.filled"
            )
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.peerName).font(.headline)
                if let peerURL = proposal.peerURL {
                    Text(peerURL)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(LocusTheme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            Text(proposal.accounts.isEmpty
                 ? "Check that this is the dapp you intended to connect. It will receive only the account access and permissions below."
                 : "Check the account and network before adding this connection to Wallet Hub.")
                .font(.callout)
                .foregroundStyle(LocusTheme.textSecondary)
            ForEach(proposal.namespaces, id: \.namespace) { namespace in
                VStack(alignment: .leading, spacing: 5) {
                    Text(namespace.namespace.rawValue.uppercased())
                        .font(.caption.weight(.semibold))
                    Text(namespace.networkIDs.sorted().map {
                        WalletNetworkCatalog.descriptor(id: $0)?.displayName ?? $0
                    }.joined(separator: " · "))
                        .font(.callout.weight(.medium))
                    ForEach(namespace.methods.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) { method in
                        Label(WalletConnectionPresentation.methodLabel(method), systemImage: "checkmark")
                            .font(.callout)
                            .foregroundStyle(LocusTheme.textSecondary)
                    }
                }
                .padding(10)
                .background(LocusTheme.surfaceStructural, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(proposal.accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.label).font(.caption.weight(.semibold))
                    Text(account.address)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Text(account.ownership.isConnectorManaged
                         ? "Managed by Phantom. You approve every action here in Locus. This account cannot run automatically."
                         : "You approve every action here in Locus, then in your wallet. This account cannot run automatically.")
                        .font(.callout)
                        .foregroundStyle(LocusTheme.textSecondary)
                }
                .padding(10)
                .background(LocusTheme.surfaceStructural, in: RoundedRectangle(cornerRadius: 10))
            }
            Label(
                currentTime >= proposal.expiresAt
                    ? "This request expired. Reject it and start a new connection."
                    : "Connecting does not authorize a transaction or sign-in.",
                systemImage: currentTime >= proposal.expiresAt ? "clock.badge.exclamationmark" : "info.circle"
            )
                .font(.callout)
                .foregroundStyle(currentTime >= proposal.expiresAt ? LocusTheme.warning : LocusTheme.textSecondary)
                .accessibilityIdentifier("wallet.connection.proposal.status")
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Reject", role: .cancel) {
                    guard !resolved else { return }
                    resolved = true
                    gateway.resolveConnectionProposal(approved: false)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve Connection") {
                    guard !resolved, Date() < proposal.expiresAt else { return }
                    resolved = true
                    gateway.resolveConnectionProposal(approved: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolved || currentTime >= proposal.expiresAt)
                .accessibilityIdentifier("wallet.connection.proposal.approve")
            }
            .padding(18)
            .background(LocusTheme.panel)
        }
        .frame(width: 560, height: 580)
        .interactiveDismissDisabled()
        .task {
            while !Task.isCancelled {
                currentTime = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct WalletSectionCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(LocusTheme.textPrimary)
            content
        }
        .padding(18)
        .locusCard(radius: 12)
    }
}

private struct WalletAlphaRiskSheet: View {
    @Environment(\.dismiss) private var dismiss
    let enable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Enable Locus Vault?", systemImage: "exclamationmark.shield.fill")
                .font(.title2.weight(.bold))
            Text("You—not Locus—are responsible for safeguarding the recovery phrase and reviewing every transaction.")
                .font(.body)
                .foregroundStyle(LocusTheme.textSecondary)
            risk("Mainnet is release-gated", "A signed manifest must prove that audit, legal, soak, incident, provider, notarization, and update-feed gates passed.")
            risk("Create a separate recovery phrase", "Do not reuse or import a MetaMask, Phantom, Slush, or other wallet phrase.")
            risk("Start with limited funds", "Verify recovery and each chain address before increasing balances.")
            risk("Authorization stays narrow", "Enabling the feature does not bypass unlock, simulation, policy checks, or exact confirmation.")
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("I Understand — Enable") {
                    enable()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    private func risk(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LocusTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(LocusTheme.textTertiary)
            }
        }
    }
}

private struct WalletSendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let snapshot: WalletAccountSnapshot
    @State private var recipient = ""
    @State private var amount = ""
    @State private var tokenID = ""
    @State private var maximumFee = "0.01"
    @State private var preparing = false
    @State private var preparationError: String?
    @State private var externalReviewApproved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send \(snapshot.symbol)")
                .font(.title2.weight(.bold))
            Label(networkName, systemImage: "network")
                .font(.headline)
            Text("From \(snapshot.address)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(LocusTheme.textTertiary)
                .textSelection(.enabled)

            field(
                "Recipient address",
                placeholder: snapshot.chain == .solana ? "Base58 address" : "0x…",
                text: $recipient
            )
            if !recipient.isEmpty, !validDestination {
                Label("Enter a valid \(networkName) address. Names and other networks are not supported here.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.dangerForeground)
                    .accessibilityIdentifier("wallet.send.recipient-error")
            }
            if isNFT {
                if let fixedTokenID {
                    LabeledContent(fixedAssetIDLabel) {
                        Text(fixedTokenID).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    field("Token ID", placeholder: "0", text: $tokenID)
                }
            } else {
                field("Amount (\(snapshot.symbol))", placeholder: "0.01", text: $amount)
            }
            field(
                "Maximum network fee (\(network?.nativeSymbol ?? "native asset"))",
                placeholder: "0.01", text: $maximumFee
            )

            Text("You will review the recipient, amount, network fee, and simulation before sending.")
                .font(.callout)
                .foregroundStyle(LocusTheme.textSecondary)
            if snapshot.ownership != .locusVault {
                Label(snapshot.ownership.isConnectorManaged
                      ? "Managed by Phantom. Approve this transfer in Locus. It cannot run automatically."
                      : "After your Locus review, approve this transfer in your connected wallet.",
                      systemImage: "person.crop.circle.badge.checkmark")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.textSecondary)
            }

            if !isTransferSupported {
                Label("This asset does not have an active reviewed transfer path.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.warning)
            }
            if let error = preparationError, !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(LocusTheme.dangerForeground)
            }
            if preparing, externalReviewApproved {
                Label(
                    snapshot.ownership.requiresWalletOwnedConfirmation
                        ? "Continue in your connected wallet to approve or reject this transfer."
                        : "Submitting the transaction you approved in Locus…",
                    systemImage: "clock"
                )
                .font(.callout)
                .foregroundStyle(LocusTheme.textSecondary)
                .accessibilityIdentifier("wallet.send.approval-status")
            }

            Spacer()
            HStack {
                Button("Cancel", role: .cancel) {
                    if let pending = gateway.pendingConfirmation,
                       pending.accountID == snapshot.accountID {
                        gateway.cancelConfirmation(intentID: pending.id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(preparing && externalReviewApproved)
                Spacer()
                if preparing { ProgressView().controlSize(.small).accessibilityLabel("Preparing transaction review") }
                Button(preparing
                       ? (externalReviewApproved ? "Waiting for Transaction…" : "Preparing…")
                       : "Review Transaction") {
                    prepare()
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(!isValid || preparing)
                .accessibilityIdentifier("wallet.send.review")
            }
        }
        .padding(24)
        .frame(width: 560, height: 600)
        .interactiveDismissDisabled(preparing)
        .sheet(item: Binding<WalletPreparedTransaction?>(
            get: {
                guard snapshot.ownership != .locusVault,
                      gateway.pendingConfirmation?.accountID == snapshot.accountID else { return nil }
                return gateway.pendingConfirmation
            },
            set: { value in
                if value == nil, let pending = gateway.pendingConfirmation,
                   pending.accountID == snapshot.accountID {
                    gateway.cancelConfirmation(intentID: pending.id)
                }
            }
        )) { transaction in
            WalletTransactionConfirmationSheet(
                gateway: gateway, transaction: transaction,
                didApprove: { externalReviewApproved = true }
            )
        }
    }

    private var networkName: String {
        WalletNetworkCatalog.descriptor(id: snapshot.networkID)?.displayName ?? snapshot.networkID
    }

    private var network: WalletNetworkDescriptor? {
        WalletNetworkCatalog.descriptor(id: snapshot.networkID)
    }

    private var asset: WalletAsset? {
        gateway.assets.first { $0.id == snapshot.assetID }
    }

    private var assetIdentity: WalletEVMAssetIdentity? {
        WalletEVMAssetIdentity.parse(snapshot.assetID)
    }

    private var solanaCollectibleIdentity: WalletSolanaCollectibleIdentity? {
        WalletSolanaCollectibleIdentity.parse(snapshot.assetID)
    }

    private var suiObjectIdentity: WalletSuiObjectIdentity? {
        WalletSuiObjectIdentity.parse(snapshot.assetID)
    }

    private var isNative: Bool { snapshot.assetID == network?.nativeAssetID }
    private var isNFT: Bool {
        assetIdentity?.standard == .erc721 || assetIdentity?.standard == .erc1155
            || solanaCollectibleIdentity?.standard == .core
            || suiObjectIdentity != nil
    }

    private var fixedTokenID: String? {
        assetIdentity?.tokenID ?? solanaCollectibleIdentity?.address
            ?? suiObjectIdentity?.objectID
    }

    private var fixedAssetIDLabel: String {
        if suiObjectIdentity != nil { return "Object ID" }
        if solanaCollectibleIdentity != nil { return "Asset address" }
        return "Token ID"
    }

    private var isTransferSupported: Bool {
        WalletSendEligibility.supports(
            snapshot: snapshot, assets: gateway.assets
        )
    }

    private var resolvedTokenID: String? {
        fixedTokenID
            ?? WalletBaseUnits.normalize(tokenID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var validDestination: Bool {
        let destination = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch snapshot.chain {
        case .evm:
            destination.count == 42 && destination.hasPrefix("0x")
                && destination.dropFirst(2).allSatisfy(\.isHexDigit)
        case .solana:
            WalletSolanaBase58.decode(destination, exactLength: 32) != nil
        case .sui:
            WalletSuiAddress.isCanonical(destination)
        }
    }

    private var isValid: Bool {
        guard validDestination, isTransferSupported,
              WalletAmountFormatter.baseUnits(
                  from: maximumFee.trimmingCharacters(in: .whitespacesAndNewlines),
                  decimals: network?.nativeDecimals ?? 0
              ).map({ $0 != "0" }) == true else {
            return false
        }
        if isNFT { return resolvedTokenID != nil }
        let decimals = isNative ? (network?.nativeDecimals ?? 18) : (asset?.decimals ?? -1)
        return WalletAmountFormatter.baseUnits(
            from: amount.trimmingCharacters(in: .whitespacesAndNewlines), decimals: decimals
        ).map { $0 != "0" } == true
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .disabled(preparing)
        }
    }

    private func prepare() {
        guard !preparing, isValid, let feeUnits = WalletAmountFormatter.baseUnits(
            from: maximumFee.trimmingCharacters(in: .whitespacesAndNewlines),
            decimals: network?.nativeDecimals ?? 0
        ) else { return }
        preparationError = nil
        externalReviewApproved = false
        preparing = true
        Task {
            let destination = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            let ready: Bool
            if isNative, let baseUnits = WalletAmountFormatter.baseUnits(
                from: amount.trimmingCharacters(in: .whitespacesAndNewlines),
                decimals: network?.nativeDecimals ?? 18
            ) {
                if snapshot.ownership == .locusVault {
                    ready = await gateway.prepareHumanNativeTransfer(
                        networkID: snapshot.networkID, accountID: snapshot.accountID,
                        recipient: destination, amountBaseUnits: baseUnits,
                        maximumFeeBaseUnits: feeUnits
                    )
                } else {
                    ready = await gateway.executeExternalHumanTransfer(
                        networkID: snapshot.networkID, accountID: snapshot.accountID,
                        kind: .nativeTransfer, recipient: destination,
                        amountBaseUnits: baseUnits, maximumFeeBaseUnits: feeUnits
                    )
                }
            } else if !isNFT, !isNative, asset?.kind == .fungibleToken,
                      let decimals = asset?.decimals,
                      let baseUnits = WalletAmountFormatter.baseUnits(
                          from: amount.trimmingCharacters(in: .whitespacesAndNewlines),
                          decimals: decimals
                      ) {
                if snapshot.ownership == .locusVault {
                    ready = await gateway.prepareHumanFungibleTransfer(
                        networkID: snapshot.networkID, accountID: snapshot.accountID,
                        assetID: snapshot.assetID, recipient: destination,
                        amountBaseUnits: baseUnits, maximumFeeBaseUnits: feeUnits
                    )
                } else {
                    ready = await gateway.executeExternalHumanTransfer(
                        networkID: snapshot.networkID, accountID: snapshot.accountID,
                        kind: .fungibleTokenTransfer, assetID: snapshot.assetID,
                        recipient: destination, amountBaseUnits: baseUnits,
                        maximumFeeBaseUnits: feeUnits
                    )
                }
            } else if isNFT, let resolvedTokenID {
                if snapshot.ownership == .locusVault {
                    ready = await gateway.prepareHumanNFTTransfer(
                        networkID: snapshot.networkID, accountID: snapshot.accountID,
                        assetID: snapshot.assetID, tokenID: resolvedTokenID,
                        recipient: destination, maximumFeeBaseUnits: feeUnits
                    )
                } else {
                    ready = await gateway.executeExternalHumanTransfer(
                        networkID: snapshot.networkID, accountID: snapshot.accountID,
                        kind: .nftTransfer, assetID: snapshot.assetID,
                        tokenID: resolvedTokenID, recipient: destination,
                        amountBaseUnits: "1", maximumFeeBaseUnits: feeUnits
                    )
                }
            } else {
                ready = false
            }
            preparing = false
            if ready { dismiss() }
            else { preparationError = gateway.lastError }
        }
    }
}

private struct WalletReceiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let snapshot: WalletAccountSnapshot
    @State private var addressCopied = false

    private var currentSnapshot: WalletAccountSnapshot {
        gateway.accountSnapshots.first(where: { $0.id == snapshot.id }) ?? snapshot
    }

    private var network: WalletNetworkDescriptor? {
        WalletNetworkCatalog.descriptor(id: currentSnapshot.networkID)
    }

    private var asset: WalletAsset? {
        gateway.assets.first { $0.id == currentSnapshot.assetID }
    }

    private var receivePayload: String {
        WalletReceiveURI.payload(
            address: currentSnapshot.address, networkID: currentSnapshot.networkID
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Label("Receive \(currentSnapshot.symbol)", systemImage: "arrow.down.circle.fill")
                        .font(.title2.weight(.bold))
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Text(network?.displayName ?? currentSnapshot.networkID)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(LocusTheme.accentAction.opacity(0.14))
                    .clipShape(Capsule())
                if let image = qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("QR code for the \(network?.displayName ?? currentSnapshot.networkID) account address")
                }
                Text(currentSnapshot.address)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                HStack {
                    Button(addressCopied ? "Address Copied" : "Copy Address") { copyAddress() }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
                        .accessibilityIdentifier("wallet.receive.copy-address")
                    Button("Refresh Balance") {
                        Task { await gateway.refreshAccountSnapshots() }
                    }
                }
                Text(currentSnapshot.balanceBaseUnits.flatMap {
                    WalletAmountFormatter.asset(
                        baseUnits: $0,
                        decimals: asset.map { $0.decimals ?? 0 }
                            ?? (network?.nativeDecimals ?? 0),
                        symbol: currentSnapshot.symbol
                    )
                }
                    ?? "Balance unavailable")
                    .font(.headline)
                if currentSnapshot.networkID == WalletGateway.sepoliaNetworkID {
                    Link(
                        "Find a Sepolia faucet on Ethereum.org",
                        destination: URL(string: "https://ethereum.org/en/developers/docs/networks/#sepolia-testnets")!
                    )
                }
                Label("Use only \(network?.displayName ?? currentSnapshot.networkID) when sending to this address.", systemImage: "network")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                Text("This QR code is generated on your Mac.")
                    .font(.caption)
                    .foregroundStyle(LocusTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 500, height: 620)
        .task(id: addressCopied) {
            guard addressCopied else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            addressCopied = false
        }
    }

    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(receivePayload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentSnapshot.address, forType: .string)
        addressCopied = true
    }
}

private struct WalletBrowserOriginGrantSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let request: WalletBrowserOriginGrant

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Allow this website to see your \(networkName) address?", systemImage: "globe.badge.chevron.backward")
                .font(.title2.weight(.bold))
            Text(request.origin)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("Connecting shares only the public address for \(networkName). It does not authorize transactions; every transaction requires a separate exact confirmation.")
                .font(.body)
                .foregroundStyle(LocusTheme.textSecondary)
            Text("The connection ends when you navigate to another website, lock the vault, quit, or restart Locus.")
                .font(.callout)
                .foregroundStyle(LocusTheme.warning)
            HStack {
                Button("Deny", role: .cancel) { gateway.denyBrowserOrigin(); dismiss() }
                Spacer()
                Button("Allow Address Access") { gateway.approveBrowserOrigin(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
            }
        }
        .padding(24).frame(width: 500).interactiveDismissDisabled()
    }

    private var networkName: String {
        WalletNetworkCatalog.descriptor(id: request.networkID)?.displayName ?? request.networkID
    }
}

private struct WalletNativePolicySheet: View {
    private struct PolicyOption: Identifiable {
        let account: WalletAccount
        let network: WalletNetworkDescriptor
        var id: String { "\(account.id)|\(network.id)" }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    @State private var selectedOptionID = ""
    @State private var recipient = ""
    @State private var perTransaction = ""
    @State private var sessionCap = ""
    @State private var feeCap = ""
    @State private var durationMinutes = "30"
    @State private var saveTemplate = false
    @State private var templateName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Create an Agent Spending Rule").font(.title2.weight(.bold))
            Text("This rule lives only inside the signer and disappears when the vault locks or Locus exits.")
                .font(.body).foregroundStyle(LocusTheme.textSecondary)
            Picker("Network", selection: $selectedOptionID) {
                ForEach(options) { option in
                    Text("\(option.network.displayName) · \(option.account.address.prefix(8))…")
                        .tag(option.id)
                }
            }
            field("Approved recipient", placeholder: recipientPlaceholder, text: $recipient)
            field("Maximum per transfer (\(nativeSymbol))", placeholder: "0.001", text: $perTransaction)
            field("Total session allowance (\(nativeSymbol))", placeholder: "0.005", text: $sessionCap)
            field("Maximum fee per transfer (\(nativeSymbol))", placeholder: "0.002", text: $feeCap)
            field("Expires after (minutes, max 480)", placeholder: "30", text: $durationMinutes)
            Toggle("Save as a reusable template (authorization is never saved)", isOn: $saveTemplate)
                .font(.callout)
            if saveTemplate {
                field("Template name", placeholder: "Test network allowance", text: $templateName)
            }
            Label("Only the reviewed native-transfer adapter for this exact account and network can use this rule. Contracts cannot.", systemImage: "shield.lefthalf.filled")
                .font(.callout).foregroundStyle(LocusTheme.warning)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Authorize Rule") { activate() }.buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!valid)
            }
            if let error = gateway.lastError { Text(error).font(.callout).foregroundStyle(LocusTheme.coral) }
        }
        .padding(24).frame(width: 540)
        .onAppear {
            if selectedOptionID.isEmpty { selectedOptionID = options.first?.id ?? "" }
        }
    }

    private var options: [PolicyOption] {
        gateway.accounts.flatMap { account in
            account.networkIDs.compactMap { networkID in
                guard let network = WalletNetworkCatalog.descriptor(id: networkID),
                      account.ownership == .locusVault,
                      network.chain == account.chain,
                      network.chain == .evm || network.chain == .solana,
                      network.staticallyReviewedCapabilities.contains(.autonomousPolicy)
                else { return nil }
                return PolicyOption(account: account, network: network)
            }
        }.sorted {
            if $0.network.environment != $1.network.environment {
                return $0.network.environment == .testnet
            }
            return $0.network.displayName < $1.network.displayName
        }
    }

    private var selectedOption: PolicyOption? {
        options.first { $0.id == selectedOptionID }
    }

    private var nativeSymbol: String { selectedOption?.network.nativeSymbol ?? "asset" }
    private var recipientPlaceholder: String {
        selectedOption?.network.chain == .solana ? "Base58 address" : "0x…"
    }

    private var valid: Bool {
        guard let selectedOption,
              let perTransactionUnits = parsedNative(perTransaction),
              let sessionCapUnits = parsedNative(sessionCap),
              parsedNative(feeCap) != nil else { return false }
        let validRecipient = switch selectedOption.network.chain {
        case .evm:
            recipient.count == 42 && recipient.hasPrefix("0x")
                && recipient.dropFirst(2).allSatisfy(\.isHexDigit)
        case .solana:
            WalletSolanaBase58.decode(recipient, exactLength: 32) != nil
        case .sui:
            false
        }
        return validRecipient
            && WalletBaseUnits.lessThanOrEqual(perTransactionUnits, sessionCapUnits)
            && (Int(durationMinutes) ?? 0) > 0 && (Int(durationMinutes) ?? 0) <= 480
            && (!saveTemplate || !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func activate() {
        guard let selectedOption,
              let minutes = Int(durationMinutes),
              let perTransactionUnits = parsedNative(perTransaction),
              let sessionCapUnits = parsedNative(sessionCap),
              let feeCapUnits = parsedNative(feeCap) else { return }
        let network = selectedOption.network
        let adapterID = network.chain == .solana
            ? WalletReviewedAdapters.solanaNativeTransfer
            : WalletReviewedAdapters.ethereumNativeTransfer
        let policy = WalletSessionPolicy(
            id: UUID().uuidString.lowercased(), accountID: selectedOption.account.id,
            networkID: network.id,
            allowedAssetIDs: [network.nativeAssetID],
            allowedRecipients: [recipient],
            allowedContractIDs: [], allowedAdapterIDs: [adapterID],
            maximumTransactionBaseUnits: perTransactionUnits,
            maximumSessionBaseUnits: sessionCapUnits,
            maximumFeeBaseUnits: feeCapUnits,
            expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60)),
            allowedActionKinds: [.nativeTransfer]
        )
        let template = saveTemplate ? WalletPolicyTemplate(
                id: UUID().uuidString.lowercased(),
                name: templateName.trimmingCharacters(in: .whitespacesAndNewlines),
                accountID: selectedOption.account.id, networkID: network.id,
                recipient: recipient,
                maximumTransactionBaseUnits: perTransactionUnits,
                maximumSessionBaseUnits: sessionCapUnits,
                maximumFeeBaseUnits: feeCapUnits,
                durationMinutes: minutes
            ) : nil
        Task {
            if await gateway.activatePolicy(policy) {
                if let template { gateway.savePolicyTemplate(template) }
                dismiss()
            }
        }
    }

    private func parsedNative(_ value: String) -> String? {
        guard let network = selectedOption?.network else { return nil }
        return WalletAmountFormatter.baseUnits(
            from: value.trimmingCharacters(in: .whitespacesAndNewlines),
            decimals: network.nativeDecimals
        )
    }
}

private struct WalletSPLTokenPolicySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let snapshot: WalletAccountSnapshot
    @State private var recipient = ""
    @State private var perTransaction = ""
    @State private var sessionCap = ""
    @State private var feeCap = ""
    @State private var durationMinutes = "30"

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Create a \(snapshot.symbol) Agent Rule")
                .font(.title2.weight(.bold))
            Text("This signer-owned rule is bound to this exact classic SPL mint, Solana account, recipient, amount caps, fee cap, and unlocked session.")
                .font(.body)
                .foregroundStyle(LocusTheme.textSecondary)
            Text(snapshot.assetID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(LocusTheme.textTertiary)
                .textSelection(.enabled)
            field("Approved recipient", placeholder: "Base58 address", text: $recipient)
            field(
                "Maximum per transfer (\(snapshot.symbol))",
                placeholder: "1", text: $perTransaction
            )
            field(
                "Total session allowance (\(snapshot.symbol))",
                placeholder: "5", text: $sessionCap
            )
            field(
                "Maximum fee per transfer (\(network?.nativeSymbol ?? "SOL"))",
                placeholder: "0.00001", text: $feeCap
            )
            field(
                "Expires after (minutes, max 480)",
                placeholder: "30", text: $durationMinutes
            )
            Label("Token-2022, NFTs, approvals, swaps, and any other program remain outside this rule.", systemImage: "shield.lefthalf.filled")
                .font(.callout)
                .foregroundStyle(LocusTheme.warning)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Authorize Rule") { activate() }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!valid)
            }
            if let error = gateway.lastError {
                Text(error).font(.callout).foregroundStyle(LocusTheme.coral)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var network: WalletNetworkDescriptor? {
        WalletNetworkCatalog.descriptor(id: snapshot.networkID)
    }

    private var asset: WalletAsset? {
        gateway.assets.first { $0.id == snapshot.assetID }
    }

    private var tokenDecimals: Int? {
        guard let asset, asset.isVisibleByDefault,
              asset.kind == .fungibleToken,
              WalletSolanaAssetIdentity.parse(asset.id)?.program == .spl else {
            return nil
        }
        return asset.decimals
    }

    private var valid: Bool {
        guard WalletSolanaBase58.decode(recipient, exactLength: 32) != nil,
              let perTransactionUnits = parsedToken(perTransaction),
              let sessionCapUnits = parsedToken(sessionCap),
              parsedFee(feeCap) != nil,
              let minutes = Int(durationMinutes), (1...480).contains(minutes)
        else { return false }
        return WalletBaseUnits.lessThanOrEqual(
            perTransactionUnits, sessionCapUnits
        )
    }

    private func field(
        _ title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func parsedToken(_ value: String) -> String? {
        guard let tokenDecimals else { return nil }
        return WalletAmountFormatter.baseUnits(
            from: value.trimmingCharacters(in: .whitespacesAndNewlines),
            decimals: tokenDecimals
        )
    }

    private func parsedFee(_ value: String) -> String? {
        guard let network else { return nil }
        return WalletAmountFormatter.baseUnits(
            from: value.trimmingCharacters(in: .whitespacesAndNewlines),
            decimals: network.nativeDecimals
        )
    }

    private func activate() {
        guard let minutes = Int(durationMinutes),
              let perTransactionUnits = parsedToken(perTransaction),
              let sessionCapUnits = parsedToken(sessionCap),
              let feeCapUnits = parsedFee(feeCap) else { return }
        let policy = WalletSessionPolicy(
            id: UUID().uuidString.lowercased(),
            accountID: snapshot.accountID, networkID: snapshot.networkID,
            allowedAssetIDs: [snapshot.assetID],
            allowedRecipients: [recipient], allowedContractIDs: [],
            allowedAdapterIDs: [
                WalletSolanaAssetIdentity.parse(snapshot.assetID)?.program == .token2022
                    ? WalletReviewedAdapters.solanaToken2022TransferChecked
                    : WalletReviewedAdapters.solanaSPLTransferChecked,
            ],
            maximumTransactionBaseUnits: perTransactionUnits,
            maximumSessionBaseUnits: sessionCapUnits,
            maximumFeeBaseUnits: feeCapUnits,
            expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60)),
            allowedActionKinds: [.fungibleTokenTransfer]
        )
        Task {
            if await gateway.activatePolicy(policy) { dismiss() }
        }
    }
}

private struct WalletContractPolicySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let entry: WalletContractRegistryEntry
    @State private var counterparty = ""
    @State private var inputToken = ""
    @State private var perTransaction = ""
    @State private var sessionCap = ""
    @State private var feeCap = ""
    @State private var durationMinutes = "30"

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Authorize an Advanced Contract Rule")
                .font(.title2.weight(.bold))
            Text("\(entry.label) · \(adapterName)")
                .font(.headline)
            Text(entry.checksumAddress).font(.system(.caption, design: .monospaced))
                .foregroundStyle(LocusTheme.muted).textSelection(.enabled)
            Text("This authorization is bound to this registry ID, runtime code hash, adapter, token asset, counterparty, fee ceiling, and signer session.")
                .font(.callout).foregroundStyle(LocusTheme.muted)
            if isSwapAdapter {
                field("Input token address", placeholder: "0x…", text: $inputToken)
            }
            field(counterpartyTitle, placeholder: "0x…", text: $counterparty)
            field("Maximum per action (token base units)", placeholder: "1000000", text: $perTransaction)
            field("Total session allowance (raw token units)", placeholder: "5000000", text: $sessionCap)
            field("Maximum fee per action (wei)", placeholder: "2000000000000000", text: $feeCap)
            field("Expires after (minutes, max 480)", placeholder: "30", text: $durationMinutes)
            Label(adapterWarning, systemImage: "shield.lefthalf.filled")
                .font(.callout).foregroundStyle(LocusTheme.warning)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Authorize Rule") { activate() }.buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!valid)
            }
            if let error = gateway.lastError {
                Text(error).font(.callout).foregroundStyle(LocusTheme.coral)
            }
        }
        .padding(22).frame(width: 520)
    }

    private var adapterName: String {
        switch entry.reviewedAdapterID {
        case WalletReviewedAdapters.erc20: "ERC-20 transfer / finite approval"
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn:
            "Universal Router legacy V2 exact-input"
        case WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn:
            "Universal Router V2/V3 exact-input"
        default: "Exact confirmation only"
        }
    }

    private var counterpartyTitle: String {
        entry.reviewedAdapterID == WalletReviewedAdapters.erc20
            ? "Approved recipient or spender" : "Approved swap recipient"
    }

    private var adapterWarning: String {
        if entry.reviewedAdapterID == WalletReviewedAdapters.erc20 {
            return "Unlimited approvals and any unrecognized side effect still require exact confirmation."
        }
        if entry.reviewedAdapterID
            == WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn {
            return "Only one V2 or V3 exact-input command, canonical route and per-hop limits, a nonzero minimum output, the current account as recipient, and a 20-minute deadline are eligible."
        }
        return "Only one legacy V2 exact-input command, a nonzero minimum output, the current account as recipient, and a 20-minute deadline are eligible."
    }

    private var isSwapAdapter: Bool {
        guard let adapterID = entry.reviewedAdapterID else { return false }
        return [
            WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn,
            WalletReviewedAdapters.uniswapUniversalRouterV2V3ExactIn,
        ].contains(adapterID)
    }

    private var assetAddress: String {
        entry.reviewedAdapterID == WalletReviewedAdapters.erc20
            ? entry.checksumAddress : inputToken
    }

    private var valid: Bool {
        guard entry.reviewedAdapterID != nil,
              isAddress(counterparty), isAddress(assetAddress),
              WalletBaseUnits.normalize(perTransaction) != nil,
              WalletBaseUnits.normalize(sessionCap) != nil,
              WalletBaseUnits.normalize(feeCap) != nil,
              let minutes = Int(durationMinutes), (1...480).contains(minutes),
              gateway.accounts.contains(where: { $0.chain == .evm }) else { return false }
        return WalletBaseUnits.lessThanOrEqual(perTransaction, sessionCap)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func isAddress(_ value: String) -> Bool {
        value.count == 42 && value.hasPrefix("0x")
            && value.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private func activate() {
        guard let account = gateway.accounts.first(where: { $0.chain == .evm }),
              let adapterID = entry.reviewedAdapterID,
              let minutes = Int(durationMinutes) else { return }
        let policy = WalletSessionPolicy(
            id: UUID().uuidString.lowercased(), accountID: account.id,
            networkID: WalletGateway.sepoliaNetworkID,
            allowedAssetIDs: [
                "eip155:11155111/erc20:\(assetAddress.lowercased())"
            ],
            allowedRecipients: [counterparty], allowedContractIDs: [entry.id],
            allowedAdapterIDs: [adapterID],
            maximumTransactionBaseUnits: perTransaction,
            maximumSessionBaseUnits: sessionCap, maximumFeeBaseUnits: feeCap,
            expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60)),
            allowedActionKinds: [.contractCall]
        )
        Task { if await gateway.activatePolicy(policy) { dismiss() } }
    }
}

private struct WalletContractRegistrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    @State private var registryID = ""
    @State private var label = ""
    @State private var address = ""
    @State private var functions = ""
    @State private var abiJSON = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify a Sepolia Contract").font(.title2.weight(.bold))
            Text("Locus reads the deployed bytecode, normalizes the ABI, and records exact function selectors. Registration enables decoded confirmation only; autonomous use still requires a reviewed adapter.")
                .font(.body).foregroundStyle(LocusTheme.muted)
            HStack {
                TextField("Registry ID (for example token.usdc)", text: $registryID)
                TextField("Display label", text: $label)
            }.textFieldStyle(.roundedBorder)
            TextField("Sepolia contract address (0x…)", text: $address).textFieldStyle(.roundedBorder)
            TextField("Permitted signatures, comma-separated", text: $functions).textFieldStyle(.roundedBorder)
            Text("Normalized ABI source").font(.callout.weight(.semibold))
            TextEditor(text: $abiJSON).font(.system(.caption, design: .monospaced))
                .frame(height: 150).overlay(RoundedRectangle(cornerRadius: 6).stroke(LocusTheme.separator))
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Verify and Add") { add() }.buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(registryID.isEmpty || label.isEmpty || address.isEmpty || abiJSON.isEmpty)
            }
            if let error = gateway.lastError { Text(error).font(.callout).foregroundStyle(LocusTheme.coral) }
        }
        .padding(22).frame(width: 660)
    }

    private func add() {
        let draft = WalletContractRegistryDraft(
            id: registryID, networkID: WalletGateway.sepoliaNetworkID,
            address: address, label: label, abiJSON: abiJSON,
            permittedFunctions: functions.split(separator: ",").map(String.init),
            reviewedAdapterID: nil
        )
        Task { if await gateway.addContractRegistryEntry(draft) { dismiss() } }
    }
}

private struct WalletVaultDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    @State private var confirmation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Locus Vault?").font(.title2.weight(.bold))
            Text("This removes the encrypted vault from this Mac. Locus cannot recover funds without your 24-word phrase.")
                .font(.body).foregroundStyle(LocusTheme.muted)
            TextField("Type DELETE LOCUS VAULT", text: $confirmation).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Delete vault", role: .destructive) {
                    Task { if await gateway.deleteVault(confirmation: confirmation) { dismiss() } }
                }.disabled(confirmation != "DELETE LOCUS VAULT")
            }
        }.padding(22).frame(width: 440)
    }
}

private struct WalletRecoveryVaultDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Recovery-Only Vault?").font(.title2.weight(.bold))
            Text("This permanently removes the encrypted preview vault retained during mainnet rotation. It does not delete the active production vault.")
                .font(.body).foregroundStyle(LocusTheme.muted)
            TextField("Type DELETE RECOVERY VAULT", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Delete recovery vault", role: .destructive) {
                    Task {
                        if await gateway.deleteRecoveryVault(confirmation: confirmation) { dismiss() }
                    }
                }
                .disabled(confirmation != "DELETE RECOVERY VAULT")
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}

private struct WalletTransactionConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let transaction: WalletPreparedTransaction
    var didApprove: (() -> Void)? = nil
    @State private var submitting = false
    @State private var submissionError: String?
    @State private var currentTime = Date()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        Label("Review Transaction", systemImage: "checkmark.shield.fill")
                            .font(.title2.weight(.bold))
                        Spacer()
                        Text(networkName)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LocusTheme.accentAction.opacity(0.14))
                            .clipShape(Capsule())
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(requester)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LocusTheme.textTertiary)
                        Text(actionTitle)
                            .font(.system(.title, design: .rounded, weight: .semibold))
                        Text(destinationText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(LocusTheme.textSecondary)
                            .textSelection(.enabled)
                    }

                    summaryStatus(
                        title: transaction.simulationSucceeded ? "Simulation succeeded" : "Simulation failed",
                        detail: transaction.simulation,
                        symbol: transaction.simulationSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill",
                        color: transaction.simulationSucceeded ? LocusTheme.success : LocusTheme.dangerForeground
                    )
                    summaryStatus(
                        title: "Estimated network fee",
                        detail: feeText,
                        symbol: "fuelpump.fill",
                        color: LocusTheme.textSecondary
                    )
                    if let ownership = transactionOwnership, ownership != .locusVault {
                        summaryStatus(
                            title: ownership.isConnectorManaged ? "Approve in Locus" : "Wallet approval comes next",
                            detail: ownership.isConnectorManaged
                                ? "Phantom manages this account. This exact review authorizes this action; no separate Phantom prompt follows."
                                : "After this review, your connected wallet must approve this same transaction before it can be sent.",
                            symbol: "person.crop.circle.badge.checkmark",
                            color: LocusTheme.textSecondary
                        )
                        .accessibilityIdentifier("wallet.transaction.approval-model")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What to Know").font(.headline)
                        ForEach(riskMessages, id: \.self) { message in
                            Label(message, systemImage: canConfirm ? "info.circle" : "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(canConfirm ? LocusTheme.textSecondary : LocusTheme.warning)
                        }
                    }

                    DisclosureGroup("Transaction Details") {
                        VStack(alignment: .leading, spacing: 9) {
                            detailRow("Requester", requester)
                            detailRow("Network", transaction.networkID)
                            detailRow("Account ID", transaction.accountID)
                            detailRow("Intent ID", transaction.id)
                            detailRow("Nonce", transaction.nonce)
                            detailRow("Digest", transaction.digest)
                            detailRow("Spend (base units)", transaction.spendBaseUnits)
                            detailRow("Fee quote (base units)", transaction.feeQuoteBaseUnits)
                            detailRow("Fee ceiling (base units)", transaction.maximumFeeBaseUnits)
                            detailRow("Policy decision", transaction.policyDecision)
                            detailRow("Policy ID", transaction.policyID ?? "None")
                            detailRow("Expires", transaction.expiresAt.formatted(date: .abbreviated, time: .standard))
                            if let contract = transaction.contract {
                                detailRow("Contract", "\(contract.label) · \(contract.address)")
                                detailRow("Method", contract.function)
                                detailRow("Runtime code hash", contract.runtimeCodeHash)
                                detailRow("ABI digest", contract.abiDigest)
                                detailRow("Adapter", transaction.adapterID ?? "None")
                                detailRow("Typed arguments", transaction.action.arguments.map {
                                    "\($0.type): \($0.value)"
                                }.joined(separator: "\n"))
                            } else {
                                detailRow("Recipient", transaction.action.recipient ?? "Unknown")
                                detailRow("Amount (base units)", transaction.action.amountBaseUnits ?? "0")
                            }
                            detailRow("Decoded effects", transaction.effects.map {
                                let destination = $0.spender.map { "spender \($0)" } ?? ($0.to ?? "unknown")
                                return "\($0.kind) \($0.amountBaseUnits) \($0.assetID) → \(destination)"
                            }.joined(separator: "\n"))
                            detailRow("Risk flags", transaction.riskFlags.isEmpty
                                ? "None"
                                : transaction.riskFlags.map(\.rawValue).joined(separator: ", "))
                        }
                        .padding(.top, 10)
                    }
                    .font(.headline)
                    if let error = submissionError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(LocusTheme.dangerForeground)
                            .accessibilityIdentifier("wallet.transaction.error")
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button("Cancel", role: .cancel) {
                    gateway.cancelConfirmation(intentID: transaction.id)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(submitting)
                Spacer()
                if submitting {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Submitting transaction")
                }
                Button(submitting ? "Submitting…" : confirmationTitle) {
                    guard !submitting, canConfirm else { return }
                    submitting = true
                    submissionError = nil
                    didApprove?()
                    if transaction.source.kind == .humanUI,
                       transactionOwnership == .locusVault {
                        Task {
                            if await gateway.confirmAndExecuteHumanIntent(intentID: transaction.id) {
                                dismiss()
                            } else {
                                submissionError = gateway.lastError ?? "The transaction could not be submitted. Check Activity before trying again."
                                submitting = false
                            }
                        }
                    } else {
                        gateway.confirm(intentID: transaction.id)
                        dismiss()
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!canConfirm || submitting)
                    .accessibilityIdentifier("wallet.transaction.confirm")
            }
            .padding(18)
            .background(LocusTheme.panel)
        }
        .frame(width: 620, height: 640)
        .interactiveDismissDisabled()
        .task {
            while !Task.isCancelled {
                currentTime = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var transactionOwnership: WalletAccountOwnership? {
        gateway.accounts.first(where: { $0.id == transaction.accountID })?.ownership
    }

    private var requester: String {
        switch transaction.source.kind {
        case .agent: "Requested by Locus agent"
        case .humanUI: "Requested in Wallet Hub"
        case .browser, .embeddedBrowser:
            "Requested by \(transaction.source.origin ?? "unknown website")"
        case .walletConnectPeer:
            "Requested by \(transaction.source.displayName ?? "WalletConnect peer")"
        }
    }

    private var actionTitle: String {
        if transaction.action.type == .exactInputSwap {
            return "Review Swap"
        }
        if transaction.action.type == .swapAllowanceSetup {
            return "Set Up Swap Allowance"
        }
        if let amount = transaction.action.amountBaseUnits,
           let formatted = formattedSpend(amount) {
            return "Send \(formatted)"
        }
        if let contract = transaction.contract {
            return "Call \(contract.label)"
        }
        return transaction.summary
    }

    private var networkName: String {
        WalletNetworkCatalog.descriptor(id: transaction.networkID)?.displayName
            ?? transaction.networkID
    }

    private var destinationText: String {
        if let contract = transaction.contract {
            return "\(contract.function) · \(contract.address)"
        }
        return transaction.action.recipient ?? "Recipient unavailable"
    }

    private var feeText: String {
        let formatted = formattedNative(transaction.feeQuoteBaseUnits)
            ?? "\(transaction.feeQuoteBaseUnits) base units"
        let ceiling = formattedNative(transaction.maximumFeeBaseUnits)
            ?? "\(transaction.maximumFeeBaseUnits) base units"
        return "\(formatted) · ceiling \(ceiling)"
    }

    private var riskMessages: [String] {
        var messages = transaction.riskFlags.map { flag in
            switch flag {
            case .unlimitedApproval: "This request includes an unlimited token approval."
            case .unknownEffect: "The simulation found an effect Locus cannot fully explain."
            case .undecodableCall: "The contract call could not be fully decoded."
            case .codeHashMismatch: "The contract code no longer matches the reviewed registry entry."
            case .staleQuote: "The quoted contract action may be stale."
            case .networkIdentityMismatch: "The provider reported a different network identity."
            case .providerDisagreement: "Independent providers disagree about this transaction."
            case .staleBlockhash: "The Solana blockhash has expired."
            case .staleObjectVersion: "A Sui object changed after this transaction was reviewed."
            case .lookupTableSubstitution: "A Solana address lookup table changed after review."
            case .packageUpgrade: "A reviewed contract, program, or package changed after review."
            }
        }
        if messages.isEmpty {
            messages.append(transaction.source.kind == .browser
                ? "Website transactions always require this exact confirmation."
                : "No additional risk flags were reported by the reviewed adapter.")
        }
        if transaction.expiresAt <= currentTime { messages.append("This prepared transaction has expired. Cancel and prepare a new review.") }
        if transaction.policyDecision.lowercased().contains("denied") {
            messages.append("The signer or policy denied this request.")
        }
        if transactionOwnership == nil {
            messages.append("This account is no longer available. Reconnect it and prepare a new review.")
        }
        return messages
    }

    private var canConfirm: Bool {
        transactionOwnership != nil
            && currentTime < transaction.expiresAt
            && gateway.isTransactionConfirmable(transaction)
    }

    private var confirmationTitle: String {
        if let ownership = transactionOwnership, ownership != .locusVault {
            return ownership.isConnectorManaged ? "Approve and Send" : "Continue to Wallet Approval"
        }
        if transaction.action.type == .exactInputSwap { return "Confirm Swap" }
        if transaction.action.type == .swapAllowanceSetup { return "Approve Exact Allowance" }
        if let amount = transaction.action.amountBaseUnits,
           let formatted = formattedSpend(amount) {
            return "Confirm and Send \(formatted)"
        }
        if let contract = transaction.contract {
            return "Confirm \(contract.function) on \(networkName)"
        }
        return "Confirm \(networkName) Transaction"
    }

    private func formattedNative(_ baseUnits: String) -> String? {
        guard let network = WalletNetworkCatalog.descriptor(
            id: transaction.networkID
        ) else { return nil }
        return WalletAmountFormatter.asset(
            baseUnits: baseUnits, decimals: network.nativeDecimals,
            symbol: network.nativeSymbol
        )
    }

    private func formattedSpend(_ baseUnits: String) -> String? {
        guard let network = WalletNetworkCatalog.descriptor(
            id: transaction.networkID
        ) else { return nil }
        if transaction.budgetAssetID == network.nativeAssetID {
            return WalletAmountFormatter.asset(
                baseUnits: baseUnits, decimals: network.nativeDecimals,
                symbol: network.nativeSymbol
            )
        }
        guard let asset = gateway.assets.first(where: {
            $0.id == transaction.budgetAssetID
        }), let decimals = asset.decimals else {
            return "\(baseUnits) token units"
        }
        return WalletAmountFormatter.asset(
            baseUnits: baseUnits, decimals: decimals, symbol: asset.symbol
        )
    }

    private func summaryStatus(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(LocusTheme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LocusTheme.textTertiary)
            Text(value.isEmpty ? "None" : value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(LocusTheme.textSecondary)
                .textSelection(.enabled)
        }
    }
}
