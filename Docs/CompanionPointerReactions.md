# Companion pointer reactions

The character in the Companion tab, main conversation, and companion profile
reacts only while the mouse is inside its own surface in the key Locus window. Other avatars,
setup previews, and the menu-bar companion stay neutral.
This is a local presentation effect. It does not create work, collect pointer
history, change permissions, call a model, or imply that the agent is working.

- Passing the pointer over the character starts eight seconds of following.
  Fast passes between mouse events also count, as does scrolling while over the
  character. Moving elsewhere in the surface does not start or prolong following.
  A new pass over the character can start another eight-second response.
- A native app-local mouse-move and scroll listener filters events to the character's own
  key window and returns every event unchanged. Tracking requires an enabled,
  visible surface and the pointer inside that surface's bounds.
  A tracking area requests
  native movement events and handles entry and exit; duplicate updates coalesce.
  There is no global input monitor, cursor polling, accessibility
  permission request, or interception of clicks and scrolling. This also works
  when a SwiftUI hosting view does not forward a foreign tracking area's moves.
- The direction is measured from the character's center in screen coordinates.
  A small neutral area around its face prevents rapid changes when crossing the
  center. Updates are bounded and coalesced on the main queue. A cancellable
  one-shot deadline returns the character to neutral after eight seconds even
  if the mouse stops moving; it does not poll or collect pointer history.
- A v2 atlas supplies sixteen actual look poses: row 9 starts at up and advances
  clockwise through 157.5 degrees; row 10 continues from down through 337.5
  degrees. The nearest pose is held while watching the pointer. These cells are
  not played as an invented looking-around animation.
- Legacy v1 sprites and imported static pictures receive only a subtle movement
  and tilt of the whole artwork, snapped to discrete whole-point/degree poses
  without an eased glide. No eyes or limbs are synthesized. The native original
  characters move their existing drawn eyes through discrete positions.
- Reactions run only in idle. Greeting, queued, working, approval, completion,
  failure, paused, and unavailable states retain their actual status behavior.
  These reactions do not clear real task completion or errors.
- Leaving the surface or switching focus cancels following and returns the character to neutral.
  Reduce Motion, **Animate characters** off, hidden/occluded views, and closing
  or detaching the view disable reactions and remove the listener, tracking area,
  and pending deadline. Real
  status labels and normal keyboard navigation remain unchanged.

Playback uses Locus's own 8fps stepped timing: approved source frames last one
or more 125ms ticks, with two-second rests during idle and longer waiting holds.
Greetings and completion reactions have a brief final hold. The native original
characters also use held key poses rather than continuous spring or breathing
interpolation. Pointer gaze remains event-driven and holds the nearest of the
sixteen supplied look frames; there is no cursor polling or extra animation loop.
The existing painted artwork and asset bytes are unchanged—this is a change to
motion, not a pixel-art redraw or a claim about another product's frame rate.

These are Locus's own interaction rules, not a claim of undocumented parity with
another application's character behavior. `CompanionPointerTests` cover direction
mapping, invalid geometry, status priority, v1 fallback, contact activation,
fast passes, scrolling, bounded follow duration, expiry without movement, and tracking cleanup.
The hosted-window case posts a mouse-move event through the native application
queue and verifies delivery through the app-local listener in an `NSHostingView`.
It does not invoke the character's event handler directly or move the system
cursor; environments unable to activate a test window explicitly skip that case.
`CompanionMotionTests` cover frame cadence, quiet idle/waiting holds, brief action
timing, symmetric pose snapping, and invalid numeric input.
