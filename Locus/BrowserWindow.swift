import SwiftUI

/// The Browser at full size, outside the 280–520pt inspector. Same chrome,
/// same live web views; the window simply holds the borrowing claim while it
/// is open — a `WKWebView` has one superview, so the inspector shows a
/// hand-off notice instead of a blank pane.
/// Menu command; its own view because `openWindow` is an environment value
/// and the `.commands` builder has no environment of its own.
struct OpenBrowserWindowButton: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Browser Window") {
            openWindow(id: "browser")
        }
        .disabled(model.justChatEnabled)
    }
}

struct BrowserWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        BrowserPanel(
            browser: model.browser,
            sessionID: model.currentSessionID,
            homeURL: model.normalizedPreviewURL,
            viewportRaw: Binding(
                get: { model.settings.browserViewportRaw },
                set: { model.settings.browserViewportRaw = $0 }
            ),
            isWindowHost: true,
            onAttachToChat: { [weak model] data in
                model?.addPastedImages(
                    [(data: data, mimeType: "image/png")],
                    nameStem: "Browser screenshot"
                ) ?? false
            }
        )
        .frame(minWidth: 600, minHeight: 400)
        .background(LocusTheme.paper)
        .preferredColorScheme(.light)
        .onAppear { model.browser.windowHosted = true }
        .onDisappear { model.browser.windowHosted = false }
        .accessibilityIdentifier("browser.window")
    }
}
