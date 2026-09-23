import SwiftUI

struct SocialConnectionSheet: View {
    @ObservedObject var store: SocialStudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var origin = "https://app.openpo.st"
    @State private var token = ""
    @State private var workspaces: [OpenPostWorkspace] = []
    @State private var selected = ""
    @State private var busy = false
    @State private var error: String?
    @State private var testedOrigin = ""
    @State private var testedToken = ""
    private var verified: Bool { origin == testedOrigin && token == testedToken && !workspaces.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect OpenPost").font(.locus(size: 22, weight: .semibold))
            Text("Use a developer token from OpenPost → Settings → Personal → Developer. Allow API read and write access to the workspace you want to use.")
                .foregroundStyle(LocusTheme.muted)
            VStack(alignment: .leading, spacing: 8) {
                Text("Instance address").font(.locus(size: 12, weight: .medium))
                TextField("https://app.openpo.st", text: $origin).textFieldStyle(.roundedBorder)
                Text("Self-hosted? Enter your instance's origin without /api/v1.").font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Developer token").font(.locus(size: 12, weight: .medium))
                SecureField("Paste token", text: $token).textFieldStyle(.roundedBorder)
            }
            if verified {
                Picker("Workspace", selection: $selected) {
                    ForEach(workspaces) { workspace in Text(workspace.name + (workspace.canEdit ? "" : " · read only")).tag(workspace.id) }
                }
            }
            if let error { Text(error).foregroundStyle(LocusTheme.danger).textSelection(.enabled) }
            Label("Token stored in macOS Keychain. Drafts stay on this Mac until you send them.", systemImage: "lock.shield")
                .font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button {
                    if verified { connect() } else { Task { await test() } }
                } label: {
                    SocialPrimaryLabel(verified ? "Connect workspace" : "Find workspaces")
                }.buttonStyle(LocusButtonStyle(kind: .primary)).disabled(busy || token.isEmpty)
            }
        }.font(.locus(size: 13)).padding(28).frame(width: 530).background(LocusTheme.paper).foregroundStyle(LocusTheme.ink)
            .buttonStyle(LocusButtonStyle(kind: .quiet)).interactiveDismissDisabled(busy)
            .onAppear { origin = store.document.connection?.origin ?? "https://app.openpo.st" }
    }

    private func test() async {
        busy = true; error = nil
        let requestedOrigin = origin; let requestedToken = token
        defer { busy = false }
        do {
            let client = try OpenPostClient(origin: requestedOrigin, token: requestedToken)
            let found = try await client.workspaces()
            guard !store.revoked, origin == requestedOrigin, token == requestedToken else { return }
            guard !found.isEmpty else { throw SocialStudioError.message("This token has no accessible workspaces. Check its workspace access in OpenPost.") }
            workspaces = found; selected = found.first?.id ?? ""
            testedOrigin = requestedOrigin; testedToken = requestedToken
        } catch { self.error = error.localizedDescription }
    }
    private func connect() {
        guard let workspace = workspaces.first(where: { $0.id == selected }), verified else { return }
        do {
            try store.connect(origin: origin, token: token, workspace: workspace)
            token = ""; testedToken = ""; dismiss()
            Task { await store.refresh() }
        } catch { self.error = error.localizedDescription }
    }
}

