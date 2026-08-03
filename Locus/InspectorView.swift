import AppKit
import SwiftUI

/// The right-hand inspector: a tab shell around workspace run state, files,
/// instructions, terminal, preview and checkpoints, with a drag handle on its
/// leading edge.
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabStrip()
                .environmentObject(model)

            Group {
                switch model.inspectorTab {
                case .plan:
                    InspectorPlanTab()
                case .changes:
                    InspectorChangesTab()
                case .files:
                    InspectorFilesTab()
                case .terminal:
                    InspectorTerminalTab()
                case .preview:
                    InspectorPreviewTab()
                case .checkpoints:
                    InspectorCheckpointsTab()
                case .agents:
                    InspectorAgentsTab()
                }
            }
            .environmentObject(model)
            .frame(maxHeight: .infinity)
        }
        .background(LocusTheme.paperDeep)
        .overlay(alignment: .leading) {
            InspectorResizeHandle()
                .environmentObject(model)
        }
    }
}

/// Shared empty state for inspector tabs.
struct InspectorPlaceholder: View {
    let symbol: String
    let title: String
    let message: String
    let identifier: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 23))
                .foregroundStyle(LocusTheme.muted)
            Text(title)
                .font(.system(size: 11, weight: .bold))
            Text(message)
                .font(.system(size: 9))
                .foregroundStyle(LocusTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

/// Icon-first tab strip. Labels appear only when the panel is wide enough, and
/// the attention badge sits on the icon so it survives icon-only mode.
private struct InspectorTabStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases) { tab in
                tabButton(tab)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.inspectorCollapsed = true
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LocusTheme.muted)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide inspector")
            .accessibilityLabel("Hide inspector")
            .accessibilityIdentifier("inspector.collapse")
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LocusTheme.line).frame(height: 1)
        }
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        let selected = model.inspectorTab == tab
        return Button {
            model.selectInspectorTab(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .overlay(alignment: .topTrailing) {
                        badge(for: tab)
                    }
                if model.inspectorShowsLabels {
                    Text(tab.title)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? LocusTheme.ink : LocusTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle()
                        .fill(LocusTheme.ink)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel("\(tab.title) inspector")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("inspector.tab.\(tab.rawValue)")
    }

    @ViewBuilder
    private func badge(for tab: InspectorTab) -> some View {
        if tab == .changes, model.changedFileCount > 0 {
            // Coral only while the change is still unseen; once you have opened
            // the tab the count stays but stops asking for attention.
            let unseen = model.changesHaveUnseenUpdate
            Text(model.changedFileCount > 99 ? "99+" : "\(model.changedFileCount)")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 3)
                .frame(height: 11)
                .background(unseen ? LocusTheme.coral : LocusTheme.muted)
                .clipShape(Capsule())
                .offset(x: 9, y: -5)
                .accessibilityElement()
                .accessibilityLabel(
                    unseen
                        ? "\(model.changedFileCount) changed files, new since you last looked"
                        : "\(model.changedFileCount) changed files"
                )
                .accessibilityIdentifier("inspector.tab.changes.badge")
        } else if tab == .plan, model.planHasUnseenUpdate {
            Circle()
                .fill(LocusTheme.coral)
                .frame(width: 5, height: 5)
                .offset(x: 5, y: -3)
                .accessibilityElement()
                .accessibilityLabel("Plan updated")
                .accessibilityIdentifier("inspector.tab.plan.badge")
        }
    }
}

/// Drag target on the inspector's leading divider.
private struct InspectorResizeHandle: View {
    @EnvironmentObject private var model: AppModel
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(LocusTheme.line)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // `.set()` rather than push/pop: an unbalanced pair is
                        // the classic way to leave the cursor stuck.
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // Accumulate from a captured start width so the
                                // panel cannot drift over a long drag.
                                let start = startWidth ?? model.inspectorWidth
                                if startWidth == nil { startWidth = start }
                                model.setInspectorWidth(start - value.translation.width)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                model.commitInspectorWidth()
                            }
                    )
                    .onTapGesture(count: 2) {
                        model.setInspectorWidth(AppSettings.defaultInspectorWidth)
                        model.commitInspectorWidth()
                    }
                    .accessibilityLabel("Resize inspector")
                    .accessibilityIdentifier("inspector.resizeHandle")
            }
    }
}
