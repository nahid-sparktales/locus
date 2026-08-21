import AppKit
import WebKit

/// Real input for the agent's browser.
///
/// The JavaScript bridge dispatches `MouseEvent`s and `KeyboardEvent`s it
/// builds itself. Those carry `isTrusted === false` and no user activation, so
/// a page is free to ignore them — and many do: drag surfaces that check the
/// flag, controls that only respond inside a user gesture, and anything drawn
/// into a `<canvas>`, which has no element to mint a ref for in the first
/// place.
///
/// These are `NSEvent`s handed to the web view the same way AppKit hands it the
/// user's. WebKit converts them in the web process, so the page sees trusted
/// input with a real user gesture, hit-tested by WebKit rather than by us.
///
/// Coordinates everywhere here are **page CSS pixels, viewport-relative** — the
/// same frame `getBoundingClientRect` reports to the bridge and the same frame
/// a screenshot is captured in, so a coordinate read off a picture can be
/// passed straight back in.
enum BrowserInput {
    /// Which physical button a click carries.
    enum MouseButton {
        case left
        case right
    }

    /// Delay between the halves of a click and between drag steps. WebKit
    /// hands events to the web process asynchronously; without a gap, a
    /// mouse-up can be coalesced ahead of the mouse-down's hit test and the
    /// page sees a click it never got a press for.
    static let stepDelay = Duration.milliseconds(16)

    /// Modifier vocabulary shared with the bridge path, so `modifiers:
    /// ["cmd"]` means the same thing whichever route an action takes.
    static func modifiers(from raw: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in raw.map({ $0.lowercased() }) {
            switch name {
            case "alt", "option": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            case "cmd", "command", "meta": flags.insert(.command)
            case "shift": flags.insert(.shift)
            default: continue
            }
        }
        return flags
    }
}

// MARK: - Keys

extension BrowserInput {
    /// One keystroke, resolved from the DOM key name the tool schema advertises
    /// to what AppKit needs: a virtual key code and the characters the key
    /// produces. Both matter — WebKit derives `event.code` from the key code and
    /// `event.key` from the characters, and text insertion needs the characters
    /// to be right.
    struct Key {
        let keyCode: UInt16
        let characters: String
        let charactersIgnoringModifiers: String
        /// Set when the character itself requires shift, so "A" arrives as
        /// shift+a rather than as a bare key that claims to be uppercase.
        let impliedModifiers: NSEvent.ModifierFlags

        init(
            keyCode: UInt16,
            characters: String,
            charactersIgnoringModifiers: String? = nil,
            impliedModifiers: NSEvent.ModifierFlags = []
        ) {
            self.keyCode = keyCode
            self.characters = characters
            self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
            self.impliedModifiers = impliedModifiers
        }

        /// Resolve a DOM key name (`Enter`, `ArrowDown`, `a`) or a single
        /// character. Returns nil for a name with no macOS equivalent, which
        /// the caller reports rather than silently pressing something else.
        init?(name raw: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            if let named = Self.named[name.lowercased()] {
                self = named
                return
            }
            // A single character is the common case: the model asks for "a" or
            // "/" and means the key that types it.
            guard name.count == 1, let character = name.first else { return nil }
            self.init(character: character)
        }

        /// The key that types one character.
        init(character: Character) {
            let text = String(character)
            let lowered = String(character).lowercased()
            let keyCode = Self.asciiKeyCodes[lowered.first ?? character] ?? 0
            let needsShift = String(character) != lowered
                && lowered.rangeOfCharacter(from: .letters) != nil
            self.init(
                keyCode: keyCode,
                characters: text,
                charactersIgnoringModifiers: needsShift ? lowered : text,
                impliedModifiers: needsShift ? .shift : []
            )
        }

