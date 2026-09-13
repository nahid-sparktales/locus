# Agent World renderer

The local TypeScript/Babylon.js renderer for the Agent World Locus plugin. Its
native window, conversations, permissions, and task execution belong to Locus.
The catalog includes **Orbital Locus Outpost** (a campus with humanoid residents) and
**The Local Line** (a One Piece-inspired ocean with playful local-AI names and a ship for each agent).
The saved theme ID remains `grand-line`; existing settings and asset paths stay valid.

Outpost uses Locus's charcoal, warm paper, sage, and lime palette. Its **Mixed /
Pandas / Explorers** selector switches residents without resetting their positions,
routes, selection, or work. Mixed is the default for new preferences and balances
pandas, human characters, and robots. Surviving agents keep their kind when the
roster changes; newcomers fill the least represented group. Humans have visible
faces, varied hair and skin tones, and articulated walking. The original pandas match the site's ink/cream
mascot, with four accessories, planted walking feet, arm swing, and subtle idle
motion. They require no downloaded model or generation credits. Locus saves the
appearance per screen; standalone previews use local browser storage and support
`?theme=outpost&residentStyle=mixed`. Existing saved appearance choices are retained.

## Build and verify

```sh
cd AgentWorldWeb
npm ci
npm run check
```

Node 22.18 or newer supports the TypeScript unit tests. The build writes the
standalone UI into `plugins/agent-world/ui`; it deliberately preserves `themes/`
and its prepared GLB artwork. Dependencies, shaders, and GLB loaders are bundled
locally. No CDN or model-provider access is required while exploring.

Serve the packaged `ui` directory over localhost for browser inspection. Without
the native `locusScreen` bridge, the page clearly identifies its demo residents
and makes no model calls. Native windows never add demo residents. The theme
menu switches between both worlds; `?theme=grand-line` and `?theme=outpost`
select a standalone preview. From the repository root, run
`agent/.venv/bin/python Tools/VerifyAgentWorldPackage.py` to check every catalog
theme, embedded assets, humanoid clips, references, hashes, and paid-task totals.

## Host boundary

The renderer sends version 1 `ready`, `selectAgent`, `preferences`, `openAttention`,
`openTransfer`, `openSharedChat`, and `openAgentControls` messages
through `window.webkit.messageHandlers.locusScreen`. Locus sends `snapshot` and
`visibility` messages to `window.locusAgentWorld.receive`. `src/state.ts` defines
and validates the contract. Agent IDs are profile UUIDs; status values describe
actual host activity. Roster buttons expose `data-agent-id` and `data-status`
attributes for UI verification. Optional `attentionRequests` and `transfers` carry
only bounded display metadata and native UUID tokens. Locus resolves each token
to the exact request or transfer; transcript paths remain native.

Both worlds open in an elevated overview. Click a resident, ship, or its name to
interact. Choose Move map to pan by dragging, Rotate to orbit, or use arrow
keys/WASD to move across the map. Scroll to zoom and Reset view restores the
overview. Ships turn before translating and their models align with the course. Hover and selection highlight
the agent's name and marker. The searchable Residents/Fleet roster supports
keyboard selection and reaches every agent across sectors, with at most 12 in each.
Available and completed residents stroll along the commons promenade and pause
between destinations. Working, queued, and attention states return residents to
their assigned workstations. Selecting or hovering an available resident pauses
its stroll for easy interaction; assigning work resumes its return to the desk.
In The Local Line, each visible agent has its own named island berth. Idle ships
usually stay near their island, with occasional longer voyages. Working agents
return and settle broadside at their island pier. The original inward approach
bearing stays unchanged, so departures still turn and sail bow-first. Adding or removing a profile preserves the
other ships' homes. `grandLineScenery.ts` supplies the ocean, RAM Belts, Thread Line,
Recurse Mountain, island landmarks, and the shared obstacles used for navigation.
A voyage chart reflects the supplied One Piece Grand Line reference; named islands,
Llamoon, Seed Kings, and SkypiAI provide One Piece references. The layout is a
fan-art interpretation rather than a canonically scaled map.

