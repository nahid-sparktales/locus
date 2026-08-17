import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A capture waiting to be annotated. The decoded CGImage is the pixel ground
/// truth every annotation coordinate refers to.
struct BrowserScreenshotDraft: Identifiable {
    let id = UUID()
    let image: CGImage
    let pageTitle: String
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case crop
    case pen
    case rectangle
    case arrow
    case text

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .crop: "crop"
        case .pen: "pencil.line"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .crop: "Crop"
        case .pen: "Pen"
        case .rectangle: "Box"
        case .arrow: "Arrow"
        case .text: "Text"
        }
    }
}

/// The annotate-and-attach sheet. All geometry lives in image pixels; the
/// canvas maps view points through one `fitScale` division, and the same
/// `AnnotationGeometry` paths draw the live preview and the flattened export,
/// so preview equals output by construction.
struct BrowserScreenshotSheet: View {
    let draft: BrowserScreenshotDraft
    /// Returns whether the attachment was accepted — a full composer refuses,
    /// and the sheet must keep the user's annotation work alive when it does.
    let onAttach: (Data) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var attachRefused = false

    @State private var shapes: [AnnotationShape] = []
    @State private var crop: CGRect?
    @State private var tool: AnnotationTool = .pen
    @State private var color: AnnotationColor = .red
    @State private var dragStart: CGPoint?
    @State private var inProgress: AnnotationShape?
    @State private var cropDraft: CGRect?
    @State private var labelOrigin: CGPoint?
    @State private var labelText = ""
    @FocusState private var labelFocused: Bool

