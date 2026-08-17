import SwiftUI

private struct ShortcutReference: Identifiable {
    let keys: String
    let title: String
    var id: String { keys + title }
}

private struct ShortcutReferenceGroup: Identifiable {
    let name: String
    let shortcuts: [ShortcutReference]
    var id: String { name }
}

private let shortcutReferenceGroups: [ShortcutReferenceGroup] = [
    ShortcutReferenceGroup(name: "General", shortcuts: [
        ShortcutReference(keys: "⌘K", title: "Command palette"),
        ShortcutReference(keys: "⌘F", title: "Find in conversation"),
        ShortcutReference(keys: "⇧⌘F", title: "Search all conversations"),
        ShortcutReference(keys: "⌘/", title: "Keyboard shortcuts"),
        ShortcutReference(keys: "⌘N", title: "New session"),
        ShortcutReference(keys: "⌘⇧K", title: "Clear chat"),
        ShortcutReference(keys: "⌘S", title: "Create checkpoint"),
        ShortcutReference(keys: "⌘R", title: "Review changes"),
    ]),
    ShortcutReferenceGroup(name: "Composer", shortcuts: [
        ShortcutReference(keys: "↵", title: "Send · queue for next turn while busy"),
        ShortcutReference(keys: "⌘↵", title: "Send · steer while busy · stop when empty"),
        ShortcutReference(keys: "⇧↵", title: "Add a new line"),
        ShortcutReference(keys: "Esc", title: "Stop the current run / close popups"),
        ShortcutReference(keys: "↑ ↓", title: "Browse prompt history (empty composer)"),
        ShortcutReference(keys: "/", title: "Slash commands"),
        ShortcutReference(keys: "@", title: "Mention a workspace file"),
        ShortcutReference(keys: "↑↓ · 1–3 · ↵ · Esc", title: "Answer an approval or permission request"),
    ]),
    ShortcutReferenceGroup(name: "Panels", shortcuts: [
        ShortcutReference(keys: "⌘0", title: "Show/hide sidebar"),
        ShortcutReference(keys: "⌘1–⌘9", title: "Open inspector tabs"),
        ShortcutReference(keys: "⌘⌥I", title: "Show/hide inspector"),
    ]),
    ShortcutReferenceGroup(name: "Browser (while the panel is showing)", shortcuts: [
        ShortcutReference(keys: "⌘T", title: "New tab"),
        ShortcutReference(keys: "⌘W", title: "Close tab"),
        ShortcutReference(keys: "⇧⌘] ⇧⌘[", title: "Next / previous tab"),
    ]),
    ShortcutReferenceGroup(name: "Modes", shortcuts: [
        ShortcutReference(keys: "⌥A", title: "Just Chat"),
        ShortcutReference(keys: "⌥P", title: "Plan mode"),
        ShortcutReference(keys: "⌥B", title: "Build mode"),
    ]),
]

private struct KeyboardShortcutsReference: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(shortcutReferenceGroups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(group.name.uppercased())
                        .font(.locus(size: 8, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(LocusTheme.muted)
                    VStack(spacing: 0) {
                        ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                            HStack {
                                Text(shortcut.title)
                                    .font(.locus(size: 10, weight: .medium))
                                Spacer()
                                Text(shortcut.keys)
                                    .font(.locus(size: 9, design: .monospaced))
                                    .foregroundStyle(LocusTheme.muted)
                                    .padding(.horizontal, 7)
                                    .frame(height: 20)
                                    .background(LocusTheme.paperDeep)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .padding(.horizontal, 11)
                            .frame(minHeight: 34)
                            if index < group.shortcuts.count - 1 {
                                Divider().overlay(LocusTheme.line.opacity(0.6))
                            }
                        }
                    }
                    .locusCard(radius: 9)
                }
            }
        }
        .accessibilityIdentifier("shortcuts.reference")
    }
}

/// The persistent reference requested in Settings, directly below Extensions.
struct KeyboardShortcutsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keyboard shortcuts")
                    .font(.locus(size: 15, weight: .bold))
                Text("Everything in Locus remains reachable from the keyboard, including the command palette with ⌘K.")
                    .font(.locus(size: 9))
                    .foregroundStyle(LocusTheme.muted)
                    .padding(.bottom, 14)
                KeyboardShortcutsReference()
            }
            .padding(20)
        }
        .background(LocusTheme.panel)
        .accessibilityIdentifier("settings.shortcuts")
    }
}

/// Keyboard shortcut reference, still presented with ⌘/ and `/shortcuts`.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard shortcuts")
                        .font(.locus(size: 15, weight: .bold))
                    Text("Everything in Locus is reachable from the keyboard.")
                        .font(.locus(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.locus())
                .accessibilityLabel("Close shortcuts")
                .accessibilityIdentifier("shortcuts.close")
            }
            .padding(16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            ScrollView {
                KeyboardShortcutsReference()
                    .padding(16)
            }
        }
        .frame(width: 430, height: 520)
        .background(LocusTheme.panel)
    }
}
