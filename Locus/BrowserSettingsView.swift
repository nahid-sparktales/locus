import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum BrowserSettingsRoute: String, Hashable {
    case passwords, contacts, cards, history, downloads, siteData, permissions, importing

    var title: String {
        switch self {
        case .passwords: "Passwords"
        case .contacts: "Contact Information"
        case .cards: "Payment Cards"
        case .history: "Browsing History"
        case .downloads: "Downloads"
        case .siteData: "Cookies and Site Data"
        case .permissions: "Site Permissions"
        case .importing: "Import Browser Data"
        }
    }
}

struct BrowserSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var browser: BrowserService
    @Binding var draft: AppSettings
    @Binding var deepLink: String?
    @Binding var advancedExpanded: Bool
    @State private var navigationPath: [BrowserSettingsRoute] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                Section("Agent access") {
                    Toggle("Let the agent browse the web", isOn: $draft.browserEnabled)
                        .accessibilityIdentifier("settings.browser.enabled")
                    Picker("Browsing history for agents", selection: $draft.browserHistoryAccessRaw) {
                        ForEach(BrowserHistoryAccess.allCases) { access in
                            Text(access.title).tag(access.rawValue)
                        }
                    }
                    Toggle("Let the model use saved passwords", isOn: $draft.browserAgentPasswordsEnabled)
                        .accessibilityIdentifier("settings.browser.modelPasswords")
                    Toggle("Let the model use saved contact information", isOn: $draft.browserAgentContactsEnabled)
                        .accessibilityIdentifier("settings.browser.modelContacts")
                    Toggle("Let the model use saved payment cards", isOn: $draft.browserAgentPaymentCardsEnabled)
                        .accessibilityIdentifier("settings.browser.modelCards")
                    Text("Enabled records can be returned as raw values to the active model, including hosted providers. Passwords are limited to the open site's exact origin. Enabling payment cards also lets the model complete checkout; security codes are never stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Your browser data") {
                    managerLink(.passwords, symbol: "key.fill", summary: vaultSummary)
                        .id("settings.browser.passwords")
                    managerLink(.contacts, symbol: "person.text.rectangle", summary: vaultSummary(browser.autofillVault.contacts.count, noun: "contact"))
                    managerLink(.cards, symbol: "creditcard.fill", summary: vaultSummary(browser.autofillVault.cards.count, noun: "card"))
                    managerLink(.history, symbol: "clock.arrow.circlepath", summary: profileSummary(browser.activityStore.history.count, noun: "visit"))
                        .id("settings.browser.history")
                    managerLink(.downloads, symbol: "arrow.down.circle", summary: downloadSummary)
                        .id("settings.browser.downloads")
                    managerLink(.siteData, symbol: "externaldrive.badge.icloud", summary: "Clear selected data or one site")
                    managerLink(.permissions, symbol: "hand.raised.fill", summary: permissionSummary)
                        .id("settings.browser.permissions")
                    managerLink(.importing, symbol: "square.and.arrow.down", summary: "Passwords, contacts, and history")
                }

                Section("Defaults") {
                    TextField("Home URL", text: $draft.previewURL)
                        .accessibilityIdentifier("settings.previewURL")
                    Picker("Viewport", selection: $draft.browserViewportRaw) {
                        ForEach(BrowserViewport.allCases) { viewport in
                            Text(viewport.title).tag(viewport.rawValue)
                        }
                    }
                    Picker("Page appearance", selection: $draft.browserPageAppearanceRaw) {
                        ForEach(BrowserPageAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    Picker("Browsing profile", selection: $draft.browserPersistProfile) {
                        Text("Private until quit").tag(false)
                        Text("Keep per workspace").tag(true)
                    }
                    Text(draft.browserPersistProfile
                        ? "History, downloads, cookies, and site data are kept only for this workspace."
                        : "History and download activity stay in memory and disappear when Locus quits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    SettingsAdvancedDisclosureRow(
                        isExpanded: $advancedExpanded,
                        detail: "Input behavior, search, and debugging"
                    )
                    .accessibilityIdentifier("settings.browser.advanced")
                }
                .id("settings.browser.webInspector")

                if advancedExpanded {
                    Section("Advanced browser controls") {
                        browserAdvancedControls
                    }
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("settings.browser.root")
            .navigationDestination(for: BrowserSettingsRoute.self) { route in
                destination(route)
                    .navigationTitle(route.title)
            }
        }
        .onAppear { openDeepLinkIfNeeded() }
        .onChange(of: deepLink) { _, _ in openDeepLinkIfNeeded() }
        .task { if !browser.autofillVault.isReady { await browser.autofillVault.load() } }
    }

    private func openDeepLinkIfNeeded() {
        guard let deepLink else { return }
        let route: BrowserSettingsRoute?
        switch deepLink {
        case "settings.browser.passwords": route = .passwords
        case "settings.browser.contacts": route = .contacts
        case "settings.browser.cards": route = .cards
        case "settings.browser.history": route = .history
        case "settings.browser.downloads": route = .downloads
        case "settings.browser.siteData": route = .siteData
        case "settings.browser.permissions": route = .permissions
        case "settings.browser.import": route = .importing
        case "settings.browser.webInspector":
            advancedExpanded = true
            route = nil
        default: route = nil
        }
        if let route { navigationPath = [route] }
        self.deepLink = nil
    }

    private var vaultSummary: String {
        vaultSummary(browser.autofillVault.passwords.count, noun: "password")
    }

    private func vaultSummary(_ count: Int, noun: String) -> String {
        if browser.autofillVault.isLoading { return "Loading Autofill…" }
        guard browser.autofillVault.isReady else { return "Autofill unavailable" }
        return "\(count) saved \(noun)\(count == 1 ? "" : "s")"
    }

    private func profileSummary(_ count: Int, noun: String) -> String {
        let value = "\(count) \(noun)\(count == 1 ? "" : "s")"
        return draft.browserPersistProfile ? value : "\(value) · Private session"
    }

    private var downloadSummary: String {
        let destination = BrowserDownloadDestinationKind(
            rawValue: draft.browserDownloadDestinationRaw
        )?.title ?? "Downloads"
        let active = browser.activityStore.downloads.filter { $0.state == .running }.count
        return active == 0 ? destination : "\(active) active · \(destination)"
    }

    private var permissionSummary: String {
        let count = browser.permissionStore.overrides.count
        return count == 0 ? "Secure defaults" : "\(count) site override\(count == 1 ? "" : "s")"
    }

    private func managerLink(
        _ route: BrowserSettingsRoute,
        symbol: String,
        summary: String
    ) -> some View {
        NavigationLink(value: route) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(LocusTheme.accentAction)
                    .frame(width: 24)
            }
            .padding(.vertical, 3)
        }
        .accessibilityIdentifier("settings.browser.manager.\(route.rawValue)")
    }

    @ViewBuilder
    private func destination(_ route: BrowserSettingsRoute) -> some View {
        switch route {
        case .passwords:
            BrowserPasswordManager(vault: browser.autofillVault)
        case .contacts:
            BrowserContactManager(vault: browser.autofillVault)
        case .cards:
            BrowserCardManager(vault: browser.autofillVault)
        case .history:
            BrowserHistoryManager(browser: browser, sessionID: model.currentSessionID)
        case .downloads:
            BrowserDownloadManager(browser: browser, draft: $draft)
        case .siteData:
            BrowserSiteDataManager(browser: browser)
        case .permissions:
            BrowserPermissionManager(browser: browser, draft: $draft)
        case .importing:
            BrowserImportManager(browser: browser)
        }
    }

    private var browserAdvancedControls: some View {
        Group {
            Picker("Agent input", selection: $draft.browserRealInput) {
                Text("Real input").tag(true)
                Text("Synthetic events only").tag(false)
            }
            Toggle("Emulate a mobile device at phone widths", isOn: $draft.browserEmulateDevice)
            Picker("Presentation", selection: $draft.browserPresentationModeRaw) {
                ForEach(BrowserPresentationMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text("The selected viewport stays exact while the canvas scales to fit, keeping page layout and agent coordinates stable.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ProviderLogo(name: "Google", size: 24)
                Picker("Search in Google opens in", selection: $draft.webSearchDestinationRaw) {
                    ForEach(WebSearchDestination.allCases) { destination in
                        Text(destination.title).tag(destination.rawValue)
                    }
                }
            }
            Toggle("Allow the Web Inspector to attach", isOn: $draft.browserWebInspector)
                .accessibilityIdentifier("settings.browser.webInspector")
            Text("Web Inspector can read the current page's cookies and storage. Leave it off unless you are debugging.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BrowserVaultUnavailableView: View {
    @ObservedObject var vault: BrowserAutofillVault

    var body: some View {
        if vault.isLoading {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading encrypted Autofill data…")
            }
        } else {
            ContentUnavailableView {
                Label("Autofill Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(vault.lastError ?? "Autofill data could not be loaded.")
            } actions: {
                Button("Try Again") { Task { await vault.load() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct BrowserPasswordManager: View {
    @ObservedObject var vault: BrowserAutofillVault
    @State private var editor: BrowserPasswordRecord?
    @State private var error = ""

    var body: some View {
        Group {
            if vault.isReady {
                if vault.passwords.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Passwords", systemImage: "key")
                    } description: {
                        Text("Passwords you add here stay encrypted on this Mac.")
                    } actions: {
                        Button("Add Password") {
                            editor = BrowserPasswordRecord(origin: "", username: "", password: "")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(vault.passwords) { password in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(password.displayOrigin).fontWeight(.medium)
                                        Text(password.username.isEmpty ? "No username" : password.username)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("••••••••").foregroundStyle(.secondary)
                                    Button("Edit") { editor = password }.buttonStyle(.borderless)
                                    Button("Delete", role: .destructive) {
                                        do { try vault.removePassword(password.id) }
                                        catch { self.error = error.localizedDescription }
                                    }.buttonStyle(.borderless)
                                }
                                .padding(.vertical, 4)
                            }
                        } header: {
                            HStack {
                                Text("Saved Passwords")
                                Spacer()
                                Button("Add Password") { editor = BrowserPasswordRecord(origin: "", username: "", password: "") }
                            }
                        }
                        Section {
                            Text("Suggestions appear after an eligible field is focused. Model access follows the saved Browser setting and is limited to this website's exact origin.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                BrowserVaultUnavailableView(vault: vault)
            }
        }
        .task { if !vault.isReady { await vault.load() } }
        .sheet(item: $editor) { record in
            BrowserPasswordEditor(record: record) { value in
                do { try vault.save(value); editor = nil }
                catch { self.error = error.localizedDescription }
            }
        }
        .alert("Could Not Save Password", isPresented: .constant(!error.isEmpty)) {
            Button("OK") { error = "" }
        } message: { Text(error) }
    }
}

private struct BrowserPasswordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var record: BrowserPasswordRecord
    let save: (BrowserPasswordRecord) -> Void

    var body: some View {
        Form {
            TextField("Website", text: $record.origin, prompt: Text("https://example.com"))
            TextField("Username", text: $record.username)
            SecureField("Password", text: $record.password)
            TextField("Label", text: $record.label)
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 250)
        .safeAreaInset(edge: .bottom) {
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save(record) }.buttonStyle(.borderedProminent).disabled(record.origin.isEmpty || record.password.isEmpty) }
                .padding()
                .background(.bar)
        }
    }
}

private struct BrowserContactManager: View {
    @ObservedObject var vault: BrowserAutofillVault
    @State private var editor: BrowserContactRecord?
    @State private var error = ""

    var body: some View {
        Group {
            if vault.isReady {
                if vault.contacts.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Contact Information", systemImage: "person.text.rectangle")
                    } description: {
                        Text("Add a contact to fill names, addresses, email, and phone fields.")
                    } actions: {
                        Button("Add Contact") { editor = BrowserContactRecord() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(vault.contacts) { contact in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(contact.fullName.isEmpty ? contact.label : contact.fullName).fontWeight(.medium)
                                        Text(contact.summary).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Edit") { editor = contact }.buttonStyle(.borderless)
                                    Button("Delete", role: .destructive) {
                                        do { try vault.removeContact(contact.id) }
                                        catch { self.error = error.localizedDescription }
                                    }.buttonStyle(.borderless)
                                }.padding(.vertical, 4)
                            }
                        } header: {
                            HStack { Text("Saved Contact Information"); Spacer(); Button("Add Contact") { editor = BrowserContactRecord() } }
                        }
                    }
                }
            } else {
                BrowserVaultUnavailableView(vault: vault)
            }
        }
        .task { if !vault.isReady { await vault.load() } }
        .sheet(item: $editor) { record in
            BrowserContactEditor(record: record) { value in
                do { try vault.save(value); editor = nil }
                catch { self.error = error.localizedDescription }
            }
        }
        .alert("Could Not Save Contact", isPresented: .constant(!error.isEmpty)) {
            Button("OK") { error = "" }
        } message: { Text(error) }
    }
}

private struct BrowserContactEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var record: BrowserContactRecord
    let save: (BrowserContactRecord) -> Void

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Label", text: $record.label)
                TextField("Full name", text: $record.fullName)
                TextField("Organization", text: $record.organization)
                TextField("Email", text: $record.email)
                TextField("Phone", text: $record.phone)
            }
            Section("Address") {
                TextField("Street", text: $record.street)
                TextField("City", text: $record.city)
                TextField("State or province", text: $record.region)
                TextField("Postal code", text: $record.postalCode)
                TextField("Country", text: $record.country)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 520)
        .safeAreaInset(edge: .bottom) {
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save(record) }.buttonStyle(.borderedProminent) }
                .padding().background(.bar)
        }
    }
}

