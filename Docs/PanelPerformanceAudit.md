# Right-panel performance audit

September 9, 2026. Scope: opening and switching right-side panels, expanding
and restoring them, and dragging their divider with an existing long chat.

## Changes

| Finding | Change |
| --- | --- |
| A four-row chat containing a 36-section Markdown answer entered a sustained SwiftUI layout loop when restoring an expanded panel. Width stabilization alone did not resolve it; removing lazy height estimation for that short transcript did. | Lay out up to 40 presentation rows eagerly, retaining lazy rendering for longer histories. Give both columns resolved widths and give transcript text a finite viewport-based wrapping width. Streaming text also handles unspecified and infinite measurement proposals. |
| Inspector, sidebar, and expanded-chat widths published through `AppModel` on every pointer event, invalidating unrelated conversation and panel views. | Widths now publish through `WorkspaceLayoutModel`. Views observe that owner directly; commands retain compatibility accessors. Repeated clamped widths do not publish. Settings are saved on release. |
| `ConversationView.body` allocated and filled an indexed row array for the entire transcript whenever unrelated state refreshed the view. | Indexed rows and session-scoped scroll identities are created once with the immutable transcript snapshot and reused across layout, tab, and selection changes. Session renames preserve their storage; content and session replacements update them coherently. |
| Spring-driven panel geometry repeatedly rewrapped native text in populated chats. A single large answer can contain many text views despite having few transcript rows. | Panel layout changes use their final geometry immediately at 100 presentation items or 16 KiB of stored answer/reasoning/tool-detail text. Short chats retain the shared panel animation. Reduce Motion also selects immediate layout. The policy is computed at transcript commit time, not during resizing. |
| Returning to Files while indexing cancelled the waiting task but could leave its detached disk scan running alongside another scan. Empty results also triggered repeated scans. | Reuse an in-flight scan for the same workspace and cache empty completed indexes. Explicit refresh, invalidation, workspace changes, and cancellation retain their generation checks. |

The sidebar gear menu now includes **Check for Updates…** for automatic-update
builds, connected to the existing update controller and its enabled state.
Manual and App Store builds expose **Software Updates…**, which opens the
appropriate Settings page. The compact sidebar receives the same controller.

## Verification

Regression coverage includes a 500-block transcript with 300 divider updates,
shared row-storage identity, replacement/rename behavior, long-answer layout
policy, overlapping and empty file scans, saved widths, transcript selection,
scroll following, the transition between eager and lazy history, and native
text rewrapping. The UI stress fixture exercises
Files, Terminal, and repeated Browser expansion/restoration beside a 36-section
answer, preserving the address draft.

Native and UI runs use an isolated test app identity so the installed Locus
can remain open. The UI test copy loads its bundled frameworks instead of
overriding their paths with the build directory. The 36-section stress test
now completes all three expansion/restoration cycles and preserves the address
draft; the earlier lazy-only version repeatedly timed out at 120 seconds.
This comparison demonstrates resolution of that stall, not a general timing
benchmark. The final native behavior run passed all 148 tests, including the
600-message virtualization check and the eager/lazy history transition.

All six selected UI tests also passed: long-answer expansion/restoration,
compact-window overlay sidebar, Context panel state, overflowing panel tabs,
live resize, and the sidebar update menu. The final run therefore passed
**154 tests with zero failures**. The Debug build, design-system audit, and
`git diff --check` passed. Two source observation-boundary checks passed
directly after the isolated native test host stalled opening the source
directory; those checks are outside the 154-test total.

The existing live-resize sampler recorded 24 samples on the default 12-section
fixture: 0.633 ms p95 main-thread work, 5.440 ms maximum, and a settled width of
1003 points. These are advisory measurements from this machine and test run,
not display-frame timings or a before/after release benchmark.

The update check itself was not sent to the release server; the UI test
verified the manual-build Settings destination, and controller unit tests
covered update availability and configuration.

## Limits

This removes redundant invalidation, allocation, scanning, and intermediate
animated reflow. Text still needs an exact layout at the final width; a very
large individual answer can therefore still cost more than a short one.
Streaming parsing, native browser/terminal rendering, and backend response
latency have separate owners and are not accelerated by these changes.

The 40-row eager-layout boundary and animation thresholds are conservative
heuristics. Eager layout trades a bounded number of mounted rows for exact
heights; long histories retain virtualization. These are not a hardware-specific
frame-rate guarantee. Tests establish structural savings and correctness;
they do not establish an end-to-end percentage speedup against a release build.
