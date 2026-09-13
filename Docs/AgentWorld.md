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
- In Agent World, choose **New Agent** above the Residents or Fleet list. Set
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
- Choose a world from the theme menu; Locus remembers the selection.
- Outpost uses Locus's charcoal, warm ivory, and lime palette. Its **Mixed /
  Pandas / Explorers** option offers a mixed crew, all pandas, or the original residents.
  Mixed is the default for new preferences and includes balanced pandas, people,
  and robots. Humans have visible faces, different hair and skin tones, and an
  articulated walk. Existing agents keep their kind when the roster changes.
  Locus remembers this appearance independently of the world selection. Switching
  preserves the agents' locations, routes, identities, and work.
- Click an agent, ship, or its label to interact. The searchable **Residents**
  list in Outpost and **Your fleet** list in The Local Line also provide keyboard
  access to every agent.
- Available agents explore the commons or sail the Local Line. Agents with
  active work return to their assigned workstation or berth. Selecting or
  hovering over a wandering agent pauses it so it is easy to interact with.
- The system's reduced-motion preference stops ambient wandering, ship rocking,
  wakes, moving water, and drifting scenery. Ships can still return to their
  berths when their work state changes. Camera inertia is also disabled.
- Open **Captain’s Quarters** in The Local Line, or **Agent workspace** in
  Outpost, for the full native Locus conversation and composer. It reuses the
  main page’s attachments, voice, models, tools, skills, work modes, task controls,
  approvals, questions, and inspector. The agent menu provides editing,
  management, and a new conversation. Existing permissions continue to apply.
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
- **Ship signals** lists approvals, input requests, and handoffs. **Ping Ping**, the snail communicator, appears in the top-right corner only when an approval or input request
  needs attention. Its Meshy-generated 3D model sits beside the agent and request
  label; multiple requests can be browsed individually. Collapse it to a compact
  pill or hide it; **Show alerts** restores it. This display preference is remembered. Selecting a request opens
  the exact conversation that needs attention. Courier skiffs
  visualize actual results passed between agents, once per handoff. Their detail
  view opens the receiving conversation; a shared team task is identified as such.
  The web scene receives event IDs and short labels, while complete messages and
  request details stay in native Locus.
- Each saved profile has a separate persistent conversation for each project.
  **Open in Locus** opens that same saved conversation in the main workspace.
  The world stays with the project it opened in; changing the main workspace
  does not redirect queued work. Use **Start a new conversation** in the
  resident's menu to deliberately replace that resident's saved binding.
- Closing the world releases its rendering resources. It does not stop work.
  Use the conversation's Stop action to interrupt a task.

The outpost combines planted commons, lounge areas, and workstations with four
explorer designs and four panda accessories. Pandas follow the site's original
ink/cream/lime mascot and have articulated knees, feet, arms, and idle animation.
The Local Line assigns a stable ship design and island home to each visible agent
and shows the ship and home in the Fleet list. Idle ships roam freely across the
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
The islands have sculpted shores, blended shallow water, detailed foliage and
buildings, and softer surf. Retina rendering and clearer map text preserve the
miniature detail when you zoom in.

The fleet includes Thousand Funny, Going Sherry, BaratAI, Navy Q4, Polar Tensor,
Spade Prompters’ Ship, Thread Force, Moby Disk, Perfume CUDA, Oro JSON,
Queen Llama Chanter, and Dragon’s Chip. Their miniature proportions, figureheads,
sails, and colors follow the user-supplied ship reference.

## Develop and verify

The frontend source lives in `AgentWorldWeb`. From that directory, run
`npm ci` and `npm run check`. The build writes the bundled runtime into
`plugins/agent-world/ui` and preserves the theme assets.

From the repository root, run `agent/.venv/bin/python
Tools/VerifyAgentWorldPackage.py` to validate every catalog theme, embedded GLB
resources, humanoid animation clips, ship geometry and textures, reference and
asset hashes, and the complete generation credit ledger. Use the repository's
normal Python and native test commands for the host and execution contracts.

For a standalone visual preview, serve `plugins/agent-world/ui` with a local
HTTP server. It displays a clearly marked demonstration roster when the native
Locus bridge is absent. Append `?theme=grand-line` or `?theme=outpost` to choose a
preview directly. Demonstration residents and ships cannot start real agent tasks. Sample alerts and
couriers are explicitly labeled, and their buttons explain the native behavior.
Append `&residentStyle=mixed` to the Outpost preview to show pandas, people, and robots together.

## Add a theme

Register a theme in `ui/themes/catalog.json`. Its directory contains `theme.json`,
`provenance.json`, and self-contained GLB files. The version-1 manifest describes
the theme ID, name, description, environment (`campus` or `ocean`), palette, asset
paths, target model heights, orientation corrections, and optional map layout.
The layout can set the map radius, resident workstation positions, navigation
landmarks, and decorative props. All asset paths stay within the installed
plugin. Use embedded textures and geometry without external
Draco, Basis, or meshopt decoders.

Humanoid characters carry idle and walking animation clips, selected by their
clip names. Ocean themes use the twelve `ship_` asset types and animate each ship
as a whole, so ship GLBs do not require humanoid rigs or walking clips. Missing
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

The Local Line campaign totals **648 credits**: 108 for twelve isolated reference
images, 180 for the first twelve textured ship models, and 360 for twelve
higher-detail Meshy 7 replacements. The full first pass remains in the accounting
even though the replacements are shipped. The quality pass targets 30,000 faces
per ship and uses 4K PBR source textures. The packaged ships retain that geometry
and use 2K color textures with 1K normal and metallic/roughness maps to reduce
loading time and graphics memory. Opaque color textures use high-quality JPEG;
PBR maps remain PNG. `Tools/OptimizeGrandLineAssets.py` preserves the original
GLBs outside the repository and verifies that geometry bytes remain unchanged.
The shipped-file hashes in provenance identify the exact artwork loaded by the
plugin. The supplied ship image and twelve generated
references are retained locally with their hashes.

The shared Ping Ping alert asset adds **44 credits**: 9 for its reference
image and 35 for a textured Meshy 7 Ultra model. Its original 20,000-face geometry
is preserved; the package uses 2K color and 1K PBR textures. Shared artwork and its
separate ledger live in `ui/assets`, so the model is counted once across themes.

The two worlds and shared alert artwork account for **901 credits**, below 1,000. No credits are
used to install, open, or explore either world. Submitting the same prompts again
is not guaranteed to reproduce identical models.

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
