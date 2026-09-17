# Agent World

Agent World is an optional Locus plugin. It opens a separate 3D window populated
by the user's saved agent profiles. Choose **Orbital Locus Outpost** for a planted
space campus or **The Local Line** for a One Piece-inspired ocean where each
agent has its own ship. Conversations and work run through Locus's existing
providers and permissions. Exploring either world makes no model calls.

## Install and enter

Build the Locus version containing plugin screen support. In Settings →
Extensions, add this repository directory as a local marketplace if it has not
already been discovered from the current workspace. Install **Agent World**,
review its screen capabilities, and choose **Open**. Installed screens also
appear in the Work menu.

The repository's `.agents/plugins/marketplace.json` points to the distributable
package at `plugins/agent-world`. The web runtime and prepared assets are
included in that package. Users do not need Node, a Meshy account, or a Meshy
API key. Installing this plugin in a Locus version without screen support does
not provide a launchable world. This is a Locus screen extension, not a Codex
screen extension.

## Meet your agents

- In Locus’s **Agent** page, choose **New Agent** to use the same setup form as
  Agent World. Saving creates a named sidebar group and its first chat. Saved
  agents also appear as residents in the world.
- In Agent World, choose **New Agent** in the Residents sidebar. Set
  the agent’s name, model, instructions, and access in the native setup form.
  Saving adds the agent to the world; the other agents keep their locations
  and routes. Select the new agent whenever you want to start a conversation.
- **Manage Agent → Add…** offers **New chat**, **On a schedule**, **When an event
  arrives**, and **When a price changes**. Each conversation and automation
  stays with that agent and uses its saved model, instructions, and access.
- Choose **Move map** to drag across the ocean, or **Rotate** to orbit. Arrow keys
  and WASD also move the map; scroll to zoom and **Reset view** restores the overview.
  The widened Local Line has spaced islands and berths, with RAM Belts farther
  north and south. Ships turn toward their course before sailing bow-first.
- Choose a world from the native top toolbar beside **Crew Chat** and **Residents**;
  Locus remembers the selection. The ocean has no duplicate fleet panel or theme
  picker over the map. Its upper-right corner holds **Den Den Dispatch**, flush with the top border; Outpost
  has its own communications beacon.
- Outpost uses Locus's charcoal, warm ivory, and lime palette. Its **Mixed /
  Pandas / Explorers** option offers a mixed crew, all pandas, or the original residents.
  Mixed is the default for new preferences and includes balanced pandas, people,
  and robots. Humans have visible faces, different hair and skin tones, and an
  articulated walk. Existing agents keep their kind when the roster changes.
  Locus remembers this appearance independently of the world selection. Switching
  preserves the agents' locations, routes, identities, and work.
- Click an agent, ship, or its label to interact. The searchable native
  **Residents** sidebar provides keyboard access to every agent. Compact captain cards
  use detailed ship portraits and show the assigned ship, home island, and current status.
  Each row has a visible **New chat** action; the sidebar starts at 206 points wide. Fleet management,
  Crew Chat, Captain’s Quarters, and attention shortcuts live here.
- Choose **Ship style** on a resident card, or from the agent actions menu in
  Captain’s Quarters, to assign any of the fifteen boats. **Automatic** restores
  that profile’s original automatic boat assignment; the original twelve styles
  remain the automatic pool. Locus saves explicit choices per profile and screen.
  Changing a boat preserves the agent, conversation, home island, location, and
  work state. It does not move the agent to another account or start a task.
- Available agents explore the commons or sail the Local Line. Agents with
  active work return to their assigned workstation or berth. Selecting or
  hovering over a wandering agent pauses it so it is easy to interact with.
- The ocean uses a seamless local ripple-normal texture at several flowing scales,
  soft sky reflections and sun glints, turquoise depth transitions, and broken
  foam at each island's actual shoreline. Ship wakes curve and fade into the
  sea. The material has one small texture and does not fetch remote imagery or
  use extra reflection render targets. These effects add no Meshy credits.
- The system's reduced-motion preference stops ambient wandering, ship rocking,
  wakes, moving water, and drifting scenery. Ships can still return to their
  berths when their work state changes. Camera inertia is also disabled.