private struct BrowserCardManager: View {
    @ObservedObject var vault: BrowserAutofillVault
    @State private var editor: BrowserPaymentCardRecord?
    @State private var error = ""

    var body: some View {
        Group {
            if vault.isReady {
                if vault.cards.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Payment Cards", systemImage: "creditcard")
                    } description: {
                        Text("Security codes are never requested or stored.")
                    } actions: {
                        Button("Add Card") { editor = BrowserPaymentCardRecord() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            ForEach(vault.cards) { card in
                                HStack {
                                    Image(systemName: "creditcard.fill").foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(card.nickname).fontWeight(.medium)
                                        Text("\(card.maskedNumber) · \(String(format: "%02d", card.expirationMonth))/\(card.expirationYear)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Edit") { editor = card }.buttonStyle(.borderless)
                                    Button("Delete", role: .destructive) {
                                        do { try vault.removeCard(card.id) }
                                        catch { self.error = error.localizedDescription }
                                    }.buttonStyle(.borderless)
                                }.padding(.vertical, 4)
                            }
                        } header: {
                            HStack { Text("Saved Payment Cards"); Spacer(); Button("Add Card") { editor = BrowserPaymentCardRecord() } }
                        }
                        Section {
                            Label("Locus never asks for or stores CVC, CVV, or CID security codes.", systemImage: "lock.shield")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                BrowserVaultUnavailableView(vault: vault)
            }
        }
        .task { if !vault.isReady { await vault.load() } }
        .sheet(item: $editor) { record in
            BrowserCardEditor(record: record, contacts: vault.contacts) { value in
                do { try vault.save(value); editor = nil }
                catch { self.error = error.localizedDescription }
            }
        }
        .alert("Could Not Save Card", isPresented: .constant(!error.isEmpty)) {
            Button("OK") { error = "" }
        } message: { Text(error) }
    }
}

private struct BrowserCardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var record: BrowserPaymentCardRecord
    let contacts: [BrowserContactRecord]
    let save: (BrowserPaymentCardRecord) -> Void

