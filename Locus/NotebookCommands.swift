import SwiftUI

private struct NotebookModelFocusKey: FocusedValueKey {
    typealias Value = NotebookModel
}

private struct NotebookCreateNoteFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var notebookModel: NotebookModel? {
        get { self[NotebookModelFocusKey.self] }
        set { self[NotebookModelFocusKey.self] = newValue }
    }
    var notebookCreateNote: (() -> Void)? {
        get { self[NotebookCreateNoteFocusKey.self] }
        set { self[NotebookCreateNoteFocusKey.self] = newValue }
    }
}

/// One owner for Command-N: the frontmost Notebook creates a note, otherwise
/// the existing workspace/agent destination creates a chat.
struct NotebookNewNoteCommand: View {
    @FocusedValue(\.notebookModel) private var notebook
    @FocusedValue(\.notebookCreateNote) private var createNote
    let newChat: () -> Void

    var body: some View {
        Button(notebook == nil ? "New Chat" : "New Note") {
            if let createNote {
                createNote()
            } else if notebook == nil {
                newChat()
            }
        }
        .disabled(notebook != nil && createNote == nil)
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityIdentifier("menu.newItem")
    }
}
