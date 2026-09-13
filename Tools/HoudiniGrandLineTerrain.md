# Houdini terrain authoring

Status on 2026-09-13: **authored in Houdini 22.0.429 Apprentice**.
The actual SOP networks cooked successfully and produced an editable
[terrain study](/Users/nahid/Documents/locus-artwork/houdini/terrain-study-20260913/grand_line_terrain.hipnc)
with 37,248 cliff triangles and 37,440 mountain triangles. Every cooked vertex
passes the existing map envelopes; the mountain stays inside radius 2.5.
A separate [Mantra preview](/Users/nahid/Documents/locus-artwork/houdini/terrain-study-20260913/grand_line_terrain_preview.png)
retains the Apprentice watermark. The starting silhouettes are less finished
than the shipped Meshy artwork and remain a study for later refinement.
The [authoring report](/Users/nahid/Documents/locus-artwork/houdini/terrain-study-20260913/houdini-authoring-report.json)
records the real version, active license, bounds, and source hash.

An independent native `rop_gltf::2.0` box export under the same license failed:
“glTF export is only supported in Houdini Core and Houdini FX versions.”
The action returned but the node reported this error and no GLB was created.
The [capability report](/Users/nahid/Documents/locus-artwork/houdini/terrain-study-20260913/gltf-capability.json)
preserves that result. Houdini terrain remains an editable study; the shipped
map still uses its verified Meshy assets. No substitute exporter was used.

## Installation and licensing

The Mac is Apple Silicon with macOS 26.4.1, 32 GB RAM, and approximately 229 GiB
free disk space at inspection. Those CPU, OS, memory, and disk values meet the
corresponding published [Houdini 22 requirements](https://www.sidefx.com/Support/system-requirements/).
The installed command-line runtime and Apprentice license have now been verified.

Installed build: `/Applications/Houdini/Houdini22.0.429`.
The working interpreter is
`/Applications/Houdini/Houdini22.0.429/Frameworks/Houdini.framework/Versions/22.0/Resources/bin/hython`.
It runs without additional environment setup and reports Python 3.13.10 and
`licenseCategoryType.Apprentice`.

No credentials have been accessed or submitted, and this workflow makes no
purchases. Apprentice is a free non-commercial learning license. It is not a
substitute for an appropriate production license. The script permits an
editable study HIP and reports Apprentice’s observed native GLB export limit
when `--export` is requested. An export-capable license is required for that
path; the production map has not been replaced with Apprentice study output.
[Apprentice restrictions](https://www.sidefx.com/faq/question/apprentice-restrictions/),
[licensing setup](https://www.sidefx.com/faq/question/how-do-i-license-houdini/).

## Run the prepared workflow

From the repository root, the design-only check needs ordinary Python:

```sh
python3 Tools/HoudiniGrandLineTerrain.py --validate-design
```

After installing and licensing Houdini, open its Houdini Terminal, change to
this repository, and create a new staging directory through the script:

```sh
hython Tools/HoudiniGrandLineTerrain.py --output /tmp/locus-houdini-terrain-v1
```

To also invoke Houdini’s own GLTF exporter under an appropriate license:

```sh
hython Tools/HoudiniGrandLineTerrain.py --output /tmp/locus-houdini-terrain-v2 --export
```

`hython` includes the real `hou` module and checks out an available Houdini
license. The script does not emulate that module. Use a fresh session and an
unused staging directory; existing authoring networks, conflicting materials,
and existing output directories are refused.
[SideFX command-line scripting](https://www.sidefx.com/docs/houdini/hom/commandline.html).

The script creates an editable network for each asset:

```text
/obj/locus_terrain_authoring/<asset>
  strata_and_riverbed  (Python SOP, embedded source + terrain controls)
          ↓
  terrain_normals     (Houdini Normal SOP)
          ↓
  OUT_TERRAIN
          ↓
  EXPORT_GLB          (Houdini GLTF ROP, only with --export)
```

The source SOP exposes Terrain seed, Rock detail, Strata relief, and Riverbed
depth. Its saved implementation is embedded in the HIP so moving the project
does not break an external Python import. Layered sandstone, ledge color,
upper moss, converging carved riverbeds, and the narrow water ribbon are
explicit geometry and attributes. These are authored starting shapes requiring
visual review in Houdini, not a claim that an unrendered model is better than
the existing artwork. Python SOP geometry and `Cd` attributes follow SideFX’s
[documented authoring interface](https://www.sidefx.com/docs/houdini/hom/cb/pythonsop.html).

The output extension follows the active license (`.hip`, `.hiplc`, or `.hipnc`).
Successful real runs produce `houdini-authoring-report.json` with the Houdini
version, license category, vertex bounds, triangle counts, and source hash.
Successful exports add actual GLB hashes. Export failures stop with the
Houdini error; the workflow never creates a substitute “Houdini” GLB.

## Terrain and navigation contract

`HoudiniGrandLineTerrain.json` records the current map placements. The terrain
is authored around the local origin. The renderer retains responsibility for
world placement and normalization.

| Asset | Local envelope | Default design triangles | Existing placements |
| --- | --- | ---: | --- |
| Thread Line cliff module | 4.2 × 10.4, height ≤6.9 | 37,248 | x = −29, paired north/south ridge modules |
| Recurse Mountain | radius ≤2.5, height ≤8 | 37,440 | x = −29, z = ±6.3 |

The mountain footprint preserves the open passage between z = −3.8 and +3.8.
The tool checks every point, including water surfaces, before and after the
Houdini cook. A 42,000-triangle ceiling per asset keeps the initial authoring
output near the existing asset budget. No actor berth or navigation obstacle
is changed by the script. Seed and relief-control extrema pass the independent
design-bound checks; actual Houdini output must pass them again.

## Artist refinement and export review

For finer terrain study, a native HeightField → Noise → erosion/mask → Convert
HeightField branch can be added beside the radial cliff network, then used to
sculpt or project detail onto its fixed envelope. Heightfields suit landscape
surfaces; the polygon branch retains control over steep cliff sides and carved
channels. Reduce the converted mesh before comparison because HeightField
conversion can substantially increase memory and polygon counts.
[SideFX terrain conversion workflow](https://www.sidefx.com/docs/houdini/heightfields/workflows.html).

Inspect silhouette continuity between adjacent cliff modules, river-channel
placement, normal direction, UV seams, vertex colors, and readable strata at
the map’s normal camera distance. Keep the native glTF exporter’s Draco option
off. A `.glb` output embeds its resources in one file; glTF 2.0 and Principled
Shader materials are supported by SideFX’s exporter. The script checks the
exporter’s parameter labels, accepts Houdini 22’s Render to Disk action, and
checks node errors and file contents because the action may return despite failure.
[SideFX GLB export](https://www.sidefx.com/docs/houdini/nodes/out/gltf.html),
[supported glTF features](https://www.sidefx.com/docs/houdini/io/gltf.html).

Before replacing artwork, inspect the real exports in Locus’s Babylon preview
and native WebKit, preserve geometry and decoded pixels during packaging, and
record Houdini provenance separately from the existing Meshy generation ledger.
Only integrate a visibly reviewed export that passes the package and navigation
checks. This authoring tool never edits `plugins/agent-world` itself.