    private var imageSize: CGSize {
        CGSize(width: draft.image.width, height: draft.image.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LocusTheme.line)
            toolStrip
            canvasArea
            Divider().overlay(LocusTheme.line)
            footer
        }
        .frame(width: 900, height: 640)
        .background(LocusTheme.panel)
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Annotate screenshot")
                    .font(.locus(size: 15, weight: .bold))
                Text(draft.pageTitle.isEmpty ? "Captured page" : draft.pageTitle)
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.locus())
            .accessibilityLabel("Close annotation")
            .accessibilityIdentifier("browser.annotate.close")
        }
        .padding(14)
    }

    private var toolStrip: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $tool) {
                ForEach(AnnotationTool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .accessibilityIdentifier("browser.annotate.tool")

            HStack(spacing: 5) {
                ForEach(AnnotationColor.allCases) { swatch in
                    Button {
                        color = swatch
                    } label: {
                        Circle()
                            .fill(Color(nsColor: swatch.nsColor))
                            .frame(width: 14, height: 14)
                            .overlay {
                                if swatch == color {
                                    Circle().stroke(LocusTheme.ink, lineWidth: 2)
                                        .padding(-2)
                                }
                            }
                    }
                    .buttonStyle(.locus())
                    .accessibilityLabel("\(swatch.rawValue) color")
                    .accessibilityIdentifier("browser.annotate.color.\(swatch.rawValue)")
                }
            }

            Spacer()

            if crop != nil {
                Button("Reset Crop") { crop = nil }
                    .font(.locus(size: 9, weight: .semibold))
                    .accessibilityIdentifier("browser.annotate.resetCrop")
            }
            Button {
                if !shapes.isEmpty { shapes.removeLast() }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.locus(size: 9, weight: .semibold))
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(shapes.isEmpty)
            .accessibilityIdentifier("browser.annotate.undo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var canvasArea: some View {
        GeometryReader { geometry in
            let fitScale = min(
                geometry.size.width / imageSize.width,
                geometry.size.height / imageSize.height,
                1.5
            )
            let displaySize = CGSize(
                width: imageSize.width * fitScale,
                height: imageSize.height * fitScale
            )
            ZStack {
                Image(decorative: draft.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay {
                        annotationCanvas(fitScale: fitScale)
                    }
                    .overlay {
                        if let origin = labelOrigin {
                            labelEditor(origin: origin, fitScale: fitScale)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .gesture(drawGesture(fitScale: fitScale))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .background(LocusTheme.paperDeep.opacity(0.5))
        .accessibilityIdentifier("browser.annotate.canvas")
    }

    private func annotationCanvas(fitScale: CGFloat) -> some View {
        Canvas { context, _ in
            context.scaleBy(x: fitScale, y: fitScale)
            let strokeWidth = AnnotationGeometry.strokeWidth(forImageWidth: imageSize.width)
            let headLength = strokeWidth * 4
            let fontSize = AnnotationGeometry.labelFontSize(forImageWidth: imageSize.width)
            for shape in shapes + (inProgress.map { [$0] } ?? []) {
                let swatch = AnnotationGeometry.color(of: shape)
                if case .label(let text, let origin, _) = shape {
                    context.draw(
                        Text(text)
                            .font(.locus(size: fontSize, weight: .semibold))
                            .foregroundColor(Color(nsColor: swatch.nsColor)),
                        at: origin,
                        anchor: .topLeading
                    )
                    continue
                }
                context.stroke(
                    Path(AnnotationGeometry.path(for: shape, headLength: headLength)),
                    with: .color(Color(nsColor: swatch.nsColor)),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )
            }
            // The crop renders as a bright border with everything outside
            // dimmed — the classic marquee.
            if let active = cropDraft ?? crop {
                let outside = Path { path in
                    path.addRect(CGRect(origin: .zero, size: imageSize))
                    path.addRect(active)
                }
                context.fill(outside, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
                context.stroke(
                    Path(active),
                    with: .color(.white),
                    lineWidth: max(2, strokeWidth / 2)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func labelEditor(origin: CGPoint, fitScale: CGFloat) -> some View {
        TextField("Label", text: $labelText)
            .textFieldStyle(.roundedBorder)
            .font(.locus(size: 12, weight: .semibold))
            .frame(width: 220)
            .focused($labelFocused)
            .onSubmit {
                let text = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    shapes.append(.label(text: text, origin: origin, color: color))
                }
                labelOrigin = nil
                labelText = ""
            }
            .onExitCommand {
                labelOrigin = nil
                labelText = ""
            }
            .position(
                x: min(origin.x * fitScale + 110, imageSize.width * fitScale - 110),
                y: max(origin.y * fitScale - 18, 14)
            )
            .accessibilityIdentifier("browser.annotate.labelInput")
    }

    private func drawGesture(fitScale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = CGPoint(
                    x: (value.location.x / fitScale).clamped(to: 0...imageSize.width),
                    y: (value.location.y / fitScale).clamped(to: 0...imageSize.height)
                )
                if dragStart == nil { dragStart = point }
                guard let start = dragStart else { return }
                switch tool {
                case .pen:
                    if case .pen(var points, let color) = inProgress {
                        points.append(point)
                        inProgress = .pen(points: points, color: color)
                    } else {
                        inProgress = .pen(points: [point], color: color)
                    }
                case .rectangle:
                    inProgress = .rectangle(
                        AnnotationGeometry.normalizedRect(from: start, to: point),
                        color: color
                    )
                case .arrow:
                    inProgress = .arrow(start: start, end: point, color: color)
                case .crop:
                    cropDraft = AnnotationGeometry.normalizedRect(from: start, to: point)
                case .text:
                    break
                }
            }
            .onEnded { value in
                defer {
                    dragStart = nil
                    inProgress = nil
                    cropDraft = nil
                }
                guard let start = dragStart else { return }
                let end = CGPoint(
                    x: (value.location.x / fitScale).clamped(to: 0...imageSize.width),
                    y: (value.location.y / fitScale).clamped(to: 0...imageSize.height)
                )
                // Click-vs-drag slop is a screen-feel constant, so it is
                // measured in VIEW points. Dividing first would scale the
                // tolerance by 1/fitScale — on a Retina desktop capture that
                // shrank the Text tool's click window to ~1 point and made it
                // feel dead.
                let travel = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                )
                switch tool {
                case .text:
                    guard travel < 4 else { return }
                    labelOrigin = start
                    labelText = ""
                    labelFocused = true
                case .pen, .rectangle, .arrow:
                    if let shape = inProgress, travel >= 2 {
                        shapes.append(shape)
                    }
                case .crop:
                    crop = AnnotationGeometry.clampCrop(
                        AnnotationGeometry.normalizedRect(from: start, to: end),
                        in: imageSize
                    )
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Cancel") { dismiss() }
                .accessibilityIdentifier("browser.annotate.cancel")
            if attachRefused {
                Text("The composer could not take it — remove an attachment or crop smaller.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.warning)
                    .accessibilityIdentifier("browser.annotate.refused")
            }
            Spacer()
            Button("Copy") {
                if let data = flattened() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(data, forType: .png)
                }
            }
            .accessibilityIdentifier("browser.annotate.copy")
            Button("Save PNG…") { savePNG() }
                .accessibilityIdentifier("browser.annotate.save")
            Button("Attach to Chat") {
                guard let data = flattened() else { return }
                if onAttach(data) {
                    dismiss()
                } else {
                    // The annotation survives; Copy and Save stay available.
                    attachRefused = true
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(LocusTheme.ink)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("browser.annotate.attach")
        }
        .padding(14)
    }

    private func flattened() -> Data? {
        AnnotationFlattener.flatten(base: draft.image, shapes: shapes, crop: crop)
    }

    private func savePNG() {
        guard let data = flattened() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = Date().formatted(
            Date.FormatStyle()
                .year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        )
        panel.nameFieldStringValue = "Browser screenshot \(stamp).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