Ping Ping appears only for concrete approval or input requests. Its top-right
card uses a separately prepared Meshy snail, with accessible controls for every
pending request. Collapse and hide controls preserve your preference, and a small
**Show alerts** control restores the card. Clicking the card or a ship’s snail opens the exact request in
**Captain’s quarters**. The widget releases its graphics resources when requests
clear and respects page visibility and reduced motion. Courier skiffs visualize recent
agent handoffs and artifacts without changing the agents’ own navigation. Repeated
snapshots never replay a delivery. **Crew Chat**, **Captain’s quarters**, and the
keyboard-accessible **Ship signals** list open their native counterparts. Standalone
previews label their sample events and send no native actions.

A small One Piece-inspired crew comes ashore only when a busy ship has reached
its own berth and finished turning parallel to shore. A longer jetty and a
retractable boarding plank connect the broadside hull to its landing. They walk and work on
visible timber shore plazas, with raised surfaces above the two stone city rims.
Waiting, queued, and failed agents get quiet waiting poses; selecting an idle ship
does not create work. Crews leave before departures and remain decorative members
of the owning agent: clicking one selects that captain. Ship labels expose
`data-crew-ashore` and name the number of crew ashore.

Ship identities remain stable across status changes and roster reordering. The
Fleet list names the agent's ship. Ocean navigation uses ship-sized clearance,
open lanes, and separate berths. Wakes, gentle rocking, and animated water are
visual effects; they never start a model call or invent task activity.
`prefers-reduced-motion` disables ambient voyages, rocking, wakes, moving water,
scenery drift, character animation, and camera inertia; necessary returns to a
workstation or berth still follow the work state.
Rendering stops while hidden; closing the page disposes the scene independently
of any native tasks. Labels expose `data-status`, `data-behavior`, `data-appearance`,
`data-world-x`, and `data-world-z` for read-only integration verification.

## Adding a packaged theme

Add its safe slug and display name to `ui/themes/catalog.json`, then add
`ui/themes/<slug>/theme.json` and local `assets/*.glb` files. No application or
renderer changes are needed to select additional catalog themes.

`src/theme.ts` defines the version 1 manifest. A theme supplies its `campus` or
`ocean` environment, palette, asset paths, target model heights, optional
orientation corrections in radians,
map radius, resident station locations, decorative prop placements, obstacles,
and shared wandering destinations.
Optional station locations fall back to the outpost
campus layout. Workstation consoles sit 1.6 world units along each station's
facing direction. Navigation and rendered consoles use the same shared geometry.
Four resident appearances are balanced across the initial roster and cached by
profile UUID, so status updates and roster reordering keep each agent's look. Supported
props include station, beacon, habitat, crates, planter, lounge, and server models.
GLBs are normalized by their bounding boxes before placement. Idle and walking
animation groups are detected from their names; the supplied Meshy characters use
`Idle` and `Casual_Walk`. The explorer is an autonomous resident appearance.
Ocean themes use the twelve `ship_` asset keys in `theme.ts`. Whole-ship motion
replaces humanoid animation, so ships require neither rigs nor walking clips.
The Local Line's twelve designs follow the supplied miniature-ship image.
Its Meshy 7 quality pass targets 30,000 faces and 4K PBR source textures per ship.
`Tools/OptimizeGrandLineAssets.py` preserves original GLBs privately and keeps
all geometry bytes unchanged while preparing 2K JPEG color and 1K PNG PBR maps
for the shipped models. This reduces file size and graphics memory; transparent
color maps, if present, remain PNG. Asset templates are cached and loaded two at
a time, with visible progress during preparation.

Package GLBs with embedded textures and geometry that require no external
decoders: external URLs, Draco/Basis decoders, and worker scripts are blocked by
the page policy. Failed
assets retain built-in geometry and display a notice. Unsupported graphics keep
the resident roster available.

## Artwork accounting

Each theme carries `provenance.json` with task IDs, prompts, costs, and hashes of
the shipped assets. The Local Line also retains the supplied ship image and its
twelve isolated reference images. Its **648-credit** total includes 108 for
references, 180 for the original ship pass, and 360 for higher-detail replacements.
The Outpost's original and commons campaigns total **209 credits**, making the
combined world artwork spend **857 credits**. The shared Ping Ping alert asset
adds **44 credits**, bringing the complete prepared package to **901 credits**. Its
model is `ui/assets/models/den-den-mushi.glb`; shared artwork provenance lives
beside the shared asset folder. Generation never runs during builds,
installation, or normal exploration. Credentials and expiring provider URLs stay
out of the packaged provenance.
