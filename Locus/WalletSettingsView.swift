import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct WalletSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var gateway: WalletGateway
    @Binding var rpcURL: String
    @Binding var alphaEnabled: Bool
    @Binding var browserEnabled: Bool
    @State private var recoveryPresented = false
    @State private var deletePresented = false
    @State private var policyPresented = false
    @State private var registryPresented = false
    @State private var contractPolicyEntry: WalletContractRegistryEntry?
    @State private var receiveSnapshot: WalletAccountSnapshot?
    @State private var alphaRiskPresented = false
    @State private var browserChangePresented = false
    @State private var requestedBrowserAccess = false
    @State private var advancedExpanded = false

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
                case .setupRequired, .backupIncomplete, .locked, .ready:
                    enabledHeader
                    accountCard
                    activityCard
                    spendingRulesCard
                    connectionsCard
                    advancedCard
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
        .sheet(isPresented: $recoveryPresented) {
            if let creation = gateway.vaultCreation {
                WalletVaultBackupSheet(gateway: gateway, creation: creation)
            }
        }
        .sheet(isPresented: $deletePresented) { WalletVaultDeleteSheet(gateway: gateway) }
        .sheet(isPresented: $policyPresented) { WalletNativePolicySheet(gateway: gateway) }
        .sheet(isPresented: $registryPresented) { WalletContractRegistrySheet(gateway: gateway) }
        .sheet(item: $receiveSnapshot) { snapshot in
            WalletReceiveSheet(gateway: gateway, snapshot: snapshot)
        }
        .sheet(item: $contractPolicyEntry) { entry in
            WalletContractPolicySheet(gateway: gateway, entry: entry)
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
                description: Text("The private Sepolia alpha uses a separately signed wallet component that is not included in the Mac App Store build.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
            Text("No wallet setting can enable signing in this build.")
                .font(.callout)
                .foregroundStyle(LocusTheme.textTertiary)
        }
        .accessibilityIdentifier("settings.wallet.unavailable-build")
    }

    private var alphaDisabledView: some View {
        WalletSectionCard(title: "Locus Vault Private Alpha", symbol: "wallet.bifold.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("A separate, limited-fund wallet for agent activity on Sepolia.")
                    .font(.title3.weight(.semibold))
                Text("Set up, receive test ETH, review every website transaction, and give the Locus agent narrow spending rules—all without Terminal activation.")
                    .font(.body)
                    .foregroundStyle(LocusTheme.textSecondary)
                Label("Off by default · Sepolia only · no mainnet signing", systemImage: "checkmark.shield")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(LocusTheme.success)
                Button("Review Risks and Enable") { alphaRiskPresented = true }
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
            Label("Sepolia Private Alpha", systemImage: "testtube.2")
                .font(.headline)
                .foregroundStyle(LocusTheme.textPrimary)
            Text(gateway.statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(gateway.hubState == .ready ? LocusTheme.success : LocusTheme.warning)
                .accessibilityIdentifier("settings.wallet.status")
            Spacer()
            Button("Turn Off Alpha", role: .destructive) {
                browserEnabled = false
                alphaEnabled = false
            }
            .accessibilityIdentifier("settings.wallet.disable-alpha")
        }
    }

    private var accountCard: some View {
        WalletSectionCard(title: "Account", symbol: "person.crop.circle") {
            switch gateway.hubState {
            case .setupRequired:
                setupRequiredContent
            case .backupIncomplete:
                backupIncompleteContent
            default:
                if let snapshot = evmSnapshot {
                    accountContent(snapshot)
                } else {
                    Text("The Sepolia account will appear after vault setup completes.")
                        .foregroundStyle(LocusTheme.textSecondary)
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
            Text("Use a new recovery phrase and only limited Sepolia test funds. Never import an external wallet phrase.")
                .font(.body)
                .foregroundStyle(LocusTheme.textSecondary)
            Button("Create Locus Vault") {
                Task {
                    if await gateway.beginVaultCreation() != nil { recoveryPresented = true }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LocusTheme.ink)
            .accessibilityIdentifier("settings.wallet.create")
        }
    }

    private var backupIncompleteContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Confirm your recovery backup", systemImage: "key.viewfinder")
                .font(.title3.weight(.semibold))
            Text("The vault cannot be used until the requested recovery words are confirmed.")
                .foregroundStyle(LocusTheme.textSecondary)
            if gateway.vaultCreation != nil {
                Button("Continue Backup") { recoveryPresented = true }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
            } else {
                Button("Restart Setup") {
                    Task {
                        await gateway.cancelVaultCreation()
                        if await gateway.beginVaultCreation() != nil { recoveryPresented = true }
                    }
                }
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
                        Text("Sepolia")
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
                .accessibilityLabel("Refresh Sepolia balance")
            }

            HStack(spacing: 8) {
                Text(shortAddress(snapshot.address))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(LocusTheme.textSecondary)
                    .textSelection(.enabled)
                Button("Copy") { copy(snapshot.address) }
                Button("Receive") { receiveSnapshot = snapshot }
                    .buttonStyle(.borderedProminent)
                    .tint(LocusTheme.ink)
                Spacer()
            }

            if gateway.status == .unlocked {
                Button("Lock Vault") { model.lockWalletSession() }
                    .accessibilityIdentifier("settings.wallet.lock")
            } else if gateway.canAuthorizeSession {
                Button("Unlock Vault") { Task { await model.authorizeWalletSession() } }
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
                Text("No Sepolia transactions yet.")
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
                            if let url = URL(string: "https://sepolia.etherscan.io/tx/\(item.transactionHash)") {
                                Link("View on Etherscan", destination: url)
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
                Button("New ETH Rule") { policyPresented = true }
                    .disabled(gateway.status != .unlocked)
            }
            ForEach(gateway.activePolicyStatuses) { status in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(policyLabel(status.policy)) → \(status.policy.allowedRecipients.sorted().joined(separator: ", "))")
                        .font(.headline)
                        .lineLimit(1)
                    if status.policy.allowedAdapterIDs.contains("native-eth-transfer-v1") {
                        Text("Used \(WalletAmountFormatter.ether(wei: status.spentBaseUnits) ?? status.spentBaseUnits) of \(WalletAmountFormatter.ether(wei: status.policy.maximumSessionBaseUnits) ?? status.policy.maximumSessionBaseUnits)")
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
                    Text("Lets websites ask to see this Sepolia address. Every transaction still requires exact confirmation.")
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
                    advancedContracts
                    Divider()
                    advancedAddresses
                    Divider()
                    futureCapabilities
                    Divider()
                    advancedDiagnostics
                    Divider()
                    Button("Delete Locus Vault", role: .destructive) { deletePresented = true }
                        .disabled(gateway.vaultState == .missing)
                        .accessibilityIdentifier("settings.wallet.delete")
                    Text("Deletion removes the encrypted vault from this Mac and requires the exact confirmation phrase. Receiving addresses are removed with it.")
                        .font(.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                }
                .padding(.top, 14)
            } label: {
                Text("RPC, contracts, diagnostics, and future capabilities")
                    .font(.callout)
                    .foregroundStyle(LocusTheme.textSecondary)
            }
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
            Text("Read-Only Multichain Addresses").font(.headline)
            ForEach(gateway.accountSnapshots.filter { $0.chain != .evm }) { snapshot in
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.chain == .solana ? "Solana" : "Sui")
                        .font(.headline)
                    Text(snapshot.address)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Public address only · signing unavailable")
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
            Text("MetaMask Connect on Sepolia is the recommended next milestone after this alpha. Mainnet and native Solana/Sui signing remain separate audited projects.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var advancedDiagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Private Alpha Diagnostics").font(.headline)
            Button("Copy Diagnostics") {
                copy(gateway.diagnosticSnapshot().text())
            }
            Text("Includes build, signer, feature-gate, vault, RPC category, and activity counts. Excludes addresses, origins, policy contents, ABIs, signed transactions, recovery material, and unrestricted errors.")
                .font(.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
    }

    private var evmSnapshot: WalletAccountSnapshot? {
        gateway.accountSnapshots.first { $0.chain == .evm }
    }

    private func balanceText(_ snapshot: WalletAccountSnapshot) -> String {
        snapshot.balanceBaseUnits.flatMap(WalletAmountFormatter.ether) ?? "Balance unavailable"
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
        case "native-eth-transfer-v1": "Native ETH"
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
            Label("Enable the Sepolia Private Alpha?", systemImage: "exclamationmark.shield.fill")
                .font(.title2.weight(.bold))
            Text("Locus Vault is experimental. Use it only with test assets you can afford to lose.")
                .font(.body)
                .foregroundStyle(LocusTheme.textSecondary)
            risk("Sepolia only", "Mainnet signing remains unavailable.")
            risk("Create a separate recovery phrase", "Do not reuse or import a MetaMask, Phantom, Slush, or other wallet phrase.")
            risk("Keep funds limited", "Use small faucet amounts for alpha testing.")
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

private struct WalletReceiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let snapshot: WalletAccountSnapshot

    private var currentSnapshot: WalletAccountSnapshot {
        gateway.accountSnapshots.first(where: { $0.id == snapshot.id }) ?? snapshot
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Label("Receive Sepolia ETH", systemImage: "arrow.down.circle.fill")
                        .font(.title2.weight(.bold))
                    Spacer()
                    Button("Done") { dismiss() }
                }
                Text("Sepolia")
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
                        .accessibilityLabel("QR code for the Sepolia account address")
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
                Text(currentSnapshot.balanceBaseUnits.flatMap(WalletAmountFormatter.ether)
                    ?? "Balance unavailable")
                    .font(.headline)
                Link(
                    "Find a Sepolia faucet on Ethereum.org",
                    destination: URL(string: "https://ethereum.org/en/developers/docs/networks/#sepolia-testnets")!
                )
                Text("The QR is generated locally and encodes \(WalletReceiveURI.erc681(address: currentSnapshot.address)). No address is sent to a QR service.")
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
        filter.message = Data(WalletReceiveURI.erc681(address: currentSnapshot.address).utf8)
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
            Label("Allow this website to see your Sepolia address?", systemImage: "globe.badge.chevron.backward")
                .font(.title2.weight(.bold))
            Text(request.origin)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("Connecting only shares the public Sepolia address. It does not authorize transactions; every transaction requires a separate exact confirmation.")
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
}

private struct WalletNativePolicySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
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
            field("Approved recipient", placeholder: "0x…", text: $recipient)
            field("Maximum per transfer (ETH)", placeholder: "0.001", text: $perTransaction)
            field("Total session allowance (ETH)", placeholder: "0.005", text: $sessionCap)
            field("Maximum fee per transfer (ETH)", placeholder: "0.002", text: $feeCap)
            field("Expires after (minutes, max 480)", placeholder: "30", text: $durationMinutes)
            Toggle("Save as a reusable template (authorization is never saved)", isOn: $saveTemplate)
                .font(.callout)
            if saveTemplate {
                field("Template name", placeholder: "Sepolia test allowance", text: $templateName)
            }
            Label("Only the reviewed native-ETH adapter can use this rule. Contracts and unlimited approvals cannot.", systemImage: "shield.lefthalf.filled")
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
        .padding(24).frame(width: 520)
    }

    private var valid: Bool {
        guard let perTransactionWei = parsedETH(perTransaction),
              let sessionCapWei = parsedETH(sessionCap),
              parsedETH(feeCap) != nil else { return false }
        return recipient.count == 42 && recipient.hasPrefix("0x")
            && WalletBaseUnits.lessThanOrEqual(perTransactionWei, sessionCapWei)
            && (Int(durationMinutes) ?? 0) > 0 && (Int(durationMinutes) ?? 0) <= 480
            && (!saveTemplate || !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !gateway.accounts.filter { $0.chain == .evm }.isEmpty
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func activate() {
        guard let account = gateway.accounts.first(where: { $0.chain == .evm }),
              let minutes = Int(durationMinutes),
              let perTransactionWei = parsedETH(perTransaction),
              let sessionCapWei = parsedETH(sessionCap),
              let feeCapWei = parsedETH(feeCap) else { return }
        let policy = WalletSessionPolicy(
            id: UUID().uuidString.lowercased(), accountID: account.id,
            networkID: WalletGateway.sepoliaNetworkID,
            allowedAssetIDs: ["slip44:60"], allowedRecipients: [recipient],
            allowedContractIDs: [], allowedAdapterIDs: ["native-eth-transfer-v1"],
            maximumTransactionBaseUnits: perTransactionWei,
            maximumSessionBaseUnits: sessionCapWei,
            maximumFeeBaseUnits: feeCapWei,
            expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60))
        )
        let template = saveTemplate ? WalletPolicyTemplate(
                id: UUID().uuidString.lowercased(),
                name: templateName.trimmingCharacters(in: .whitespacesAndNewlines),
                accountID: account.id, networkID: WalletGateway.sepoliaNetworkID,
                recipient: recipient, maximumTransactionBaseUnits: perTransactionWei,
                maximumSessionBaseUnits: sessionCapWei, maximumFeeBaseUnits: feeCapWei,
                durationMinutes: minutes
            ) : nil
        Task {
            if await gateway.activatePolicy(policy) {
                if let template { gateway.savePolicyTemplate(template) }
                dismiss()
            }
        }
    }

    private func parsedETH(_ value: String) -> String? {
        WalletAmountFormatter.wei(fromEther: value.trimmingCharacters(in: .whitespacesAndNewlines))
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
            expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60))
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

private struct WalletVaultBackupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let creation: WalletVaultCreation
    @State private var confirming = false
    @State private var answers: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(confirming ? "Confirm your recovery phrase" : "Write down these 24 words")
                .font(.title2.weight(.bold))
            Text(confirming
                 ? "Enter the six requested words. Paste and clipboard actions are disabled."
                 : "This is the only time Locus shows the phrase. Keep it offline and private.")
                .font(.body).foregroundStyle(LocusTheme.muted)
            if !confirming {
                Text("This phrase belongs only to Locus Vault. Never enter a MetaMask, Phantom, Slush, or other wallet phrase here. Standard recovery paths: EVM m/44'/60'/0'/0/0 · Solana m/44'/501'/0'/0' · Sui m/44'/784'/0'/0'/0'.")
                    .font(.callout).foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirming {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(creation.verificationIndices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Word \(index + 1)").font(.callout.weight(.semibold))
                            WalletNoPasteSecureField(text: Binding(
                                get: { answers[index] ?? "" }, set: { answers[index] = $0 }
                            )).frame(height: 24)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                    ForEach(Array(creation.words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 5) {
                            Text("\(index + 1).").foregroundStyle(LocusTheme.textTertiary)
                            Text(word).fontWeight(.semibold)
                            Spacer()
                        }
                        .font(LocusType.monoCaption).padding(6)
                        .background(LocusTheme.surfaceCard).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { Task { await gateway.cancelVaultCreation(); dismiss() } }
                Spacer()
                if confirming {
                    Button("Activate vault") {
                        Task { if await gateway.confirmVaultBackup(wordsByIndex: answers) { dismiss() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(creation.verificationIndices.contains { (answers[$0] ?? "").isEmpty })
                } else {
                    Button("I saved all 24 words") { confirming = true }.buttonStyle(.borderedProminent)
                }
            }
            if let error = gateway.lastError { Text(error).font(.callout).foregroundStyle(LocusTheme.coral) }
        }
        .padding(22).frame(width: 620).interactiveDismissDisabled()
    }
}

private struct WalletNoPasteSecureField: NSViewRepresentable {
    @Binding var text: String
    final class Field: NSSecureTextField {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" { return true }
            return super.performKeyEquivalent(with: event)
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WalletNoPasteSecureField
        init(_ parent: WalletNoPasteSecureField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field(); field.delegate = context.coordinator
        field.isAutomaticTextCompletionEnabled = false
        field.menu = NSMenu()
        return field
    }
    func updateNSView(_ view: Field, context: Context) {
        if view.stringValue != text { view.stringValue = text }
        context.coordinator.parent = self
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
                        Text("Sepolia")
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
                            detailRow("Fee quote (wei)", transaction.feeQuoteBaseUnits)
                            detailRow("Fee ceiling (wei)", transaction.maximumFeeBaseUnits)
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
                                detailRow("Amount (wei)", transaction.action.amountBaseUnits ?? "0")
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
                    gateway.confirm(intentID: transaction.id)
                    dismiss()
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
        case .browser: "Requested by \(transaction.source.origin ?? "unknown website")"
        }
    }

    private var actionTitle: String {
        if let amount = transaction.action.amountBaseUnits,
           let formatted = WalletAmountFormatter.ether(wei: amount) {
            return "Send \(formatted)"
        }
        if let contract = transaction.contract {
            return "Call \(contract.label)"
        }
        return transaction.summary
    }

    private var destinationText: String {
        if let contract = transaction.contract {
            return "\(contract.function) · \(contract.address)"
        }
        return transaction.action.recipient ?? "Recipient unavailable"
    }

    private var feeText: String {
        let formatted = WalletAmountFormatter.ether(wei: transaction.feeQuoteBaseUnits)
            ?? "\(transaction.feeQuoteBaseUnits) wei"
        return "\(formatted) · ceiling \(transaction.maximumFeeBaseUnits) wei"
    }

    private var riskMessages: [String] {
        var messages = transaction.riskFlags.map { flag in
            switch flag {
            case .unlimitedApproval: "This request includes an unlimited token approval."
            case .unknownEffect: "The simulation found an effect Locus cannot fully explain."
            case .undecodableCall: "The contract call could not be fully decoded."
            case .codeHashMismatch: "The contract code no longer matches the reviewed registry entry."
            case .staleQuote: "The quoted contract action may be stale."
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
           let formatted = WalletAmountFormatter.ether(wei: amount) {
            return "Confirm and Send \(formatted.replacingOccurrences(of: " ETH", with: "")) Sepolia ETH"
        }
        if let contract = transaction.contract {
            return "Confirm \(contract.function) on Sepolia"
        }
        return "Confirm Sepolia Transaction"
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
