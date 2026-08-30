import AppKit
import SwiftUI

enum ComposerSymbols {
    static let schedule = "calendar.badge.plus"
}

enum ComposerMetrics {
    static func editorHeight(for text: String, width: CGFloat) -> CGFloat {
        let measurementText: String
        if text.isEmpty {
            measurementText = " "
        } else {
            measurementText = text.hasSuffix("\n") ? text + " " : text
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let bounds = (measurementText as NSString).boundingRect(
            with: NSSize(width: max(width - 24, 120), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .paragraphStyle: paragraph,
            ]
        )
        return min(max(ceil(bounds.height) + 22, 58), 180)
    }
}

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contextPresented = false
    @State private var permissionModesPresented = false
    @State private var teamPickerPresented = false
    @State private var quickTeamPresented = false
    @State private var popupSelection = 0
    @State private var popupDismissedDraft: String?
    @State private var editorWidth: CGFloat = 600
    @FocusState private var focused: Bool

    private var accentFill: Color { model.effectiveAccent.fillColor }
    private var accentAction: Color { model.accentActionColor }
    private var accentInk: Color {
        Color(nsColor: model.effectiveAccent.brandInkNSColor())
    }

    private enum Popup {
        case slash([SlashCommand])
        case routing([TeamMentionTarget])
        case mention([URL])
        case skill([ExtensionSkill])
    }

