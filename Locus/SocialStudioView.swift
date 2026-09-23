import AppKit
import SwiftUI

private enum SocialSection: String, CaseIterable, Identifiable {
    case drafts = "Drafts", calendar = "Calendar", research = "Research", activity = "Activity", accounts = "Accounts", brand = "Brand voice"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .drafts: "square.and.pencil"
        case .calendar: "calendar"
        case .research: "sparkle.magnifyingglass"
        case .activity: "chart.bar.xaxis"
        case .accounts: "person.crop.rectangle.stack"
        case .brand: "text.bubble"
        }
    }
    var subtitle: String {
        switch self {
        case .drafts: "A good post starts with something worth sharing."
        case .calendar: "Give your ideas a place in the week."
        case .research: "Find the conversations worth joining."
        case .activity: "Follow every post from draft to delivery."
        case .accounts: "Your publishing destinations, together."
        case .brand: "Keep every channel sounding like you."
        }
    }
}

struct SocialStudioView: View {
    @ObservedObject var store: SocialStudioStore
    @ObservedObject var appModel: AppModel
    @State private var section = SocialSection.drafts
    @State private var search = ""
    @State private var editing: SocialDraft?
    @State private var transferring: SocialDraft?
    @State private var removing: SocialDraft?
    @State private var connecting = false
    @State private var topic = ""
    @State private var month = Calendar.current.startOfDay(for: Date())
    @State private var confirming: SocialPublicationAction?
    @Environment(\.locusViewColors) private var colors