struct SocialTransferSheet: View {
    @ObservedObject var store: SocialStudioStore
    let draft: SocialDraft
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.handoff == nil ? "Send draft to OpenPost" : "Retry draft transfer").font(.locus(size: 22, weight: .semibold))
            Text(draft.displayTitle).font(.locus(size: 15, weight: .medium))
            Text("Workspace: \(store.document.connection?.workspaceName ?? "Unavailable")").foregroundStyle(LocusTheme.muted)
            if draft.handoff == nil {
                Text("Choose destinations. Each receives its platform version, or the original if you haven't written one.").foregroundStyle(LocusTheme.muted)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.accounts) { account in
                            Toggle(account.label + (account.isActive ? "" : " · inactive"), isOn: Binding(get: { selected.contains(account.id) }, set: { enabled in
                                if enabled { selected.insert(account.id) } else { selected.remove(account.id) }
                            })).disabled(!account.isActive)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 210)
                if selected.isEmpty { Text("No destinations selected. You can add them in OpenPost later.").font(.locus(size: 11)).foregroundStyle(LocusTheme.muted) }
            } else {
                Text("Retries the exact saved content and destinations with the original transfer key. This avoids creating another draft if the first response was lost.").foregroundStyle(LocusTheme.muted)
            }
            Label("Creates an unpublished draft. Schedule or publish separately in Activity.", systemImage: "doc.badge.arrow.up")
                .font(.locus(size: 12)).foregroundStyle(LocusTheme.muted)
            if let error = store.error { Text(error).foregroundStyle(LocusTheme.danger).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button {
                    Task {
                        await store.sendDraft(draft.id, accountIDs: selected)
                        if store.error == nil { dismiss() }
                    }
                } label: { SocialPrimaryLabel("Send draft") }
                    .buttonStyle(LocusButtonStyle(kind: .primary)).disabled(store.busy)
            }
        }.font(.locus(size: 13)).padding(28).frame(width: 540).background(LocusTheme.paper).foregroundStyle(LocusTheme.ink)
            .buttonStyle(LocusButtonStyle(kind: .quiet)).interactiveDismissDisabled(store.busy)
            .onAppear { selected = Set(store.accounts.filter { $0.isActive && $0.channel.map(draft.channels.contains) == true }.map(\.id)) }
    }
}

struct SocialPublicationAction: Identifiable {
    var id: String { publication.id + operation }
    let publication: OpenPostPublication
    let operation: String
    var title: String {
        switch operation { case "schedule": "Schedule publication"; case "cancel": "Cancel schedule"; default: "Publish now" }
    }
}

struct SocialPublicationReview: View {
    @ObservedObject var store: SocialStudioStore
    let action: SocialPublicationAction
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(action.title).font(.locus(size: 22, weight: .semibold))
            Text(action.publication.displayTitle).font(.locus(size: 15, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(action.publication.sourceText).textSelection(.enabled)
                    ForEach(action.publication.renditions ?? []) { rendition in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(store.accounts.first { $0.id == rendition.socialAccountId }?.label ?? rendition.platform.capitalized,
                                  systemImage: "person.crop.circle").font(.locus(size: 12, weight: .semibold))
                            Text(rendition.body ?? action.publication.sourceText).textSelection(.enabled)
                        }.padding(12).locusCard()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            if action.operation == "schedule", let time = action.publication.scheduledDate {
                Label(time.formatted(date: .complete, time: .shortened) + " · " + TimeZone.current.identifier,
                      systemImage: "calendar").foregroundStyle(LocusTheme.muted)
            }
            Text(action.operation == "publish-now" ? "OpenPost will publish this saved revision to its selected destinations. Review the destination versions in OpenPost if you have edited them there." : action.operation == "schedule" ? "OpenPost will run the saved schedule even when Locus is closed." : "OpenPost will cancel the scheduled job. A post that has already started publishing may still complete.")
                .font(.locus(size: 12)).foregroundStyle(LocusTheme.muted)
            if let error = store.error { Text(error).foregroundStyle(LocusTheme.danger).textSelection(.enabled) }
            HStack {
                Button("Back") { dismiss() }.disabled(store.busy).keyboardShortcut(.cancelAction)
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button {
                    Task { await store.perform(action.operation, publication: action.publication); if store.error == nil { dismiss() } }
                } label: { SocialPrimaryLabel(action.title) }
                    .buttonStyle(LocusButtonStyle(kind: .primary)).disabled(store.busy)
            }
        }.font(.locus(size: 13)).padding(28).frame(width: 550).background(LocusTheme.paper).foregroundStyle(LocusTheme.ink)
            .buttonStyle(LocusButtonStyle(kind: .quiet)).interactiveDismissDisabled(store.busy)
            .onAppear { store.error = nil }
    }
}
