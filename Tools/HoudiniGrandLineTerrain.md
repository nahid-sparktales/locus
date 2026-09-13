# Houdini terrain authoring

Status on 2026-09-13: **authored in Houdini 22.0.429 Apprentice**.
The actual SOP networks cooked successfully and produced the editable
`grand_line_terrain.hipnc` study with 37,248 cliff triangles and 37,440 mountain triangles. Every cooked vertex
passes the existing map envelopes; the mountain stays inside radius 2.5.
A separate `grand_line_terrain_preview.png` Mantra preview
retains the Apprentice watermark. The starting silhouettes are less finished
than the shipped Meshy artwork and remain a study for later refinement.
The generated `houdini-authoring-report.json`
records the real version, active license, bounds, and source hash.

An independent native `rop_gltf::2.0` box export under the same license failed:
“glTF export is only supported in Houdini Core and Houdini FX versions.”
The action returned but the node reported this error and no GLB was created.
The generated `gltf-capability.json` preserves that result. A separately requested
interchange workflow uses Houdini's supported native PLY export, then Blender's
own importer and GLB exporter. The shipped map still uses its verified Meshy
assets; these terrain conversions remain study deliverables.

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
purchases. Apprentice is a free non-commercial learning license. The authoring
script saves an editable study HIP and reports Apprentice’s observed native
GLB export limit when `--export` is requested. An export-capable license is
required for that native GLB path. The separate PLY-to-Blender workflow records
the source Apprentice license in its report and exported object metadata.
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

## Convert the study through Blender

`ConvertHoudiniTerrainWithBlender.py` runs real Houdini and Blender background
processes, preserving the original HIP and active application sessions. Native
PLY export has been verified in Houdini 22.0.429 Apprentice; the installed
Blender used for conversion is 5.1.2. This path does not invoke Houdini's GLTF ROP.

Pass installed executable paths and a new, unused output directory. For example,
from a Houdini Terminal with `hython` on `PATH`:

```sh
python3 Tools/ConvertHoudiniTerrainWithBlender.py \
  --source-hip /path/to/terrain-study/grand_line_terrain.hipnc \
  --output /path/to/terrain-study/blender-conversion-v1 \
  --hython "$(command -v hython)" \
  --blender /Applications/Blender.app/Contents/MacOS/Blender
```

The native Houdini PLY files retain source positions and triangle connectivity.
Companion `.attributes.json` files carry float `Cd` colors, corner UVs and normals,
and face material assignments; PLY alone cannot preserve that complete material
representation. Corner attributes are removed only from an in-memory export copy
to prevent PLY from splitting vertices. The saved Houdini network is unchanged.
Blender imports the PLY geometry, verifies its complete point and face order,
then reconstructs the original attributes and Principled materials. Sandstone
and water keep their source roughness and vertex colors. The converter explicitly
supports the study's white base tint, enabled point colors and no base texture;
edited shader settings outside that subset stop conversion rather than silently
changing the material.
[SideFX geometry saving](https://www.sidefx.com/docs/houdini/hom/hou/Geometry.html#saveToFile).

In this HIP, all cooked corner normals oppose the outward PLY triangle cross
products. Blender negates those shading normals while preserving polygon and
corner order, recording `source_corner_normal_sign_correction: -1` in the report
and `source_normal_sign_correction` in GLB extras. A consistently aligned source
keeps its normals; mixed normal orientation stops for inspection. This explicit
application-convention correction fixes exterior shading without changing shape.

The output directory contains:

- `scenery_red_line.ply` and `scenery_reverse_mountain.ply`, with attribute sidecars.
- `scenery_red_line.glb` and `scenery_reverse_mountain.glb`, exported by Blender
  with normals, UVs, vertex colors, materials and embedded resources.
- `grand_line_terrain_converted.blend`, an editable scene with the two forms
  arranged side by side, plus review lights, ground and camera.
- `blender_terrain_preview.png`, a 1500 × 1100 Cycles render of that review scene.
- `houdini-interchange-report.json` and `blender-conversion-report.json`, recording
  real application versions, source provenance, hashes, counts and bounds.

Individual GLBs keep the source local origin and unit scale. Houdini's Y-up
coordinates are converted to Blender's Z-up for editing, then back to glTF Y-up
on export. The review layout offsets, ground and lights are excluded from those
individual assets. The workflow checks the exported GLB triangle counts, local
bounds, expected attributes and absence of external dependencies; a mismatch
fails conversion. Blender then reimports the actual GLBs, checks their dimensions
and triangle counts again, and uses those meshes for the editable review scene
and render. The source HIP hash is checked before and after processing.

Conversion preserves the existing terrain study; it does not refine its shapes
or automatically replace any map artwork. Improve the Houdini network and review
the result before considering asset integration.

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