    var body: some View {
        Form {
            TextField("Nickname", text: $record.nickname)
            TextField("Name on card", text: $record.cardholder)
            TextField("Card number", text: $record.number)
            HStack {
                Picker("Month", selection: $record.expirationMonth) {
                    ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                Picker("Year", selection: $record.expirationYear) {
                    ForEach(Calendar.current.component(.year, from: Date())...Calendar.current.component(.year, from: Date()) + 20, id: \.self) { Text(String($0)).tag($0) }
                }
            }
            Picker("Billing address", selection: $record.billingContactID) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(contacts) { contact in
                    Text(contact.fullName.isEmpty ? contact.label : contact.fullName).tag(Optional(contact.id))
                }
            }
            Label("Security codes are intentionally never accepted or stored.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
        .safeAreaInset(edge: .bottom) {
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save(record) }.buttonStyle(.borderedProminent).disabled(!record.isValid) }
                .padding().background(.bar)
        }
    }
}

private enum BrowserHistoryRange: String, CaseIterable, Identifiable {
    case all = "All time", today = "Today", week = "Past week", month = "Past month"
    var id: String { rawValue }
    var cutoff: Date? {
        switch self {
        case .all: nil
        case .today: Calendar.current.startOfDay(for: Date())
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: Calendar.current.date(byAdding: .month, value: -1, to: Date())
        }
    }
}

