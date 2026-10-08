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
transport audits pass, and the protocol manifest is current. Native checks executed 195 cases: 194 passed, one hosted-pointer activation
case skipped, zero failures. Evidence:
`/tmp/locus-companion-overview-native.nDAo1v/host.41gzdr/tests.xcresult`.

Nine focused UI scenarios passed across isolated runs: both sidebar destinations
and draft preservation; shared panel/main chat and narrow inspector layout;
Companion profile; reviewed context sharing; unread behavior; activity window
visibility; pinned scrolling through 24 message pairs; and the two compact-window
New Agent editor/role-picker cases that failed in the previous release’s CI.
The new scrolling assertion deliberately reaches both ends of lazy history.
The final navigation assertion verifies the selected Agent tab, compact summary,
and absence of a duplicate character or transcript.

Local UI evidence:
- `/tmp/locus-distribution-ui.ldftbO/tests.xcresult` (initial passing cases).
- `/tmp/locus-distribution-ui.jGfgZX/tests.xcresult` (pinned scrolling).
- `/tmp/locus-distribution-ui.wM8zFr/tests.xcresult` (final overview navigation).

An earlier UI run exposed the production duplicate-overview suppression that
hid the requested Agent panel; that was corrected before final validation.
Two initial test assumptions were corrected from observed UI state: restored
history need not start at its final message, and a headerless SwiftUI scroll
container merges its accessibility identifier with the outer panel. The final
assertions verify actual scrolling and visible summary contents instead.

The signed full-app update rehearsal saved a queued output through real
AppModel cleanup, completed installation, and automatically opened the full
Locus app with a visible main window. See
[the updater evidence and limits](UpdaterRestart-2026-10-08.md).

LocusX’s full-runtime Debug build passed its edition audit (45 Mach-O files),
runtime imports, and strict signature verification. All 25 updater lifecycle,
edition-isolation, and manual-update Settings checks passed:
`/tmp/locus-422-locusx-tests-cr4sm9nm/tests.xcresult`.

The Debug update-distribution Settings UI check also passed, bringing focused
UI coverage to ten unique passing scenarios:
`/tmp/locus-distribution-ui.krhvYE/tests.xcresult`.
