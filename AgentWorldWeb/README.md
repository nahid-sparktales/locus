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

Keyboard movement is camera-relative, collision handling uses a bounded flat
map, and each sector contains at most 12 residents. The searchable roster reaches
every resident across sectors. Rendering stops while hidden; closing the page
disposes the scene independently of any native tasks.

## Adding a packaged theme

Add its safe slug and display name to `ui/themes/catalog.json`, then add
`ui/themes/<slug>/theme.json` and local `assets/*.glb` files. No application or
renderer changes are needed to select additional catalog themes.

`src/theme.ts` defines the version 1 manifest. A theme supplies its palette,
asset paths, target model heights, optional orientation corrections in radians,
map radius, player spawn, resident station locations, and decorative prop
placements/collision radii. Optional station locations fall back to the outpost
ring. Workstation consoles sit 1.15 world units outward from each resident.
GLB models are normalized by their bounding boxes before placement. Idle and
walking animation groups are detected from their names; the supplied Meshy
characters use `Idle` and `Casual_Walk`.

Package GLBs with embedded uncompressed textures and geometry: external URLs,
Draco/Basis decoders, and worker scripts are blocked by the page policy. Failed
assets retain built-in geometry and display a notice. Unsupported graphics keep
the resident roster available.
