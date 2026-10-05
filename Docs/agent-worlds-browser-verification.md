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

## Extracted candidate

Candidate source: independent `agent-worlds` repository, renderer commit `967e10c`; contract/adapter/dev host were still being finalized while these visual checks ran. A fresh final package checksum and clean-clone result are recorded separately in the artifact acceptance record. Candidate files here do not claim exact pixel equality with the baseline.

The explicit developer server (`npm run dev`, `http://127.0.0.1:4173/`) uses only synthetic UUIDs and profiles. Its visible Mock Locus Host panel controls a fixed seeded state and a simulation clock beginning at 2023-11-14T22:13:20Z. The panel is centered so it does not cover native world controls. Captures use the same in-app browser; this second tab remained at 1280×720 despite the browser-level viewport override. Therefore compare layout/artwork/controls, not screenshot dimensions or moving ship positions. The production no-host capture used a separate tab and static server on port 4175.

| Check | Observed result |
| --- | --- |
| Independent asset startup | All 44 models completed loading; islands, individual ship/status badges, ocean, route chart and communicator rendered. |
| Production without native host | Explicit full-window unavailable message, Retry connection, no synthetic profiles. `candidate-no-host.jpg`. |
| Explicit empty fixture | Zero roster entries and the adventure empty state; loaded island world remains visible. `candidate-empty.jpg`. |
| Population limit | 500 synthetic agents produced 500 roster entries; duplicate event did not add duplicates. |
| Workspace invalidation | Switching workspace cleared roster and showed connection unavailable; explicit reconnect returned an empty alternate workspace. |
| Capability denial | Missing required `agents.read` produced an incompatible/capabilities unavailable message. `candidate-denied.jpg`. Read-only mode disabled agent actions, quarters and preference controls with reasons. |
| Repeated lifecycle | Zero → 500 → workspace switch → reconnect → 10 → read only → deny required → full access → 10 left Residents collapsed; one press correctly opened ten rows with matching `aria-expanded=true`. |
| Search and selection | Search `Demo agent 1` matched profiles 1 and 10; selecting profile 1 focused its ship and logged `agents.open` with that synthetic UUID. |
| Captain’s Quarters | Deck preview and crew cards matched the retained design; Return to map worked. `candidate-quarters.jpg`. Host log recorded `navigation.open` for agents. |
| Island shortcut | Settings → Elbaf changed backdrop/subtitle and logged `presentation.open` with allowlisted `elbaf`. `candidate-elbaf.jpg`. |
| Attention panel | Communicator opened Attention/Activity tabs with status-specific synthetic crew rows. `candidate-attention.jpg`. |
| Browser console | No warning/error entries were captured during completed renderer interactions. |

`candidate-local-line.jpg` captures the fully loaded map with the mock panel collapsed and simulation paused. Existing typography, artwork, camera controls and layout are retained; product identity is Agent Worlds / Local Line and there is no world selector.

These browser checks found and fixed a developer entrypoint URL error, paused-clock redraw starvation, stale expanded/collapsed DOM state after reconnect, and read-only controls that were insufficiently explicit. The mock host also initially buffered responses while simulation was paused; the host owner separated deliberate delay from the simulation clock. A final fresh-build recheck is recorded below after that change.

No real profiles, messages, tools, chats or app preferences were modified. Browser preview and logged intentions do not establish native UI behavior; the installed-package WKWebView acceptance tests cover that boundary separately. This interface exposes no CPU profiler, GPU timing, media emulation or deterministic baseline seed override. We do not claim a numerical CPU/frame-time improvement, reduced-motion verification, or a performance budget pass from screenshots. Build bytes and package bounds are measured by the artifact verifier.

### Final mock-host recheck

After rebuilding the root fixes at independent commit `3e6afd4`, paused simulation no longer delayed host events or responses. Starting with ten agents, Pause → Raise approval → Add agent produced eleven roster entries and five attention items immediately. While still paused, selecting an agent, changing sailing area and boat style, New Agent, Crew Chat and opening an approval logged the corresponding `agents.open`, `preferences.set`, `agents.create`, `chats.openShared` and `attention.open` intentions. Reset world settings returned the sailing area to Whole map. No timeout status appeared after the response deadline elapsed; the browser console remained free of warnings/errors. Zero agents disposed and remounted the renderer into the empty state with no inherited selection/activity panel, while keeping loaded scenery visible. The final empty and approval screenshots replace the earlier captures.