    var body: some View {
        VStack(spacing: 8) {
            if !model.queuedMessages.isEmpty {
                queueRow
            }

            // While a permission request is pending the prompt replaces the
            // input entirely, the way Claude Code and Codex do it: nothing can
            // be typed or sent until the request is answered, and the keyboard
            // drives the answer. The draft lives on the model, so it survives
            // the editor unmounting and is back the moment the panel clears.
            if let request = model.activePermissionRequest {
                PermissionPromptView(request: request)
                    .frame(maxWidth: 740)
                    .transition(LocusMotion.transition(edge: .bottom, reduceMotion: reduceMotion))
            } else if model.planApprovalPending {
                // Same contract as the permission panel: the finished plan is
                // a decision point, so the decision replaces the input.
                PlanApprovalPromptView()
                    .frame(maxWidth: 740)
                    .transition(LocusMotion.transition(edge: .bottom, reduceMotion: reduceMotion))
            } else if let question = model.pendingUserQuestion {
                // A question the agent asked is the same kind of decision
                // point; esc hands the answer back to the composer instead.
                QuestionPromptView(question: question)
                    .frame(maxWidth: 740)
                    .transition(LocusMotion.transition(edge: .bottom, reduceMotion: reduceMotion))
            } else {
                VStack(spacing: 0) {
                    if let popup = activePopup {
                        popupList(popup)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(LocusTheme.line).frame(height: 1)
                            }
                    }

                    // TextKit supplies an exact wrapped height at the current
                    // composer width. The field starts as one line, grows with
                    // the draft, then caps and scrolls internally so a long
                    // prompt never pushes the transcript away.
                    ZStack(alignment: .topLeading) {
                        if model.draftText.isEmpty {
                            Text(placeholder)
                                .font(.locus(size: 13))
                                .foregroundStyle(LocusTheme.inkSoft.opacity(0.82))
                                .padding(.horizontal, 12)
                                .padding(.top, 11)
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("composer.placeholder")
                        }

                        TextEditor(text: $model.draftText)
                            .font(.locus(size: 13))
                            .foregroundStyle(LocusTheme.ink)
                            .lineSpacing(5)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .focused($focused)
                            .accessibilityLabel("Message Locus")
                            .accessibilityIdentifier("composer.input")
                            .onKeyPress(.upArrow) { handleUpArrow() }
                            .onKeyPress(.downArrow) { handleDownArrow() }
                            .onKeyPress(.return, phases: .down) { press in handleReturn(press) }
                            .onKeyPress(.tab) { handleTab() }
                            .onKeyPress(.escape) { handleEscape() }
                    }
                    .frame(height: measuredEditorHeight)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { editorWidth = proxy.size.width }
                                .onChange(of: proxy.size.width) {
                                    editorWidth = proxy.size.width
                                }
                        }
                    }

                    if model.hasComposerContextChips {
                        attachmentChipsRow
                    }

                    actionRow
                }
                .frame(maxWidth: 740)
                .locusSurface(.floating, radius: 13)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(
                            focused
                                ? accentAction.opacity(0.72)
                                : LocusTheme.separator,
                            lineWidth: focused ? 1.5 : 1
                        )
                }
                .chatAttachmentDropTarget()
                .chatPasteInterceptor(editorFocused: focused)
                .shadow(
                    color: focused
                        ? accentAction.opacity(0.1)
                        : Color.black.opacity(0.08),
                    radius: focused ? 24 : 22,
                    y: 9
                )
                .animation(reduceMotion ? nil : LocusMotion.press, value: focused)
                .transition(LocusMotion.transition(edge: .bottom, reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [LocusTheme.panel.opacity(0), LocusTheme.panel],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .animation(LocusMotion.spatial, value: model.activePermissionRequest?.requestID)
        .animation(LocusMotion.spatial, value: model.planApprovalPending)
        .sheet(isPresented: $quickTeamPresented) {
            QuickTeamBuilderView(suggestedName: model.agentTeamsModel.suggestedQuickTeamName())
                .environmentObject(model)
        }
        .onAppear { restoreFocus() }
        .onChange(of: model.activePermissionRequest?.requestID) {
            // Focus returns to the editor after any decision — option 3 is
            // "tell Locus what to do differently", so typing must just work.
            if model.activePermissionRequest == nil { restoreFocus() }
        }
        .onChange(of: model.planApprovalPending) {
            // Same for "keep planning": the natural next act is typing the
            // refinement, so the editor takes focus back.
            if !model.planApprovalPending { restoreFocus() }
        }
        .onChange(of: model.composerFocusToken) {
            restoreFocus()
        }
        .onChange(of: model.teamRunLive.shouldShowTeamDispatchApproval) {
            if !model.teamRunLive.shouldShowTeamDispatchApproval && !model.teamRunLive.shouldShowTeamDispatchProgress {
                restoreFocus()
            }
        }
        .onChange(of: model.draftText) {
            popupSelection = 0
            if let dismissed = popupDismissedDraft, dismissed != model.draftText {
                popupDismissedDraft = nil
            }
            if !model.justChatEnabled,
               WorkspaceIndex.activeMention(in: model.draftText) != nil {
                model.workspaceFiles.refresh()
            }
        }
    }

    private func restoreFocus() {
        Task { @MainActor in
            await Task.yield()
            focused = true
        }
    }

    // MARK: - Popup state

    private var activePopup: Popup? {
        guard popupDismissedDraft != model.draftText else { return nil }
        if let query = SlashCommand.query(from: model.draftText) {
            // Capped here, at the source of truth: the arrow keys, ↵ and the
            // rendered rows must all agree on the same list, or the selection
            // can walk onto commands the user cannot see.
            let matches = Array(SlashCommand.matches(for: query).prefix(8))
            return matches.isEmpty ? nil : .slash(matches)
        }
        // Just Chat is conversation-only. Merely typing @ or $ must not index
        // the workspace or offer a skill that can instruct agentic work.
        guard !model.justChatEnabled else { return nil }
        if let mention = WorkspaceIndex.activeMention(in: model.draftText) {
            let query = mention.query.lowercased()
            let targets: [TeamMentionTarget] = (
                model.agentTeams.map(TeamMentionTarget.team)
                    + model.agentProfiles.map(TeamMentionTarget.agent)
            ).filter {
                query.isEmpty || $0.name.lowercased().contains(query)
            }
            if !targets.isEmpty {
                return .routing(Array(targets.prefix(8)))
            }
            let matches = WorkspaceIndex.matches(
                query: mention.query,
                in: model.workspaceFiles.files,
                root: model.workspacePath
            )
            return matches.isEmpty ? nil : .mention(matches)
        }
        if let query = activeSkillQuery {
            let matches = model.extensionsModel.extensions.skills.filter {
                $0.enabled && $0.error == nil
                    && (query.isEmpty || $0.id.localizedCaseInsensitiveContains(query))
            }
            .prefix(8)
            return matches.isEmpty ? nil : .skill(Array(matches))
        }
        return nil
    }

    private var activeSkillQuery: String? {
        let text = model.draftText
        guard let dollar = text.lastIndex(of: "$"),
              dollar == text.startIndex || text[text.index(before: dollar)].isWhitespace
        else { return nil }
        let queryStart = text.index(after: dollar)
        let query = String(text[queryStart...])
        guard !query.contains(where: { $0.isWhitespace }),
              query.allSatisfy({ $0.isLetter || $0.isNumber || ".:_-".contains($0) })
        else { return nil }
        return query
    }

    private func popupCount(_ popup: Popup) -> Int {
        switch popup {
        case .slash(let commands): commands.count
        case .routing(let targets): targets.count
        case .mention(let files): files.count
        case .skill(let skills): skills.count
        }
    }

    private func applyPopupSelection(_ popup: Popup) {
        switch popup {
        case .slash(let commands):
            let index = min(popupSelection, commands.count - 1)
            applySlashCommand(commands[index])
        case .routing(let targets):
            applyRoutingTarget(targets[min(popupSelection, targets.count - 1)])
        case .mention(let files):
            let index = min(popupSelection, files.count - 1)
            model.applyMention(files[index])
        case .skill(let skills):
            applySkill(skills[min(popupSelection, skills.count - 1)])
        }
    }

    private func applySlashCommand(_ command: SlashCommand) {
        let argument = SlashCommand.argument(in: model.draftText)
        if !argument.isEmpty || command.argumentHint == nil {
            model.send("/\(command.name)\(argument.isEmpty ? "" : " \(argument)")")
        } else {
            // The command expects an argument — complete it and keep typing.
            model.draftText = "/\(command.name) "
        }
        focused = true
    }

    private func completePopupSelection(_ popup: Popup) {
        switch popup {
        case .slash(let commands):
            let command = commands[min(popupSelection, commands.count - 1)]
            model.draftText = "/\(command.name)\(command.argumentHint != nil ? " " : "")"
        case .routing(let targets):
            applyRoutingTarget(targets[min(popupSelection, targets.count - 1)])
        case .mention(let files):
            model.applyMention(files[min(popupSelection, files.count - 1)])
        case .skill(let skills):
            applySkill(skills[min(popupSelection, skills.count - 1)])
        }
    }

    private func applySkill(_ skill: ExtensionSkill) {
        guard let dollar = model.draftText.lastIndex(of: "$") else { return }
        model.draftText.replaceSubrange(dollar..., with: "$\(skill.id) ")
        focused = true
    }

    private func applyRoutingTarget(_ target: TeamMentionTarget) {
        guard let mention = WorkspaceIndex.activeMention(in: model.draftText) else { return }
        let safeName = target.name.filter {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
        model.draftText.replaceSubrange(mention.range, with: "@\(safeName) ")
        focused = true
    }

    // MARK: - Key handling

    private func handleUpArrow() -> KeyPress.Result {
        if let popup = activePopup {
            popupSelection = max(popupSelection - 1, 0)
            _ = popup
            return .handled
        }
        // Recall history only when the composer is empty or already browsing,
        // so the caret stays free inside a typed multi-line draft.
        guard !model.isBusy,
              model.draftText.isEmpty || model.isBrowsingPromptHistory
        else { return .ignored }
        model.previousPrompt()
        return .handled
    }

    private func handleDownArrow() -> KeyPress.Result {
        if let popup = activePopup {
            popupSelection = min(popupSelection + 1, popupCount(popup) - 1)
            return .handled
        }
        guard !model.isBusy, model.isBrowsingPromptHistory else { return .ignored }
        model.nextPrompt()
        return .handled
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        switch ComposerReturnAction.current(
            hasPopup: activePopup != nil,
            isBusy: model.isBusy,
            canSubmit: canSubmit,
            canSteer: !isWaitingForTeamApproval && !isStopping,
            modifiers: press.modifiers
        ) {
        case .completePopup:
            guard let popup = activePopup else { return .ignored }
            applyPopupSelection(popup)
            return .handled
        case .send:
            guard canSubmit else { return .handled }
            model.submitDraft()
            focused = true
            return .handled
        case .queue:
            guard canSubmit else { return .handled }
            model.queueDraft()
            focused = true
            return .handled
        case .steer:
            guard canSubmit else { return .handled }
            model.steerDraft()
            focused = true
            return .handled
        case .stop:
            guard !isStopping else { return .handled }
            model.stop()
            return .handled
        case .newline:
            return .ignored
        }
    }

    private func handleTab() -> KeyPress.Result {
        guard let popup = activePopup else { return .ignored }
        completePopupSelection(popup)
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        if activePopup != nil {
            popupDismissedDraft = model.draftText
            return .handled
        }
        if model.isBusy {
            model.stop()
            return .handled
        }
        return .ignored
    }

    // MARK: - Sections

    private var queueRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.locus(size: 9))
                .foregroundStyle(LocusTheme.inkSoft)
            ForEach(Array(model.queuedMessages.enumerated()), id: \.offset) { index, message in
                HStack(spacing: 5) {
                    Text(message.components(separatedBy: .newlines).first.map { String($0.prefix(38)) } ?? "")
                        .font(.locus(size: 8, weight: .medium))
                        .lineLimit(1)
                    Button {
                        model.removeQueuedMessage(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.locus(size: 7, weight: .bold))
                    }
                    .buttonStyle(.locus())
                    .accessibilityLabel("Remove queued message")
                    .accessibilityIdentifier("composer.queued.\(index).remove")
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(LocusTheme.paperDeep)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(LocusTheme.line, lineWidth: 1) }
            }
            Spacer()
        }
        .frame(maxWidth: 740)
        .accessibilityIdentifier("composer.queue")
    }

    @ViewBuilder
    private func popupList(_ popup: Popup) -> some View {
        VStack(spacing: 1) {
            switch popup {
            case .slash(let commands):
                ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                    popupRow(
                        index: index,
                        symbol: command.symbol,
                        title: "/\(command.name)\(command.argumentHint.map { " <\($0)>" } ?? "")",
                        subtitle: command.summary,
                        identifier: "composer.slash.\(command.name)"
                    ) {
                        popupSelection = index
                        applySlashCommand(command)
                    }
                }
            case .routing(let targets):
                ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                    popupRow(
                        index: index,
                        symbol: target.symbol,
                        title: "@\(target.name)",
                        subtitle: target.subtitle,
                        identifier: "composer.routing.\(target.id)"
                    ) {
                        popupSelection = index
                        applyRoutingTarget(target)
                    }
                }
            case .mention(let files):
                ForEach(Array(files.enumerated()), id: \.element) { index, file in
                    popupRow(
                        index: index,
                        symbol: "doc.text",
                        title: file.lastPathComponent,
                        subtitle: WorkspaceIndex.relativePath(file, root: model.workspacePath),
                        identifier: "composer.mention.\(file.lastPathComponent)"
                    ) {
                        popupSelection = index
                        model.applyMention(file)
                        focused = true
                    }
                }
            case .skill(let skills):
                ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                    popupRow(
                        index: index,
                        symbol: "sparkles",
                        title: "$\(skill.id)",
                        subtitle: skill.description,
                        identifier: "composer.skill.\(skill.id)"
                    ) {
                        popupSelection = index
                        applySkill(skill)
                    }
                }
            }
        }
        // No container identifier here: on macOS it propagates onto the row
        // buttons and would clobber their per-row identifiers.
        .padding(5)
    }

    private func popupRow(
        index: Int,
        symbol: String,
        title: String,
        subtitle: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.locus(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 18)
                Text(title)
                    .font(.locus(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.ink)
                Text(subtitle)
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(1)
                Spacer()
                if index == popupSelection {
                    Text("↵")
                        .font(.locus(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(index == popupSelection ? LocusTheme.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .onHover { hovering in
            if hovering { popupSelection = index }
        }
        .accessibilityIdentifier(identifier)
    }

    private var modeControls: some View {
        HStack(spacing: 3) {
            ForEach([WorkMode.plan, WorkMode.grill]) { mode in
                Button {
                    model.selectedMode = model.selectedMode == mode ? .work : mode
                } label: {
                    Text(mode.title)
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(model.selectedMode == mode ? LocusTheme.paper : LocusTheme.muted)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(model.selectedMode == mode ? LocusTheme.ink : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.locus())
                .accessibilityLabel("\(mode.title) mode")
                .accessibilityValue(model.selectedMode == mode ? "Selected" : "Not selected")
                .accessibilityIdentifier("composer.mode.\(mode.rawValue)")
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            Button {
                teamPickerPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.agentTeamsModel.teamModeEnabled
                        ? "person.2.fill" : "person.fill")
                    Text(model.selectedAgentTeam?.name ?? "Solo")
                        .lineLimit(1)
                }
                .font(.locus(size: 9, weight: .semibold))
                .foregroundStyle(model.agentTeamsModel.teamModeEnabled ? accentAction : LocusTheme.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                    .background(LocusTheme.paperDeep.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.locus())
            .fixedSize()
            .popover(isPresented: $teamPickerPresented, arrowEdge: .bottom) {
                ComposerTeamPickerPopover(
                    dismiss: { teamPickerPresented = false },
                    createQuickTeam: {
                        teamPickerPresented = false
                        Task { @MainActor in
                            await Task.yield()
                            quickTeamPresented = true
                        }
                    },
                    manageAdvanced: {
                        teamPickerPresented = false
                        model.presentSettings(.agents)
                    }
                )
                .environmentObject(model)
            }
            .accessibilityLabel("Solo or team routing")
            .accessibilityValue(model.selectedAgentTeam?.name ?? "Solo")
            .accessibilityIdentifier("composer.team")
        }
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            if model.justChatEnabled {
                Button {
                    contextPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        Text("\(model.availableChatAttachments.count) attached")
                    }
                    .font(.locus(size: 9, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(LocusTheme.paperDeep.opacity(0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.locus())
                .popover(isPresented: $contextPresented, arrowEdge: .bottom) {
                    ChatAttachmentsPopover()
                        .environmentObject(model)
                }
                .accessibilityLabel("Open chat attachments")
                .accessibilityIdentifier("composer.chatAttachments")

                ComposerAttachmentSourceMenu(style: .plus)
                    .environmentObject(model)

                Label("Chat only", systemImage: "lock.fill")
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(LocusTheme.paperDeep.opacity(0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier("composer.justChatBoundary")
            } else {
                Button {
                    contextPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        if model.includedContextCount == 0 {
                            Text("Context")
                        } else {
                            Text("\(model.includedContextCount)")
                            Text(model.includedContextTokens.formatted(.number.notation(.compactName)))
                                .foregroundStyle(LocusTheme.muted.opacity(0.68))
                        }
                    }
                    .font(.locus(size: 9, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(LocusTheme.paperDeep.opacity(0.68))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.locus())
                .fixedSize()
                .popover(isPresented: $contextPresented, arrowEdge: .bottom) {
                    ContextPopover()
                        .environmentObject(model)
                }
                .accessibilityLabel("Open context pack")
                .accessibilityIdentifier("composer.context")

                ComposerAttachmentSourceMenu(style: .paperclip)
                    .environmentObject(model)

                permissionChip
            }

            if model.justChatEnabled {
                Button("Attach live application…", systemImage: "scope") {}
                    .disabled(true)
                    .help("Live application control is unavailable in Just Chat")
                Button("Attach iOS Simulator…", systemImage: "ipad.and.iphone") {}
                    .disabled(true)
                    .help("iOS Simulator control is unavailable in Just Chat")
            } else {
                Divider()
                    .frame(height: 17)
                    .padding(.horizontal, 1)
                modeControls
                    .fixedSize()
                    .layoutPriority(2)
                    .transition(LocusMotion.transition(edge: .leading, reduceMotion: reduceMotion))
            }

            Spacer()

            if model.isBusy {
                if primaryAction != .stop, !isWaitingForTeamApproval, !isStopping {
                    Menu {
                        Button("Steer Active Turn", systemImage: "arrow.turn.up.right") {
                            model.steerDraft()
                        }
                        .accessibilityIdentifier("composer.steer")
                        Button("Stop & Send as New Turn", systemImage: "stop.circle") {
                            model.stopAndSendDraft()
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.locus(size: 9, weight: .bold))
                            .foregroundStyle(LocusTheme.muted)
                            .frame(width: 26, height: 32)
                            .background(LocusTheme.paperDeep)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(!canSubmit)
                    .help("Choose how this message joins the conversation")
                    .accessibilityLabel("More send choices")
                    .accessibilityIdentifier("composer.sendChoices")
                }

                if primaryAction == .stop {
                    // Empty composer during a run: this slot used to hold a
                    // disabled steer arrow — dead space exactly where every
                    // coding agent puts its stop control. Typing switches it
                    // back to the next-turn queue action.
                    Button {
                        submit()
                    } label: {
                        Group {
                            if isStopping {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "stop.fill")
                                    .font(.locus(size: 12, weight: .bold))
                                    .foregroundStyle(Color.white)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .background(LocusTheme.coral)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.locus())
                    .disabled(isStopping)
                    .help(isStopping ? "Stopping…" : "Stop the current run (⌘↵ or Esc)")
                    .accessibilityLabel(isStopping ? "Stopping" : "Stop the current run")
                    .accessibilityIdentifier("composer.stop")
                } else {
                    Button {
                        submit()
                    } label: {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.locus(size: 12, weight: .bold))
                            .foregroundStyle(canSubmit ? accentInk : LocusTheme.muted)
                            .frame(width: 32, height: 32)
                            .background(canSubmit ? accentFill : LocusTheme.paperDeep)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.locus())
                    .disabled(!canSubmit)
                    .help("Queue for the next turn (↵)")
                    .accessibilityLabel("Queue for next turn")
                    .accessibilityIdentifier("composer.queueButton")
                }
            } else {
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.locus(size: 13, weight: .bold))
                        .foregroundStyle(canSubmit ? accentInk : LocusTheme.muted)
                        .frame(width: 32, height: 32)
                        .background(
                            canSubmit
                                ? accentFill
                                : LocusTheme.paperDeep.opacity(0.75)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    canSubmit
                                        ? accentAction.opacity(0.45)
                                        : LocusTheme.line,
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.locus())
                .disabled(!canSubmit || model.hasPendingPermission)
                .help(
                    model.hasPendingPermission
                        ? "Answer the pending permission request first"
                        : "Send (↵) · New line (⇧↵)"
                )
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("composer.send")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// Always-visible reminder of what the agent may do without asking, and
    /// the fastest way to change it.
    private var permissionChip: some View {
        Button {
            permissionModesPresented.toggle()
        } label: {
            permissionChipLabel
                .foregroundStyle(model.permissionMode.isRisky
                    ? LocusTheme.danger : LocusTheme.muted)
        }
        .buttonStyle(.locus())
        .fixedSize()
        .background(LocusTheme.paperDeep.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(LocusTheme.line, lineWidth: 1)
        }
        .popover(isPresented: $permissionModesPresented, arrowEdge: .bottom) {
            permissionModePopover
        }
        .help("Permissions: \(model.permissionMode.detail)")
        .accessibilityLabel("Permission mode, \(model.permissionMode.title)")
        .accessibilityValue(model.permissionMode.isRisky ? "Danger" : "Standard")
        .accessibilityIdentifier("composer.permissionMode")
    }

    private var permissionChipLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: model.permissionMode.isRisky
                ? "exclamationmark.shield.fill"
                : "shield.lefthalf.filled")
            Text(model.permissionMode.shortTitle)
        }
        .font(.locus(size: 9, weight: .semibold))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    private var permissionModePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permission mode")
                .font(.locus(size: 10, weight: .bold))

            ForEach(PermissionMode.allCases) { mode in
                Button {
                    model.setPermissionMode(mode)
                    permissionModesPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode.symbol)
                            .frame(width: 15)
                        Text(mode.title)
                        Spacer(minLength: 12)
                        if model.permissionMode == mode {
                            Image(systemName: "checkmark")
                                .font(.locus(size: 8, weight: .bold))
                        }
                    }
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(mode.isRisky ? LocusTheme.danger : LocusTheme.inkSoft)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(model.permissionMode == mode
                        ? LocusTheme.paperDeep : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.locus())
                .accessibilityIdentifier("composer.permissionMode.\(mode.rawValue)")
            }

            Divider().overlay(LocusTheme.line)

            Text(model.permissionMode.detail)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Reset session allowances") {
                model.resetPermissions()
                permissionModesPresented = false
            }
            .buttonStyle(.locus())
            .font(.locus(size: 8, weight: .semibold))
            .foregroundStyle(LocusTheme.inkSoft)
            .disabled(model.allowedTools.isEmpty && model.permissionMode == .ask)
        }
        .padding(10)
        .frame(width: 240)
        .background(LocusTheme.white)
    }

    private var promptTrimmed: String {
        model.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !promptTrimmed.isEmpty || !model.availableChatAttachments.isEmpty
    }

    private var primaryAction: ComposerPrimaryAction {
        .current(
            isBusy: model.isBusy,
            canSubmit: canSubmit,
            isWaitingForTeamApproval: isWaitingForTeamApproval
        )
    }

    private var isStopping: Bool {
        model.steeringState?.hasPrefix("Stopping") == true
    }

    private var attachmentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.chatAttachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.kind == .image || attachment.kind == .applicationSnapshot,
                           let data = attachment.imageData,
                           let image = NSImage(data: data) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        } else {
                            Image(systemName: attachmentSymbol(attachment.kind))
                                .font(.locus(size: 10))
                                .foregroundStyle(
                                    attachment.isAvailable ? LocusTheme.muted : LocusTheme.warning
                                )
                                .frame(width: 22, height: 22)
                        }
                        Text(attachment.name)
                            .font(.locus(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                        Button {
                            model.removeChatAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.locus(size: 8, weight: .semibold))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        .buttonStyle(.locus())
                        .accessibilityLabel("Remove \(attachment.name)")
                        .accessibilityIdentifier(
                            "composer.attachmentChip.\(attachment.id.uuidString).remove"
                        )
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 30)
                    .background(LocusTheme.paperDeep.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
                    .accessibilityIdentifier("composer.attachmentChip.\(attachment.id.uuidString)")
                }
                if let target = model.currentLiveApplicationTarget {
                    persistentContextChip(
                        title: target.name + (model.justChatEnabled ? " · paused" : ""),
                        symbol: model.currentLiveApplicationIsConnected
                            ? "macwindow" : "exclamationmark.triangle",
                        iconData: target.iconData,
                        warning: !model.currentLiveApplicationIsConnected,
                        open: {},
                        detach: { model.detachLiveApplication() },
                        identifier: "composer.liveApplicationChip"
                    )
                }
                if let target = model.currentSimulatorTarget {
                    persistentContextChip(
                        title: target.device.name + (
                            model.justChatEnabled
                                ? " · paused"
                                : (model.simulatorControl.nativeAvailable ? "" : " · disconnected")
                        ),
                        symbol: serviceSymbol,
                        iconData: nil,
                        warning: !model.simulatorControl.nativeAvailable,
                        open: {
                            if !model.justChatEnabled { model.selectInspectorTab(.simulator) }
                        },
                        detach: { model.detachSimulator() },
                        identifier: "composer.simulatorChip"
                    )
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 38)
    }

    private var serviceSymbol: String {
        model.simulatorControl.nativeAvailable
            ? "ipad.and.iphone" : "exclamationmark.triangle"
    }

    private func attachmentSymbol(_ kind: ChatAttachmentKind) -> String {
        switch kind {
        case .text: "doc.text"
        case .image: "photo"
        case .applicationSnapshot: "macwindow.badge.plus"
        }
    }

    private func persistentContextChip(
        title: String,
        symbol: String,
        iconData: Data?,
        warning: Bool,
        open: @escaping () -> Void,
        detach: @escaping () -> Void,
        identifier: String
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
                    if let iconData, let icon = NSImage(data: iconData) {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: symbol)
                            .font(.locus(size: 10))
                            .foregroundStyle(warning ? LocusTheme.warning : accentAction)
                            .frame(width: 22, height: 22)
                    }
                    Text(title)
                        .font(.locus(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 170, alignment: .leading)
                }
            }
            .buttonStyle(.locus())
            Button(action: detach) {
                Image(systemName: "xmark")
                    .font(.locus(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
            }
            .buttonStyle(.locus())
            .accessibilityLabel("Detach \(title)")
        }
        .padding(.horizontal, 7)
        .frame(height: 30)
        .background(LocusTheme.paperDeep.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(warning ? LocusTheme.warning.opacity(0.6) : LocusTheme.line, lineWidth: 1)
        }
        .accessibilityIdentifier(identifier)
    }

    private var placeholder: String {
        if isWaitingForTeamApproval {
            return "Add a follow-up for after the plan decision…"
        }
        return switch model.selectedMode {
        case .ask: "Ask anything"
        case .work: "Ask Locus to work on something…"
        case .plan: "Describe what you want to plan…"
        case .grill: "What should we stress-test?"
        }
    }

    private var measuredEditorHeight: CGFloat {
        ComposerMetrics.editorHeight(for: model.draftText, width: editorWidth)
    }

    private var isWaitingForTeamApproval: Bool {
        model.orchestrationState == .waitingDispatchApproval
    }

    private func submit() {
        if primaryAction == .stop {
            guard !isStopping else { return }
            model.stop()
            return
        }
        guard canSubmit else { return }
        model.submitDraft()
        focused = true
    }
}

/// What the composer's primary button does right now. Pure, so the whole
/// decision table is unit-testable away from the view.
enum ComposerPrimaryAction: Equatable {
    case send
    case queue
    case stop

    static func current(
        isBusy: Bool,
        canSubmit: Bool,
        isWaitingForTeamApproval: Bool
    ) -> ComposerPrimaryAction {
        guard isBusy else { return .send }
        if isWaitingForTeamApproval { return .queue }
        return canSubmit ? .queue : .stop
    }
}

enum ComposerReturnAction: Equatable {
    case completePopup
    case send
    case queue
    case steer
    case stop
    case newline

    static func current(
        hasPopup: Bool,
        isBusy: Bool,
        canSubmit: Bool,
        canSteer: Bool,
        modifiers: EventModifiers
    ) -> ComposerReturnAction {
        if hasPopup { return .completePopup }
        let textModifiers: EventModifiers = [.command, .control, .option, .shift]
        let commandOnly = modifiers.contains(.command)
            && modifiers.intersection([.control, .option, .shift]).isEmpty
        if commandOnly {
            guard canSubmit else { return isBusy ? .stop : .newline }
            guard isBusy else { return .send }
            return canSteer ? .steer : .queue
        }
        guard modifiers.intersection(textModifiers).isEmpty else { return .newline }
        guard canSubmit else { return .newline }
        if isBusy { return .queue }
        return .send
    }
}

private struct ComposerTeamPickerPopover: View {
    @EnvironmentObject private var model: AppModel
    let dismiss: () -> Void
    let createQuickTeam: () -> Void
    let manageAdvanced: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.sequence.fill")
                    .font(.locus(size: 13, weight: .semibold))
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 30, height: 30)
                    .background(LocusTheme.signal.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Choose how Locus works")
                        .font(.locus(size: 12, weight: .bold))
                    Text("Use one model or let a dispatcher coordinate a saved team.")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.locus(size: 9, weight: .bold))
                }
                .buttonStyle(.locus())
                .accessibilityLabel("Close team picker")
                .accessibilityIdentifier("composer.teamPicker.close")
            }
            .padding(13)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    soloCard
                    if model.agentTeams.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No saved teams yet")
                                .font(.locus(size: 10, weight: .semibold))
                            Text("Create one by choosing a dispatcher, lead editor, and any helper models.")
                                .font(.locus(size: 8))
                                .foregroundStyle(LocusTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("SAVED TEAMS")
                            .font(.locus(size: 8, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(LocusTheme.muted)
                            .padding(.top, 3)
                        ForEach(model.agentTeams) { team in
                            teamCard(team)
                        }
                    }
                }
                .padding(11)
            }
            .frame(maxHeight: 400)

            Divider()

            VStack(spacing: 4) {
                actionButton(
                    "Create Quick Team…",
                    symbol: "plus.circle.fill",
                    identifier: "composer.teamPicker.create"
                ) { createQuickTeam() }
                actionButton(
                    "Manage Advanced Teams…",
                    symbol: "slider.horizontal.3",
                    identifier: "composer.teamPicker.manage"
                ) { manageAdvanced() }
            }
            .padding(8)
        }
        .frame(width: 430)
        .background(LocusTheme.panel)
        .accessibilityIdentifier("composer.teamPicker")
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private var soloCard: some View {
        let selected = model.agentTeamsModel.selectedAgentTeamID == nil
        return Button {
            model.agentTeamsModel.selectSoloRoute()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.fill")
                    .foregroundStyle(selected ? LocusTheme.signalDeep : LocusTheme.muted)
                    .frame(width: 24, height: 24)
                    .background(selected ? LocusTheme.signal.opacity(0.10) : LocusTheme.paperDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Solo")
                        .font(.locus(size: 10, weight: .semibold))
                    Text("Use the selected conversation model directly")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? LocusTheme.signalDeep : LocusTheme.muted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? LocusTheme.signal.opacity(0.08) : LocusTheme.white.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? LocusTheme.signalDeep.opacity(0.6) : LocusTheme.line)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel("Solo, use the selected conversation model")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("composer.teamPicker.solo")
    }

    private func teamCard(_ team: AgentTeam) -> some View {
        let selected = model.agentTeamsModel.selectedAgentTeamID == team.id
        let profiles = team.memberIDs.compactMap { id in
            model.agentProfiles.first(where: { $0.id == id })
        }
        let dispatcher = team.dispatcherID.flatMap { id in
            profiles.first(where: { $0.id == id })
        }
        let lead = team.defaultWriterID.flatMap { id in
            profiles.first(where: { $0.id == id })
        }
        let helpers = profiles.filter { $0.id != dispatcher?.id && $0.id != lead?.id }
        let issue = teamIssue(team)

        return Button {
            model.agentTeamsModel.selectAgentTeam(team.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: issue == nil ? "person.2.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue == nil ? LocusTheme.signalDeep : LocusTheme.coral)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(team.name)
                            .font(.locus(size: 10, weight: .bold))
                            .lineLimit(1)
                        Text(issue ?? "Dispatcher chooses from \(profiles.count) configured agents")
                            .font(.locus(size: 8))
                            .foregroundStyle(issue == nil ? LocusTheme.muted : LocusTheme.coral)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? LocusTheme.signalDeep : LocusTheme.muted)
                }
                if let dispatcher {
                    profileLine("Dispatcher", profile: dispatcher, symbol: "arrow.triangle.branch")
                }
                if let lead {
                    profileLine("Lead", profile: lead, symbol: "hammer.fill")
                }
                if !helpers.isEmpty {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "person.2")
                            .font(.locus(size: 8))
                            .foregroundStyle(LocusTheme.muted)
                            .frame(width: 13)
                        Text("Helpers · \(helpers.map(\.model).joined(separator: ", "))")
                            .font(.locus(size: 8, design: .monospaced))
                            .foregroundStyle(LocusTheme.inkSoft)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? LocusTheme.signal.opacity(0.08) : LocusTheme.white.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? LocusTheme.signalDeep.opacity(0.6) : LocusTheme.line)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityLabel(teamAccessibilityLabel(team, profiles: profiles, issue: issue))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("composer.teamPicker.team.\(team.id.uuidString)")
    }

    private func profileLine(
        _ label: String,
        profile: AgentProfile,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .frame(width: 13)
            Text("\(label) · \(profile.model) · \(routeTitle(profile.route))")
                .font(.locus(size: 8, design: .monospaced))
                .foregroundStyle(LocusTheme.inkSoft)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func teamIssue(_ team: AgentTeam) -> String? {
        if let error = AgentTeamValidation.errors(team: team, profiles: model.agentProfiles).first {
            return error
        }
        let memberAccountIDs = Set(team.memberIDs.compactMap { id in
            model.agentProfiles.first(where: { $0.id == id })?.route.accountID
        })
        for accountID in memberAccountIDs {
            guard let account = model.providerAccounts.first(where: { $0.id == accountID }) else {
                return "A hosted provider used by this team is unavailable."
            }
            if !account.hasKey {
                return "Reconnect \(account.displayName) before using this team."
            }
        }
        if let error = AgentTeamValidation.routeErrors(
            team: team,
            profiles: model.agentProfiles,
            accounts: model.providerAccounts,
            accountModels: model.accountModels
        ).first {
            return error
        }
        if let missingID = memberAccountIDs.subtracting(model.agentTeamsModel.teamRoutingConsentAccountIDs).first {
            let name = model.providerAccounts.first(where: { $0.id == missingID })?.displayName
                ?? "a hosted provider"
            return "Allow automatic routing for \(name) in Advanced settings."
        }
        return nil
    }

    private func routeTitle(_ route: AgentRoute) -> String {
        switch route {
        case .localOllama: "Local"
        case .providerAccount(let accountID):
            model.providerAccounts.first(where: { $0.id == accountID })?.shortName
                ?? "Unavailable"
        }
    }

    private func teamAccessibilityLabel(
        _ team: AgentTeam,
        profiles: [AgentProfile],
        issue: String?
    ) -> String {
        let models = profiles.map(\.model).joined(separator: ", ")
        return [team.name, "models \(models)", issue].compactMap { $0 }.joined(separator: ", ")
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(LocusTheme.signalDeep)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            .font(.locus(size: 9, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.locus())
        .accessibilityIdentifier(identifier)
    }
}

private enum ComposerAttachmentMenuStyle {
    case plus
    case paperclip
}

private struct ComposerAttachmentSourceMenu: View {
    @EnvironmentObject private var model: AppModel
    @State private var reviewPresented = false
    @State private var refreshRevision = 0
    let style: ComposerAttachmentMenuStyle

    var body: some View {
        Menu {
            Button("Review message attachments", systemImage: "tray.full") {
                reviewPresented = true
            }
            .disabled(model.chatAttachments.isEmpty)
            Divider()
            Button("Add files or photos…", systemImage: "doc.badge.plus") {
                model.addChatAttachments()
            }
            .disabled(model.isLoadingChatAttachments)

            if ApplicationContextService.isAvailable {
                if let current = model.applicationContext.lastExternalApplication {
                    Button {
                        model.attachApplicationSnapshot(current)
                    } label: {
                        Label("Attach \(current.name)", systemImage: "macwindow.badge.plus")
                    }
                    .disabled(model.isLoadingChatAttachments)
                } else {
                    Button("Attach current application", systemImage: "macwindow.badge.plus") {}
                        .disabled(true)
                }
            } else {
                Button("Application context requires the direct-download build") {}
                    .disabled(true)
            }

            if !model.justChatEnabled {
                Menu("Attach live application…", systemImage: "scope") {
                    if model.applicationContext.runningApplications.isEmpty {
                        Button("No applications are available") {}
                            .disabled(true)
                    }
                    ForEach(model.applicationContext.runningApplications) { target in
                        Button {
                            model.attachLiveApplication(target)
                        } label: {
                            if let data = target.iconData, let icon = NSImage(data: data) {
                                Label {
                                    Text(target.name)
                                } icon: {
                                    Image(nsImage: icon)
                                }
                            } else {
                                Label(target.name, systemImage: "macwindow")
                            }
                        }
                    }
                }
                .disabled(!ApplicationContextService.isAvailable)

                Menu("Attach iOS Simulator…", systemImage: "ipad.and.iphone") {
                    if !SimulatorControlService.isSupportedBuild {
                        Button("Requires the direct-download build") {}
                            .disabled(true)
                    } else if model.simulatorControl.devices.isEmpty {
                        Button("No iPhone or iPad simulators found") {
                            model.refreshSimulatorDevices()
                        }
                    }
                    ForEach(model.simulatorControl.devices) { device in
                        Button {
                            model.attachSimulator(device)
                        } label: {
                            Label(
                                "\(device.name) — \(device.subtitle)",
                                systemImage: device.isIPad ? "ipad" : "iphone"
                            )
                        }
                    }
                    if model.simulatorControl.isRefreshing {
                        Button("Refreshing simulators…") {}
                            .disabled(true)
                    } else {
                        Divider()
                        Button("Refresh Simulators", systemImage: "arrow.clockwise") {
                            model.refreshSimulatorDevices()
                        }
                    }
                }
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach files, application context, or an iOS Simulator")
        .accessibilityLabel("Add message context")
        .accessibilityIdentifier("composer.addChatAttachment")
        .popover(isPresented: $reviewPresented, arrowEdge: .bottom) {
            ChatAttachmentsPopover()
                .environmentObject(model)
        }
        .onAppear {
            // The service is seeded at initialization and stays current from
            // workspace launch/termination notifications. Avoid refreshing on
            // every identity-driven menu rebuild, which otherwise forms a
            // publish → rebuild → onAppear loop.
            if model.applicationContext.runningApplications.isEmpty {
                model.applicationContext.refreshRunningApplications()
            }
            if !model.justChatEnabled,
               model.simulatorControl.devices.isEmpty,
               !model.simulatorControl.isRefreshing
            {
                model.refreshSimulatorDevices()
            }
        }
        .onReceive(model.applicationContext.objectWillChange) { _ in
            refreshRevision &+= 1
        }
        .onReceive(model.simulatorControl.objectWillChange) { _ in
            refreshRevision &+= 1
        }
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .plus:
            Image(systemName: "plus")
                .font(.locus(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(LocusTheme.paperDeep.opacity(0.68))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LocusTheme.line, lineWidth: 1)
                }
        case .paperclip:
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                if !model.availableChatAttachments.isEmpty {
                    Text("\(model.availableChatAttachments.count)")
                }
            }
            .font(.locus(size: 9, weight: .semibold))
            .foregroundStyle(imageWarning ? LocusTheme.warning : LocusTheme.ink)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(LocusTheme.paperDeep.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        imageWarning ? LocusTheme.warning.opacity(0.55) : LocusTheme.line,
                        lineWidth: 1
                    )
            }
        }
    }

    private var imageWarning: Bool {
        model.activeModelRejectsImages
            && model.chatAttachments.contains {
                $0.kind == .image || $0.kind == .applicationSnapshot
            }
    }
}

private struct ChatAttachmentsPopover: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CHAT ATTACHMENTS")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text("Inputs sent with this message")
                        .font(.locus(size: 11, weight: .bold))
                }
                Spacer()
                Button {
                    model.addChatAttachments()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.locus())
                .font(.locus(size: 9, weight: .semibold))
                .accessibilityIdentifier("chatAttachments.add")
                .disabled(model.isLoadingChatAttachments)
            }
            .padding(13)

            Label(
                model.justChatEnabled
                    ? "Only these inputs are supplied to the model. Chat cannot browse "
                        + "their folders, use tools, or edit anything."
                    : "These files and Appshots ride with this one message as direct evidence. In a "
                        + "team run, images reach the dispatcher and the first coding job.",
                systemImage: model.justChatEnabled ? "lock.shield" : "paperclip"
            )
            .font(.locus(size: 8))
            .foregroundStyle(LocusTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(LocusTheme.paperDeep.opacity(0.7))

            if model.activeModelRejectsImages,
               model.chatAttachments.contains(where: {
                   $0.kind == .image || $0.kind == .applicationSnapshot
               }) {
                Label(
                    "\(model.selectedModel) reports no vision support. Locus will "
                        + "send the images and fall back to their names if the model "
                        + "rejects them.",
                    systemImage: "eye.slash"
                )
                .font(.locus(size: 8))
                .foregroundStyle(LocusTheme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(LocusTheme.warning.opacity(0.08))
                .accessibilityIdentifier("chatAttachments.visionWarning")
            }

            if model.isLoadingChatAttachments {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing attachments…")
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.vertical, 28)
                .accessibilityIdentifier("chatAttachments.loading")
            } else if model.chatAttachments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.locus(size: 19))
                        .foregroundStyle(LocusTheme.muted)
                    Text("No attachments yet")
                        .font(.locus(size: 10, weight: .semibold))
                    Text("Attach text or source files, PDFs, and common image formats.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.chatAttachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: attachmentSymbol(attachment.kind))
                                    .font(.locus(size: 11))
                                    .foregroundStyle(
                                        attachment.isAvailable ? LocusTheme.muted : LocusTheme.warning
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.name)
                                        .font(.locus(size: 9, weight: .semibold))
                                        .foregroundStyle(
                                            attachment.isAvailable ? LocusTheme.ink : LocusTheme.muted
                                        )
                                        .lineLimit(1)
                                    Text(attachment.detail)
                                        .font(.locus(size: 7))
                                        .foregroundStyle(
                                            attachment.issue == nil ? LocusTheme.muted : LocusTheme.warning
                                        )
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    model.removeChatAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.locus(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.locus())
                                .foregroundStyle(LocusTheme.muted)
                                .accessibilityLabel("Remove \(attachment.name)")
                                .accessibilityIdentifier(
                                    "chatAttachments.file.\(attachment.id.uuidString).remove"
                                )
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 40)
                            .background(Color.white.opacity(0.001))
                        }
                    }
                    .padding(5)
                }
                .frame(maxHeight: 260)
            }

            if let notice = model.chatAttachmentNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(LocusTheme.paperDeep.opacity(0.45))
            }
        }
        .frame(width: 370)
        .background(LocusTheme.white)
    }

    private func attachmentSymbol(_ kind: ChatAttachmentKind) -> String {
        switch kind {
        case .text: "doc.text"
        case .image: "photo"
        case .applicationSnapshot: "macwindow.badge.plus"
        }
    }
}