- Open **Captain’s Quarters** in The Local Line, or **Agent workspace** in
  Outpost, for the full native Locus conversation and composer. It reuses the
  main page’s attachments, voice, models, tools, skills, work modes, task controls,
  approvals, questions, and inspector. The agent menu provides editing,
  management, ship style, and a new conversation. The ocean workspace uses the
  map’s navy, teal, ivory, and brass palette, with **Captain’s log**, **Vivre card**
  (agent details), **Tools**, and **Crew Chat** tabs. The Vivre card belongs to the
  selected agent and remains available when its old conversation is missing. Missing
  conversations offer an explicit new-chat recovery action; a connection failure
  remains retryable and does not silently replace the conversation. Outpost retains its charcoal and lime
  workspace. The top-bar expand control gives the conversation more room or
  restores the map alongside it. Existing permissions continue to apply.
- **Crew Chat** is available from the main Agent page and both worlds. Both
  surfaces share the same persisted history for a project. Every saved agent is
  a member, but only explicitly tagged agents or agents whose declared skills
  match the request are selected to reply. Use `@Name` or the member buttons;
  ambiguous or unknown mentions need clarification. There is no all-agent
  broadcast fallback. The composer previews recipients before sending.
- Crew replies use real separate conversations for the selected saved profiles,
  including their models, access restrictions, and the normal Locus queue. The
  shared history supplies recent context; each reply shows its real progress and
  can be stopped or opened in the native conversation. Restoring history never
  reruns unfinished tasks. A world pinned to another project does not show that
  project’s messages by accident.
- In The Local Line, the persistent 3D **Den Den Dispatch** button opens and closes
  **Activity Center**. In Outpost, a separate packaged Meshy **Comms beacon** opens
  **Mission Control**, using Outpost’s charcoal and lime theme. Outpost does not
  load the Den Den model. Switching themes replaces the communicator artwork
  while retaining the center’s open state and selected tab. The Outpost beacon
  reuses existing artwork and adds no generation credits.
- The center’s **Attention** tab contains actual approval and input requests,
  plus status-only entries for agents needing review when no explicit request
  already represents them. A failed status is not presented as an approval.
  **Activity** shows current working and queued agents, completed states, and
  recorded handoffs and artifacts, with deliveries ordered newest first. This is
  a view of native state and recorded transfers, not a synthetic task history.
  Request actions open the exact conversation containing that request; delivery
  actions open the real transfer details; agent status entries open that agent’s
  conversation.
  Complete messages and sensitive details remain in the native workspace.
- Both communicators remain available with zero requests. The Den Den rings only
  when attention exists. Counts, empty states, keyboard-operated tabs, visible
  focus, and Escape make the center usable without navigating the 3D scene.
  Residents has a matching shortcut. The standalone preview labels its sample
  activity as Demo and cannot send it as real agent work.
- Real recent handoffs or artifact transfers can trigger an **Alliance
  rendezvous** when both ships are visible, free of pending attention, and a
  reachable berth is available. The visitor sails alongside its partner; a
  gangplank and mooring lines appear once both ships settle. Afterwards normal
  movement resumes. At most two rendezvous run together, and recorded transfers
  are not replayed merely because another snapshot arrives.
- Pairs of stationary ships whose agents are actually working can exchange
  playful **cannon practice** volleys, with arcing cannonballs, smoke, and water
  splashes short of the other hull. At most two pairs participate. This animation
  creates no damage, conflict, chat message, or collaboration record. Pending
  attention takes priority; reduced motion disables rendezvous and cannon effects.
- Nearby idle ships have a **75% chance** to interact once per close encounter.
  Of those interactions, **55%** are playful cannon exchanges and **45%** are
  relaxed side-by-side visits with mooring lines. Ships must separate before
  another chance is rolled, with a 70-second cooldown and at most two encounters.
  Actual work, attention, selection, or real transfers take priority immediately.
- A working island gains a soft mint-and-gold shoreline glow and a small gold
  beacon only after its own working ship has settled at its home berth, facing
  the pier. Idle, returning, queued, failed, or waiting agents do not light an
  empty work area, and a visiting ally does not activate the host island’s work
  light. The glow remains steady with reduced motion enabled.
- Small **News Coo** flocks occasionally glide and flap through both worlds,
  wearing pilot caps and carrying newspaper bags. These ambient visits are
  independent of real messages or agent activity and use local geometry rather
  than paid assets. Reduced motion hides the birds entirely.
- Detailed Meshy **Laboon** and **Sea King** models inhabit the cape and RAM Belts.
  Click Laboon, then press **E** or choose **Sing along** for a short swaying dance,
  musical notes, and rotating messages. **Escape** closes the bubble. Reduced
  motion preserves the response without moving him; no audio or agent task starts.
