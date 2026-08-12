import SwiftUI

/// The always-visible right rail. Collapsing the inspector no longer empties
/// the window edge: Terminal, Plan, Browser, and an ellipsis holding the rest
/// stay within reach, and the panel opens to the rail's left. Attention badges
/// live on the icons, so a run can ask for eyes without the panel being open.
struct InspectorRail: View {
    @EnvironmentObject private var model: AppModel

    /// Destinations that live behind the ellipsis rather than on the rail
    /// itself. The inspector's dynamic tab bar is driven by open state, not
    /// this fixed menu inventory.
    static let menuTabs = InspectorTab.workspaceTabs.filter { $0 != .terminal }

    var body: some View {
        VStack(spacing: 6) {
            moreMenu
            railTab(.terminal)
            railTab(.plan)
            railTab(.preview)
            Spacer(minLength: 0)
            zoomButton
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .leading) {
            Rectangle().fill(LocusTheme.line).frame(width: 1)
        }
    }

    private var zoomButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                model.toggleInspectorZoom()
            }
        } label: {
            Image(
                systemName: model.inspectorZoomed
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(LocusTheme.muted)
            .frame(width: 32, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(model.inspectorZoomed ? "Restore panel (⌘⌥E)" : "Expand panel (⌘⌥E)")
        .accessibilityLabel(model.inspectorZoomed ? "Restore panel" : "Expand panel")
        .accessibilityIdentifier("inspector.zoom")
    }

    private func railTab(_ tab: InspectorTab) -> some View {
        let selected = !model.inspectorCollapsed && model.inspectorTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                model.toggleInspectorTab(tab)
            }
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? LocusTheme.ink : LocusTheme.muted)
                .overlay(alignment: .topTrailing) {
                    InspectorTabBadge(tab: tab)
                }
                .frame(width: 32, height: 30)
                .background {
                    // The strip's underline idiom has no room at 44pt; the
                    // app's card shape marks the open tab instead.
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LocusTheme.white)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(LocusTheme.line, lineWidth: 1)
                            }
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel("\(tab.title) inspector")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("inspector.rail.\(tab.rawValue)")
    }

    private var moreMenu: some View {
        Menu {
            ForEach(Self.menuTabs) { tab in
                Button(menuTitle(for: tab)) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.selectInspectorTab(tab)
                    }
                }
                .accessibilityIdentifier("inspector.rail.menu.\(tab.rawValue)")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LocusTheme.muted)
                .overlay(alignment: .topTrailing) {
                    // Changes lives in this menu, so its unseen dot surfaces
                    // here — the count itself waits in the menu title.
                    if model.changesHaveUnseenUpdate {
                        Circle()
                            .fill(LocusTheme.coral)
                            .frame(width: 5, height: 5)
                            .offset(x: 5, y: -3)
                    }
                }
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 30)
        .help("More panels")
        .accessibilityLabel("More panels")
        .accessibilityIdentifier("inspector.rail.more")
    }

    private func menuTitle(for tab: InspectorTab) -> String {
        if tab == .changes, model.changedFileCount > 0 {
            return "\(tab.title) (\(model.changedFileCount))"
        }
        return tab.title
    }
}