private struct BrowserHistoryManager: View {
    @ObservedObject var browser: BrowserService
    @ObservedObject private var store: BrowserActivityStore
    let sessionID: String
    @State private var query = ""
    @State private var range = BrowserHistoryRange.all
    @State private var pageSize = 50
    @State private var selection = Set<UUID>()
    @State private var clearAll = false

    init(browser: BrowserService, sessionID: String) {
        self.browser = browser
        self.sessionID = sessionID
        _store = ObservedObject(wrappedValue: browser.activityStore)
    }

    private var matches: [BrowserHistoryEntry] {
        store.searchHistory(query: query, limit: 1_000).filter { range.cutoff == nil || $0.visitedAt >= range.cutoff! }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
                Picker("Date", selection: $range) { ForEach(BrowserHistoryRange.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().frame(width: 130)
                Button("Delete Selected", role: .destructive) { store.removeHistory(ids: selection); selection.removeAll() }
                    .disabled(selection.isEmpty)
                Button("Clear All…", role: .destructive) { clearAll = true }.disabled(store.history.isEmpty)
            }.padding()
            List(matches.prefix(pageSize), selection: $selection) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.isEmpty ? entry.host : entry.title).lineLimit(1)
                        Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(entry.visitedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    Button("Open") {
                        _ = browser.userNavigate(entry.url, sessionID: sessionID)
                    }.buttonStyle(.borderless)
                    Button("Delete", role: .destructive) { store.removeHistory(ids: [entry.id]) }.buttonStyle(.borderless)
                }.tag(entry.id)
            }
            if matches.count > pageSize {
                Button("Load More") { pageSize += 50 }.padding(10)
            }
        }
        .overlay {
            if matches.isEmpty { ContentUnavailableView("No History", systemImage: "clock", description: Text(store.isPersistent ? "Pages you visit in this workspace appear here." : "This private session has no matching visits.")) }
        }
        .alert("Clear all browsing history?", isPresented: $clearAll) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { store.clearHistory() }
        } message: { Text("This removes visit records for the current workspace profile.") }
    }
}