- The fourteen destinations form an irregular archipelago with radii from 1.2 to
  3.5 world units. Larger Alabasta, Water 7, Wano, Elbaf, and Egghead contrast with
  smaller ports. The original twelve homes remain stable; ships can also visit
  Elbaf and Egghead. Harbor routes, shore effects, obstacles, and the Log Pose
  chart use the same geography.
- Each saved profile has a separate persistent conversation for each project.
  **Open in Locus** opens that same saved conversation in the main workspace.
  The world stays with the project it opened in; changing the main workspace
  does not redirect queued work. Use **New chat** on the resident card or **New conversation** in the
  resident's menu to deliberately replace that resident's saved binding.
- Closing the world releases its rendering resources. It does not stop work.
  Use the conversation's Stop action to interrupt a task.

The outpost combines planted commons, lounge areas, and workstations with four
explorer designs and four panda accessories. Pandas follow the site's original
ink/cream/lime mascot and have articulated knees, feet, arms, and idle animation.
The Local Line assigns a stable ship design and island home to each visible agent
and shows the ship and home in Residents. Idle ships roam freely across the
sea, pause briefly between destinations, and return to their pier when work begins. At the berth they turn side-on to the
pier. A small crew appears in its island work area after the ship settles, walks
and works there, and leaves before departure. Eight locally built character
designs evoke Luffy, Zoro, Chopper, Nami, Robin, Franky, Jinbei, and Marines.
They use no Meshy credits and follow reduced-motion preferences.
Adding or removing an agent preserves the other visible ships' island homes.
Fleets and outpost sectors show up to
twelve agents at a time; the roster reaches agents in every sector. A missing
profile, unavailable account, disconnected worker, or failed 3D renderer is shown
explicitly; the world never substitutes a different model account.

The Local Line follows the supplied map reference: an ocean route between two
RAM Belts crosses the Thread Line at Recurse Mountain. A voyage chart accompanies
the scene. Landmarks include Twin Cache and Llamoon, Little Gradient, DRAM Island,
Alabatcha, Water 7B, Enies LoRA, Sabaudio, Machineford, Wano Weights, Whole Cache,
LoRA Tale, JAXa, and floating SkypiAI. Seed Kings appear in the RAM Belts. Ship routes
use the same island and Thread Line obstacles as the scene, with open sailing lanes
and twelve berths. This is an unofficial fan-art interpretation, not a
canonically scaled map.
Fourteen detailed Meshy assets provide twelve destination islands, floating
SkypiAI, and the Thread Line cliffs. A fifteenth scenery asset supplies Recurse
Mountain itself, with sculpted red-rock strata, river channels, and a waterfall.
Its paired mountain faces frame the Thread Line passage. Flowing waterfall
highlights and soft spray at the foot of the falls stay still under reduced
motion, as do the water effects at Water 7B.
Each uses a 40,000-face geometry target with painted stone, foliage, and
architecture. The island footprints stay within their harbors and sailing lanes;
blended shallows and surf join the coastlines to the ocean. Llamoon, drifting
resin bubbles, and the Knock Up Stream add life around the models. Retina
rendering and clearer map text preserve miniature detail when zooming in.

The fleet includes Thousand Funny, Going Sherry, BaratAI, Navy Q4, Polar Tensor,
Spade Prompters’ Ship, Thread Force, Moby Disk, Perfume CUDA, Oro JSON,
Queen Llama Chanter, Dragon’s Chip, **Mihawk’s Coffin Boat**, **Garp’s Battleship**,
and **Marine Patrol**. The first twelve follow the supplied ship reference.
The three additions provide a small gothic coffin craft, Garp’s dog-figurehead
battleship, and a conventional white-and-blue Marine vessel. These are fifteen
selectable styles, not an increase to the twelve simultaneously visible agents.

## Develop and verify

The frontend source lives in `AgentWorldWeb`. From that directory, run
`npm ci` and `npm run check`. The build writes the bundled runtime into
`plugins/agent-world/ui` and preserves the theme assets.

The packaging verifier also needs Pillow with WebP support in its development
environment (`agent/.venv/bin/python -m pip install Pillow`). This is a tooling
dependency; the app decodes its textures locally without Python image libraries.
From the repository root, run `agent/.venv/bin/python
Tools/VerifyAgentWorldPackage.py` to validate every catalog theme, embedded GLB
resources, humanoid animation clips, ship geometry and textures, reference and
asset hashes, and the complete generation credit ledger. Use the repository's
normal Python and native test commands for the host and execution contracts.

