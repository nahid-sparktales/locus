# Agent Worlds browser verification

## Original Local Line baseline

Source: Locus `4cce6ebfaa31f76cd7790967ad8ce7d7e2338deb`, unchanged tracked plugin UI. Captured October 5, 2026 after the architecture audit, before any deletion/cutover. Server:

```sh
python3 -m http.server 4174 --bind 127.0.0.1 --directory plugins/agent-world/ui
```

Browser: Codex in-app browser, hidden tab through supported CUA interface, explicit viewport 1440×1000. URL `http://127.0.0.1:4174/?theme=grand-line`; original entrypoint rewrites preview settings into the query. DOM confirmed viewport 1440×1000, body width 1440 and document visible. All 44 model loads finished; no warning/error messages were captured in the console. The original page chooses demo state automatically without its native bridge. This is a known baseline behavior; the candidate deliberately requires an explicit mock-host entrypoint.

Evidence:

- `agent-worlds-verification/baseline-local-line.jpg`: loaded ocean/islands, map controls, twelve ship badges, one working indicator and attention communicator.
- `agent-worlds-verification/baseline-quarters.jpg`: deck backdrop, twelve crew cards and preview-only native-tool explanation.
- `agent-worlds-verification/baseline-elbaf.jpg`: Settings → Elbaf changes backdrop and island subtitle while retaining crew cards.
- `agent-worlds-verification/baseline-attention.jpg`: communicator opens an attention panel containing one explicit sample approval for Echo.
- `baseline-roster.txt` and `baseline-attention.txt`: saved DOM snapshots, including selectable ship designs and displayed status metadata.

Observed controls and effects: Residents opens a searchable twelve-agent roster; each agent has a boat-style selector with Automatic plus fifteen ship designs. Crew statuses include working, queued, attention, completed and available. Captain's Quarters opens a full-window preview; Return to map closes it. Settings offers island shortcuts for Elbaf, Marineford, Water 7, Wano and Drum Island, plus the enabled island-click shortcut. Selecting Elbaf opens its matching illustrated backdrop. Activity Center opens Attention and Activity tabs; its sample approval explicitly says no real request is pending. Ship sailing area switches Whole map/Left side/Right side; choosing Left side changes the query, camera and reset-button label, then was restored to Whole map. Rotate/Move map/reset controls are present.

The supported CUA browser interface exposes viewport control but no media emulation or deterministic clock/randomness override. These images document loaded artwork/layout and real interactions, **not deterministic frame-level visual equality or reduced-motion compliance**. The moving fleet's positions can differ by time. The original UI has no read-only control to produce an empty roster, so no empty-state baseline was fabricated through script injection. Native Captain's Quarters, chats, tools, calendar, board, permission prompts and macOS integration are outside this browser proof.

A first attempt to create a visible IAB tab was rejected because subagents cannot show IAB; a hidden tab succeeded. A settings lookup by ARIA button name failed because the HTML summary is exposed as a generic DOM node; the current native accessibility entry opened it successfully. Neither observation indicates a product regression.

Candidate results will be recorded after its independent build and explicit developer fixtures are ready. The original source remains available throughout the acceptance phase.