    private var drafts: [SocialDraft] {
        store.document.drafts.filter { search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            VStack(spacing: 0) {
                header
                if let error = store.error { banner(error, error: true) }
                if let notice = store.notice { banner(notice, error: false) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch section {
                        case .drafts: draftContent
                        case .calendar: calendarContent
                        case .research: researchContent
                        case .activity: activityContent
                        case .accounts: accountsContent
                        case .brand: SocialBrandEditor(store: store)
                        }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }.background(colors.paper)
        }
        .font(.locus(size: 13))
        .foregroundStyle(colors.ink)
        .preferredColorScheme(appModel.effectiveAppearance.colorScheme)
        .tint(appModel.accentActionColor)
        .buttonStyle(LocusButtonStyle(kind: .quiet))
        .sheet(item: $editing) { draft in
            SocialComposer(store: store, initial: draft, assistant: openAssistant)
        }
        .sheet(item: $transferring) { draft in SocialTransferSheet(store: store, draft: draft) }
        .sheet(isPresented: $connecting) { SocialConnectionSheet(store: store) }
        .sheet(item: $confirming) { action in
            SocialPublicationReview(store: store, action: action)
        }
        .alert("Remove local draft?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let draft = removing { store.remove(draft.id) }; removing = nil }
        } message: { Text("This removes only the local copy. Any draft or scheduled post already in OpenPost stays there.") }
        .task { await store.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.locus(size: 20, weight: .medium)).foregroundStyle(colors.signalDeep)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Social Studio").font(.locus(size: 15, weight: .semibold))
                    Text("LOCUS PLUGIN").font(.locus(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(colors.muted)
                }
            }.padding(.top, 10)
            Button { editing = SocialDraft() } label: {
                SocialPrimaryLabel("New post", icon: "plus", expands: true)
            }.buttonStyle(LocusButtonStyle(kind: .primary)).keyboardShortcut("n", modifiers: [.command, .option])
                .accessibilityIdentifier("socialStudio.newPost")
            VStack(spacing: 5) {
                ForEach(SocialSection.allCases) { item in
                    Button { section = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 18)
                            Text(item.rawValue)
                            Spacer()
                            if item == .drafts { Text("\(store.document.drafts.count)").foregroundStyle(colors.muted).font(.locus(size: 11)) }
                        }.padding(.horizontal, 10).padding(.vertical, 10)
                            .background(section == item ? colors.signal.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(section == item ? colors.ink : colors.inkSoft)
                    }.buttonStyle(.locus()).accessibilityIdentifier("socialStudio.section.\(item.id)")
                }
            }
            Spacer()
            Button { section = .research } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Last 30 days", systemImage: "sparkles").font(.locus(size: 12, weight: .semibold))
                    Text("Turn recent conversations into your next post.").font(.locus(size: 11)).foregroundStyle(colors.muted)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).locusCard()
            }.buttonStyle(.locus())
            VStack(alignment: .leading, spacing: 5) {
                Label(URL(fileURLWithPath: store.workspace).lastPathComponent, systemImage: "folder").lineLimit(1)
                Text(store.document.connection?.workspaceName ?? "Local drafts · ready to write")
                    .font(.locus(size: 10)).foregroundStyle(colors.muted).lineLimit(1)
            }.font(.locus(size: 11)).padding(.bottom, 6)
        }.padding(16).background(colors.paperDeep)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(section.rawValue).font(.locus(size: 25, weight: .semibold))
                Text(section.subtitle).foregroundStyle(colors.muted).font(.locus(size: 12))
            }
            Spacer()
            if store.busy { ProgressView().controlSize(.small).accessibilityLabel("Contacting OpenPost") }
            if section == .drafts {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(colors.muted)
                    TextField("Find a draft", text: $search).textFieldStyle(.plain)
                }.padding(9).frame(width: 170).locusCard(radius: 8)
                Menu {
                    Button("Export drafts…") { store.exportDrafts() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            if section == .activity || section == .accounts || section == .calendar {
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.busy || store.document.connection == nil)
            }
        }.padding(.horizontal, 28).padding(.vertical, 24).overlay(alignment: .bottom) { Divider() }
    }

    private func banner(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: error ? "exclamationmark.circle" : "checkmark.circle")
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { if error { store.error = nil } else { store.notice = nil } } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss message")
        }.font(.locus(size: 12)).foregroundStyle(error ? colors.danger : colors.success)
            .padding(12).background((error ? colors.danger : colors.success).opacity(0.07))
    }

    private var draftContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                metric("In your studio", value: store.document.drafts.filter { $0.handoff == nil }.count, icon: "square.and.pencil")
                metric("Planned locally", value: store.document.drafts.filter { $0.plannedAt != nil && $0.handoff == nil }.count, icon: "calendar")
                metric("Sent to OpenPost", value: store.document.drafts.filter { $0.handoff?.publicationID != nil }.count, icon: "paperplane")
            }
            if drafts.isEmpty {
                empty(search.isEmpty ? "Your next post starts here" : "No matching drafts",
                      detail: search.isEmpty ? "Capture an idea, make it yours for each channel, then plan when to share it." : "Try a different word or clear your search.", icon: "square.and.pencil")
                if search.isEmpty {
                    HStack {
                        Button { editing = SocialDraft() } label: { SocialPrimaryLabel("Write your first post") }.buttonStyle(.locus(.primary))
                        Button("Find an idea") { section = .research }
                    }.frame(maxWidth: .infinity)
                    HStack(spacing: 14) {
                        starter("A product update", detail: "What changed, and why it matters.", text: "What we shipped:\n\nWhy it matters:\n\nTry it:")
                        starter("Something you learned", detail: "Share a useful lesson from the work.", text: "Something I learned this week:\n\nWhat surprised me:\n\nWhat I'd do differently:")
                        starter("Start a conversation", detail: "Ask a question people can answer.", text: "I've been thinking about…\n\nMy experience so far:\n\nHow do you approach this?")
                    }.padding(.top, 20)
                }
            } else {
                ForEach(drafts) { draft in draftCard(draft) }
            }
        }
    }

    private func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.locus(size: 11)).foregroundStyle(colors.muted)
            Text("\(value)").font(.locus(size: 28, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).locusCard()
    }

    private func starter(_ title: String, detail: String, text: String) -> some View {
        Button { var draft = SocialDraft(); draft.title = title; draft.text = text; editing = draft } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "arrow.up.right").foregroundStyle(colors.signalDeep)
                Text(title).font(.locus(size: 13, weight: .medium))
                Text(detail).font(.locus(size: 11)).foregroundStyle(colors.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).locusCard()
        }.buttonStyle(.locus())
    }

    private func draftCard(_ draft: SocialDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.displayTitle).font(.locus(size: 15, weight: .semibold))
                Spacer()
                status(draft.handoff?.publicationID != nil ? "In OpenPost" : draft.handoff != nil ? "Transfer pending" : draft.plannedAt == nil ? "Draft" : "Planned locally")
                Menu {
                    Button("Duplicate") { editing = draft.copy() }
                    Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(draft.text, forType: .string) }
                    Button("Remove local draft…", role: .destructive) { removing = draft }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            }
            Text(draft.text.isEmpty ? "An idea waiting for its words." : draft.text).lineLimit(3).foregroundStyle(colors.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(draft.channels.prefix(3)) { channel in status(channel.title) }
                if draft.channels.count > 3 { status("+\(draft.channels.count - 3)").help(draft.channels.map(\.title).joined(separator: ", ")) }
                if let date = draft.plannedAt { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.locus(size: 11)).foregroundStyle(colors.muted) }
                Spacer()
                if draft.handoff == nil { Button("Edit") { editing = draft }.accessibilityLabel("Edit \(draft.displayTitle)") }
                if draft.handoff?.publicationID == nil {
                    Button(draft.handoff == nil ? "Send to OpenPost" : "Retry transfer") {
                        if store.document.connection == nil { connecting = true } else { transferring = draft }
                    }.disabled(store.busy || draft.isEmpty)
                } else { Button("View activity") { section = .activity } }
            }
        }.padding(20).locusCard(radius: 12)
    }

    private var calendarContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(month, format: .dateTime.month(.wide).year()).font(.locus(size: 19, weight: .medium))
                Spacer()
                Button("Today") { month = Date() }
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next month")
            }
            Text("Local plans are reminders, not publishing jobs. Send a draft to OpenPost and schedule it in Activity to publish automatically.")
                .font(.locus(size: 12)).foregroundStyle(colors.muted)
                .accessibilityIdentifier("socialStudio.calendarExplanation")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1) {
                ForEach(0..<7, id: \.self) { index in
                    Text(Calendar.current.shortWeekdaySymbols[(Calendar.current.firstWeekday - 1 + index) % 7])
                        .font(.locus(size: 11, weight: .medium)).foregroundStyle(colors.muted).padding(8)
                }
                ForEach(monthDays, id: \.self) { date in
                    dayCell(date)
                }
            }.background(colors.line.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 10))
            Label("Times shown in \(TimeZone.current.identifier)", systemImage: "clock").font(.locus(size: 11)).foregroundStyle(colors.muted)
            HStack(spacing: 16) {
                Label("Local plan", systemImage: "circle").foregroundStyle(colors.signalDeep)
                Label("OpenPost · latest 100 publications", systemImage: "checkmark.circle").foregroundStyle(colors.blue)
            }.font(.locus(size: 11))
        }
    }

    private var monthDays: [Date] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: month)!.start
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: start) }
    }
    private func shiftMonth(_ offset: Int) { month = Calendar.current.date(byAdding: .month, value: offset, to: month) ?? month }

    private func dayCell(_ date: Date) -> some View {
        let remoteIDs = Set(store.publications.map(\.id))
        let posts = store.document.drafts.filter { draft in
            !(draft.handoff?.publicationID.map(remoteIDs.contains) ?? false)
                && (draft.plannedAt.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false)
        }
        let remote = store.publications.filter { $0.scheduledDate.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.locus(size: 11, weight: Calendar.current.isDateInToday(date) ? .bold : .regular))
                    .foregroundStyle(Calendar.current.isDate(date, equalTo: month, toGranularity: .month) ? colors.ink : colors.muted)
                Spacer()
                Button {
                    var draft = SocialDraft(); draft.plannedAt = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date); editing = draft
                } label: { Image(systemName: "plus").font(.locus(size: 9)) }.buttonStyle(.locus())
                    .accessibilityLabel("Plan a post for \(date.formatted(date: .complete, time: .omitted))")
            }
            ForEach(posts.prefix(2)) { post in
                Button { if post.handoff == nil { editing = post } else { section = .activity } } label: {
                    Text(post.displayTitle).font(.locus(size: 10)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4).background(colors.signal.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.locus())
            }
            ForEach(remote.prefix(max(0, 2 - posts.count))) { post in
                Button { section = .activity } label: {
                    Text(post.displayTitle).font(.locus(size: 10)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4).background(colors.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.locus()).help(post.status)
            }
            if posts.count + remote.count > 2 {
                Menu("+\(posts.count + remote.count - 2) more") {
                    ForEach(posts.dropFirst(2)) { post in Button(post.displayTitle) { if post.handoff == nil { editing = post } else { section = .activity } } }
                    ForEach(remote.dropFirst(max(0, 2 - posts.count))) { post in Button(post.displayTitle) { section = .activity } }
                }.font(.locus(size: 9)).menuStyle(.borderlessButton)
            }
            Spacer(minLength: 0)
        }.padding(8).frame(height: 106).frame(maxWidth: .infinity).background(colors.panel)
    }

    private var researchContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                Label("A little context. Better content.", systemImage: "sparkle.magnifyingglass").font(.locus(size: 21, weight: .medium))
                Text("Research what people are discussing, then turn what you learn into something useful for your audience.").foregroundStyle(colors.muted)
                TextField("A topic, product, or community…", text: $topic).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("socialStudio.researchTopic")
                HStack {
                    Button { openAssistant(.research, topic, nil) } label: { SocialPrimaryLabel("Research last 30 days", icon: "sparkles") }
                        .buttonStyle(LocusButtonStyle(kind: .primary)).disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("socialStudio.researchRecent")
                    Button("Brainstorm post ideas") { openAssistant(.ideas, topic, nil) }
                        .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Opens a new Locus chat with an editable request. Send it when you're ready; results stay in that conversation.")
                    .font(.locus(size: 11)).foregroundStyle(colors.muted)
            }.padding(26).locusCard(radius: 14)
            HStack(alignment: .top, spacing: 18) {
                researchNote("01", "Listen first", "The last30days skill looks for recent sources, repeated questions, and emerging discussions.")
                researchNote("02", "Find your angle", "Your saved audience, voice, and content themes travel with the research request.")
                researchNote("03", "Make it yours", "Review the evidence, copy a useful angle into a new post, and adapt it for each channel.")
            }
        }.frame(maxWidth: 880, alignment: .leading)
    }
    private func researchNote(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(number).font(.locus(size: 12, weight: .medium)).foregroundStyle(colors.signalDeep)
            Text(title).font(.locus(size: 14, weight: .semibold))
            Text(detail).font(.locus(size: 12)).foregroundStyle(colors.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.document.connection == nil {
                empty("Connect your publishing workspace", detail: "OpenPost handles delivery while Locus keeps your writing and research together.", icon: "paperplane")
                Button { connecting = true } label: { SocialPrimaryLabel("Connect OpenPost") }.buttonStyle(.locus(.primary))
            } else {
                HStack {
                    Text("Latest 100 OpenPost publications").font(.locus(size: 12)).foregroundStyle(colors.muted)
                    Spacer()
                    if let date = store.lastSynced { Text("Updated \(date.formatted(date: .omitted, time: .shortened))").font(.locus(size: 11)).foregroundStyle(colors.muted) }
                }
                if store.publications.isEmpty { empty("No publications loaded", detail: "Send a local draft to OpenPost, or refresh to see existing publications.", icon: "tray") }
                ForEach(store.publications) { post in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(post.displayTitle).font(.locus(size: 15, weight: .semibold))
                            Spacer(); status(post.status)
                        }
                        Text(post.sourceText).lineLimit(4).foregroundStyle(colors.inkSoft)
                        if let date = post.scheduledDate {
                            Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar").font(.locus(size: 11)).foregroundStyle(colors.muted)
                        }
                        ForEach(post.renditions ?? []) { rendition in
                            HStack {
                                Text(rendition.platform.capitalized).font(.locus(size: 12, weight: .medium))
                                status(rendition.status)
                                if let error = rendition.errorMessage, !error.isEmpty { Text(error).font(.locus(size: 11)).foregroundStyle(colors.danger).textSelection(.enabled) }
                                Spacer()
                                if let raw = rendition.externalUrl, let url = URL(string: raw), url.scheme == "https" {
                                    Link("View post ↗", destination: url).font(.locus(size: 11))
                                }
                            }
                        }
                        HStack {
                            if post.status == "draft" {
                                Button("Schedule…") { confirming = .init(publication: post, operation: "schedule") }
                                    .disabled(post.scheduledAt == nil || post.scheduledAt == "")
                                Button("Publish now…") { confirming = .init(publication: post, operation: "publish-now") }
                            }
                            if post.status == "scheduled" { Button("Cancel schedule…") { confirming = .init(publication: post, operation: "cancel") } }
                            Spacer()
                            Button("Open OpenPost ↗") { openOpenPost() }
                        }.disabled(store.busy)
                    }.padding(20).locusCard(radius: 12)
                }
                Text("Delivery states come from OpenPost. Engagement analytics, media editing, and inbox tools are available in your OpenPost workspace.")
                    .font(.locus(size: 11)).foregroundStyle(colors.muted)
            }
        }
    }

    private var accountsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.locus(size: 28)).foregroundStyle(colors.signalDeep)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.document.connection?.workspaceName ?? "Connect OpenPost").font(.locus(size: 20, weight: .medium))
                        Text(store.document.connection?.origin ?? "Use OpenPost Hosted or your own instance.").foregroundStyle(colors.muted)
                    }
                    Spacer()
                    status(store.document.connection == nil ? "Not connected" : "Configured")
                }
                Text("Connect social accounts in OpenPost, then select them when you send a draft. Locus stores your developer token in macOS Keychain.")
                    .font(.locus(size: 12)).foregroundStyle(colors.muted)
                HStack {
                    Button { connecting = true } label: { SocialPrimaryLabel(store.document.connection == nil ? "Connect OpenPost" : "Change connection") }
                        .buttonStyle(LocusButtonStyle(kind: .primary))
                        .accessibilityIdentifier("socialStudio.connect")
                    Button("Open OpenPost ↗") { openOpenPost() }
                    if store.document.connection != nil { Button("Disconnect") { store.disconnect() } }
                }.disabled(store.busy)
            }.padding(24).locusCard(radius: 12)
            if !store.accounts.isEmpty {
                Text("CONNECTED DESTINATIONS").font(.locus(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(colors.muted)
                ForEach(store.accounts) { account in
                    HStack(spacing: 14) {
                        Text(account.channel?.monogram ?? String(account.platform.prefix(1)).uppercased())
                            .font(.locus(size: 17, weight: .semibold)).frame(width: 40, height: 40).background(colors.paperDeep, in: RoundedRectangle(cornerRadius: 10))
                        Text(account.label)
                        Spacer(); status(account.isActive ? "Active" : "Reconnect in OpenPost")
                    }.padding(16).locusCard()
                }
            }
            Text("Platform capabilities vary. OpenPost validates each destination before scheduling or publishing. Use its editors for images, carousels, video, and media-required channels.")
                .foregroundStyle(colors.muted).font(.locus(size: 12))
        }
    }

    private func status(_ text: String) -> some View {
        Text(text.replacingOccurrences(of: "_", with: " ").capitalized).font(.locus(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4).background(colors.paperDeep, in: Capsule()).foregroundStyle(colors.inkSoft)
    }
    private func empty(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.locus(size: 32, weight: .light)).foregroundStyle(colors.signalDeep)
            Text(title).font(.locus(size: 21, weight: .medium))
            Text(detail).foregroundStyle(colors.muted).multilineTextAlignment(.center).frame(maxWidth: 430)
        }.frame(maxWidth: .infinity).padding(.vertical, 38)
    }
    private func openOpenPost() {
        if let url = try? OpenPostClient.validatedOrigin(store.document.connection?.origin ?? "https://app.openpo.st") { NSWorkspace.shared.open(url) }
    }
    private func openAssistant(_ action: SocialAssistantAction, _ topic: String, _ draft: SocialDraft?) {
        guard !store.revoked else { return }
        let prompt = action.prompt(topic: topic, draft: draft, brand: store.document.brand)
        guard let task = appModel.startNewChat(in: store.workspace, environment: .local, initialDraft: prompt) else {
            store.error = "Locus is changing chats. Wait a moment and try again."; return
        }
        Task { @MainActor in
            guard await task.value else { store.error = "The research chat could not open. Check the Locus connection and try again."; return }
            LocusApplicationDelegate.mainWindow(in: NSApp.windows)?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct SocialComposer: View {
    @ObservedObject var store: SocialStudioStore
    let assistant: (SocialAssistantAction, String, SocialDraft?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SocialDraft
    @State private var selected: SocialChannel?
    @Environment(\.locusViewColors) private var colors
    init(store: SocialStudioStore, initial: SocialDraft, assistant: @escaping (SocialAssistantAction, String, SocialDraft?) -> Void) {
        self.store = store; self.assistant = assistant; _draft = State(initialValue: initial)
    }
    private var text: Binding<String> {
        Binding(get: { selected.map { draft.text(for: $0) } ?? draft.text }, set: { value in
            if let selected { draft.variants[selected.rawValue] = value } else { draft.text = value }
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compose a post").font(.locus(size: 22, weight: .semibold))
                    Text("One idea. A version for every channel.").font(.locus(size: 12)).foregroundStyle(colors.muted)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { if store.save(draft) { dismiss() } } label: { SocialPrimaryLabel("Save draft") }.buttonStyle(.locus(.primary)).keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("socialStudio.saveDraft")
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Give this post a title", text: $draft.title).textFieldStyle(.plain).font(.locus(size: 19, weight: .medium))
                        .accessibilityIdentifier("socialStudio.draftTitle")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            tab("Original", value: nil)
                            ForEach(draft.channels) { channel in tab(channel.title, value: channel) }
                        }
                    }.frame(height: 34)
                    TextEditor(text: text).font(.locus(size: 15)).scrollContentBackground(.hidden)
                        .padding(10).frame(height: 235).background(colors.paperDeep, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(selected.map { "\($0.title) version" } ?? "Original post")
                        .accessibilityIdentifier("socialStudio.draftText")
                    HStack {
                        Text("\(text.wrappedValue.count) characters").font(.locus(size: 11)).foregroundStyle(colors.muted)
                        Spacer()
                        if let selected, draft.variants[selected.rawValue] != nil {
                            Button("Use original") { draft.variants.removeValue(forKey: selected.rawValue) }
                        }
                        Button { assistant(.adapt, "", draft) } label: { Label("Adapt with Locus", systemImage: "sparkles") }.disabled(draft.isEmpty || draft.channels.isEmpty)
                    }
                    Divider()
                    Text("CHANNELS").font(.locus(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(colors.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], alignment: .leading, spacing: 8) {
                        ForEach(SocialChannel.allCases) { channel in
                            Toggle(channel.title, isOn: Binding(get: { draft.channels.contains(channel) }, set: { enabled in
                                if enabled { draft.channels.append(channel) }
                                else { draft.channels.removeAll { $0 == channel }; if selected == channel { selected = nil } }
                            })).toggleStyle(.checkbox).font(.locus(size: 12))
                        }
                    }
                    Toggle("Plan a date", isOn: Binding(get: { draft.plannedAt != nil }, set: { draft.plannedAt = $0 ? Date().addingTimeInterval(86400) : nil }))
                    if draft.plannedAt != nil {
                        DatePicker("Planned for", selection: Binding(get: { draft.plannedAt ?? Date() }, set: { draft.plannedAt = $0 }))
                        Text("\(TimeZone.current.identifier) · Saved as a local plan until scheduled through OpenPost.").font(.locus(size: 10)).foregroundStyle(colors.muted)
                    }
                    if let error = store.error { Text(error).font(.locus(size: 12)).foregroundStyle(colors.danger) }
                }.padding(24).frame(maxWidth: .infinity)
                }
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    Text("TEXT PREVIEW").font(.locus(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(colors.muted)
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 10) {
                            Text(String(store.document.brand.name.prefix(1)).uppercased().isEmpty ? "S" : String(store.document.brand.name.prefix(1)).uppercased())
                                .font(.locus(size: 17, weight: .semibold)).frame(width: 40, height: 40).background(colors.signal.opacity(0.2), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.document.brand.name.isEmpty ? "Your brand" : store.document.brand.name).font(.locus(size: 13, weight: .semibold))
                                Text(selected?.title ?? "Original post").font(.locus(size: 11)).foregroundStyle(colors.muted)
                            }
                        }
                        ScrollView {
                            Text(text.wrappedValue.isEmpty ? "Your words will appear here." : text.wrappedValue)
                                .font(.locus(size: 13)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 360)
                        Divider()
                        HStack(spacing: 22) { Image(systemName: "heart"); Image(systemName: "bubble"); Image(systemName: "arrowshape.turn.up.right") }
                            .foregroundStyle(colors.muted).accessibilityHidden(true)
                    }.padding(20).locusCard(radius: 14)
                    Text("A text preview, not an exact platform rendering. OpenPost checks destination limits and media requirements before publishing.")
                        .font(.locus(size: 11)).foregroundStyle(colors.muted)
                }.padding(24).frame(width: 300)
            }
        }.frame(width: 940, height: 735).background(colors.paper).foregroundStyle(colors.ink)
            .buttonStyle(LocusButtonStyle(kind: .quiet)).interactiveDismissDisabled()
    }
    private func tab(_ title: String, value: SocialChannel?) -> some View {
        Button { selected = value } label: {
            Text(title).font(.locus(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected == value ? colors.signal.opacity(0.18) : colors.paperDeep, in: Capsule())
        }.buttonStyle(.locus())
    }
}

private struct SocialBrandEditor: View {
    @ObservedObject var store: SocialStudioStore
    @State private var brand = SocialBrand()
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A shared starting point for your writing and research.").foregroundStyle(LocusTheme.muted)
            field("Brand or creator name", text: $brand.name, prompt: "How you introduce yourself")
            field("Audience", text: $brand.audience, prompt: "Who you're writing for")
            field("Voice", text: $brand.voice, prompt: "Tone, phrases you use, and things to avoid")
            field("Content themes", text: $brand.topics, prompt: "The topics you want to be known for")
            HStack {
                Button { saved = store.saveBrand(brand) } label: { SocialPrimaryLabel("Save brand voice") }.buttonStyle(.locus(.primary))
                if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(LocusTheme.success) }
            }
            Text("Stored for this Locus project and included in assistant requests you open from Social Studio.").font(.locus(size: 11)).foregroundStyle(LocusTheme.muted)
        }.frame(maxWidth: 650, alignment: .leading).onAppear { brand = store.document.brand }
            .onChange(of: brand) { _, _ in saved = false }
    }
    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.locus(size: 13, weight: .medium))
            TextField(prompt, text: text, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
        }
    }
}

struct SocialPrimaryLabel: View {
    let title: String
    var icon: String?
    var expands = false
    init(_ title: String, icon: String? = nil, expands: Bool = false) { self.title = title; self.icon = icon; self.expands = expands }
    var body: some View {
        HStack(spacing: 7) {
            if let icon { Image(systemName: icon) }
            Text(title)
        }.font(.locus(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(minHeight: 34)
            .frame(maxWidth: expands ? .infinity : nil)
            .foregroundStyle(LocusTheme.brandInk).background(LocusTheme.accentFill, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
