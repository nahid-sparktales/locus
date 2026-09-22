# Agent World renderer

## Current agent workflow

Select an agent or ship to open **Overview**, the same agent page used in the main
workspace. It includes settings, chats, automations, connections, and recent results.
**Chat** opens its conversation with the native tools alongside it. Use **Show tools**
or **Hide tools** to control the split view without leaving the chat.
**New chat**, **Crew Chat**, and agent editing remain available inside Agent World.
**Captain’s Quarters** opens a large, themed management deck over the ocean
(**Agent workspace** in Outpost). It keeps the searchable crew list beside the
shared agent overview, chat, and workspace tools. Calendar and Task board have
direct navigation and stay beside chat when a conversation is active. The crew
overview lists all agents as cards, even before one is selected. Accounts, Plugins, Connections, automations, Library, and
Identity Vault use the existing native controls. The task board is Locus’s shared
project board; it is not an Atlassian Jira connection. Board cards can open a new,
profile-bound chat in the world with an editable draft, without sending it.

Captain’s Quarters has a full ship-deck backdrop and defaults to warm wood,
cream, and brass. **Settings → Captain’s Quarters appearance** keeps **Ocean blue**
available; the choice persists between launches. Native sheets, editors, chat,
and tools inherit the chosen palette. The ocean map keeps its blue appearance.

Calendar always includes **Locus Calendar**, stored locally and usable without an
external account. Connected macOS calendars overlay it with separate visibility
controls. Both event and board editors include an **@ Tag an agent** picker;
tags store stable agent IDs and show current profile names. Tags identify agents;
they do not automatically dispatch work or send calendar invitations.

Click the camera on an agent’s Overview to choose a profile picture. Right-click
the picture to remove it. Pictures appear in the regular sidebar, agent picker,
overview, and world crew list. They are cropped locally to 256px thumbnails,
persisted separately from execution profiles, and excluded from plugin snapshots.

The native **Activity Center** shows live tasks, approvals, results, refresh errors,
and recovery actions. The snail communicator opens that same Activity Center.

When work starts, ships reserve the nearest free island by navigable sailing
distance. Existing reservations survive queued and attention states, and release
on completion. All twenty Local Line islands can host work. A mint glow follows
working ships until docking, then the island shoreline and beacon light up.
Decorative rendezvous never divert working ships. Reduced motion keeps signals
static. The four inward-facing island models keep their artwork orientation. Alabatcha
and Elbatch occupy the southern and central waters, leaving the Marineford triangle open.

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
`openTransfer`, `openSharedChat`, `openAgentControls`, and `createAgent` messages
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
In The Local Line, agents reserve a free named island berth when work begins. Idle ships
roam freely between destinations across the sea, with brief pauses. Working agents
choose the nearest reachable free berth and settle broadside at its pier. The original inward approach
bearing stays unchanged, so departures still turn and sail bow-first. Adding or removing a profile preserves the
other ships' homes and current routes. **New Agent** opens the native setup form
directly from the roster and adds the saved profile to the world.
`grandLineScenery.ts` supplies the ocean, RAM Belts, Thread Line,
Recurse Mountain, island landmarks, and the shared obstacles used for navigation.
A voyage chart reflects the supplied One Piece Grand Line reference; named islands,
Llamoon, Seed Kings, and SkypiAI provide One Piece references. The layout is a
fan-art interpretation rather than a canonically scaled map.
The coastlines use finer sculpted terrain, sand gradients, scattered rocks, and
blended shallow water with broken surf. Layered foliage, finished house trim,
and curved pagoda roofs add detail at close range. Map text uses filtered
textures, the ocean uses higher-resolution shadows, and both worlds render at
up to two physical pixels per CSS pixel on Retina displays.

Ping Ping appears only for concrete approval or input requests. Its top-right
card uses a separately prepared Meshy snail, with accessible controls for every
pending request. Collapse and hide controls preserve your preference, and a small
**Show alerts** control restores the card. Clicking the card or a ship’s snail opens the exact request in
**Agent workspace**. The widget releases its graphics resources when requests
clear and respects page visibility and reduced motion. Courier skiffs visualize recent
agent handoffs and artifacts without changing the agents’ own navigation. Repeated
snapshots never replay a delivery. **Crew Chat**, **Agent workspace**, and the
keyboard-accessible **Activity Center** open their native counterparts. Standalone
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
Ocean themes use the fifteen `ship_` asset keys in `theme.ts`. Whole-ship motion
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
adds **44 credits**. Later scenery and companion campaigns bring the Local Line
to **1,800 Meshy credits** and the complete package to **2,053 credits**. Its
model is `ui/assets/models/den-den-mushi.glb`; shared artwork provenance lives
beside the shared asset folder. Generation never runs during builds,
installation, or normal exploration. Credentials and expiring provider URLs stay
out of the packaged provenance.


Paradise occupies the right side of the Red Line in the default view: Twin Cape,
Little Garden, Drum, Alabasta, Water Seven, Jaya/Skypiea, Sabaody, and the
Marineford reference group. Wano, Whole Cake, Laugh Tale, Elbaf, and Egghead
remain in the New World on the left. Mary Geoise stands on the ridge above
Marineford; Impel Down sits inside the northern shipping channel, Amazon Lily occupies the northern Calm Belt, and
Enies Lobby completes the triangle. A slowly turning whirlpool marks the
Marineford current. Docks overlap the front shoreline; the Impel Down and
Amazon Lily entrances and docks face forward toward the Marineford region.

Six new Meshy reference/model pairs cost 234 credits: Mary Geoise, Impel Down,
Amazon Lily, a new Sabaody archipelago, Zunesha with Zou, and Momonosuke.
Zunesha follows a clear route beyond the leftmost islands, with alternating leg
strokes; the little pink dragon circles above Wano. Reduced motion freezes both
routes and the whirlpool. Original geometry is retained with 1K color and 512px
PBR textures for these additions and several small older models, keeping the
complete plugin below the 250 MiB installation limit. All twenty harbors remain
reachable and the twelve native captain-home indices stay stable. Mary Geoise
is a continental landmark, so ships do not berth on the cliff top.

A final 60-credit Meshy campaign adds Dressrosa, Punk Hazard, Hachinosu, and
Long Ring Long Land: four Smart Topology previews at 5 credits each, followed
by four Meshy 7.1 texture refinements at 10 credits each. Original geometry,
preview images, task lineage, and runtime hashes are retained. The first three
islands sit in the New World; Long Ring Long Land sits in Paradise. Two clear
offshore patrol points per island keep the expanded navigation graph bounded.

The Calm Belt bands share the same ±24 centerlines across both sides of the Red
Line. Main island footprints sit between their inner edges at ±20.8; Amazon Lily
is the exception, with a reachable dock at the channel edge. Hull-aware sailing
bounds apply to both captain ships and handoff couriers, so the central mountain
entrance is the only cross-sea route.

The standalone browser preview opens Captain’s Quarters as a full-window modal
using the native deck artwork (lossless WebP). It supports crew search, finding
ships, viewing the bare deck, Escape and returning to the map. Live conversations
and management tools still open through the native Locus bridge.