For a standalone visual preview, serve `plugins/agent-world/ui` with a local
HTTP server. It displays a clearly marked demonstration roster when the native
Locus bridge is absent. Append `?theme=grand-line` or `?theme=outpost` to choose a
preview directly. In the standalone ocean preview, a compact **Residents** button
opens a searchable drawer with a **Boat** selector for every profile. Demo boat
choices are stored only in that browser’s local storage. Native snapshots remain
authoritative inside Locus and ignore demo preferences. Opening the drawer closes
the activity center, and opening the center closes the drawer.

Demonstration residents and ships cannot start real agent tasks. Sample alerts
and couriers are explicitly labeled, and their buttons explain native behavior.
Append `&residentStyle=mixed` to the Outpost preview to show pandas, people, and
robots together. Check both theme-specific communicators, zero-attention states,
keyboard selection, theme switching, and system reduced motion when verifying UI
changes. The source tests also cover style validation, stale identities, ship
swaps, island work signals, News Coo flight timing, and encounter eligibility.

## Add a theme

Register a theme in `ui/themes/catalog.json`. Its directory contains `theme.json`,
`provenance.json`, and self-contained GLB files, optionally wrapped in explicit
`.glb.gz` containers. The version-1 manifest describes
the theme ID, name, description, environment (`campus` or `ocean`), palette, asset
paths, target model heights, orientation corrections, and optional map layout.
The layout can set the map radius, resident workstation positions, navigation
landmarks, and decorative props. All asset paths stay within the installed
plugin. Use embedded textures and geometry without external
Draco, Basis, or meshopt decoders.

Humanoid characters carry idle and walking animation clips, selected by their
clip names. Ocean themes support fifteen `ship_` asset types and animate each
ship as a whole, so ship GLBs do not require humanoid rigs or walking clips.
`DEFAULT_SHIP_ASSET_TYPES` preserves the original twelve automatic assignments;
`SHIP_ASSET_TYPES` includes the three explicitly selectable additions. Missing
artwork uses simple geometry so agents remain reachable. Changing artwork or a
map does not change profile IDs, conversations, provider routes, or permissions.

## Asset provenance and regeneration

The prepared assets were generated using Meshy for this project. Their prompts,
task IDs, hashes, and credit totals are recorded in the theme's
`provenance.json`. Babylon.js retains its Apache-2.0 license; packaged notices
are included with the plugin.

Orbital Locus Outpost used **209 Meshy credits**: 112 for the original campaign and 97
for the commons expansion. Its eleven models include four animated resident
designs and seven scenery models; the original explorer is reused as a resident.
The panda and human characters are original procedural geometry, with no additional
Meshy credits. Their materials and joint animations are created locally by the renderer.

The original Local Line ship campaigns total **648 credits**: 108 for twelve
isolated reference images, 180 for the first twelve textured ship models, and
360 for twelve higher-detail Meshy 7 replacements. The full first pass remains
in the accounting even though the replacements are shipped. The quality pass
targets 30,000 faces per ship and uses 4K PBR source textures. The packaged ships retain that geometry
and use 2K color textures with 1K normal and metallic/roughness maps to reduce
loading time and graphics memory. Opaque color textures use high-quality JPEG;
the final package stores PBR maps in lossless WebP.
`Tools/OptimizeGrandLineAssets.py` preserves the original GLBs outside the
repository and verifies that geometry bytes remain unchanged.
The shipped-file hashes in provenance identify the exact artwork loaded by the
plugin. The supplied ship image and twelve generated
references are retained locally with their hashes.

The shared Den Den Mushi alert asset adds **44 credits**: 9 for its reference
image and 35 for a textured Meshy 7 Ultra model. Its original 20,000-face geometry
is preserved; the package uses 2K color and 1K PBR textures. Shared artwork and its
separate ledger live in `ui/assets`, so the model is counted once. The ocean
communicator uses it; Outpost uses its already-accounted-for beacon instead.

The additional approved campaigns add **858 credits** in total:

| Campaign | References | Textured models | Total |
| --- | ---: | ---: | ---: |
| Fourteen islands and cliffs | 126 | 420 | **546** |
| Mihawk, Garp, and Marine Patrol ships | 27 | 90 | **117** |
| Recurse Mountain | 9 | 30 | **39** |
| Laboon and Sea King | 18 | 60 | **78** |
| Elbaf and Egghead islands | 18 | 60 | **78** |
| **Additional campaigns combined** | **198** | **660** | **858** |

