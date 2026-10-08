# Companion 4.2.1 verification

October 8, 2026. This revision supersedes the interaction descriptions in the
older Companion tab verification: the Agent sidebar now has a dedicated
Companion spot, the primary companion has one ongoing chat and profile, and the
right panel shows an overview when that chat is open centrally.

Companion dispatch is always Ask. Its explicit read-only context tools list,
search, and read saved chats across workspaces and agents, including archived
conversations. Existing permission opt-outs and Private Identity isolation are
preserved. Historical messages are evidence rather than new instructions.
ChatGPT hosted apps without local read-only metadata are excluded from Companion
Ask, including unsolicited approval requests. Ordinary Ask routing is unchanged.

## Native and UI evidence

- Native: 190 cases executed, 189 passed, one pointer-host activation skip, zero
  failures. The run covers AppUpdateControllerTests, AppEditionTests, and all
  sixteen Companion test classes, including dispatch, queue restoration, loading
  ownership, unread persistence, pointer timing, and cleanup.
- Focused UI: eight unique cases passed across the final runs. They cover the
  single shared chat and draft, overview substitution, scrolling character,
  aligned context control, dedicated sidebar, both unread menus, companion
  profile/tools/return-to-chat, and Debug update settings.
- One menu-bar UI case explicitly skipped because this MacBook's notch obscures
  its status item. It is not counted as a pass.
- Screenshots were reviewed for the narrow inspector, main conversation,
  companion profile, and unread sidebar. The profile fits without clipping;
  the character has no fixed opaque header; Ask and Look at this share the
  composer toolbar. Draft preservation passed with an exact baseline assertion.

UI testing found and corrected inverted Mark as read/unread actions in both
menus. A profile geometry check now waits for the inspector-collapse animation.
An external window interrupted one test's initial typing; the test now clears
and verifies its initial draft before checking exact preservation. A first
XCTest attempt timed out enabling automation before any test ran; the fresh
isolated run executed normally without changing OS permissions.

Local native evidence:
`/tmp/locus-companion-overview-native.2sFBqm/host.Gga0vN/tests.xcresult`.
Initial UI run and reviewed screenshots:
`/tmp/locus-companion-overview-ui.mwS3Kj/tests.xcresult`.
Final unread verification:
`/tmp/locus-distribution-ui.dJoYA3/tests.xcresult`.
Final profile and draft verification:
`/tmp/locus-distribution-ui.xiJvm2/tests.xcresult`.

All local app hosts were copied to temporary paths and assigned isolated bundle
identities. These tests did not update or terminate the installed Locus app.
Backend/provider fixtures do not claim live model-service validation.

The updater's separate signed installation and actual process-relaunch proof is
recorded in [UpdaterRestart-2026-10-08.md](UpdaterRestart-2026-10-08.md).
