import SwiftUI

/// Keyboard shortcut reference, presented with ⌘/ like Claude Code's
/// shortcuts help.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        let keys: String
        let title: String
        var id: String { keys + title }
    }

    private struct Group: Identifiable {
        let name: String
        let shortcuts: [Shortcut]
        var id: String { name }
    }

    private let groups: [Group] = [
        Group(name: "General", shortcuts: [
            Shortcut(keys: "⌘K", title: "Command palette"),
            Shortcut(keys: "⌘F", title: "Find in conversation"),
            Shortcut(keys: "⌘/", title: "Keyboard shortcuts"),
            Shortcut(keys: "⌘N", title: "New session"),
            Shortcut(keys: "⌘⇧K", title: "Clear chat"),
            Shortcut(keys: "⌘S", title: "Create checkpoint"),
            Shortcut(keys: "⌘R", title: "Review changes"),
        ]),
        Group(name: "Composer", shortcuts: [
            Shortcut(keys: "⌘↵", title: "Send message (queues while busy)"),
            Shortcut(keys: "Esc", title: "Stop the current run / close popups"),
            Shortcut(keys: "↑ ↓", title: "Browse prompt history (empty composer)"),
            Shortcut(keys: "/", title: "Slash commands"),
            Shortcut(keys: "@", title: "Mention a workspace file"),
            Shortcut(keys: "↑↓ · 1–3 · ↵ · Esc", title: "Answer a permission request"),
        ]),
        Group(name: "Panels", shortcuts: [
            Shortcut(keys: "⌘0", title: "Show/hide sidebar"),
            Shortcut(keys: "⌘1–⌘8", title: "Plan · Changes · Files · Console · Preview · Checkpoints · AGENTS.md · Workflows"),
            Shortcut(keys: "⌘⌥I", title: "Show/hide inspector"),
        ]),
        Group(name: "Modes", shortcuts: [
            Shortcut(keys: "⌥A", title: "Just Chat"),
            Shortcut(keys: "⌥P", title: "Plan mode"),
            Shortcut(keys: "⌥B", title: "Build mode"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard shortcuts")
                        .font(.system(size: 15, weight: .bold))
                    Text("Everything in Locus is reachable from the keyboard.")
                        .font(.system(size: 9))
                        .foregroundStyle(LocusTheme.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close shortcuts")
                .accessibilityIdentifier("shortcuts.close")
            }
            .padding(16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LocusTheme.line).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.name.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.9)
                                .foregroundStyle(LocusTheme.muted)
                            VStack(spacing: 0) {
                                ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                    HStack {
                                        Text(shortcut.title)
                                            .font(.system(size: 10, weight: .medium))
                                        Spacer()
                                        Text(shortcut.keys)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(LocusTheme.muted)
                                            .padding(.horizontal, 7)
                                            .frame(height: 20)
                                            .background(LocusTheme.paperDeep)
                                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    }
                                    .padding(.horizontal, 11)
                                    .frame(height: 34)
                                    if index < group.shortcuts.count - 1 {
                                        Divider().overlay(LocusTheme.line.opacity(0.6))
                                    }
                                }
                            }
                            .locusCard(radius: 9)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 430, height: 520)
        .background(LocusTheme.panel)
    }
}
