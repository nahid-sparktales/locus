import AppKit
import SwiftUI

extension CompanionPalette {
    var color: Color {
        switch self {
        case .mint: Color(red: 0.32, green: 0.73, blue: 0.62)
        case .sky: Color(red: 0.37, green: 0.65, blue: 0.91)
        case .rose: Color(red: 0.91, green: 0.48, blue: 0.61)
        case .amber: Color(red: 0.96, green: 0.68, blue: 0.30)
        case .violet: Color(red: 0.64, green: 0.51, blue: 0.84)
        case .slate: Color(red: 0.49, green: 0.60, blue: 0.66)
        }
    }
}

/// Native miniature characters, including approved locally bundled sprite art.
/// Neither rendering path needs Agent World nor runtime artwork downloads.
/// The cancellable view task has no network/runtime access and stops on disappearance.
struct CompanionCharacterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let appearance: CompanionAppearance
    var size: CGFloat = 180
    var pose: CompanionCharacterPose = .idle
    var animationsEnabled = true
    var customImageData: Data? = nil
    @State private var visible = false
    @State private var windowVisible = false
    @State private var blinking = false
    @State private var lift: CGFloat = 0
    @State private var wave: CGFloat = 0
    @State private var pointer = CompanionPointerResponse.neutral
    @State private var finishedGreetingKey: String?

    private var canAnimate: Bool {
        visible && windowVisible && animationsEnabled && !reduceMotion && scenePhase == .active
            && pose != .paused && pose != .unavailable
    }
    private var animationKey: String { "\(canAnimate)-\(pose.rawValue)-\(appearance.assetID)" }
    private var presentationPose: CompanionCharacterPose {
        pose == .greeting && finishedGreetingKey == animationKey ? .idle : pose
    }
    private var canFollowPointer: Bool { CompanionPointerResponse.allowsReaction(canAnimate: canAnimate, pose: presentationPose) }
    private var pointerResponse: CompanionPointerResponse { canFollowPointer ? pointer : .neutral }

    var body: some View {
        let sprite = appearance.validated.bundledSprite
        let spriteAtlas = sprite.flatMap { CompanionSpriteCatalog.atlas(for: $0) }
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let atlas = spriteAtlas {
                    CompanionSpriteView(atlas: atlas, pose: presentationPose, canAnimate: canAnimate,
                        pointer: pointerResponse, onGreetingCompleted: { finishedGreetingKey = animationKey })
                        .id(appearance.assetID)
                        .scaleEffect(sprite?.presentationScale ?? 1)
                        .rotationEffect(.degrees(atlas.version == 1 ? Double(pointerResponse.x) * 2 : 0), anchor: .bottom)
                        .offset(x: atlas.version == 1 ? pointerResponse.x * size * 0.015 : 0,
                                y: atlas.version == 1 ? pointerResponse.y * size * 0.01 : 0)
                        .animation(canFollowPointer ? LocusMotion.content : nil, value: pointerResponse)
                } else if appearance.kind == .portrait, let customImageData,
                   let image = NSImage(data: customImageData) {
                    // Static artwork receives whole-image movement only. It is not a rig.
                    Image(nsImage: image).resizable().scaledToFit()
                        .padding(size * 0.06)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
                        .rotationEffect(.degrees(Double(pointerResponse.x) * 2), anchor: .bottom)
                        .offset(x: pointerResponse.x * size * 0.015,
                                y: lift * size / 200 + pointerResponse.y * size * 0.01)
                        .animation(canFollowPointer ? LocusMotion.content : nil, value: pointerResponse)
                } else {
                    CompanionCanvas(appearance: appearance.validated, blinking: blinking,
                        lift: lift, wave: wave, pointer: pointerResponse, pose: presentationPose)
                        .animation(canFollowPointer ? LocusMotion.content : nil, value: pointerResponse)
                }
            }
            .saturation(pose == .unavailable && appearance.kind != .bundledSprite ? 0.55 : 1)
            if let symbol = statusSymbol {
                Image(systemName: symbol)
                    .font(.locus(size: max(9, size * 0.11), weight: .semibold))
                    .foregroundStyle(statusColor)
                    .padding(max(3, size * 0.025))
                    .background(.background, in: Circle())
                    .overlay(Circle().stroke(statusColor.opacity(0.35), lineWidth: 1))
                    .padding(size * 0.05)
            }
        }
        .frame(width: size, height: size)
        .background(CompanionWindowVisibility { windowVisible = $0 }.frame(width: 0, height: 0))
        .background(CompanionPointerTracking(enabled: canFollowPointer) { pointer = $0 }.allowsHitTesting(false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appearance.kind == .portrait
            ? (customImageData == nil ? "Character picture unavailable; showing Robot" : "Custom character")
            : (sprite != nil && spriteAtlas == nil ? "\(appearance.displayName) artwork unavailable; showing Robot"
               : "\(appearance.validated.displayName) character"))
        .accessibilityValue(pose.label)
        .onAppear { visible = true }
        .onDisappear { visible = false; pointer = .neutral; finishedGreetingKey = nil; resetMotion() }
        .task(id: animationKey) { await animate() }
    }

    private var statusSymbol: String? {
        switch pose {
        case .idle, .greeting: nil
        case .queued: "clock"
        case .working: "ellipsis"
        case .needsApproval: "hand.raised.fill"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .paused: "pause.fill"
        case .unavailable: "bolt.slash.fill"
        }
    }
    private var statusColor: Color {
        switch pose {
        case .needsApproval, .failed: .orange
        case .completed: .green
        default: .secondary
        }
    }
    @MainActor private func resetMotion() { blinking = false; lift = 0; wave = 0 }
    @MainActor private func animate() async {
        resetMotion()
        finishedGreetingKey = nil
        guard canAnimate, appearance.kind != .bundledSprite else { return }
        do {
            if pose == .greeting || pose == .completed {
                for _ in 0..<2 {
                    withAnimation(LocusMotion.content) { wave = 1; lift = -2 }
                    try await Task.sleep(for: .milliseconds(240))
                    withAnimation(LocusMotion.content) { wave = 0; lift = 0 }
                    try await Task.sleep(for: .milliseconds(240))
                }
                if pose == .greeting { finishedGreetingKey = animationKey }
            }
            while !Task.isCancelled {
                // A slow breath is decorative; only a real working pose gets a nod.
                withAnimation(LocusMotion.companionBreath) { lift = pose == .working ? -2 : -0.8 }
                try await Task.sleep(for: .seconds(2))
                withAnimation(LocusMotion.companionBreath) { lift = 0 }
                try await Task.sleep(for: .seconds(2))
                if appearance.animationCapability == .articulated {
                    blinking = true
                    try await Task.sleep(for: .milliseconds(130))
                    blinking = false
                }
            }
        } catch { /* View task cancellation is normal lifecycle cleanup. */ }
    }
}

