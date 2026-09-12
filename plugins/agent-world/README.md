# Agent World for Locus

Enter Orbital Outpost, meet your saved agents as 3D characters, and chat or
assign work through a native Locus conversation panel.

Requires a Locus build supporting version-1 plugin screens. Install this
package through Locus Extensions, then choose Open or use the Work menu.
The first theme, the Babylon.js runtime, and five prepared Meshy models are
included. No generation service or API key is needed to use the plugin.

Click an agent or its label to interact. Drag to orbit the overview camera and
scroll to zoom. The resident list provides keyboard and search access to every
agent. Closing the window does not stop agent tasks.

The plugin requests:

- `agents.read`: display saved agent names, roles, and activity labels.
- `agents.interact`: select an agent to open Locus's native conversation panel.
- `world.preferences`: remember the selected world theme.

Credentials, model calls, transcripts, and tool approvals stay in native Locus.
The screen receives no API keys. The local world makes no network requests.

See `ui/themes/outpost/provenance.json` for generated asset provenance and
credit accounting. Source and development documentation are in the Locus
repository's `AgentWorldWeb` directory and `Docs/AgentWorld.md`.

## Notices

Locus Agent World is licensed under Apache-2.0; see LICENSE. Babylon.js 9.26.0
is copyright The Babylon.js team and licensed under Apache-2.0; the upstream
license and notices are in `licenses/`. Babylon's optional network-loaded
decoders and WebGPU compiler binaries are not used by this package.

Artwork was generated with Meshy for this project. The included provenance
records identify the original generation tasks and prompts. Meshy is the
asset-generation service, not a runtime dependency or sponsor of Locus.
