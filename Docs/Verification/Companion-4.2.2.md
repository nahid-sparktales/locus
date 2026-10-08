# Companion 4.2.2 verification

## Behavior

The Companion shortcut above Manage Accounts opens its dedicated profile in
both Agent and Work. The Companion entry under Agents opens the existing
canonical conversation. Profile navigation from that conversation also selects
the Agent inspector, without reloading the transcript or changing its draft.

The main-chat character is a transparent, non-intercepting overlay at the top
of the transcript viewport. Only the initial breathing room and catch-up
content scroll. The right Companion overview includes Ask mode, provider and
model health, conversation activity, and shortcuts to memory, catch-up, focus,
and the desktop companion.

Activity cards have no ambient dismiss action. Main-window activity keeps the
window open; menu-bar and tools-sheet hosts supply their own presentation
closure. This fixes the window disappearing when Show all activity is pressed.

## Chat retrieval

The user’s screenshot showed saved replies from before the installed 4.2.1
update. Read-only diagnostics against the installed history tools found 17
matching excerpts across eight other chats for the requested image-generation
topic, and reading a source chat returned its message and workspace metadata.
No model request or user-data mutation was needed for that diagnostic.

Two new regressions reopen persisted pre-companion Ask and Work conversations
through actual server admission and profile routing. Both rebuild the managed
provider tool contract, search another agent’s archived chat in another
workspace, and read its source message while keeping the same Locus session.
The managed provider itself uses a local protocol fixture; this is not a live
model-response test. The provider/history/admission/queue suite passed 131 tests.

## Release checks

Release packaging and edition fixtures: 94 tests passed. Design-system and
transport audits pass, and the protocol manifest is current. Native/UI evidence
and the signed updater rehearsal are recorded below once complete.