These campaigns use 40,000-face target Meshy 7 models with 4K source textures.
Packaging keeps the original geometry and uses 2K color with 1K PBR maps.
`Tools/GenerateGrandLineIslands.py` runs a supplied plan with its exact approved
credit ceiling, hidden key input, durable reservations, and private resumable
state. The plans are `Tools/GrandLineIslandPrompts.json`,
`Tools/GrandLineShipExpansionPrompts.json`,
`Tools/GrandLineMountainPrompts.json`, `Tools/GrandLineCreaturePrompts.json`, and
`Tools/GrandLineNewWorldPrompts.json`. Credentials are never packaged.

The final size-reduction pass checks all thirty-four Local Line models and the eleven
Outpost models, replacing embedded PNG textures with lossless WebP through
`EXT_texture_webp` where the result is smaller. Outpost’s four resident models
benefit; its seven scenery models keep their prepared textures. This pass
preserves every decoded RGBA pixel, texture dimension,
and geometry byte from the prepared runtime models. WebKit and the bundled
Babylon loader decode these embedded textures locally; no external decoder or
texture request is needed. Verification checks the decoded pixel and geometry
hashes against retained originals. Reference proofs use quality-94 JPEG at the
same dimensions; their original PNGs remain outside the repository. This pass
changes no rendered model detail and uses no Meshy credits.

The package then wraps each theme model in deterministic gzip without changing
a single decompressed GLB byte. The manifest points to the explicit `.glb.gz`
file; `assetBytes.ts` fetches it locally, expands it with the browser’s built-in
`DecompressionStream`, and passes the binary GLB to Babylon. The Outpost alert
beacon uses the same loader; the shared Den Den model remains a plain GLB. Both
the native WebKit host and standalone browser use this path, without a CDN or
external decoder. `container_encoding` records compressed and decompressed
hashes and byte counts, preserving the existing texture-encoding history.
Original containers are backed up privately before public uncompressed copies
are removed. This saves package space without reducing texture resolution,
rendered detail, materials, rigs, or animation.

`Tools/PackageGrandLineIslands.py` accepts repeated `--state-dir` arguments for
completed approved campaigns. `--compact --gzip-containers --require-complete`
performs the final encoding and release gate without making paid API calls.
The complete Local Line inventory is **34 models, 80 paid tasks, and 34
reference images**, retaining all 36 records from the original ship campaigns.
The strict verifier also checks exact file inventories, decoded pixels,
geometry fingerprints, container expansion limits, and the unchanged 250 MiB
plugin size limit. The final package is approximately **239.9 MiB**.

The Local Line’s lifetime asset total is **1,506 credits**: 648 from its original
ship campaigns plus these 858 additional credits. Including Outpost’s 209 credits and
the shared Den Den model’s 44 credits, the full package accounts for
**1,759 Meshy credits**. Procedural characters, News Coo, work glows, and encounter
effects add no credits. No credits are used to install, open, customize boats,
or explore either world. Regenerating the same prompts is not guaranteed to
produce identical artwork.

`Tools/GenerateAgentWorldAssets.py` is the developer-only utility for the original
and commons Outpost campaigns. The Local Line was prepared separately through
the Meshy image workflow; its public ledger records reference, baseline, and
quality-pass tasks. The Outpost utility reads the Meshy key from a hidden prompt
or `MESHY_API_KEY`, keeps the key in
memory, and reserves the documented credit cost before every submission. It
flushes reservations to disk before making paid requests and refuses a ceiling
of 1,000 or more. API redirects are rejected so authorization cannot be
forwarded to another host. A private state directory outside the
repository stores expiring provider responses and the durable ledger; resume
with that same directory and generation script to avoid submitting duplicate
tasks or relabeling older outputs with changed prompts. The utility rejects a
state directory inside this repository. Missing completed output files are
downloaded again from the existing tasks without new generation. Uncertain
submissions require reconciliation rather than an automatic retry. Failed
tasks remain recorded and are not automatically regenerated.

The ceiling bounds the recorded reservations using the prices in this script;
check those prices against Meshy's current pricing before starting a new asset
campaign. Keep the existing state directory when resuming a campaign. The
`commons` campaign requires the completed original ledger through
`--prior-ledger`; both ledgers count toward `--total-credit-ceiling`. Its
additional campaign ceiling cannot exceed 200 credits. Resume configuration is
bound to the original prompts, animation IDs, and prior ledger hash.

Asset generation is never part of plugin installation, startup, or normal use.