private struct CompanionWindowVisibility: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> CompanionVisibilityView { CompanionVisibilityView(changed: changed) }
    func updateNSView(_ view: CompanionVisibilityView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: CompanionVisibilityView, coordinator: ()) { view.detach() }
}

/// Window-level occlusion matters in a multi-window app: scenePhase may stay
/// active while this particular window is minimized, covered, or closing.
@MainActor
final class CompanionVisibilityView: NSView {
    var changed: (Bool) -> Void
    private(set) var observationCount = 0
    private var observers: [NSObjectProtocol] = []
    private var closing = false
    private var lastValue: Bool?

    init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("CompanionVisibilityView is programmatic") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        closing = false
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            observe(name, object: window)
        }
        observe(NSApplication.didHideNotification, object: NSApp)
        observe(NSApplication.didUnhideNotification, object: NSApp)
        publishVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); publishVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); publishVisibility() }

    private func observe(_ name: Notification.Name, object: AnyObject) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                if notification.name == NSWindow.willCloseNotification { self.closing = true }
                self.publishVisibility()
                if self.closing { self.detach() }
            }
        })
        observationCount = observers.count
    }
    private func publishVisibility() {
        let value = !closing && window?.occlusionState.contains(.visible) == true
            && window?.isMiniaturized == false && !NSApp.isHidden && !isHiddenOrHasHiddenAncestor
        publish(value)
    }
    private func publish(_ value: Bool) {
        guard lastValue != value else { return }
        lastValue = value
        // AppKit can call viewDidMoveToWindow during a SwiftUI update.
        // Deliver on the next turn without retaining a detached renderer.
        DispatchQueue.main.async { [weak self] in self?.changed(value) }
    }
    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        observationCount = 0
        publish(false)
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

