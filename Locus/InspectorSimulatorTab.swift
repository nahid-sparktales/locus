import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A task-scoped Simulator surface. Pointer gestures are mapped to device
/// points and injected through the bridge, so the Mac pointer never moves.
struct InspectorSimulatorTab: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var service: SimulatorControlService
    @State private var pointSize: CGSize?
    @State private var gestureStart: CGPoint?
    @State private var gestureStartedAt: Date?
    @State private var touchIndicator: CGPoint?
    @State private var typingText = ""
    @State private var actionMessage = ""
    @State private var confirmShutdown = false

    init(service: SimulatorControlService? = nil) {
        _service = ObservedObject(wrappedValue: service ?? SimulatorControlService())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let target { simulatorSurface(target) } else { devicePicker }
        }
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
        .onChange(of: target?.udid) { _, _ in startPreviewIfAttached() }
        .onChange(of: service.streamSettings) { _, _ in
            guard target != nil else { return }
            Task { await service.restartPreview(sessionID: model.currentSessionID) }
        }
        .onDisappear { service.stopPreview() }
    }

    private var target: SimulatorTarget? { service.target(for: model.currentSessionID) }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(service.devices) { device in
                    Button {
                        model.attachSimulator(device)
                    } label: {
                        Label(
                            "\(device.name) — \(device.state.rawValue)",
                            systemImage: device.isIPad ? "ipad" : "iphone"
                        )
                    }
                }
                Divider()
                Button("Refresh Devices") { model.refreshSimulatorDevices() }
            } label: {
                Label(
                    target?.device.name ?? "iOS Simulator",
                    systemImage: target?.device.isIPad == true ? "ipad" : "iphone"
                )
                .font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if let target {
                Text("\(target.device.runtime) · \(target.device.state.rawValue)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if target != nil {
                Button("Detach") { model.detachSimulator() }
            } else {
                Button("Refresh") { model.refreshSimulatorDevices() }
                    .disabled(service.isRefreshing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
    }

    private var devicePicker: some View {
        Group {
            if !SimulatorControlService.isSupportedBuild {
                ContentUnavailableView(
                    "Simulator Control Unavailable",
                    systemImage: "iphone.slash",
                    description: Text("Available in the direct-download build.")
                )
            } else if service.isRefreshing {
                ProgressView("Finding iPhone and iPad simulators…")
            } else if service.devices.isEmpty {
                ContentUnavailableView(
                    "No Simulators Found",
                    systemImage: "ipad.and.iphone",
                    description: Text(service.helperHealth.message)
                )
            } else {
                List(service.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.isIPad ? "ipad" : "iphone").frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).fontWeight(.medium)
                            Text(device.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Attach") { model.attachSimulator(device) }
                    }
                }
            }
        }
    }

    private func simulatorSurface(_ target: SimulatorTarget) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let imageSize = service.latestFrame?.size ?? pointSize ?? proxy.size
                let imageRect = aspectFit(content: imageSize, in: proxy.size)
                let screenRect = deviceRect(inside: imageRect)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.95)
                    if let frame = service.latestFrame {
                        Image(nsImage: frame)
                            .resizable().interpolation(.high)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                    } else {
                        ProgressView(service.previewStatus)
                            .tint(.white).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let touchIndicator {
                        Circle()
                            .fill(.white.opacity(0.25))
                            .stroke(.white.opacity(0.9), lineWidth: 1.5)
                            .frame(width: 28, height: 28)
                            .position(touchIndicator)
                    }
                }
                .contentShape(Rectangle())
                .gesture(simulatorGesture(in: screenRect))
                .accessibilityLabel("Interactive live \(target.device.name) screen")
            }
            .frame(minHeight: 240)
            statusBar
            inputBar
            deviceControls
        }
    }

    private var statusBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { liveStatus; Spacer(); streamControls }
            VStack(alignment: .leading, spacing: 7) { liveStatus; streamControls }
        }
        .padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
    }

    private var liveStatus: some View {
        HStack(spacing: 6) {
            Circle().fill(service.previewIsLive ? LocusTheme.success : Color.orange)
                .frame(width: 7, height: 7)
            Text(service.previewStatus).font(.caption).foregroundStyle(.secondary)
            if !service.previewIsLive, target != nil {
                Button("Refresh Screenshot") { refreshFallback() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private var streamControls: some View {
        HStack(spacing: 8) {
            Picker("Frame rate", selection: $service.streamSettings.framesPerSecond) {
                Text("15 fps").tag(15); Text("30 fps").tag(30); Text("60 fps").tag(60)
            }
            Picker("Resolution", selection: $service.streamSettings.resolutionScale) {
                Text("50%").tag(0.5); Text("75%").tag(0.75); Text("100%").tag(1.0)
            }
            Picker("Encoding", selection: $service.streamSettings.encoding) {
                ForEach(SimulatorStreamEncoding.allCases) { Text($0.title).tag($0) }
            }
        }
        .labelsHidden().controlSize(.small).fixedSize()
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Type into the focused simulator field", text: $typingText)
                .textFieldStyle(.roundedBorder).onSubmit { sendTyping() }
            Button("Send") { sendTyping() }.disabled(typingText.isEmpty)
            if !actionMessage.isEmpty {
                Text(actionMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10).background(.background)
    }

    private var deviceControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                control("Home", "house", "home")
                control("Lock", "lock", "lock")
                control("Volume Up", "speaker.plus", "volume_up")
                control("Volume Down", "speaker.minus", "volume_down")
                control("Rotate Left", "rotate.left", "rotate_left")
                control("Rotate Right", "rotate.right", "rotate_right")
                Divider().frame(height: 20)
                Button { saveScreenshot() } label: { Label("Screenshot", systemImage: "camera") }
                Button { toggleRecording() } label: {
                    Label(
                        service.recordingSessionID == model.currentSessionID
                            ? "Stop Recording" : "Record",
                        systemImage: service.recordingSessionID == model.currentSessionID
                            ? "stop.circle.fill" : "record.circle"
                    )
                }
                Button(role: .destructive) { confirmShutdown = true } label: {
                    Label("Shut Down", systemImage: "power")
                }
            }
            .buttonStyle(.bordered).controlSize(.small).padding(10)
        }
        .background(.bar)
    }

    private func control(_ title: String, _ symbol: String, _ button: String) -> some View {
        Button {
            Task {
                await service.userPress(sessionID: model.currentSessionID, button: button)
                if button.hasPrefix("rotate_") { await refreshPointSize() }
            }
        } label: { Label(title, systemImage: symbol) }
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
                    gestureStart = nil; gestureStartedAt = nil
                    if reduceMotion { touchIndicator = nil }
                    else { withAnimation(.easeOut(duration: 0.15)) { touchIndicator = nil } }
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
                            sessionID: model.currentSessionID, from: from, to: to,
                            duration: max(80, min(Int(elapsed * 1_000), 2_000))
                        )
                    }
                }
            }
    }

    private func aspectFit(content: CGSize, in available: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: available) }
        let scale = min(available.width / content.width, available.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (available.width - size.width) / 2,
            y: (available.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    private func deviceRect(inside imageRect: CGRect) -> CGRect {
        guard let pointSize else { return imageRect }
        return aspectFit(content: pointSize, in: imageRect.size)
            .offsetBy(dx: imageRect.minX, dy: imageRect.minY)
    }

    private func devicePoint(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.contains(point), rect.width > 0, rect.height > 0, let pointSize else { return nil }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width * pointSize.width,
            y: (point.y - rect.minY) / rect.height * pointSize.height
        )
    }

    private func startPreviewIfAttached() {
        guard target != nil else { service.stopPreview(); pointSize = nil; return }
        Task { await refreshPointSize(); await service.startPreview(sessionID: model.currentSessionID) }
    }

    private func refreshPointSize() async {
        pointSize = try? await service.devicePointSize(sessionID: model.currentSessionID)
    }

    private func refreshFallback() {
        Task {
            do { service.showFallbackFrame(try await service.saveScreenshot(sessionID: model.currentSessionID)) }
            catch { actionMessage = error.localizedDescription }
        }
    }

    private func sendTyping() {
        let text = typingText
        guard !text.isEmpty else { return }
        typingText = ""
        Task { await service.userType(sessionID: model.currentSessionID, text: text) }
    }

    private func saveScreenshot() {
        Task {
            do {
                let data = try await service.saveScreenshot(sessionID: model.currentSessionID)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "\(target?.device.name ?? "Simulator") Screenshot.png"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                actionMessage = "Screenshot saved"
            } catch { actionMessage = error.localizedDescription }
        }
    }

    private func toggleRecording() {
        if service.recordingSessionID == model.currentSessionID {
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
                    }
                } catch { actionMessage = error.localizedDescription }
            }
        } else {
            do { try service.startRecording(sessionID: model.currentSessionID); actionMessage = "Recording…" }
            catch { actionMessage = error.localizedDescription }
        }
    }

    private func shutDown() {
        Task {
            do {
                try await service.shutdown(sessionID: model.currentSessionID)
                model.simulatorDidDetachNatively()
            } catch { actionMessage = error.localizedDescription }
        }
    }
}