private struct ContextPopover: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONTEXT PACK")
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text("Selected project files")
                        .font(.locus(size: 11, weight: .bold))
                }
                Spacer()
                Button {
                    model.addContext()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.locus())
                .font(.locus(size: 9, weight: .semibold))
                .accessibilityIdentifier("context.add")
                .disabled(model.isLoadingContext)
            }
            .padding(13)

            VStack(spacing: 7) {
                HStack {
                    Text("\(model.includedContextTokens.formatted()) estimated tokens")
                    Spacer()
                    Text("\(model.includedContextCount)/50 files")
                }
                ProgressView(
                    value: Double(model.includedContextTokens),
                    total: Double(max(model.contextBudgetTokens, 1))
                )
                .progressViewStyle(.linear)
                .tint(LocusTheme.signalDeep)
                .accessibilityLabel("Context budget")
                .accessibilityValue("\(model.includedContextTokens) of \(model.contextBudgetTokens) tokens")
                if let notice = model.contextNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.locus(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        model.contextWindowTokens == nil
                            ? "60% of an assumed \(AppModel.assumedContextWindowTokens.formatted())-token window is available for files — this model's real window is unknown."
                            : "60% of the \(model.selectedModel) context window is available for files."
                    )
                    .font(.locus(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.locus(size: 8))
            .foregroundStyle(LocusTheme.muted)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(LocusTheme.paperDeep.opacity(0.7))

            if model.isLoadingContext {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading files off the main thread…")
                        .font(.locus(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.vertical, 28)
                .accessibilityIdentifier("context.loading")
            } else if model.contextFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.locus(size: 19))
                        .foregroundStyle(LocusTheme.muted)
                    Text("No context files yet")
                        .font(.locus(size: 10, weight: .semibold))
                    Text("Add only the files this run should focus on.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.contextFiles) { file in
                            HStack(spacing: 8) {
                                Button {
                                    model.toggleContext(file)
                                } label: {
                                    Image(systemName: file.isAvailable ? (file.isIncluded ? "checkmark.square.fill" : "square") : "exclamationmark.triangle.fill")
                                        .foregroundStyle(file.isAvailable ? (file.isIncluded ? LocusTheme.ink : LocusTheme.muted) : LocusTheme.warning)
                                }
                                .buttonStyle(.locus())
                                .accessibilityLabel(file.isIncluded ? "Exclude \(file.name)" : "Include \(file.name)")
                                .accessibilityIdentifier("context.file.\(file.id.uuidString).toggle")

                                Image(systemName: "doc.text")
                                    .font(.locus(size: 11))
                                    .foregroundStyle(LocusTheme.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.locus(size: 9, weight: .semibold))
                                        .foregroundStyle(file.isAvailable ? LocusTheme.ink : LocusTheme.muted)
                                        .lineLimit(1)
                                    Text(file.issue ?? "\(file.estimatedTokens.formatted()) tokens")
                                        .font(.locus(size: 7))
                                        .foregroundStyle(file.issue == nil ? LocusTheme.muted : LocusTheme.warning)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    model.removeContext(file)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.locus(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.locus())
                                .foregroundStyle(LocusTheme.muted)
                                .accessibilityLabel("Remove \(file.name)")
                                .accessibilityIdentifier("context.file.\(file.id.uuidString).remove")
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 40)
                            .background(Color.white.opacity(0.001))
                        }
                    }
                    .padding(5)
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 370)
        .background(LocusTheme.white)
    }
}