private struct CompanionCanvas: View, Animatable {
    let appearance: CompanionAppearance
    let blinking: Bool
    var lift: CGFloat
    var wave: CGFloat
    var pointer: CompanionPointerResponse
    let pose: CompanionCharacterPose
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(lift, wave), AnimatablePair(pointer.x, pointer.y)) }
        set {
            lift = newValue.first.first; wave = newValue.first.second
            pointer = .init(x: newValue.second.first, y: newValue.second.second)
        }
    }
    var body: some View {
        Canvas { context, size in
            var painter = CompanionPainter(context: context, appearance: appearance,
                blinking: blinking, lift: lift, wave: wave, pointer: pointer, pose: pose)
            painter.draw(size: size)
        }
    }
}

private struct CompanionPainter {
    var context: GraphicsContext
    let appearance: CompanionAppearance
    let blinking: Bool
    let lift: CGFloat
    let wave: CGFloat
    let pointer: CompanionPointerResponse
    let pose: CompanionCharacterPose
    private let ink = Color(red: 0.13, green: 0.20, blue: 0.25)
    private let cream = Color(red: 1, green: 0.94, blue: 0.82)
    private var tint: Color { appearance.palette.color }

    mutating func draw(size: CGSize) {
        context.scaleBy(x: size.width / 200, y: size.height / 200)
        var shadow = context
        shadow.addFilter(.blur(radius: 4))
        shadow.fill(Path(ellipseIn: CGRect(x: 54, y: 180, width: 96, height: 10)), with: .color(.black.opacity(0.14)))
        context.translateBy(x: 0, y: lift)
        switch appearance.builtIn ?? .robot {
        case .robot: robot()
        case .spark: spark()
        case .cat: cat()
        case .fox: fox()
        case .frog: frog()
        case .explorer: explorer()
        }
        if appearance.accessory == .scarf { scarf() }
    }