        /// Named keys, keyed by lowercased DOM name. Aliases are deliberate:
        /// models write both `Enter` and `Return`, both `Esc` and `Escape`.
        private static let named: [String: Key] = {
            func fn(_ scalar: Int) -> String { String(UnicodeScalar(scalar)!) }
            let table: [String: Key] = [
                "enter": Key(keyCode: 36, characters: "\r"),
                "return": Key(keyCode: 36, characters: "\r"),
                "tab": Key(keyCode: 48, characters: "\t"),
                "space": Key(keyCode: 49, characters: " "),
                " ": Key(keyCode: 49, characters: " "),
                "backspace": Key(keyCode: 51, characters: fn(0x7F)),
                "delete": Key(keyCode: 51, characters: fn(0x7F)),
                "escape": Key(keyCode: 53, characters: fn(0x1B)),
                "esc": Key(keyCode: 53, characters: fn(0x1B)),
                "forwarddelete": Key(keyCode: 117, characters: fn(0xF728)),
                "arrowleft": Key(keyCode: 123, characters: fn(0xF702)),
                "arrowright": Key(keyCode: 124, characters: fn(0xF703)),
                "arrowdown": Key(keyCode: 125, characters: fn(0xF701)),
                "arrowup": Key(keyCode: 126, characters: fn(0xF700)),
                "left": Key(keyCode: 123, characters: fn(0xF702)),
                "right": Key(keyCode: 124, characters: fn(0xF703)),
                "down": Key(keyCode: 125, characters: fn(0xF701)),
                "up": Key(keyCode: 126, characters: fn(0xF700)),
                "home": Key(keyCode: 115, characters: fn(0xF729)),
                "end": Key(keyCode: 119, characters: fn(0xF72B)),
                "pageup": Key(keyCode: 116, characters: fn(0xF72C)),
                "pagedown": Key(keyCode: 121, characters: fn(0xF72D)),
            ]
            return table
        }()

        /// Virtual key codes for the ASCII keys, so `event.code` is truthful
        /// rather than always reporting KeyA.
        private static let asciiKeyCodes: [Character: UInt16] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
            "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
            "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
            "w": 13, "x": 7, "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
            "7": 26, "8": 28, "9": 25,
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
            ",": 43, ".": 47, "/": 44, "`": 50, " ": 49,
        ]
    }
}

// MARK: - Delivery

extension OffscreenWebHost {
    /// Whether real input can be delivered right now. False means the caller
    /// should fall back to the bridge rather than report a click that never
    /// happened.
    var canDeliverRealInput: Bool {
        webView.window != nil && webView.bounds.width > 0 && webView.bounds.height > 0
    }

