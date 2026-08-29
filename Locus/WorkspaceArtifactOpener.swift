import AppKit

/// Where a workspace artifact opens when its link, card, or Outputs row is
/// activated.
enum WorkspaceArtifactDestination: Equatable {
    /// The Files inspector's text peek, scrolled to a location when one was
    /// named. `WorkspaceFileModel.preview` decodes UTF-8 only, so this is for
    /// text the app can actually render.
    case filesTab(line: Int?, column: Int?)
    /// Whatever the user has chosen to open this file type with.
    case defaultApp
}

/// The single decision point for "the user activated a produced file".
///
/// Previously each surface decided for itself, and the binary branch drove the
/// shared `QLPreviewPanel` by assigning its data source directly. That panel
/// resolves its controller from the responder chain whenever it becomes key, so
/// with no `QLPreviewPanelController` anywhere in the app AppKit took it back
/// and showed a blank or previously-previewed item. Routing through one
/// function keeps the transcript link, the artifact card, and the Outputs row
/// behaving identically.
enum WorkspaceArtifactOpener {
    static func destination(for reference: WorkspaceArtifactReference) -> WorkspaceArtifactDestination {
        destination(kind: reference.kind, sourceLocation: reference.sourceLocation)
    }

    /// A named line only makes sense in the peek that can scroll to it, so it
    /// wins over the kind — a `path.pdf:12` reference is a citation, not a
    /// document to hand to Preview.
    static func destination(
        kind: WorkspaceArtifactKind,
        sourceLocation: WorkspaceSourceLocation?
    ) -> WorkspaceArtifactDestination {
        if let sourceLocation {
            return .filesTab(line: sourceLocation.line, column: sourceLocation.column)
        }
        return kind == .source ? .filesTab(line: nil, column: nil) : .defaultApp
    }

    /// Opens `url` in the user's default application.
    ///
    /// Returns false when LaunchServices declines — no handler, or a file that
    /// vanished between the classification and the click — so the caller can
    /// fall back to revealing it rather than failing silently.
    @discardableResult
    static func openInDefaultApp(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