private struct BrowserDownloadManager: View {
    @ObservedObject var browser: BrowserService
    @ObservedObject private var store: BrowserActivityStore
    @Binding var draft: AppSettings
    @State private var filePendingDeletion: BrowserDownloadRecord?

    init(browser: BrowserService, draft: Binding<AppSettings>) {
        self.browser = browser
        _store = ObservedObject(wrappedValue: browser.activityStore)
        _draft = draft
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Destination") {
                    Picker("Save downloads to", selection: $draft.browserDownloadDestinationRaw) {
                        ForEach(BrowserDownloadDestinationKind.allCases) { kind in Text(kind.title).tag(kind.rawValue) }
                    }
                    Toggle("Ask where to save each download", isOn: $draft.browserDownloadAskEveryTime)
                    if draft.resolvedBrowserDownloadDestination == .custom {
                        Button(draft.browserCustomDownloadBookmark == nil ? "Choose Folder…" : "Choose a Different Folder…") { chooseFolder() }
                    }
                }
            }.formStyle(.grouped).frame(height: draft.resolvedBrowserDownloadDestination == .custom ? 190 : 150)
            List {
                ForEach(store.downloads) { download in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: icon(for: download.state))
                            Text(download.fileName).lineLimit(1)
                            Spacer()
                            Text(download.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        if download.state == .running { ProgressView(value: download.progress) }
                        HStack {
                            if download.state == .running {
                                Button("Pause") { browser.pauseDownload(download.id) }
                                Button("Cancel", role: .destructive) { browser.cancelDownload(download.id) }
                            } else if download.state == .paused {
                                Button("Resume") { browser.resumeDownload(download.id) }
                                Button("Cancel", role: .destructive) { browser.cancelDownload(download.id) }
                            } else if download.state == .failed || download.state == .cancelled {
                                Button("Retry") { browser.retryDownload(download.id) }
                            }
                            if download.state == .completed {
                                Button("Open") { browser.openDownload(download.id) }
                                Button("Show in Finder") { browser.revealDownload(download.id) }
                            }
                            Spacer()
                            Button("Remove from History", role: .destructive) { store.removeDownload(download.id) }
                            if download.destinationURL != nil {
                                Button("Delete File…", role: .destructive) { filePendingDeletion = download }
                            }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 5)
                }
            }
            .overlay { if store.downloads.isEmpty { ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle") } }
        }
        .alert("Move \(filePendingDeletion?.fileName ?? "file") to Trash?", isPresented: Binding(get: { filePendingDeletion != nil }, set: { if !$0 { filePendingDeletion = nil } })) {
            Button("Cancel", role: .cancel) { filePendingDeletion = nil }
            Button("Move to Trash", role: .destructive) {
                if let id = filePendingDeletion?.id { _ = browser.deleteDownloadedFile(id) }
                filePendingDeletion = nil
            }
        } message: { Text("Removing download history alone never deletes a file. This separate action moves the file to Trash.") }
    }

    private func icon(for state: BrowserDownloadState) -> String {
        switch state {
        case .running: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.browserCustomDownloadBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

private struct BrowserSiteDataManager: View {
    @ObservedObject var browser: BrowserService
    @State private var records: [BrowserWebsiteDataRecord] = []
    @State private var selected = Set<BrowserDataType>(BrowserDataType.allCases)
    @State private var confirmClear = false
    @State private var loading = true

    var body: some View {
        Form {
            Section("Clear selected data") {
                ForEach(BrowserDataType.allCases) { type in
                    Toggle(type.title, isOn: Binding(
                        get: { selected.contains(type) },
                        set: { enabled in
                            if enabled { selected.insert(type) }
                            else { selected.remove(type) }
                        }
                    ))
                }
                Button("Clear Selected Data…", role: .destructive) { confirmClear = true }
                    .disabled(selected.isEmpty)
            }
            Section("Stored by site") {
                if loading { ProgressView() }
                else if records.isEmpty { Text("No website data in this profile.").foregroundStyle(.secondary) }
                ForEach(records) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(record.displayName)
                            Text("\(record.dataTypes.count) data type\(record.dataTypes.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task { await browser.removeWebsiteData(named: record.displayName); await reload() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .alert("Clear selected browser data?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Data", role: .destructive) { browser.clearBrowsingData(selected); Task { await reload() } }
        } message: { Text("Downloaded files and Autofill are never included.") }
    }

    private func reload() async {
        loading = true
        records = await browser.websiteDataRecords()
        loading = false
    }
}

private struct BrowserPermissionManager: View {
    @ObservedObject var browser: BrowserService
    @Binding var draft: AppSettings
    @State private var origin = "https://"
    @State private var kind = BrowserPermissionKind.javascript
    @State private var decision = BrowserPermissionDecision.ask

    var body: some View {
        Form {
            Section("Global defaults") {
                ForEach(BrowserPermissionKind.allCases) { kind in
                    Picker(kind.title, selection: permissionBinding(kind)) {
                        ForEach(BrowserPermissionDecision.allCases) { decision in
                            Text(decision.title).tag(decision.rawValue)
                        }
                    }
                }
                Text("File selection is always user-only. Camera and microphone still require the macOS system prompt when allowed here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add site override") {
                TextField("Site origin", text: $origin, prompt: Text("https://example.com"))
                Picker("Permission", selection: $kind) { ForEach(BrowserPermissionKind.allCases) { Text($0.title).tag($0) } }
                Picker("Decision", selection: $decision) { ForEach(BrowserPermissionDecision.allCases) { Text($0.title).tag($0) } }
                Button("Add Override") {
                    browser.permissionStore.set(decision, kind: kind, origin: origin)
                    origin = "https://"
                }.disabled(URL(string: origin)?.host == nil)
            }
            Section("Site overrides") {
                if browser.permissionStore.overrides.isEmpty { Text("No site-specific overrides.").foregroundStyle(.secondary) }
                ForEach(browser.permissionStore.overrides) { rule in
                    HStack {
                        Image(systemName: rule.kind.symbol).frame(width: 22)
                        VStack(alignment: .leading) {
                            Text(rule.origin)
                            Text("\(rule.kind.title): \(rule.decision.title)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { browser.permissionStore.remove(rule) }
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private func permissionBinding(_ kind: BrowserPermissionKind) -> Binding<String> {
        Binding(get: { rawPermission(kind) }, set: { setPermission(kind, raw: $0) })
    }

    private func rawPermission(_ kind: BrowserPermissionKind) -> String {
        switch kind {
        case .javascript: draft.browserJavaScriptPermissionRaw
        case .userDownloads: draft.browserUserDownloadPermissionRaw
        case .agentDownloads: draft.browserAgentDownloadPermissionRaw
        case .fileUploads: draft.browserUploadPermissionRaw
        case .popups: draft.browserPopupPermissionRaw
        case .externalSchemes: draft.browserExternalPermissionRaw
        case .camera: draft.browserCameraPermissionRaw
        case .microphone: draft.browserMicrophonePermissionRaw
        }
    }

    private func setPermission(_ kind: BrowserPermissionKind, raw: String) {
        switch kind {
        case .javascript: draft.browserJavaScriptPermissionRaw = raw
        case .userDownloads: draft.browserUserDownloadPermissionRaw = raw
        case .agentDownloads: draft.browserAgentDownloadPermissionRaw = raw
        case .fileUploads: draft.browserUploadPermissionRaw = raw
        case .popups: draft.browserPopupPermissionRaw = raw
        case .externalSchemes: draft.browserExternalPermissionRaw = raw
        case .camera: draft.browserCameraPermissionRaw = raw
        case .microphone: draft.browserMicrophonePermissionRaw = raw
        }
    }
}

private struct BrowserImportManager: View {
    @ObservedObject var browser: BrowserService
    @State private var kind = BrowserImportKind.passwords
    @State private var choosingFile = false
    @State private var preview: BrowserImportPreview?
    @State private var fileName = ""
    @State private var error = ""

    var body: some View {
        Form {
            Section("Import from an exported file") {
                Picker("Data type", selection: $kind) { ForEach(BrowserImportKind.allCases) { Text($0.title).tag($0) } }
                Button("Choose File…") { choosingFile = true }
                Text("Locus validates and previews user-selected CSV, vCard, or JSON files. It does not inspect installed browser profiles and never imports payment cards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let preview {
                Section("Preview — \(fileName)") {
                    LabeledContent("Ready to import", value: "\(preview.count)")
                    LabeledContent("Passwords", value: "\(preview.passwords.count)")
                    LabeledContent("Contacts", value: "\(preview.contacts.count)")
                    LabeledContent("History entries", value: "\(preview.history.count)")
                    if preview.rejectedRows > 0 { LabeledContent("Rejected rows", value: "\(preview.rejectedRows)") }
                    Button("Import \(preview.count) Item\(preview.count == 1 ? "" : "s")") { Task { await commit(preview) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview.count == 0)
                }
            }
            if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $choosingFile,
            allowedContentTypes: [.commaSeparatedText, .json, .vCard, .plainText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                preview = try BrowserDataImporter.preview(url: url, kind: kind)
                fileName = url.lastPathComponent
                error = ""
            } catch { self.error = error.localizedDescription }
        }
    }

    private func commit(_ preview: BrowserImportPreview) async {
        if !preview.passwords.isEmpty || !preview.contacts.isEmpty {
            guard await browser.autofillVault.load() else {
                error = browser.autofillVault.lastError ?? "Autofill data could not be loaded."
                return
            }
        }
        do {
            for var password in preview.passwords {
                if let existing = browser.autofillVault.passwords.first(where: {
                    BrowserAutofillVault.normalizedOrigin($0.origin) == BrowserAutofillVault.normalizedOrigin(password.origin)
                        && $0.username.caseInsensitiveCompare(password.username) == .orderedSame
                }) { password.id = existing.id; password.createdAt = existing.createdAt }
                try browser.autofillVault.save(password)
            }
            for var contact in preview.contacts {
                if let existing = browser.autofillVault.contacts.first(where: {
                    (!contact.email.isEmpty && $0.email.caseInsensitiveCompare(contact.email) == .orderedSame)
                        || (!contact.phone.isEmpty && $0.phone == contact.phone)
                }) { contact.id = existing.id; contact.createdAt = existing.createdAt }
                try browser.autofillVault.save(contact)
            }
            let existingHistory = Set(browser.activityStore.history.map { "\($0.url)|\(Int($0.visitedAt.timeIntervalSince1970))" })
            for entry in preview.history where !existingHistory.contains("\(entry.url)|\(Int(entry.visitedAt.timeIntervalSince1970))") {
                if let url = URL(string: entry.url) {
                    browser.activityStore.recordVisit(url: url, title: entry.title, visitedAt: entry.visitedAt, source: .user)
                }
            }
            self.preview = nil
            fileName = ""
            error = "Import complete. Existing matching records were updated or skipped."
        } catch { self.error = error.localizedDescription }
    }
}
