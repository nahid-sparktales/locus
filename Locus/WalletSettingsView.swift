import AppKit
import SwiftUI

struct WalletSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var gateway: WalletGateway
    @Binding var rpcURL: String
    @State private var recoveryPresented = false
    @State private var deletePresented = false
    @State private var policyPresented = false
    @State private var registryPresented = false
    @State private var contractPolicyEntry: WalletContractRegistryEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                vaultCard
                if !gateway.accounts.isEmpty { accountsCard }
                rpcCard
                policyCard
                if !gateway.transactionHistory.isEmpty { historyCard }
                externalWalletsCard
                rolloutCard
                controlsCard
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .task {
            gateway.configureRPCURL(rpcURL)
            await gateway.refreshStatus()
            await gateway.checkRPCHealth()
            await gateway.refreshTransactionHistory()
        }
        .onChange(of: rpcURL) { _, value in gateway.configureRPCURL(value) }
        .sheet(isPresented: $recoveryPresented) {
            if let creation = gateway.vaultCreation {
                WalletVaultBackupSheet(gateway: gateway, creation: creation)
            }
        }
        .sheet(isPresented: $deletePresented) { WalletVaultDeleteSheet(gateway: gateway) }
        .sheet(isPresented: $policyPresented) { WalletNativePolicySheet(gateway: gateway) }
        .sheet(isPresented: $registryPresented) { WalletContractRegistrySheet(gateway: gateway) }
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
    }

    private var vaultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Locus Vault", systemImage: "wallet.bifold.fill")
                    .font(.locus(size: 13, weight: .bold))
                Spacer()
                Text(gateway.statusText).font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.warning)
                    .accessibilityIdentifier("settings.wallet.status")
            }
            Text("A separate, limited-fund vault for policy-controlled transactions. Existing Phantom, MetaMask, and Slush recovery phrases are never imported or extracted.")
                .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
            Label("Mainnet signing stays disabled until independent security review is complete.", systemImage: "lock.shield.fill")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.coral)
            if gateway.status == .unlocked {
                Button("Lock vault") { model.lockWalletSession() }
                    .accessibilityIdentifier("settings.wallet.lock")
            } else if gateway.canCreateVault {
                Button("Create Locus Vault") {
                    Task {
                        if await gateway.beginVaultCreation() != nil { recoveryPresented = true }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.wallet.create")
            } else if gateway.canAuthorizeSession {
                Button("Unlock vault") { Task { await model.authorizeWalletSession() } }
                    .accessibilityIdentifier("settings.wallet.unlock")
            }
            if !gateway.isExperimentalEnabled && gateway.signerAvailable {
                Text("Activation required: enable the experimental wallet for this Mac, quit Locus, then reopen it. The exact commands are in Docs/WalletActivation.md.")
                    .font(.locus(size: 9)).foregroundStyle(LocusTheme.warning)
            }
            if let error = gateway.lastError {
                Text(error).font(.locus(size: 9)).foregroundStyle(LocusTheme.coral)
            }
        }
        .padding(14).locusCard(radius: 10)
    }

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Accounts").font(.locus(size: 12, weight: .semibold))
            ForEach(gateway.accounts) { account in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: account.chain == .evm ? "diamond.fill" : "circle.hexagongrid.fill")
                        .foregroundStyle(account.chain == .evm ? LocusTheme.success : LocusTheme.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label).font(.locus(size: 10, weight: .semibold))
                        Text(account.address).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(LocusTheme.muted).textSelection(.enabled)
                        Text(account.chain == .evm ? "Sepolia signing available" : "Public account · signing is security gated")
                            .font(.locus(size: 8)).foregroundStyle(LocusTheme.textTertiary)
                        Text(derivationPath(for: account.chain))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.textTertiary)
                    }
                }
            }
        }
        .padding(14).locusCard(radius: 10)
    }

    private var rpcCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Sepolia connection").font(.locus(size: 12, weight: .semibold))
            TextField("HTTPS RPC URL", text: $rpcURL).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.wallet.rpc-url")
            HStack {
                Text(gateway.rpcHealthText).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                Spacer()
                Button("Check connection") { Task { await gateway.checkRPCHealth() } }
            }
            Text("The endpoint stays native and is never sent to Python or included in model context.")
                .font(.locus(size: 8)).foregroundStyle(LocusTheme.textTertiary)
        }
        .padding(14).locusCard(radius: 10)
    }

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Contract registry & policies").font(.locus(size: 12, weight: .semibold))
                Spacer()
                Button("Add contract") { registryPresented = true }
                    .disabled(gateway.status != .unlocked)
                Button("New budget") { policyPresented = true }
                    .disabled(gateway.status != .unlocked)
            }
            Label("Native ETH transfer adapter active", systemImage: "checkmark.shield.fill")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.success)
            Label("ERC-20 transfer/approval and one-command Universal Router exact-input calls receive reviewed semantics only when their verified ABI matches exactly.", systemImage: "checkmark.shield.fill")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
            Text(gateway.activePolicies.isEmpty
                 ? "No active budgets. Every Sepolia transfer requires exact confirmation."
                 : "\(gateway.activePolicies.count) budget(s) active until the vault locks.")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.textTertiary)
            ForEach(gateway.activePolicyStatuses) { status in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(policyLabel(status.policy)) → \(status.policy.allowedRecipients.sorted().joined(separator: ", "))")
                            .font(.locus(size: 9, weight: .semibold)).lineLimit(1)
                        Text("Used \(status.spentBaseUnits) / \(status.policy.maximumSessionBaseUnits) wei · expires \(status.policy.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                    }
                    Spacer()
                }
            }
            if !gateway.activePolicies.isEmpty {
                Button("Clear active budgets", role: .destructive) { Task { await gateway.clearPolicies() } }
                    .font(.locus(size: 9))
            }
            ForEach(gateway.savedPolicyTemplates) { template in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name).font(.locus(size: 9, weight: .semibold))
                        Text("Saved template · no current authorization")
                            .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                    }
                    Spacer()
                    Button("Authorize") {
                        Task { _ = await gateway.activatePolicyTemplate(id: template.id) }
                    }.font(.locus(size: 8)).disabled(gateway.status != .unlocked)
                    Button("Remove", role: .destructive) { gateway.removePolicyTemplate(id: template.id) }
                        .font(.locus(size: 8))
                }
            }
            ForEach(gateway.contractRegistry) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.label).font(.locus(size: 9, weight: .semibold))
                        Text(entry.checksumAddress).font(.system(size: 8, design: .monospaced))
                        Text("\(entry.permittedFunctions.count) approved method(s) · code \(entry.runtimeCodeHash.prefix(12))…")
                            .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
                        if let adapterID = entry.reviewedAdapterID {
                            Label(adapterLabel(adapterID), systemImage: "checkmark.shield.fill")
                                .font(.locus(size: 8)).foregroundStyle(LocusTheme.success)
                        }
                    }
                    Spacer()
                    if entry.reviewedAdapterID != nil {
                        Button("New budget") { contractPolicyEntry = entry }
                            .font(.locus(size: 8)).disabled(gateway.status != .unlocked)
                    }
                    Button("Remove", role: .destructive) {
                        Task { await gateway.removeContractRegistryEntry(id: entry.id) }
                    }.font(.locus(size: 8))
                }
            }
        }
        .padding(14).locusCard(radius: 10)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transaction activity").font(.locus(size: 12, weight: .semibold))
                Spacer()
                Button("Refresh") { Task { await gateway.refreshTransactionHistory() } }
                    .font(.locus(size: 8))
            }
            ForEach(gateway.transactionHistory) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.summary).font(.locus(size: 9, weight: .semibold))
                    Text(item.transactionHash).font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(activityLabel(item.state)).font(.locus(size: 8, weight: .semibold))
                            .foregroundStyle(activityColor(item.state))
                        Text(item.submittedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.locus(size: 8)).foregroundStyle(LocusTheme.textTertiary)
                        if let block = item.blockNumber {
                            Text("block \(block)").font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(LocusTheme.textTertiary)
                        }
                    }
                    if let detail = item.detail {
                        Text(detail).font(.locus(size: 8)).foregroundStyle(LocusTheme.warning)
                    }
                }
            }
        }
        .padding(14).locusCard(radius: 10)
    }

    private var externalWalletsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("External approval wallets").font(.locus(size: 12, weight: .semibold))
            ForEach(WalletExternalConnectorCatalog.connectors) { descriptor in
                connector(descriptor)
            }
            Text("Connector contracts and test-network boundaries are defined. Connection buttons remain closed until each transport dependency and callback path passes its security audit. External wallets always retain their own keys and confirmation experience.")
                .font(.locus(size: 8)).foregroundStyle(LocusTheme.muted)
        }
        .padding(14).locusCard(radius: 10)
    }

    private var rolloutCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Security rollout").font(.locus(size: 12, weight: .semibold))
            rollout("1", "Native ETH on Sepolia", ready: true)
            rollout("2", "Registered ABI calls with exact confirmation", ready: true)
            rollout("3", "Session-scoped Sepolia browser provider", ready: gateway.browserProviderEnabled)
            rollout("4", "Reviewed ERC-20 and narrow Uniswap budgets", ready: true)
            rollout("5", "External wallet connector foundations", ready: true)
            rollout("6", "Mainnet, Solana, and Sui signing", ready: false)
            if gateway.isExperimentalEnabled && !gateway.browserProviderEnabled {
                Text("Browser access has a separate experimental activation gate. Registered contract calls remain exact-confirmation-only until their effect adapters are reviewed.")
                    .font(.locus(size: 8)).foregroundStyle(LocusTheme.textTertiary)
            }
        }
        .padding(14).locusCard(radius: 10)
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Vault controls").font(.locus(size: 12, weight: .semibold))
            Button("Delete Locus Vault", role: .destructive) { deletePresented = true }
                .disabled(gateway.vaultState == .missing)
                .accessibilityIdentifier("settings.wallet.delete")
            Text("Deletion requires macOS authentication and the exact confirmation phrase. Locus cannot show the recovery phrase again.")
                .font(.locus(size: 8)).foregroundStyle(LocusTheme.textTertiary)
        }
        .padding(14).locusCard(radius: 10)
    }

    private func connector(_ descriptor: WalletExternalConnectorDescriptor) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.name).font(.locus(size: 10, weight: .semibold))
                Text(descriptor.transport).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
                Text("Foundation ready · external signing security gated")
                    .font(.locus(size: 8, weight: .semibold)).foregroundStyle(LocusTheme.warning)
            }
            Spacer()
            Link("Setup guide", destination: descriptor.documentationURL).font(.locus(size: 9))
        }
    }

    private func derivationPath(for chain: WalletChain) -> String {
        switch chain {
        case .evm: "Recovery path m/44'/60'/0'/0/0"
        case .solana: "Recovery path m/44'/501'/0'/0'"
        case .sui: "Recovery path m/44'/784'/0'/0'/0'"
        }
    }

    private func policyLabel(_ policy: WalletSessionPolicy) -> String {
        guard let adapterID = policy.allowedAdapterIDs.first else { return "Wallet budget" }
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

    private func rollout(_ number: String, _ title: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            Text(number).font(.locus(size: 8, weight: .bold)).frame(width: 20, height: 20)
                .background(LocusTheme.surfaceCard).clipShape(Circle())
            Text(title).font(.locus(size: 9))
            Spacer()
            Text(ready ? "Available" : "Security gated").font(.locus(size: 8, weight: .semibold))
                .foregroundStyle(ready ? LocusTheme.success : LocusTheme.warning)
        }
    }
}

private struct WalletBrowserOriginGrantSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gateway: WalletGateway
    let request: WalletBrowserOriginGrant

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect Locus Vault?", systemImage: "globe.badge.chevron.backward")
                .font(.locus(size: 16, weight: .bold))
            Text(request.origin).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text("This website can see your Sepolia EVM address and request transactions. Every request still follows the native registry, simulation, policy, and confirmation path. Message signing and chain addition remain disabled.")
                .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
            Text("Access lasts only until you navigate to another origin, lock the vault, quit, update, or restart Locus.")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.warning)
            HStack {
                Button("Deny", role: .cancel) { gateway.denyBrowserOrigin(); dismiss() }
                Spacer()
                Button("Connect for this session") { gateway.approveBrowserOrigin(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22).frame(width: 480).interactiveDismissDisabled()
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
            Text("Authorize a Sepolia budget").font(.locus(size: 16, weight: .bold))
            Text("This budget lives only inside the signer and disappears when the vault locks or Locus exits.")
                .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
            field("Approved recipient", placeholder: "0x…", text: $recipient)
            field("Maximum per transfer (wei)", placeholder: "1000000000000000", text: $perTransaction)
            field("Total session budget (wei)", placeholder: "5000000000000000", text: $sessionCap)
            field("Maximum fee per transfer (wei)", placeholder: "2000000000000000", text: $feeCap)
            field("Expires after (minutes, max 480)", placeholder: "30", text: $durationMinutes)
            Toggle("Save as a reusable template (authorization is never saved)", isOn: $saveTemplate)
                .font(.locus(size: 9))
            if saveTemplate {
                field("Template name", placeholder: "Sepolia test allowance", text: $templateName)
            }
            Label("Only the reviewed native-ETH adapter can use this budget. Contracts and unlimited approvals cannot.", systemImage: "shield.lefthalf.filled")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.warning)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Authorize budget") { activate() }.buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
            if let error = gateway.lastError { Text(error).font(.locus(size: 9)).foregroundStyle(LocusTheme.coral) }
        }
        .padding(22).frame(width: 500)
    }

    private var valid: Bool {
        recipient.count == 42 && recipient.hasPrefix("0x")
            && WalletBaseUnits.normalize(perTransaction) != nil
            && WalletBaseUnits.normalize(sessionCap) != nil
            && WalletBaseUnits.normalize(feeCap) != nil
            && (Int(durationMinutes) ?? 0) > 0 && (Int(durationMinutes) ?? 0) <= 480
            && (!saveTemplate || !templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !gateway.accounts.filter { $0.chain == .evm }.isEmpty
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.locus(size: 9, weight: .semibold))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func activate() {
        guard let account = gateway.accounts.first(where: { $0.chain == .evm }),
              let minutes = Int(durationMinutes) else { return }
        let policy = WalletSessionPolicy(
            id: UUID().uuidString.lowercased(), accountID: account.id,
            networkID: WalletGateway.sepoliaNetworkID,
            allowedAssetIDs: ["slip44:60"], allowedRecipients: [recipient],
            allowedContractIDs: [], allowedAdapterIDs: ["native-eth-transfer-v1"],
            maximumTransactionBaseUnits: perTransaction,
            maximumSessionBaseUnits: sessionCap,
            maximumFeeBaseUnits: feeCap,
            expiresAt: Date().addingTimeInterval(TimeInterval(minutes * 60))
        )
        let template = saveTemplate ? WalletPolicyTemplate(
                id: UUID().uuidString.lowercased(),
                name: templateName.trimmingCharacters(in: .whitespacesAndNewlines),
                accountID: account.id, networkID: WalletGateway.sepoliaNetworkID,
                recipient: recipient, maximumTransactionBaseUnits: perTransaction,
                maximumSessionBaseUnits: sessionCap, maximumFeeBaseUnits: feeCap,
                durationMinutes: minutes
            ) : nil
        Task {
            if await gateway.activatePolicy(policy) {
                if let template { gateway.savePolicyTemplate(template) }
                dismiss()
            }
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
            Text("Authorize a reviewed contract budget")
                .font(.locus(size: 16, weight: .bold))
            Text("\(entry.label) · \(adapterName)")
                .font(.locus(size: 10, weight: .semibold))
            Text(entry.checksumAddress).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(LocusTheme.muted).textSelection(.enabled)
            Text("This authorization is bound to this registry ID, runtime code hash, adapter, token asset, counterparty, fee ceiling, and signer session.")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.muted)
            if entry.reviewedAdapterID == WalletReviewedAdapters.uniswapUniversalRouterV2ExactIn {
                field("Input token address", placeholder: "0x…", text: $inputToken)
            }
            field(counterpartyTitle, placeholder: "0x…", text: $counterparty)
            field("Maximum per action (token base units)", placeholder: "1000000", text: $perTransaction)
            field("Total session budget (token base units)", placeholder: "5000000", text: $sessionCap)
            field("Maximum fee per action (wei)", placeholder: "2000000000000000", text: $feeCap)
            field("Expires after (minutes, max 480)", placeholder: "30", text: $durationMinutes)
            Label(adapterWarning, systemImage: "shield.lefthalf.filled")
                .font(.locus(size: 9)).foregroundStyle(LocusTheme.warning)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Authorize budget") { activate() }.buttonStyle(.borderedProminent)
                    .disabled(!valid)
            }
            if let error = gateway.lastError {
                Text(error).font(.locus(size: 9)).foregroundStyle(LocusTheme.coral)
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
            Text(title).font(.locus(size: 9, weight: .semibold))
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
            Text("Verify a Sepolia contract").font(.locus(size: 16, weight: .bold))
            Text("Locus reads the deployed bytecode, normalizes the ABI, and records exact function selectors. Registration enables decoded confirmation only; autonomous use still requires a reviewed adapter.")
                .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
            HStack {
                TextField("Registry ID (for example token.usdc)", text: $registryID)
                TextField("Display label", text: $label)
            }.textFieldStyle(.roundedBorder)
            TextField("Sepolia contract address (0x…)", text: $address).textFieldStyle(.roundedBorder)
            TextField("Permitted signatures, comma-separated", text: $functions).textFieldStyle(.roundedBorder)
            Text("Normalized ABI source").font(.locus(size: 9, weight: .semibold))
            TextEditor(text: $abiJSON).font(.system(size: 9, design: .monospaced))
                .frame(height: 150).overlay(RoundedRectangle(cornerRadius: 6).stroke(LocusTheme.separator))
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Verify and add") { add() }.buttonStyle(.borderedProminent)
                    .disabled(registryID.isEmpty || label.isEmpty || address.isEmpty || abiJSON.isEmpty)
            }
            if let error = gateway.lastError { Text(error).font(.locus(size: 9)).foregroundStyle(LocusTheme.coral) }
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
                .font(.locus(size: 16, weight: .bold))
            Text(confirming
                 ? "Enter the six requested words. Paste and clipboard actions are disabled."
                 : "This is the only time Locus shows the phrase. Keep it offline and private.")
                .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
            if !confirming {
                Text("This phrase belongs only to Locus Vault. Never enter a MetaMask, Phantom, Slush, or other wallet phrase here. Standard recovery paths: EVM m/44'/60'/0'/0/0 · Solana m/44'/501'/0'/0' · Sui m/44'/784'/0'/0'/0'.")
                    .font(.locus(size: 9)).foregroundStyle(LocusTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirming {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(creation.verificationIndices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Word \(index + 1)").font(.locus(size: 8, weight: .semibold))
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
                        .font(.system(size: 11, design: .monospaced)).padding(6)
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
            if let error = gateway.lastError { Text(error).font(.locus(size: 9)).foregroundStyle(LocusTheme.coral) }
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
            Text("Delete Locus Vault?").font(.locus(size: 16, weight: .bold))
            Text("This removes the encrypted vault from this Mac. Locus cannot recover funds without your 24-word phrase.")
                .font(.locus(size: 10)).foregroundStyle(LocusTheme.muted)
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
        VStack(alignment: .leading, spacing: 12) {
            Label("Confirm exact Sepolia transaction", systemImage: "checkmark.shield.fill")
                .font(.locus(size: 16, weight: .bold))
            row("Network", transaction.networkID)
            row("Account", transaction.accountID)
            if let contract = transaction.contract {
                row("Contract", "\(contract.label) · \(contract.address)")
                row("Code hash", contract.runtimeCodeHash)
                row("ABI digest", contract.abiDigest)
                row("Method", contract.function)
                row("Arguments", transaction.action.arguments.map {
                    "\($0.type): \($0.value)"
                }.joined(separator: "\n"))
            } else {
                row("Method", "Native ETH transfer")
                row("Recipient", transaction.action.recipient ?? "Unknown")
                if let amount = transaction.action.amountBaseUnits,
                   let formatted = WalletAmountFormatter.ether(wei: amount) {
                    row("Amount", "\(formatted) · \(amount) wei")
                }
            }
            row("Effects", transaction.effects.map {
                let destination = $0.spender.map { "spender \($0)" } ?? ($0.to ?? "unknown")
                return "\($0.kind) \($0.amountBaseUnits) \($0.assetID) → \(destination)"
            }.joined(separator: "\n"))
            row("Risk flags", transaction.riskFlags.isEmpty
                ? "None"
                : transaction.riskFlags.map(\.rawValue).joined(separator: ", "))
            row("Fee ceiling", "\(transaction.maximumFeeBaseUnits) wei")
            row("Quoted fee", "\(transaction.feeQuoteBaseUnits) wei")
            row("Simulation", transaction.simulation)
            row("Policy", transaction.policyDecision)
            row("Nonce", transaction.nonce)
            row("Expires", transaction.expiresAt.formatted(date: .omitted, time: .standard))
            Text(transaction.digest).font(.system(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.textTertiary).textSelection(.enabled)
            HStack {
                Button("Cancel", role: .cancel) { gateway.cancelConfirmation(intentID: transaction.id); dismiss() }
                Spacer()
                Button("Confirm this transaction") { gateway.confirm(intentID: transaction.id); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(transaction.expiresAt <= Date() || !transaction.simulationSucceeded)
            }
        }.padding(22).frame(width: 560).interactiveDismissDisabled()
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.locus(size: 9, weight: .semibold)).frame(width: 90, alignment: .leading)
            Text(value).font(.locus(size: 9)).foregroundStyle(LocusTheme.muted).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
