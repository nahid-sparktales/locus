> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/working-in-locus/shortcuts-and-slash-commands.md).

# Shortcuts & Slash Commands

Navigate Locus 2.1 and control a session from the keyboard.

## Essential shortcuts

| Shortcut          | Action                                                                  |
| ----------------- | ----------------------------------------------------------------------- |
| ⌘K                | Command palette                                                         |
| ⌘F                | Find in the current conversation; find on page while Browser owns focus |
| ⇧⌘F               | Search all conversations                                                |
| ⌘/                | Keyboard shortcut reference                                             |
| ⌘0                | Show or hide the sidebar                                                |
| ⌘1–⌘5, ⌘7–⌘9      | Open numbered inspector panels                                          |
| ⌘6                | Session checkpoints                                                     |
| ⇧⌘9               | Open Notebook                                                           |
| ⌘⌥I               | Show or hide the inspector                                              |
| ⌘⌥E               | Expand or restore the inspector                                         |
| ⌘N                | New chat                                                                |
| ⌘⇧K               | Clear the current chat                                                  |
| ⌘S                | Session checkpoints                                                     |
| ⌘R                | Review changes                                                          |
| ⌥A / ⌥W / ⌥P / ⌥G | Just Chat / Work / Plan / Grill                                         |
| ⌘↵                | Send, steer while busy, or stop when empty                              |
| Escape            | Stop the run or close the active prompt                                 |

While Browser is visible: ⌘T opens a tab, ⌘W closes it, and ⇧⌘]/⇧⌘\[ move between tabs.

## Composer commands

Type / to open autocomplete.

| Command                             | Purpose                                                        |
| ----------------------------------- | -------------------------------------------------------------- |
| /clear                              | Start a fresh chat and keep the current one saved              |
| /model, /models                     | Select a model or browse compatible local models               |
| /ask, /work, /plan, /grill          | Change mode                                                    |
| /gsd, /build                        | Compatibility aliases that select Grill                        |
| /checkpoint, /rewind                | Create or restore a named checkpoint                           |
| /changes                            | Review the Git working tree                                    |
| /browser                            | Open Browser; /preview remains an alias                        |
| /context                            | Add files or folders to the persistent context pack            |
| /export                             | Export the current session                                     |
| /workspace, /newworkspace           | Open or create a project folder                                |
| /copy, /retry, /stop                | Control the latest response or run                             |
| /compact                            | Compact conversation context and reset a ChatGPT helper thread |
| /remember                           | Save an approved workspace fact                                |
| /permissions, /acceptedits, /bypass | Change permission mode                                         |
| /thinking                           | Hide, collapse, or expand provider-supplied reasoning          |
| /settings, /shortcuts, /help        | Open controls and references                                   |

Unknown slash commands pass through to the local agent.
