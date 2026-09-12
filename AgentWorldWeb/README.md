# Agent World renderer

The local TypeScript/Babylon.js renderer for the Agent World Locus plugin. Its
native window, conversations, permissions, and task execution belong to Locus.

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
and makes no model calls. Native windows never add demo residents.

## Host boundary

The renderer sends version 1 `ready`, `selectAgent`, and `preferences` messages
through `window.webkit.messageHandlers.locusScreen`. Locus sends `snapshot` and
`visibility` messages to `window.locusAgentWorld.receive`. `src/state.ts` defines
and validates the contract. Agent IDs are profile UUIDs; status values describe
actual host activity. Roster buttons expose `data-agent-id` and `data-status`
attributes for UI verification.

The landscaped campus opens in a stable elevated overview. Click a resident or its name to
interact, drag the map to orbit, and scroll to zoom. Hover and selection highlight
the resident's name and floor marker. The searchable roster supports keyboard
selection and reaches every resident across sectors, with at most 12 in each.
Available and completed residents stroll along the commons promenade and pause
between destinations. Working, queued, and attention states return residents to
their assigned workstations. Selecting or hovering an available resident pauses
its stroll for easy interaction; assigning work resumes its return to the desk.
This ambient movement never starts a model call or invents task activity.
Rendering stops while hidden; closing the page disposes the scene independently
of any native tasks. Labels expose `data-status`, `data-behavior`, `data-appearance`,
`data-world-x`, and `data-world-z` for read-only integration verification.

## Adding a packaged theme

Add its safe slug and display name to `ui/themes/catalog.json`, then add
`ui/themes/<slug>/theme.json` and local `assets/*.glb` files. No application or
renderer changes are needed to select additional catalog themes.

`src/theme.ts` defines the version 1 manifest. A theme supplies its palette,
asset paths, target model heights, optional orientation corrections in radians,
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

Package GLBs with embedded uncompressed textures and geometry: external URLs,
Draco/Basis decoders, and worker scripts are blocked by the page policy. Failed
assets retain built-in geometry and display a notice. Unsupported graphics keep
the resident roster available.
