# Companion pointer reactions

An idle character can react to the pointer inside its own active Locus window.
This is a local presentation effect. It does not create work, collect pointer
history, change permissions, call a model, or imply that the agent is working.

- A native app-local mouse-move listener filters events to the character's own
  active key window and returns every event unchanged. A tracking area requests
  native movement events and handles entry and exit; duplicate updates coalesce.
  There is no global input monitor, cursor polling, accessibility
  permission request, or interception of clicks and scrolling. This also works
  when a SwiftUI hosting view does not forward a foreign tracking area's moves.
- The direction is measured from the character's center in screen coordinates.
  A small neutral area around its face prevents rapid changes when crossing the
  center. Updates are bounded and coalesced on the main queue without a timer.
- A v2 atlas supplies sixteen actual look poses: row 9 starts at up and advances
  clockwise through 157.5 degrees; row 10 continues from down through 337.5
  degrees. The nearest pose is held while watching the pointer. These cells are
  not played as an invented looking-around animation.
- Legacy v1 sprites and imported static pictures receive only a subtle movement
  and tilt of the whole artwork. No eyes or limbs are synthesized. The native
  original characters move their existing drawn eyes within their faces.
- Reactions run only in idle. Greeting, queued, working, approval, completion,
  failure, paused, and unavailable states retain their actual status behavior.
  A setup preview becomes idle after its decorative greeting finishes, so it can
  then follow the pointer. This does not clear real task completion or errors.
- Leaving the window or switching focus returns the character to neutral.
  Reduce Motion, **Animate characters** off, hidden/occluded views, and closing
  or detaching the view disable reactions and remove both the listener and tracking area. Real
  status labels and normal keyboard navigation remain unchanged.

These are Locus's own interaction rules, not a claim of undocumented parity with
another application's character behavior. `CompanionPointerTests` cover direction
mapping, invalid geometry, status priority, v1 fallback, and tracking cleanup.
The hosted-window case posts a mouse-move event through the native application
queue and verifies delivery through the app-local listener in an `NSHostingView`.
It does not invoke the character's event handler directly or move the system
cursor; environments unable to activate a test window explicitly skip that case.