    /// The live size of the page area in CSS pixels.
    ///
    /// Not the same as `viewport`: while the view is lent to a visible panel it
    /// takes the borrower's size, and aiming at the middle of the *emulated*
    /// viewport would then land outside the view entirely.
    var visibleSizeInCSSPixels: CGSize {
        let zoom = max(webView.pageZoom, 0.01)
        let bounds = webView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return viewport }
        return CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
    }

    /// Page CSS pixels into the web view's window coordinates.
    ///
    /// `WKWebView` is flipped on macOS, so client coordinates and view points
    /// share an origin and only the page zoom separates them; the conversion to
    /// window coordinates is what puts the y axis back the way AppKit wants it.
    func windowPoint(forPageCSS point: CGPoint) -> NSPoint? {
        guard canDeliverRealInput else { return nil }
        let zoom = webView.pageZoom
        let scaled = NSPoint(x: point.x * zoom, y: point.y * zoom)
        let viewPoint = webView.isFlipped
            ? scaled
            : NSPoint(x: scaled.x, y: webView.bounds.height - scaled.y)
        return webView.convert(viewPoint, to: nil)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        button: BrowserInput.MouseButton,
        clickCount: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: webView.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0
        )
    }

    /// Move the pointer, so `:hover`, tooltips and hover-opened menus behave
    /// the way they do for a person before the press lands.
    private func deliverMove(to point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard let event = mouseEvent(
            .mouseMoved, at: point, button: .left, clickCount: 0, modifiers: modifiers
        ) else { return }
        webView.mouseMoved(with: event)
    }

    /// One press-and-release at a page coordinate.
    @discardableResult
    func deliverClick(
        at page: CGPoint,
        button: BrowserInput.MouseButton = .left,
        clickCount: Int = 1,
        modifiers: NSEvent.ModifierFlags = []
    ) async -> Bool {
        await withInputDelivery { [self] in
            guard let point = windowPoint(forPageCSS: page) else { return false }
            deliverMove(to: point, modifiers: modifiers)
            try? await Task.sleep(for: BrowserInput.stepDelay)
            // A double click is a click of count 1 followed by one of count 2:
            // sending only the second leaves the page without the first, and
            // text editors that select a word on the second click do nothing.
            for count in 1...max(1, clickCount) {
                guard let down = mouseEvent(
                    button == .right ? .rightMouseDown : .leftMouseDown,
                    at: point, button: button, clickCount: count, modifiers: modifiers
                ), let up = mouseEvent(
                    button == .right ? .rightMouseUp : .leftMouseUp,
                    at: point, button: button, clickCount: count, modifiers: modifiers
                ) else { return false }
                if button == .right {
                    webView.rightMouseDown(with: down)
                    try? await Task.sleep(for: BrowserInput.stepDelay)
                    webView.rightMouseUp(with: up)
                } else {
                    webView.mouseDown(with: down)
                    try? await Task.sleep(for: BrowserInput.stepDelay)
                    webView.mouseUp(with: up)
                }
                try? await Task.sleep(for: BrowserInput.stepDelay)
            }
            return true
        } ?? false
    }

    /// Move the pointer without pressing.
    @discardableResult
    func deliverHover(at page: CGPoint, holding: Duration = .zero) async -> Bool {
        await withInputDelivery { [self] in
            guard let point = windowPoint(forPageCSS: page) else { return false }
            deliverMove(to: point, modifiers: [])
            if holding > .zero { try? await Task.sleep(for: holding) }
            return true
        } ?? false
    }

    /// Press at one point, move through intermediate steps, release at another.
    ///
    /// The intermediate moves are what make this a drag rather than a teleport:
    /// sortable lists and canvas tools track `pointermove` and do nothing at all
    /// for a press and release with no travel between them.
    @discardableResult
    func deliverDrag(
        from start: CGPoint,
        to end: CGPoint,
        steps: Int = 8,
        modifiers: NSEvent.ModifierFlags = []
    ) async -> Bool {
        await withInputDelivery { [self] in
            guard let from = windowPoint(forPageCSS: start),
                  let to = windowPoint(forPageCSS: end)
            else { return false }
            deliverMove(to: from, modifiers: modifiers)
            try? await Task.sleep(for: BrowserInput.stepDelay)
            guard let down = mouseEvent(
                .leftMouseDown, at: from, button: .left, clickCount: 1, modifiers: modifiers
            ) else { return false }
            webView.mouseDown(with: down)
            try? await Task.sleep(for: BrowserInput.stepDelay)

            let count = max(1, steps)
            for step in 1...count {
                let progress = CGFloat(step) / CGFloat(count)
                let point = NSPoint(
                    x: from.x + (to.x - from.x) * progress,
                    y: from.y + (to.y - from.y) * progress
                )
                if let dragged = mouseEvent(
                    .leftMouseDragged, at: point, button: .left,
                    clickCount: 1, modifiers: modifiers
                ) {
                    webView.mouseDragged(with: dragged)
                }
                try? await Task.sleep(for: BrowserInput.stepDelay)
            }

            guard let up = mouseEvent(
                .leftMouseUp, at: to, button: .left, clickCount: 1, modifiers: modifiers
            ) else { return false }
            webView.mouseUp(with: up)
            return true
        } ?? false
    }

    /// Scroll at a page coordinate, so the container under that point moves
    /// rather than always the document.
    @discardableResult
    func deliverScroll(at page: CGPoint, deltaX: CGFloat, deltaY: CGFloat) async -> Bool {
        await withInputDelivery { [self] in
            guard let point = windowPoint(forPageCSS: page) else { return false }
            // Put the pointer over the target first: a wheel event scrolls what
            // the pointer is on, and hovering is what a person would have done.
            deliverMove(to: point, modifiers: [])
            try? await Task.sleep(for: BrowserInput.stepDelay)

            // Delivered as a phased gesture — began, changed, ended — the way a
            // trackpad sends one. A lone unphased wheel event is swallowed while
            // WebKit decides which scroller the gesture belongs to, so the
            // first scroll of a session would silently do nothing.
            let steps: [(phase: Int64, x: CGFloat, y: CGFloat)] = [
                (Self.scrollPhaseBegan, 0, 0),
                (Self.scrollPhaseChanged, deltaX, deltaY),
                (Self.scrollPhaseEnded, 0, 0),
            ]
            guard let flipBase = windowFlipBase() else { return false }
            for step in steps {
                guard deliverWheel(
                    at: point, flipBase: flipBase,
                    phase: step.phase, deltaX: step.x, deltaY: step.y
                ) else { return false }
                try? await Task.sleep(for: BrowserInput.stepDelay)
            }
            return true
        } ?? false
    }

    /// `kCGScrollPhaseBegan` and friends. Spelled out because `CGEventField`
    /// exposes the field but not the phase values.
    private static let scrollPhaseBegan: Int64 = 1
    private static let scrollPhaseChanged: Int64 = 2
    private static let scrollPhaseEnded: Int64 = 4

    /// Where AppKit puts y = 0 when it bridges a windowless `CGEvent`.
    ///
    /// A wheel event has to be built as a `CGEvent` — `NSEvent.mouseEvent`
    /// cannot make one — and the bridged `NSEvent` belongs to no window, so it
    /// reports its location straight back out of the `CGEvent`, flipped about
    /// the primary display. Aiming *that* at a window point is what puts a
    /// scroll under the right element.
    ///
    /// The flip is measured rather than looked up. Asking `NSScreen` for the
    /// height would make scrolling depend on a display existing, and a Mac with
    /// the lid shut and nothing attached has none; probing reads the axis back
    /// out of AppKit itself and stays correct whatever the display arrangement
    /// — or absence — happens to be. It is measured on a throwaway event,
    /// because bridging one `CGEvent` twice yields a second `NSEvent` that
    /// WebKit will not act on.
    private func windowFlipBase() -> CGFloat? {
        guard let probeEvent = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .privateState),
            units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0
        ) else { return nil }
        probeEvent.location = .zero
        return NSEvent(cgEvent: probeEvent)?.locationInWindow.y
    }

    private func deliverWheel(
        at point: NSPoint,
        flipBase: CGFloat,
        phase: Int64,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> Bool {
        guard let scroll = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .privateState),
            units: .pixel,
            wheelCount: deltaX == 0 ? 1 : 2,
            wheel1: Int32(clamping: Int(-deltaY)),
            wheel2: Int32(clamping: Int(-deltaX)),
            wheel3: 0
        ) else { return false }
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        scroll.location = CGPoint(x: point.x, y: flipBase - point.y)
        guard let event = NSEvent(cgEvent: scroll) else { return false }
        webView.scrollWheel(with: event)
        return true
    }

    /// Press and release one key.
    @discardableResult
    func deliverKey(
        _ key: BrowserInput.Key,
        modifiers: NSEvent.ModifierFlags = [],
        repeatCount: Int = 1
    ) async -> Bool {
        await withKeyboardFocus { [self] in
            let flags = modifiers.union(key.impliedModifiers)
            for index in 0..<max(1, repeatCount) {
                guard let down = keyEvent(
                    .keyDown, key: key, modifiers: flags, isRepeat: index > 0
                ), let up = keyEvent(.keyUp, key: key, modifiers: flags, isRepeat: false) else {
                    return false
                }
                webView.keyDown(with: down)
                try? await Task.sleep(for: BrowserInput.stepDelay)
                webView.keyUp(with: up)
                try? await Task.sleep(for: BrowserInput.stepDelay)
            }
            return true
        } ?? false
    }

    /// Type a run of text as individual keystrokes into whatever holds focus.
    @discardableResult
    func deliverText(_ text: String) async -> Bool {
        await withKeyboardFocus { [self] in
            for character in text {
                let key = BrowserInput.Key(character: character)
                guard let down = keyEvent(
                    .keyDown, key: key, modifiers: key.impliedModifiers, isRepeat: false
                ), let up = keyEvent(
                    .keyUp, key: key, modifiers: key.impliedModifiers, isRepeat: false
                ) else { return false }
                webView.keyDown(with: down)
                webView.keyUp(with: up)
                try? await Task.sleep(for: BrowserInput.stepDelay)
            }
            return true
        } ?? false
    }

    private func keyEvent(
        _ type: NSEvent.EventType,
        key: BrowserInput.Key,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: webView.window?.windowNumber ?? 0,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            isARepeat: isRepeat,
            keyCode: key.keyCode
        )
    }
}