    private func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                      _ color: Color, shaded: Bool = true) {
        fill(Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)), color, shaded: shaded)
    }
    private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                         _ radius: CGFloat, _ color: Color, shaded: Bool = true) {
        fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius), color, shaded: shaded)
    }
    private func fill(_ path: Path, _ color: Color, shaded: Bool = true) {
        let bounds = path.boundingRect
        var layer = context
        if shaded {
            layer.addFilter(.shadow(color: .black.opacity(0.13), radius: 2.5, x: 0, y: 2))
            layer.fill(path, with: .linearGradient(Gradient(colors: [color.blended(with: .white, by: 0.32), color, color.blended(with: .black, by: 0.16)]),
                startPoint: CGPoint(x: bounds.minX, y: bounds.minY), endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)))
            layer.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 0.7)
        } else { layer.fill(path, with: .color(color)) }
    }
    private func line(_ points: [CGPoint], _ color: Color, width: CGFloat) {
        guard let first = points.first else { return }
        var path = Path(); path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    private func face(x: CGFloat = 100, y: CGFloat = 95, spread: CGFloat = 20, bright: Bool = false, mouth: Bool = true) {
        let eyeColor = bright ? cream : ink
        let eyeX = x + pointer.x * 2.5
        let eyeY = y + pointer.y * 2
        if blinking {
            line([.init(x: eyeX-spread-3, y: eyeY), .init(x: eyeX-spread+3, y: eyeY)], eyeColor, width: 2.4)
            line([.init(x: eyeX+spread-3, y: eyeY), .init(x: eyeX+spread+3, y: eyeY)], eyeColor, width: 2.4)
        } else {
            oval(eyeX-spread-3, eyeY-5, 6, 10, eyeColor, shaded: false)
            oval(eyeX+spread-3, eyeY-5, 6, 10, eyeColor, shaded: false)
            if !bright {
                oval(eyeX-spread-1.5, eyeY-4, 2, 3, .white, shaded: false)
                oval(eyeX+spread-1.5, eyeY-4, 2, 3, .white, shaded: false)
            }
        }
        if mouth {
            var smile = Path(); smile.move(to: .init(x: x-5, y: y+13))
            smile.addQuadCurve(to: .init(x: x+5, y: y+13), control: .init(x: x, y: y+18))
            context.stroke(smile, with: .color(eyeColor.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        if !bright {
            oval(x-spread-10, y+7, 11, 5, .pink.opacity(0.26), shaded: false)
            oval(x+spread, y+7, 11, 5, .pink.opacity(0.26), shaded: false)
        }
        if appearance.accessory == .glasses {
            for eyeX in [x-spread, x+spread] {
                context.stroke(Path(ellipseIn: .init(x: eyeX-11, y: y-12, width: 22, height: 24)),
                    with: .color(ink.opacity(0.85)), lineWidth: 2.5)
            }
            line([.init(x: x-spread+11, y: y-1), .init(x: x+spread-11, y: y-1)], ink, width: 2)
        }
    }
    private func arms(y: CGFloat = 128, color: Color? = nil) {
        let color = color ?? tint
        rounded(43, y, 18, 35, 9, color)
        // Only built-in vector limbs articulate during a greeting/completion.
        var arm = context
        arm.translateBy(x: 147, y: y+6)
        arm.rotate(by: .degrees(-Double(wave) * 100))
        arm.fill(Path(roundedRect: CGRect(x: -8, y: -3, width: 17, height: 36), cornerRadius: 9),
            with: .linearGradient(Gradient(colors: [color.blended(with: .white, by: 0.3), color]),
                startPoint: .init(x: -8, y: 0), endPoint: .init(x: 8, y: 33)))
    }
    private func robot() {
        rounded(72, 162, 23, 20, 8, tint.blended(with: .black, by: 0.1))
        rounded(105, 162, 23, 20, 8, tint.blended(with: .black, by: 0.1))
        arms()
        rounded(58, 106, 84, 67, 25, tint)
        rounded(75, 133, 50, 24, 8, cream)
        oval(94, 140, 12, 9, tint, shaded: false)
        line([.init(x: 100, y: 52), .init(x: 100, y: 34)], tint.blended(with: .black, by: 0.2), width: 5)
        oval(94, 26, 12, 12, cream)
        rounded(44, 70, 12, 27, 6, tint)
        rounded(144, 70, 12, 27, 6, tint)
        rounded(49, 47, 102, 78, 27, tint)
        rounded(61, 64, 78, 46, 17, ink)
        face(y: 83, spread: 19, bright: true)
        rounded(62, 54, 46, 4, 2, .white.opacity(0.38), shaded: false)
    }
    private func spark() {
        oval(76, 165, 19, 17, tint)
        oval(108, 165, 19, 17, tint)
        arms(y: 122)
        var shape = Path()
        shape.move(to: .init(x: 105, y: 26))
        shape.addCurve(to: .init(x: 146, y: 71), control1: .init(x: 95, y: 57), control2: .init(x: 144, y: 42))
        shape.addQuadCurve(to: .init(x: 158, y: 107), control: .init(x: 139, y: 88))
        shape.addCurve(to: .init(x: 99, y: 173), control1: .init(x: 177, y: 145), control2: .init(x: 142, y: 173))
        shape.addCurve(to: .init(x: 46, y: 104), control1: .init(x: 51, y: 173), control2: .init(x: 31, y: 139))
        shape.addQuadCurve(to: .init(x: 59, y: 68), control: .init(x: 60, y: 83))
        shape.addQuadCurve(to: .init(x: 78, y: 79), control: .init(x: 69, y: 81))
        shape.addQuadCurve(to: .init(x: 105, y: 26), control: .init(x: 69, y: 47))
        fill(shape, tint)
        oval(64, 102, 71, 58, cream.opacity(0.72), shaded: false)
        face(y: 119, spread: 19)
        oval(64, 88, 13, 7, .white.opacity(0.28), shaded: false)
    }
    private func cat() {
        var tail = Path(); tail.move(to: .init(x: 133, y: 159))
        tail.addCurve(to: .init(x: 162, y: 101), control1: .init(x: 174, y: 162), control2: .init(x: 175, y: 109))
        context.stroke(tail, with: .color(tint.blended(with: .black, by: 0.12)), style: StrokeStyle(lineWidth: 17, lineCap: .round))
        oval(63, 105, 74, 74, tint)
        oval(80, 121, 42, 51, cream)
        oval(62, 162, 31, 20, tint); oval(107, 162, 31, 20, tint)
        arms(y: 127)
        var ears = Path()
        ears.move(to: .init(x: 46, y: 84)); ears.addLine(to: .init(x: 46, y: 36))
        ears.addQuadCurve(to: .init(x: 83, y: 65), control: .init(x: 69, y: 40)); ears.closeSubpath()
        ears.move(to: .init(x: 117, y: 65)); ears.addQuadCurve(to: .init(x: 154, y: 36), control: .init(x: 131, y: 40))
        ears.addLine(to: .init(x: 154, y: 84)); ears.closeSubpath()
        fill(ears, tint)
        line([.init(x: 54, y: 51), .init(x: 57, y: 76)], .pink.opacity(0.55), width: 10)
        line([.init(x: 146, y: 51), .init(x: 143, y: 76)], .pink.opacity(0.55), width: 10)
        rounded(44, 58, 112, 72, 33, tint)
        oval(76, 96, 48, 27, cream, shaded: false)
        face(y: 91, spread: 23)
        oval(97, 103, 6, 4, ink, shaded: false)
        for direction: CGFloat in [-1, 1] {
            line([.init(x: 100+direction*33, y: 103), .init(x: 100+direction*48, y: 99)], ink.opacity(0.35), width: 1.4)
            line([.init(x: 100+direction*33, y: 109), .init(x: 100+direction*48, y: 111)], ink.opacity(0.35), width: 1.4)
        }
    }
    private func fox() {
        var tail = Path(); tail.move(to: .init(x: 128, y: 171))
        tail.addCurve(to: .init(x: 177, y: 89), control1: .init(x: 183, y: 181), control2: .init(x: 191, y: 126))
        tail.addCurve(to: .init(x: 130, y: 141), control1: .init(x: 169, y: 121), control2: .init(x: 137, y: 109)); tail.closeSubpath()
        fill(tail, tint)
        var tip = Path(); tip.move(to: .init(x: 177, y: 89)); tip.addQuadCurve(to: .init(x: 179, y: 137), control: .init(x: 187, y: 119))
        tip.addLine(to: .init(x: 156, y: 127)); tip.addQuadCurve(to: .init(x: 177, y: 89), control: .init(x: 174, y: 109)); fill(tip, cream)
        oval(62, 104, 77, 73, tint)
        oval(80, 120, 39, 51, cream)
        rounded(68, 159, 24, 23, 9, ink); rounded(106, 159, 24, 23, 9, ink)
        arms(y: 124)
        var head = Path(); head.move(to: .init(x: 45, y: 41))
        head.addLine(to: .init(x: 83, y: 64)); head.addQuadCurve(to: .init(x: 116, y: 64), control: .init(x: 100, y: 58))
        head.addLine(to: .init(x: 155, y: 41)); head.addLine(to: .init(x: 149, y: 91))
        head.addQuadCurve(to: .init(x: 100, y: 136), control: .init(x: 143, y: 121))
        head.addQuadCurve(to: .init(x: 51, y: 91), control: .init(x: 56, y: 121)); head.closeSubpath(); fill(head, tint)
        var muzzle = Path(); muzzle.move(to: .init(x: 54, y: 95))
        muzzle.addQuadCurve(to: .init(x: 100, y: 112), control: .init(x: 76, y: 90))
        muzzle.addQuadCurve(to: .init(x: 146, y: 95), control: .init(x: 123, y: 90))
        muzzle.addQuadCurve(to: .init(x: 100, y: 133), control: .init(x: 130, y: 125))
        muzzle.addQuadCurve(to: .init(x: 54, y: 95), control: .init(x: 67, y: 125)); fill(muzzle, cream)
        face(y: 90, spread: 23)
        oval(95, 108, 10, 7, ink, shaded: false)
    }
    private func frog() {
        oval(45, 164, 48, 19, tint); oval(107, 164, 48, 19, tint)
        oval(57, 106, 86, 71, tint)
        oval(77, 122, 47, 48, cream)
        arms(y: 126)
        oval(42, 64, 116, 73, tint)
        oval(54, 45, 39, 41, tint); oval(107, 45, 39, 41, tint)
        oval(63, 52, 23, 28, cream); oval(114, 52, 23, 28, cream)
        face(y: 67, spread: 25, mouth: false)
        var mouth = Path(); mouth.move(to: .init(x: 81, y: 105))
        mouth.addQuadCurve(to: .init(x: 119, y: 105), control: .init(x: 100, y: 119))
        context.stroke(mouth, with: .color(ink.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        oval(58, 99, 15, 7, .pink.opacity(0.3), shaded: false)
        oval(126, 99, 15, 7, .pink.opacity(0.3), shaded: false)
    }
    private func explorer() {
        rounded(48, 113, 27, 51, 12, cream)
        rounded(71, 160, 23, 22, 8, ink); rounded(107, 160, 23, 22, 8, ink)
        arms(y: 128)
        rounded(62, 110, 77, 63, 23, tint)
        rounded(61, 148, 78, 11, 5, ink.blended(with: cream, by: 0.2))
        rounded(94, 148, 13, 11, 3, cream)
        rounded(58, 57, 84, 73, 30, cream)
        oval(47, 82, 18, 25, cream); oval(135, 82, 18, 25, cream)
        face(y: 92, spread: 21)
        rounded(52, 41, 96, 48, 25, tint)
        oval(38, 71, 124, 22, tint)
        rounded(55, 65, 91, 10, 5, tint.blended(with: .black, by: 0.18))
        oval(95, 54, 11, 11, cream)
    }
    private func scarf() {
        let y: CGFloat = appearance.builtIn == .spark ? 151 : 121
        rounded(78, y, 44, 10, 5, cream)
        var end = Path(); end.move(to: .init(x: 111, y: y+5))
        end.addLine(to: .init(x: 130, y: y+29)); end.addLine(to: .init(x: 116, y: y+31))
        end.addLine(to: .init(x: 103, y: y+8)); end.closeSubpath(); fill(end, cream)
        line([.init(x: 115, y: y+22), .init(x: 123, y: y+22)], tint.opacity(0.45), width: 2)
    }
}

private extension Color {
    /// NSColor conversion keeps the renderer compatible with the macOS 14 target.
    func blended(with other: Color, by amount: CGFloat) -> Color {
        let start = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let end = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        return Color(nsColor: NSColor(srgbRed: start.redComponent * (1-amount) + end.redComponent * amount,
            green: start.greenComponent * (1-amount) + end.greenComponent * amount,
            blue: start.blueComponent * (1-amount) + end.blueComponent * amount,
            alpha: start.alphaComponent * (1-amount) + end.alphaComponent * amount))
    }
}
