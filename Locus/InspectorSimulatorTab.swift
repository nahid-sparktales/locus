import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A task-scoped Simulator surface. Pointer gestures are mapped to device
/// points and injected through the bridge, so the Mac pointer never moves.
struct InspectorSimulatorTab: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var service: SimulatorControlService
    @FocusState private var typingFocused: Bool
    @State private var pointSize: CGSize?
    @State private var gestureStart: CGPoint?
    @State private var gestureStartedAt: Date?
    @State private var touchIndicator: CGPoint?
    @State private var typingText = ""
    @State private var actionMessage = ""
    @State private var showTyping = false
    @State private var showStreamSettings = false
    @State private var confirmShutdown = false

    init(service: SimulatorControlService? = nil) {
        _service = ObservedObject(wrappedValue: service ?? SimulatorControlService())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let target {
                simulatorWorkspace(target)
            } else {
                devicePicker
            }
        }
        .background(LocusTheme.surfaceCanvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.simulator")
        .confirmationDialog("Shut down this simulator?", isPresented: $confirmShutdown) {
            Button("Shut Down", role: .destructive) { shutDown() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shutdown detaches the task. It does not erase or delete the device.")
        }
        .onAppear {
            if service.devices.isEmpty { model.refreshSimulatorDevices() }
            startPreviewIfAttached()
        }
        .onChange(of: target?.udid) { _, _ in
            actionMessage = ""
            showTyping = false
            startPreviewIfAttached()
        }
        .onChange(of: service.streamSettings) { _, _ in
            guard target != nil else { return }
            Task { await service.restartPreview(sessionID: model.currentSessionID) }
        }
        .onChange(of: showTyping) { _, isShowing in
            guard isShowing else { return }
            Task { @MainActor in typingFocused = true }
        }
        .onDisappear { service.stopPreview() }
    }

    private var target: SimulatorTarget? { service.target(for: model.currentSessionID) }

    private var isRecording: Bool {
        service.recordingSessionID == model.currentSessionID
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if let target {
                deviceMenu(target)
            } else {
                Image(systemName: "ipad.and.iphone")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.accentAction)
                    .frame(width: 30, height: 30)
                    .background(LocusTheme.accentFill.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("iOS Simulator")
                        .font(LocusType.caption.weight(.semibold))
                        .foregroundStyle(LocusTheme.textPrimary)
                    Text("Choose a device for this task")
                        .font(LocusType.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if target != nil {
                headerIconButton(
                    "slider.horizontal.3",
                    help: "Stream settings",
                    action: { showStreamSettings.toggle() }
                )
                .popover(isPresented: $showStreamSettings, arrowEdge: .top) {
                    streamSettingsPopover
                }

                simulatorMenu
            } else {
                headerIconButton(
                    "arrow.clockwise",
                    help: "Refresh simulators",
                    action: { model.refreshSimulatorDevices() }
                )
                .disabled(service.isRefreshing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .locusSurface(.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.separator).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simulator.header")
    }

    private func deviceMenu(_ target: SimulatorTarget) -> some View {
        Menu {
            ForEach(service.devices) { device in
                Button {
                    model.attachSimulator(device)
                } label: {
                    Label {
                        Text("\(device.name) — \(device.subtitle)")
                    } icon: {
                        Image(systemName: device.isIPad ? "ipad" : "iphone")
                    }
                }
            }
            Divider()
            Button("Refresh Devices", systemImage: "arrow.clockwise") {
                model.refreshSimulatorDevices()
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: target.device.isIPad ? "ipad" : "iphone")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(LocusTheme.accentAction)
                    .frame(width: 30, height: 30)
                    .background(LocusTheme.accentFill.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.device.name)
                        .font(LocusType.caption.weight(.semibold))
                        .foregroundStyle(LocusTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(service.previewIsLive
                                ? LocusTheme.successForeground
                                : LocusTheme.warningForeground)
                            .frame(width: 6, height: 6)
                        Text("\(target.device.runtime) · \(target.device.state.rawValue)")
                            .font(LocusType.caption)
                            .foregroundStyle(LocusTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.locus(size: 7, weight: .bold))
                    .foregroundStyle(LocusTheme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Attached simulator: \(target.device.name)")
        .accessibilityHint("Choose another simulator")
    }

    private var simulatorMenu: some View {
        Menu {
            Button("Refresh Frame", systemImage: "arrow.clockwise") { refreshFallback() }
            Divider()
            Button("Detach Simulator", systemImage: "rectangle.portrait.and.arrow.right") {
                model.detachSimulator()
            }
            Button("Shut Down…", systemImage: "power", role: .destructive) {
                confirmShutdown = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 11, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(LocusTheme.textTertiary)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("Simulator options")
        .accessibilityLabel("Simulator options")
    }

    private func headerIconButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.textTertiary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.locus(.icon))
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Device picker

    @ViewBuilder
    private var devicePicker: some View {
        if !SimulatorControlService.isSupportedBuild {
            unavailableState
        } else if service.isRefreshing {
            loadingState
        } else if service.devices.isEmpty {
            setupState
        } else {
            availableDevices
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Finding simulators…")
                .font(LocusType.caption)
                .foregroundStyle(LocusTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("simulator.loading")
    }

    private var unavailableState: some View {
        simulatorEmptyState(
            symbol: "iphone.slash",
            title: "Simulator control isn’t available",
            message: "Use the direct-download build of Locus to view and control iOS Simulator devices."
        )
    }

    private var setupState: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: "ipad.and.iphone")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(LocusTheme.accentAction)
                        .frame(width: 66, height: 66)
                        .background(LocusTheme.accentFill.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("Finish simulator setup")
                        .font(LocusType.title)
                        .foregroundStyle(LocusTheme.textPrimary)
                    Text(service.helperHealth.message)
                        .font(LocusType.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    setupStep(
                        "Full Xcode selected",
                        complete: service.helperHealth.xcodePath != nil
                    )
                    setupDivider
                    setupStep(
                        "Locus simulator bridge installed",
                        complete: service.helperHealth.touchHelperPresent
                            && service.helperHealth.treeHelperPresent
                    )
                    setupDivider
                    setupStep(
                        "Simulator tools compatible",
                        complete: service.helperHealth.compatibilityReady
                    )
                }
                .locusCard(radius: 12)

                primaryButton("Check Again", systemImage: "arrow.clockwise") {
                    model.refreshSimulatorDevices()
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("simulator.setup")
    }

    private var availableDevices: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attach a simulator")
                        .font(LocusType.title)
                        .foregroundStyle(LocusTheme.textPrimary)
                    Text("Locus and this task will share the same device. You can tap, type, rotate, capture, and record without giving up your Mac pointer.")
                        .font(LocusType.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 6)

                ForEach(service.devices) { device in
                    deviceCard(device)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simulator.devicePicker")
    }

    private func deviceCard(_ device: SimulatorDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.isIPad ? "ipad" : "iphone")
                .font(.locus(size: 14, weight: .medium))
                .foregroundStyle(LocusTheme.textPrimary)
                .frame(width: 38, height: 38)
                .background(LocusTheme.surfaceStructural)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(LocusType.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(device.state == .booted
                            ? LocusTheme.successForeground
                            : LocusTheme.textTertiary.opacity(0.65))
                        .frame(width: 6, height: 6)
                    Text(device.subtitle)
                        .font(LocusType.caption)
                        .foregroundStyle(LocusTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            primaryButton("Attach", systemImage: nil) {
                model.attachSimulator(device)
            }
            .fixedSize()
            .accessibilityIdentifier("simulator.attach.\(device.udid)")
        }
        .padding(12)
        .locusCard(radius: 12)
    }

    private func setupStep(_ title: String, complete: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .font(.locus(size: 12, weight: .semibold))
                .foregroundStyle(complete
                    ? LocusTheme.successForeground
                    : LocusTheme.textTertiary)
            Text(title)
                .font(LocusType.caption)
                .foregroundStyle(LocusTheme.textPrimary)
            Spacer()
            Text(complete ? "Ready" : "Needed")
                .font(LocusType.badge)
                .foregroundStyle(complete
                    ? LocusTheme.successForeground
                    : LocusTheme.textTertiary)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 44)
    }

    private var setupDivider: some View {
        Rectangle()
            .fill(LocusTheme.separator)
            .frame(height: 1)
            .padding(.leading, 42)
    }

    private func simulatorEmptyState(
        symbol: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LocusTheme.textTertiary)
            Text(title)
                .font(LocusType.title)
                .foregroundStyle(LocusTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(LocusType.caption)
                .foregroundStyle(LocusTheme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 400)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func primaryButton(
        _ title: String,
        systemImage: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(LocusType.badge)
            .foregroundStyle(LocusTheme.brandInk)
            .padding(.horizontal, 13)
            .frame(minHeight: 30)
            .background(LocusTheme.accentFill)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.locus(.primary))
    }

    // MARK: - Attached workspace

    private func simulatorWorkspace(_ target: SimulatorTarget) -> some View {
        GeometryReader { proxy in
            let fallbackSize = target.device.isIPad
                ? CGSize(width: 820, height: 1_180)
                : CGSize(width: 390, height: 844)
            let imageSize = service.latestFrame?.size ?? pointSize ?? fallbackSize
            let imageRect = stageImageRect(content: imageSize, in: proxy.size)
            let screenRect = deviceRect(inside: imageRect)

            ZStack(alignment: .topLeading) {
                simulatorStageBackground
                deviceDisplay(target, imageRect: imageRect)

                if let touchIndicator {
                    Circle()
                        .fill(Color.white.opacity(0.20))
                        .overlay {
                            Circle().stroke(Color.white.opacity(0.92), lineWidth: 1.5)
                        }
                        .frame(width: 28, height: 28)
                        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                        .position(touchIndicator)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(simulatorGesture(in: screenRect))
            .overlay(alignment: .topLeading) {
                statusPill
                    .padding(12)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if showTyping {
                        typingTray
                            .transition(LocusMotion.transition(
                                edge: .bottom,
                                reduceMotion: reduceMotion
                            ))
                    }
                    controlsDock
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .animation(reduceMotion ? nil : LocusMotion.spatial, value: showTyping)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Interactive live \(target.device.name) screen")
            .accessibilityIdentifier("simulator.stage")
        }
        .frame(minHeight: 260)
    }

    private var simulatorStageBackground: some View {
        ZStack {
            LocusTheme.surfaceStructural
            Rectangle().fill(Color.black.opacity(0.025))
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func deviceDisplay(_ target: SimulatorTarget, imageRect: CGRect) -> some View {
        let radius = deviceCornerRadius(for: target, imageRect: imageRect)

        RoundedRectangle(cornerRadius: radius + 5, style: .continuous)
            .fill(Color.black)
            .frame(width: imageRect.width + 10, height: imageRect.height + 10)
            .overlay {
                RoundedRectangle(cornerRadius: radius + 5, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
            .position(x: imageRect.midX, y: imageRect.midY)

        if let frame = service.latestFrame {
            Image(nsImage: frame)
                .resizable()
                .interpolation(.high)
                .frame(width: imageRect.width, height: imageRect.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .position(x: imageRect.midX, y: imageRect.midY)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(service.previewStatus)
                    .font(LocusType.caption)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(width: imageRect.width, height: imageRect.height)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .position(x: imageRect.midX, y: imageRect.midY)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isRecording
                    ? LocusTheme.dangerForeground
                    : (service.previewIsLive
                        ? LocusTheme.successForeground
                        : LocusTheme.warningForeground))
                .frame(width: 7, height: 7)

            Text(statusText)
                .font(LocusType.badge)
                .foregroundStyle(LocusTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .locusSurface(.floating, radius: 9)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(LocusTheme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        .help(statusText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("simulator.status")
    }

    private var statusText: String {
        if !actionMessage.isEmpty { return actionMessage }
        if isRecording { return "Recording" }
        return service.previewStatus
    }

    private var controlsDock: some View {
        HStack(spacing: 2) {
            dockButton("house", help: "Home") {
                pressDeviceButton("home")
            }
            dockButton("lock", help: "Lock") {
                pressDeviceButton("lock")
            }
            dockButton("rotate.right", help: "Rotate right") {
                pressDeviceButton("rotate_right", refreshSize: true)
            }

            dockDivider

            dockButton(
                showTyping ? "keyboard.chevron.compact.down" : "keyboard",
                help: showTyping ? "Hide typing" : "Type on device",
                active: showTyping
            ) {
                showTyping.toggle()
            }
            dockButton("camera", help: "Save screenshot") { saveScreenshot() }
            dockButton(
                isRecording ? "stop.fill" : "record.circle",
                help: isRecording ? "Stop recording" : "Start recording",
                active: isRecording,
                destructive: isRecording
            ) {
                toggleRecording()
            }

            dockDivider
            hardwareMenu
        }
        .padding(5)
        .locusSurface(.floating, radius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LocusTheme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simulator.controls")
    }

    private var dockDivider: some View {
        Rectangle()
            .fill(LocusTheme.separator)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }

    private func dockButton(
        _ symbol: String,
        help: String,
        active: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(
                    destructive
                        ? LocusTheme.dangerForeground
                        : (active ? LocusTheme.accentAction : LocusTheme.textPrimary)
                )
                .frame(width: 32, height: 30)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(destructive
                                ? LocusTheme.dangerForeground.opacity(0.10)
                                : LocusTheme.accentFill.opacity(0.14))
                    }
                }
        }
        .buttonStyle(.locus(.icon))
        .help(help)
        .accessibilityLabel(help)
    }

    private var hardwareMenu: some View {
        Menu {
            Button("Volume Up", systemImage: "speaker.plus") {
                pressDeviceButton("volume_up")
            }
            Button("Volume Down", systemImage: "speaker.minus") {
                pressDeviceButton("volume_down")
            }
            Divider()
            Button("Rotate Left", systemImage: "rotate.left") {
                pressDeviceButton("rotate_left", refreshSize: true)
            }
            Button("Rotate Right", systemImage: "rotate.right") {
                pressDeviceButton("rotate_right", refreshSize: true)
            }
            Divider()
            Button("Refresh Frame", systemImage: "arrow.clockwise") { refreshFallback() }
            Button("Detach Simulator", systemImage: "rectangle.portrait.and.arrow.right") {
                model.detachSimulator()
            }
            Button("Shut Down…", systemImage: "power", role: .destructive) {
                confirmShutdown = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(LocusTheme.textPrimary)
                .frame(width: 32, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 30)
        .help("More device controls")
        .accessibilityLabel("More device controls")
    }

    private var typingTray: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.locus(size: 10, weight: .medium))
                .foregroundStyle(LocusTheme.textTertiary)

            TextField("Type into the focused field", text: $typingText)
                .textFieldStyle(.plain)
                .font(LocusType.caption)
                .focused($typingFocused)
                .onSubmit { sendTyping() }

            Button(action: sendTyping) {
                Image(systemName: "arrow.up")
                    .font(.locus(size: 9, weight: .bold))
                    .foregroundStyle(LocusTheme.brandInk)
                    .frame(width: 26, height: 26)
                    .background(LocusTheme.accentFill)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.locus(.primary))
            .disabled(typingText.isEmpty)
            .help("Send text")
            .accessibilityLabel("Send text")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(maxWidth: 440, minHeight: 38)
        .locusSurface(.floating, radius: 11)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(LocusTheme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simulator.typing")
    }

    private var streamSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Stream quality")
                    .font(LocusType.caption.weight(.semibold))
                    .foregroundStyle(LocusTheme.textPrimary)
                Text("These settings change the preview, not the simulated app.")
                    .font(LocusType.caption)
                    .foregroundStyle(LocusTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            streamSetting("Frame rate") {
                Picker("Frame rate", selection: $service.streamSettings.framesPerSecond) {
                    Text("15").tag(15)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            streamSetting("Resolution") {
                Picker("Resolution", selection: $service.streamSettings.resolutionScale) {
                    Text("50%").tag(0.5)
                    Text("75%").tag(0.75)
                    Text("100%").tag(1.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            streamSetting("Encoding") {
                Picker("Encoding", selection: $service.streamSettings.encoding) {
                    ForEach(SimulatorStreamEncoding.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
        .padding(14)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simulator.streamSettings")
    }

    private func streamSetting<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LocusType.badge)
                .foregroundStyle(LocusTheme.textSecondary)
            content()
        }
    }

    // MARK: - Geometry and input

    private func stageImageRect(content: CGSize, in available: CGSize) -> CGRect {
        let horizontalInset: CGFloat = 22
        let topInset: CGFloat = 48
        let bottomInset: CGFloat = showTyping ? 112 : 64
        let stageSize = CGSize(
            width: max(1, available.width - horizontalInset * 2),
            height: max(1, available.height - topInset - bottomInset)
        )
        return aspectFit(content: content, in: stageSize)
            .offsetBy(dx: horizontalInset, dy: topInset)
    }

    private func deviceCornerRadius(for target: SimulatorTarget, imageRect: CGRect) -> CGFloat {
        let base = target.device.isIPad ? imageRect.width * 0.035 : imageRect.width * 0.085
        return min(target.device.isIPad ? 18 : 30, max(8, base))
    }

    private func simulatorGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard rect.contains(value.location) else { return }
                if gestureStart == nil {
                    gestureStart = value.location
                    gestureStartedAt = Date()
                }
                touchIndicator = value.location
            }
            .onEnded { value in
                defer {
                    gestureStart = nil
                    gestureStartedAt = nil
                    if reduceMotion {
                        touchIndicator = nil
                    } else {
                        withAnimation(LocusMotion.press) { touchIndicator = nil }
                    }
                }
                guard let start = gestureStart,
                      let from = devicePoint(start, in: rect),
                      let to = devicePoint(value.location, in: rect) else { return }
                let distance = hypot(value.location.x - start.x, value.location.y - start.y)
                Task {
                    if distance < 8 {
                        await service.userTap(sessionID: model.currentSessionID, point: to)
                    } else {
                        let elapsed = Date().timeIntervalSince(gestureStartedAt ?? Date())
                        await service.userSwipe(
                            sessionID: model.currentSessionID,
                            from: from,
                            to: to,
                            duration: max(80, min(Int(elapsed * 1_000), 2_000))
                        )
                    }
                }
            }
    }

    private func aspectFit(content: CGSize, in available: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else {
            return CGRect(origin: .zero, size: available)
        }
        let scale = min(available.width / content.width, available.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func deviceRect(inside imageRect: CGRect) -> CGRect {
        guard let pointSize else { return imageRect }
        return aspectFit(content: pointSize, in: imageRect.size)
            .offsetBy(dx: imageRect.minX, dy: imageRect.minY)
    }

    private func devicePoint(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.contains(point), rect.width > 0, rect.height > 0, let pointSize else {
            return nil
        }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width * pointSize.width,
            y: (point.y - rect.minY) / rect.height * pointSize.height
        )
    }

    // MARK: - Actions

    private func startPreviewIfAttached() {
        guard target != nil else {
            service.stopPreview()
            pointSize = nil
            return
        }
        Task {
            await refreshPointSize()
            await service.startPreview(sessionID: model.currentSessionID)
        }
    }

    private func refreshPointSize() async {
        pointSize = try? await service.devicePointSize(sessionID: model.currentSessionID)
    }

    private func pressDeviceButton(_ button: String, refreshSize: Bool = false) {
        actionMessage = ""
        Task {
            await service.userPress(sessionID: model.currentSessionID, button: button)
            if refreshSize { await refreshPointSize() }
        }
    }

    private func refreshFallback() {
        actionMessage = "Refreshing frame…"
        Task {
            do {
                service.showFallbackFrame(
                    try await service.saveScreenshot(sessionID: model.currentSessionID)
                )
                actionMessage = "Frame refreshed"
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    private func sendTyping() {
        let text = typingText
        guard !text.isEmpty else { return }
        typingText = ""
        Task {
            await service.userType(sessionID: model.currentSessionID, text: text)
            actionMessage = "Text sent"
        }
    }

    private func saveScreenshot() {
        actionMessage = "Saving screenshot…"
        Task {
            do {
                let data = try await service.saveScreenshot(sessionID: model.currentSessionID)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "\(target?.device.name ?? "Simulator") Screenshot.png"
                guard panel.runModal() == .OK, let url = panel.url else {
                    actionMessage = ""
                    return
                }
                try data.write(to: url, options: .atomic)
                actionMessage = "Screenshot saved"
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    private func toggleRecording() {
        if isRecording {
            Task {
                do {
                    let temporary = try await service.stopRecording()
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.quickTimeMovie]
                    panel.nameFieldStringValue = "\(target?.device.name ?? "Simulator") Recording.mov"
                    if panel.runModal() == .OK, let destination = panel.url {
                        try FileManager.default.copyItem(at: temporary, to: destination)
                        try? FileManager.default.removeItem(at: temporary)
                        actionMessage = "Recording saved"
                    } else {
                        actionMessage = ""
                    }
                } catch {
                    actionMessage = error.localizedDescription
                }
            }
        } else {
            do {
                try service.startRecording(sessionID: model.currentSessionID)
                actionMessage = ""
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    private func shutDown() {
        Task {
            do {
                try await service.shutdown(sessionID: model.currentSessionID)
                model.simulatorDidDetachNatively()
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }
}
