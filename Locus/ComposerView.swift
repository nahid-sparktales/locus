import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var contextPresented = false
    @State private var attachmentsPresented = false
    @State private var permissionModesPresented = false
    @State private var popupSelection = 0
    @State private var popupDismissedDraft: String?
    @FocusState private var focused: Bool

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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.planApprovalPending {
                // Same contract as the permission panel: the finished plan is
                // a decision point, so the decision replaces the input.
                PlanApprovalPromptView()
                    .frame(maxWidth: 740)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    if let popup = activePopup {
                        popupList(popup)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(LocusTheme.line).frame(height: 1)
                            }
                    }

                    if !model.justChatEnabled {
                        modeRow
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    ZStack(alignment: .topLeading) {
                        if model.draftText.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 12))
                                .foregroundStyle(LocusTheme.muted.opacity(0.58))
                                .padding(.horizontal, 12)
                                .padding(.top, 11)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $model.draftText)
                            .font(.system(size: 12))
                            .foregroundStyle(LocusTheme.ink)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            // Start compact and keep long drafts internally
                            // scrollable. The previous 120-point editor used
                            // nearly twice the vertical space of the transcript.
                            .frame(minHeight: 52, idealHeight: 60, maxHeight: 68)
                            .focused($focused)
                            .accessibilityLabel("Message Locus")
                            .accessibilityIdentifier("composer.input")
                            .onKeyPress(.upArrow) { handleUpArrow() }
                            .onKeyPress(.downArrow) { handleDownArrow() }
                            .onKeyPress(.return, phases: .down) { press in handleReturn(press) }
                            .onKeyPress(.tab) { handleTab() }
                            .onKeyPress(.escape) { handleEscape() }
                    }

                    if !model.chatAttachments.isEmpty {
                        attachmentChipsRow
                    }

                    actionRow
                }
                .frame(maxWidth: 740)
                .locusCard(radius: 13)
                .chatAttachmentDropTarget()
                .chatPasteInterceptor(editorFocused: focused)
                .shadow(color: .black.opacity(0.08), radius: 22, y: 9)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .animation(.easeInOut(duration: 0.18), value: model.activePermissionRequest?.requestID)
        .animation(.easeInOut(duration: 0.18), value: model.planApprovalPending)
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
        .onChange(of: model.shouldShowTeamDispatchApproval) {
            if !model.shouldShowTeamDispatchApproval && !model.shouldShowTeamDispatchProgress {
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
                model.refreshWorkspaceIndex()
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
                in: model.workspaceFileIndex,
                root: model.workspacePath
            )
            return matches.isEmpty ? nil : .mention(matches)
        }
        if let query = activeSkillQuery {
            let matches = model.extensions.skills.filter {
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
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
            ForEach(Array(model.queuedMessages.enumerated()), id: \.offset) { index, message in
                HStack(spacing: 5) {
                    Text(message.components(separatedBy: .newlines).first.map { String($0.prefix(38)) } ?? "")
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                    Button {
                        model.removeQueuedMessage(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .buttonStyle(.plain)
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
                    .font(.system(size: 10))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LocusTheme.ink)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(1)
                Spacer()
                if index == popupSelection {
                    Text("↵")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(LocusTheme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(index == popupSelection ? LocusTheme.paperDeep : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { popupSelection = index }
        }
        .accessibilityIdentifier(identifier)
    }

    private var modeRow: some View {
        HStack(spacing: 3) {
            ForEach([WorkMode.plan, WorkMode.build]) { mode in
                Button {
                    model.selectedMode = model.selectedMode == mode ? .work : mode
                } label: {
                    Text(mode.rawValue.capitalized)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(model.selectedMode == mode ? LocusTheme.paper : LocusTheme.muted)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(model.selectedMode == mode ? LocusTheme.ink : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.rawValue.capitalized) mode")
                .accessibilityValue(model.selectedMode == mode ? "Selected" : "Not selected")
                .accessibilityIdentifier("composer.mode.\(mode.rawValue)")
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            Menu {
                Button {
                    model.selectAgentTeam(nil)
                } label: {
                    Label("Solo", systemImage: model.selectedAgentTeamID == nil ? "checkmark" : "person")
                }
                if !model.agentTeams.isEmpty {
                    Divider()
                    ForEach(model.agentTeams) { team in
                        Button {
                            model.selectAgentTeam(team.id)
                        } label: {
                            Label(
                                team.name,
                                systemImage: model.selectedAgentTeamID == team.id ? "checkmark" : "person.3"
                            )
                        }
                    }
                }
                Divider()
                Button("Manage Agents & Teams…", systemImage: "gearshape") {
                    model.settingsPage = .agents
                    model.settingsPresented = true
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.teamModeEnabled ? "person.3.fill" : "person.fill")
                    Text(model.selectedAgentTeam?.name ?? "Solo")
                        .lineLimit(1)
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(model.teamModeEnabled ? LocusTheme.signalDeep : LocusTheme.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(LocusTheme.paperDeep.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Solo or team routing")
            .accessibilityIdentifier("composer.team")
            Spacer()
            Text(model.selectedMode.description)
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .frame(height: 37)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line.opacity(0.65)).frame(height: 1)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 7) {
            if model.justChatEnabled {
                Button {
                    contextPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        Text("\(model.availableChatAttachments.count) attached")
                    }
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(LocusTheme.paperDeep.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $contextPresented, arrowEdge: .bottom) {
                    ChatAttachmentsPopover()
                        .environmentObject(model)
                }
                .accessibilityLabel("Open chat attachments")
                .accessibilityIdentifier("composer.chatAttachments")

                Button {
                    model.addChatAttachments()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .background(LocusTheme.paperDeep.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(LocusTheme.line, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Attach files, PDFs, or images to this message")
                .accessibilityLabel("Add chat attachments")
                .accessibilityIdentifier("composer.addChatAttachment")
                .disabled(model.isLoadingChatAttachments)

                Label("Chat only", systemImage: "lock.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(LocusTheme.paperDeep.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityIdentifier("composer.justChatBoundary")
            } else {
                Button {
                    contextPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("\(model.includedContextCount) files")
                        Text(model.includedContextTokens.formatted(.number.notation(.compactName)))
                            .foregroundStyle(LocusTheme.muted.opacity(0.68))
                    }
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(LocusTheme.paperDeep.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(LocusTheme.line, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $contextPresented, arrowEdge: .bottom) {
                    ContextPopover()
                        .environmentObject(model)
                }
                .accessibilityLabel("Open context pack")
                .accessibilityIdentifier("composer.context")

                Button {
                    model.addContext()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .background(LocusTheme.paperDeep.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(LocusTheme.line, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Add files or folders to context")
                .accessibilityLabel("Add context")
                .accessibilityIdentifier("composer.addContext")
                .disabled(model.isLoadingContext)

                Button {
                    contextPresented = false
                    attachmentsPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        if !model.availableChatAttachments.isEmpty {
                            Text("\(model.availableChatAttachments.count)")
                        }
                    }
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(
                        attachmentWarningActive ? LocusTheme.warning : LocusTheme.ink
                    )
                    .padding(.horizontal, 8)
                    .frame(height: 27)
                    .background(LocusTheme.paperDeep.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                attachmentWarningActive
                                    ? LocusTheme.warning.opacity(0.55) : LocusTheme.line,
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $attachmentsPresented, arrowEdge: .bottom) {
                    ChatAttachmentsPopover()
                        .environmentObject(model)
                }
                .help("Attach files, PDFs, or images to this message")
                .accessibilityLabel("Open message attachments")
                .accessibilityIdentifier("composer.chatAttachments")

                permissionChip
            }

            Spacer()

            Text(sendHint)
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted.opacity(0.62))

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
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(LocusTheme.muted)
                            .frame(width: 24, height: 30)
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
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.white)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .background(LocusTheme.coral)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isStopping)
                    .help(isStopping ? "Stopping…" : "Stop the current run (⌘↵ or Esc)")
                    .accessibilityLabel(isStopping ? "Stopping" : "Stop the current run")
                    .accessibilityIdentifier("composer.stop")
                } else {
                    Button {
                        submit()
                    } label: {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(canSubmit ? LocusTheme.brandInk : LocusTheme.muted)
                            .frame(width: 30, height: 30)
                            .background(canSubmit ? LocusTheme.signal : LocusTheme.paperDeep)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSubmit ? LocusTheme.signal : LocusTheme.paper)
                        .frame(width: 30, height: 30)
                        .background(LocusTheme.ink.opacity(canSubmit ? 1 : 0.22))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || model.hasPendingPermission)
                .help(
                    model.hasPendingPermission
                        ? "Answer the pending permission request first"
                        : "Send (↵)"
                )
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("composer.send")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 9)
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
        .buttonStyle(.plain)
        .fixedSize()
        .background(LocusTheme.paperDeep.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
        .font(.system(size: 8, weight: .semibold))
        .padding(.horizontal, 8)
        .frame(height: 27)
        .contentShape(Rectangle())
    }

    private var permissionModePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permission mode")
                .font(.system(size: 10, weight: .bold))

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
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(mode.isRisky ? LocusTheme.danger : LocusTheme.inkSoft)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(model.permissionMode == mode
                        ? LocusTheme.paperDeep : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.permissionMode.\(mode.rawValue)")
            }

            Divider().overlay(LocusTheme.line)

            Text(model.permissionMode.detail)
                .font(.system(size: 8))
                .foregroundStyle(LocusTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button("Reset session allowances") {
                model.resetPermissions()
                permissionModesPresented = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 8, weight: .semibold))
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

    private var attachmentWarningActive: Bool {
        model.activeModelRejectsImages
            && model.chatAttachments.contains { $0.kind == .image }
    }

    private var attachmentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.chatAttachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.kind == .image,
                           let data = attachment.imageData,
                           let image = NSImage(data: data) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 22, height: 22)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        } else {
                            Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    attachment.isAvailable ? LocusTheme.muted : LocusTheme.warning
                                )
                                .frame(width: 22, height: 22)
                        }
                        Text(attachment.name)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .frame(maxWidth: 140, alignment: .leading)
                        Button {
                            model.removeChatAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(LocusTheme.muted)
                        }
                        .buttonStyle(.plain)
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
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 38)
    }

    private var sendHint: String {
        // No permission branch: while a request is pending the whole card —
        // including this hint — is replaced by the permission panel.
        model.isBusy
            ? (isWaitingForTeamApproval
                ? "↵ Queue for Next Turn"
                : "↵ Queue · ⌘↵ Steer")
            : "↵ Send"
    }

    private var placeholder: String {
        if isWaitingForTeamApproval {
            return "Write the next message — it will send after the plan decision…"
        }
        return switch model.selectedMode {
        case .ask: "Ask anything…  (attach files or images · no workspace tools)"
        case .work: "What should Locus work on?  ( / commands · @ files · ⌘V images )"
        case .plan: "Describe the change you want to plan…  ( / commands · @ files · ⌘V images )"
        case .build: "What should we build next?  ( / commands · @ files · ⌘V images )"
        }
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

private struct ChatAttachmentsPopover: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CHAT ATTACHMENTS")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text("Files sent with this message")
                        .font(.system(size: 11, weight: .bold))
                }
                Spacer()
                Button {
                    model.addChatAttachments()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9, weight: .semibold))
                .accessibilityIdentifier("chatAttachments.add")
                .disabled(model.isLoadingChatAttachments)
            }
            .padding(13)

            Label(
                model.justChatEnabled
                    ? "Only these files are supplied to the model. Chat cannot browse "
                        + "their folders, use tools, or edit anything."
                    : "These files ride with this one message as direct evidence. In a "
                        + "team run, images reach the dispatcher and the first coding job.",
                systemImage: model.justChatEnabled ? "lock.shield" : "paperclip"
            )
            .font(.system(size: 8))
            .foregroundStyle(LocusTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(LocusTheme.paperDeep.opacity(0.7))

            if model.activeModelRejectsImages,
               model.chatAttachments.contains(where: { $0.kind == .image }) {
                Label(
                    "\(model.selectedModel) reports no vision support. Locus will "
                        + "send the images and fall back to their names if the model "
                        + "rejects them.",
                    systemImage: "eye.slash"
                )
                .font(.system(size: 8))
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
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.vertical, 28)
                .accessibilityIdentifier("chatAttachments.loading")
            } else if model.chatAttachments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 19))
                        .foregroundStyle(LocusTheme.muted)
                    Text("No attachments yet")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Attach text or source files, PDFs, and common image formats.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.chatAttachments) { attachment in
                            HStack(spacing: 8) {
                                Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                                    .font(.system(size: 11))
                                    .foregroundStyle(
                                        attachment.isAvailable ? LocusTheme.muted : LocusTheme.warning
                                    )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.name)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(
                                            attachment.isAvailable ? LocusTheme.ink : LocusTheme.muted
                                        )
                                        .lineLimit(1)
                                    Text(attachment.detail)
                                        .font(.system(size: 7))
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
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.plain)
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
                    .font(.system(size: 8))
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
}

private struct ContextPopover: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONTEXT PACK")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(LocusTheme.muted)
                    Text("Selected project files")
                        .font(.system(size: 11, weight: .bold))
                }
                Spacer()
                Button {
                    model.addContext()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9, weight: .semibold))
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
                        .font(.system(size: 8))
                        .foregroundStyle(LocusTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        model.contextWindowTokens == nil
                            ? "60% of an assumed \(AppModel.assumedContextWindowTokens.formatted())-token window is available for files — this model's real window is unknown."
                            : "60% of the \(model.selectedModel) context window is available for files."
                    )
                    .font(.system(size: 8))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(LocusTheme.muted)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(LocusTheme.paperDeep.opacity(0.7))

            if model.isLoadingContext {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading files off the main thread…")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LocusTheme.muted)
                }
                .padding(.vertical, 28)
                .accessibilityIdentifier("context.loading")
            } else if model.contextFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 19))
                        .foregroundStyle(LocusTheme.muted)
                    Text("No context files yet")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add only the files this run should focus on.")
                        .font(.system(size: 9))
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
                                .buttonStyle(.plain)
                                .accessibilityLabel(file.isIncluded ? "Exclude \(file.name)" : "Include \(file.name)")
                                .accessibilityIdentifier("context.file.\(file.id.uuidString).toggle")

                                Image(systemName: "doc.text")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LocusTheme.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(file.isAvailable ? LocusTheme.ink : LocusTheme.muted)
                                        .lineLimit(1)
                                    Text(file.issue ?? "\(file.estimatedTokens.formatted()) tokens")
                                        .font(.system(size: 7))
                                        .foregroundStyle(file.issue == nil ? LocusTheme.muted : LocusTheme.warning)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    model.removeContext(file)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .buttonStyle(.plain)
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
