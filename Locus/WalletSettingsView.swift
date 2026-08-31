import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

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
                case .setupRequired, .backupIncomplete, .rotationRequired, .locked, .ready:
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(WalletHubSection.allCases) { section in
                    Button(section.rawValue) { selectedSection = section }
                        .buttonStyle(.bordered)
                        .tint(selectedSection == section ? LocusTheme.ink : LocusTheme.textSecondary)
                        .controlSize(.small)
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
            gatedCapabilityCard(
                title: "Swap", symbol: "arrow.left.arrow.right",
                detail: "Exact-input swap adapters activate only after their reviewed route, slippage, fee, package or program, simulation, legal-region, and signed release gates pass."
            )
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
                Text("Prepare a semantic transfer, simulate it, review decoded effects, then approve the exact transaction in the isolated signer.")
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
                                .disabled(gateway.status != .unlocked)
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
            Button("Create Locus Vault") {
                Task { _ = await gateway.beginVaultCreation() }
            }
            .buttonStyle(.borderedProminent)
            .tint(LocusTheme.ink)
            .accessibilityIdentifier("settings.wallet.create")
            Button("Restore from 24 Words") {
                Task { _ = await gateway.beginVaultRestoration() }
            }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.wallet.restore")
        }
    }

    private var backupIncompleteContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Confirm your recovery backup", systemImage: "key.viewfinder")
                .font(.title3.weight(.semibold))
            Text("The vault cannot be used until the requested recovery words are confirmed.")
                .foregroundStyle(LocusTheme.textSecondary)
            ProgressView("The isolated recovery window owns phrase display and verification.")
                .controlSize(.small)
        }
    }

    private var rotationRequiredContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Rotate for Mainnet", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3.weight(.semibold))
            Text("Your earlier preview vault remains encrypted and recovery-only. Mainnet signing stays disabled until you create and verify a new production recovery phrase.")
                .foregroundStyle(LocusTheme.textSecondary)
            Button("Create Production Recovery Phrase") {
                Task { _ = await gateway.beginMainnetRotation() }
            }
            .buttonStyle(.borderedProminent)
            .tint(LocusTheme.ink)
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
                    .disabled(gateway.status != .unlocked || !sendSupported(snapshot))
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
        }
    }

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
            Text("Future Capabilities").font(.headline)
            ForEach(WalletExternalConnectorCatalog.connectors) { descriptor in
                HStack {
                    Text(descriptor.name).font(.body.weight(.medium))
                    Spacer()
                    Text("Unavailable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LocusTheme.textTertiary)
                }
            }
            Text("Connectors and chain adapters remain unavailable until their signed capability, legal-region, and release gates are bundled in a notarized build.")
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
        guard let network = WalletNetworkCatalog.descriptor(id: snapshot.networkID)
        else { return false }
        if snapshot.assetID == network.nativeAssetID {
            return snapshot.chain == .evm || snapshot.chain == .solana
        }
        if snapshot.chain == .evm {
            return WalletEVMAssetIdentity.parse(snapshot.assetID) != nil
        }
        guard snapshot.chain == .solana,
              WalletSolanaAssetIdentity.parse(snapshot.assetID)?.program == .spl,
              let asset = gateway.assets.first(where: { $0.id == snapshot.assetID })
        else { return false }
        return asset.isVisibleByDefault && asset.kind == .fungibleToken
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
        case WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn:
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
                "Raw destination",
                placeholder: snapshot.chain == .solana ? "Base58 address" : "0x…",
                text: $recipient
            )
            if isNFT {
                if let fixedTokenID = assetIdentity?.tokenID {
                    LabeledContent("Token ID") {
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

            Text("The exact raw destination, network, amount, maximum fee, decoded effects, and fresh simulation appear again before signing.")
                .font(.callout)
                .foregroundStyle(LocusTheme.textSecondary)

            if snapshot.chain == .sui
                || (snapshot.chain == .solana && !isNative && !isReviewedSPL) {
                Label("This chain adapter remains disabled until its signer and audit gate passes.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.warning)
            }
            if let error = gateway.lastError, !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(LocusTheme.dangerForeground)
            }

            Spacer()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(preparing ? "Preparing…" : "Review Transaction") {
                    prepare()
                }
                .buttonStyle(.borderedProminent)
                .tint(LocusTheme.ink)
                .disabled(!isValid || preparing)
            }
        }
        .padding(24)
        .frame(width: 520, height: 500)
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

    private var solanaAssetIdentity: WalletSolanaAssetIdentity? {
        WalletSolanaAssetIdentity.parse(snapshot.assetID)
    }

    private var isNative: Bool { snapshot.assetID == network?.nativeAssetID }
    private var isNFT: Bool {
        assetIdentity?.standard == .erc721 || assetIdentity?.standard == .erc1155
    }
    private var isReviewedSPL: Bool {
        guard snapshot.chain == .solana,
              solanaAssetIdentity?.program == .spl,
              let asset, asset.kind == .fungibleToken,
              asset.isVisibleByDefault,
              asset.decimals.map({ (0...255).contains($0) }) == true else {
            return false
        }
        return true
    }

    private var resolvedTokenID: String? {
        assetIdentity?.tokenID
            ?? WalletBaseUnits.normalize(tokenID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var isValid: Bool {
        let destination = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let validDestination: Bool = switch snapshot.chain {
        case .evm:
            destination.count == 42 && destination.hasPrefix("0x")
                && destination.dropFirst(2).allSatisfy(\.isHexDigit)
        case .solana:
            WalletSolanaBase58.decode(destination, exactLength: 32) != nil
        case .sui:
            false
        }
        guard validDestination,
              WalletAmountFormatter.baseUnits(
                  from: maximumFee.trimmingCharacters(in: .whitespacesAndNewlines),
                  decimals: network?.nativeDecimals ?? 0
              ) != nil,
              snapshot.chain == .evm || isNative || isReviewedSPL else {
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
        }
    }

    private func prepare() {
        guard let feeUnits = WalletAmountFormatter.baseUnits(
            from: maximumFee.trimmingCharacters(in: .whitespacesAndNewlines),
            decimals: network?.nativeDecimals ?? 0
        ) else { return }
        preparing = true
        Task {
            let destination = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
            let ready: Bool
            if isNative, let baseUnits = WalletAmountFormatter.baseUnits(
                from: amount.trimmingCharacters(in: .whitespacesAndNewlines),
                decimals: network?.nativeDecimals ?? 18
            ) {
                ready = await gateway.prepareHumanNativeTransfer(
                    networkID: snapshot.networkID, accountID: snapshot.accountID,
                    recipient: destination, amountBaseUnits: baseUnits,
                    maximumFeeBaseUnits: feeUnits
                )
            } else if assetIdentity?.standard == .erc20 || isReviewedSPL,
                      let decimals = asset?.decimals,
                      let baseUnits = WalletAmountFormatter.baseUnits(
                          from: amount.trimmingCharacters(in: .whitespacesAndNewlines),
                          decimals: decimals
                      ) {
                ready = await gateway.prepareHumanFungibleTransfer(
                    networkID: snapshot.networkID, accountID: snapshot.accountID,
                    assetID: snapshot.assetID, recipient: destination,
                    amountBaseUnits: baseUnits, maximumFeeBaseUnits: feeUnits
                )
            } else if isNFT, let resolvedTokenID {
                ready = await gateway.prepareHumanNFTTransfer(
                    networkID: snapshot.networkID, accountID: snapshot.accountID,
                    assetID: snapshot.assetID, tokenID: resolvedTokenID,
                    recipient: destination, maximumFeeBaseUnits: feeUnits
                )
            } else {
                ready = false
            }
            preparing = false
            if ready { dismiss() }
        }
    }
}

private struct WalletReceiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let snapshot: WalletAccountSnapshot

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
                    Button("Copy Address") { copyAddress() }
                        .buttonStyle(.borderedProminent)
                        .tint(LocusTheme.ink)
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
                Text("The QR is generated locally and encodes \(receivePayload). No address is sent to a QR service.")
                    .font(.caption)
                    .foregroundStyle(LocusTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 500, height: 620)
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
            if entry.reviewedAdapterID == WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn {
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
            "Universal Router V2 exact-input"
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
        return "Only one V2 exact-input command, a nonzero minimum output, the current account as recipient, and a 20-minute deadline are eligible."
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
                }
                .padding(24)
            }

            Divider()
            HStack {
                Button("Cancel", role: .cancel) {
                    gateway.cancelConfirmation(intentID: transaction.id)
                    dismiss()
                }
                Spacer()
                Button(confirmationTitle) {
                    if transaction.source.kind == .humanUI {
                        Task {
                            if await gateway.confirmAndExecuteHumanIntent(intentID: transaction.id) {
                                dismiss()
                            }
                        }
                    } else {
                        gateway.confirm(intentID: transaction.id)
                        dismiss()
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                    .disabled(!canConfirm)
            }
            .padding(18)
            .background(LocusTheme.panel)
        }
        .frame(width: 620, height: 640)
        .interactiveDismissDisabled()
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
        if transaction.expiresAt <= Date() { messages.append("This prepared transaction has expired.") }
        if transaction.policyDecision.lowercased().contains("denied") {
            messages.append("The signer or policy denied this request.")
        }
        return messages
    }

    private var canConfirm: Bool {
        gateway.isTransactionConfirmable(transaction)
    }

    private var confirmationTitle: String {
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
