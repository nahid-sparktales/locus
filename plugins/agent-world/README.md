# Agent World for Locus

Meet your saved agents in **Orbital Locus Outpost**, or set sail in **The Local Line**
with a separate ship for each agent. Chat and assign work through a native
Locus conversation panel.

Requires a Locus build supporting version-1 plugin screens. Install this
package through Locus Extensions, then choose Open or use the Work menu.
Both themes, the Babylon.js runtime, eleven Outpost models, and twelve Local
Line ships are included. No generation service or API key is needed to use the
plugin.

Choose a world from the theme menu. Click an agent, ship, or its label to
interact. Choose **Move map** to drag across the world or **Rotate** to orbit.
Arrow keys and WASD also pan; scroll to zoom and **Reset view** restores the
overview. Ships turn before sailing and keep their bows aligned with their routes.
The Residents or
Fleet list provides keyboard and search access to every agent, with up to twelve
visible in each sector. Closing the window does not stop agent tasks.

Free agents wander through the planted commons and pause at landmarks. Agents
with work return to their assigned stations. Four resident designs, lounge
areas, hydroponic planters, and computation stations give the campus variety.
Outpost matches Locus's charcoal, ivory, and lime colors. **Mixed** is the default
Agent Appearance for new preferences: pandas, human characters with varied faces
and hair, and robots share the campus. **Pandas** and **Explorers** remain available.
The choice is remembered, and existing agents keep their kind as the roster changes.
Pandas and humans have articulated walking and idle animation.

In The Local Line, each ship has its own island and pier. Idle agents mostly
patrol near home, with occasional longer voyages; working agents return and dock
side-on at their island. Once settled, a small One Piece-inspired crew walks and
works in the shore plaza; it leaves before the ship departs. Eight articulated
character designs are built locally without additional generation credits. Each agent keeps its own ship design, named in the Fleet list. The
twelve ships include Thousand Funny, Going Sherry, BaratAI, Navy Q4, Polar Tensor,
Spade Prompters’ Ship, Thread Force, Moby Disk, Perfume CUDA, Oro JSON,
Queen Llama Chanter, and Dragon’s Chip. The fleet follows the supplied miniature
reference, with higher-detail Meshy 7 geometry prepared from 4K PBR source
textures. The included ships preserve that geometry and use 2K color and 1K PBR
maps for faster loading and lower graphics memory.

Recurse Mountain crosses the Thread Line between two RAM Belts. A voyage chart,
Llamoon, Seed Kings, SkypiAI, and islands including Alabatcha, Water 7B, Wano Weights,
and Whole Cache bring One Piece references into the map. Routes avoid the same
islands shown in the scene. The system reduced-motion setting stops ambient
sailing, rocking, wakes, moving water, and drifting scenery.

**Crew Chat** is shared with the main Agents page. Mention a member with `@` or
let the recipient preview select agents whose declared skills match your request.
Only selected members reply through their own saved models and permissions.
**Captain’s Quarters** opens the full native Locus chat, composer, inspector,
agent editing, and task controls. Approvals and input requests appear in the
**Ping Ping** card at the top right; selecting one opens the exact request. Collapse the card
to a pill or hide it, then use **Show alerts** to restore it. This choice is remembered.
**Ship signals** lists these alerts and actual context/result handoffs. Courier
skiffs carry those handoffs between islands once per event.

The plugin requests:

- `agents.read`: display saved agent names, roles, and activity labels.
- `agents.interact`: select an agent to open Locus's native conversation panel.
- `world.preferences`: remember the selected world theme and resident appearance.

Credentials, model calls, transcripts, and tool approvals stay in native Locus.
The screen receives no API keys. The local world makes no network requests.

Each theme's `provenance.json` records asset provenance and credit accounting.
The Local Line totals **648 Meshy credits**, including its initial ship pass and
higher-detail replacements; Outpost totals **209**, for **857 credits** across
both worlds before shared artwork. The Meshy 7 Ultra Ping Ping adds **44**,
for a combined **901 credits**. Its shared ledger is in `ui/assets/provenance.json`. Opening or using the plugin spends no Meshy credits. Source and
development documentation are in the Locus repository's `AgentWorldWeb` directory
and `Docs/AgentWorld.md`.

## Notices

Locus Agent World is licensed under Apache-2.0; see LICENSE. Babylon.js 9.26.0
is copyright The Babylon.js team and licensed under Apache-2.0; the upstream
license and notices are in `licenses/`. Babylon's optional network-loaded
decoders and WebGPU compiler binaries are not used by this package.

The panda and human characters are original procedural artwork and cost no
additional Meshy credits. Pandas are inspired by Locus's website mascot. Other
models were generated with Meshy for this project. The included provenance
records identify all generation tasks, prompts, and shipped-file hashes. Meshy is
the asset-generation service, not a runtime dependency or sponsor of Locus.
The Local Line is unofficial One Piece fan art based on user-supplied references.
One Piece and the original reference designs belong to their respective rights holders.
The Local Line uses playful AI-inspired display names; the stable `grand-line` theme
ID and original asset filenames are retained for saved-setting compatibility.
