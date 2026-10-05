# Directional gaze artwork supplement

Ninja, Clover, Shadow, and Pirate gained 16 generated directional-look frames on
October 5, 2026 at the repository owner's request. Each edit used that character's
approved v1 atlas as its sole reference, after inspecting it. Generation used the
built-in imagegen tool with `transparent_background: true`; no CLI/API fallback,
new provider account, external download, or image-to-3D process was used.

This supplement extends [the original artwork provenance](CompanionArtwork.md)
and [original generation prompts](CompanionGenerationPrompts.md). It does not
assert an independent third-party redistribution license for inspired artwork.
These are locally bundled presentation assets, not a character-generation feature
that runs when Locus launches.

## Final atlas contract

All four files in `Locus/Resources/Companions/` now have v2 geometry:
1536 × 2288 RGBA pixels, eight columns and eleven rows, 192 × 208 pixels per cell.
The first nine rows retain all their original decoded RGBA pixels exactly,
including transparent pixels and unused cells. Only the two appended rows are
new. PNG compression/file hashes change; existing animation pixels do not.

The look-frame index runs clockwise from screen-up in 22.5-degree sectors.
Indices 0–7 occupy row 9 and indices 8–15 occupy row 10 (zero-based).
The cardinal directions are 0 up, 4 right, 8 down, and 12 left. These are actual
generated head/eye orientations, not copied idle frames, mirrored replacements,
painted-on eyes, or mathematical warping. The standing body remains readable.
Small pose differences are artwork, not a claim of exact anatomical angles.

The generated strips were larger than the requested canonical strip size.
Deterministic packing identified exactly 16 separate connected silhouettes, used
one uniform scale per character based on its existing idle height, aligned each
source row's foot baseline with its existing idle baseline, cropped original
generated pixels, and appended the cells. It removed detached matte residue and
alpha values at or below 4 around the new silhouettes only. No face or limb was
redrawn during packing. Existing cells were copied without resampling.

| Character | Original idle height | Strip size | Packing scale |
| --- | ---: | ---: | ---: |
| Ninja | 134 px | 2056 × 765 | 0.4768683274 |
| Clover | 132 px | 2172 × 724 | 0.4943820225 |
| Shadow | 135 px | 2063 × 762 | 0.4607508532 |
| Pirate | 124 px | 2089 × 753 | 0.4714828897 |

The renderer's presentation scaling is separate from this asset preparation.
These added frames match each old atlas's scale; they do not enlarge its original
frames or change an agent's persisted appearance reference.

## Verification

All 64 look frames were inspected in light/dark composites beside their original
idle frame. Each frame is populated, unique by RGBA hash, unclipped, and wholly
inside its cell. All four output atlases match the canonical v2 dimensions and
retain exact first-nine-row RGBA hashes. The original Pitou and legacy Gon assets
were not modified by this work.

The versioned [deterministic preparation script](../Tools/AppendCompanionGaze.py)
requires explicit original, generated-strip, and output paths. It reproduces all
four final PNG files byte-for-byte and can render all sixteen look frames on both
light and dark backgrounds:

```sh
python3 Tools/AppendCompanionGaze.py \
  --original /path/to/Character-original-v1.png \
  --gaze /path/to/approved-generated-strip.png \
  --output /path/to/Character-v2.png \
  --report /path/to/validation.json \
  --preview-dir /path/to/review
```

It refuses to overwrite either source, rejects clipped or missing silhouettes,
and checks all original pixels and all sixteen unique output-frame hashes before
saving. Input PNGs are bounded to 20 MB and 40 million decoded pixels.

Local inspection evidence is in `/tmp/locus-companion-v41-gaze/`:
`all-gaze-review.png`, per-character `*-gaze-review.png` and `*-gaze.gif`,
`source-analysis.json`, `validation.json`, original v1 copies, and the
`reproduced/` directory with CLI reproduction reports and full four-row
light/dark contact sheets. These are artwork reviews,
not native cursor-interaction or UI-test results. Renderer behavior is verified
separately.

| File | Final PNG SHA-256 |
| --- | --- |
| Ninja.png | `ce14200d834583a70d3d3cccd3cb8b09543cfc6bb2173e8a58e51fca334dced9` |
| Clover.png | `a9b8fc86d0086badd6eecdb97902a27a6d453255d8622a512543e718204ccd10` |
| Shadow.png | `6e2552277402040868c0af9e53dc18904c14c3f74d8f312f64df5e88b13a180e` |
| Pirate.png | `05c6afb030ac6b50adc228437e7df85ac8c72970802b63c736907c7351027da2` |

| Character | Preserved first-nine-row RGBA SHA-256 |
| --- | --- |
| Ninja | `32558421e691dda7433fc748b2b438869425a08b02f549b1af15b6d94d3e032a` |
| Clover | `d1671429f6b2c4b24da9bd933a277246c9cbd9e253896f3af9b5c40bc6f7b216` |
| Shadow | `ac4d1ca47e0ea2ac9c153fbf6658405e0a8286a2269fd731b884286d10b31fb8` |
| Pirate | `ee25bfef64e050b09f1767b7af0dfd90f589c482f3dcd8ddb818aa9fee0c7f28` |

## Exact built-in prompt set

Each call used the shared text below, then its listed character-identity sentence.
The reference was that character's existing `Locus/Resources/Companions/<Name>.png`.

```text
Use case: identity-preserve. Asset: an additional directional-gaze sprite strip for a native Mac companion. Input image is the exact already-approved character animation atlas: preserve its character identity, materials, face design, proportions, costume, tiny attached features and rendering style. Create ONLY a new transparent sprite strip containing EXACTLY 16 full-body standing poses arranged in EXACTLY 8 equal columns and 2 equal rows, read left to right then top to bottom. This is a gaze-direction series, not running/waving/blinking, and not a body rotation turnaround. Feet and torso remain in the same front-facing idle stance, at one consistent baseline and scale in all cells; only the head tilt/turn and the pupils genuinely track a point around the character. All eyes open. Each frame must show the intended distinct gaze direction visibly in the painted face; never simply repeat a front-facing face. Clockwise screen directions starting at UP: top row cells 0 straight up,1 up with slight right,2 diagonally upper-right,3 right with slight up,4 straight right,5 right with slight down,6 diagonally lower-right,7 down with slight right. Bottom row cells 8 straight down,9 down with slight left,10 diagonally lower-left,11 left with slight down,12 straight left,13 left with slight up,14 diagonally upper-left,15 up with slight left. Head can turn but never show the back of the head; retain readable face and both feet. Use a quiet friendly expression. Uniform cell size, all16 positions occupied exactly once. Center full silhouette in its cell with at least15% transparent safety inset each side; no part may touch a cell edge or the canvas edge. Ideally canvas1536x416; if another output size is necessary retain exactly8x2 equal cells so it can be deterministically packed. Background is genuine transparent alpha, clean antialiased edges, no matte, no cast floor shadow. No labels, numerals, logos, text, frame borders, effects, interface, detached elements or extra characters.
```

### Ninja

```text
Character identity from attached reference: blond spiky-haired fox-eared ninja in orange and black, blue eyes, fox tail, little orange chainsaw-dog cap attachment.
```

### Clover

```text
Character identity from attached reference: silver-haired wolf-eared boy, green eyes, black headband, short red coat over black-gold uniform, metal right forearm and dark tail.
```

### Shadow

```text
Character identity from attached reference: black-haired cat-eared boy, violet eyes, dark long coat with purple lining and turquoise chest seams, small white jaw detail, attached dark tail.
```

### Pirate

```text
Character identity from attached reference: black-haired boy with a straw hat and red hatband, red open vest, orange trousers, blue sash and wristbands, brown monkey tail.
```

## Generated source identities

The originals remain in the tool's generated-image library. File identifiers
and hashes below identify the approved pixels before deterministic packing.

| Character | Generated file | Source SHA-256 |
| --- | --- | --- |
| Ninja | `exec-ab1b351d-3053-44f1-927e-131011a7d40a.png` | `259e69fcbe94655c8f78a67d2644065ff4ac543669f191bc7ab1c0d0f4218b81` |
| Clover | `exec-5eb90cc7-5368-47f3-91c2-1c7d8d8d6be4.png` | `5fe235ee362b5986258c107e1e875cbbe8445c1aec20f982dab72d57b473455c` |
| Shadow | `exec-8d3a6b42-92df-49f5-b13f-1dde8986af84.png` | `df933bc2b384f54ab8d0a41af0dd83d35c7e5b0b2da955eb82de8d7834e5c246` |
| Pirate | `exec-9cabedb8-161d-4515-8f70-95eda268ec63.png` | `4152bef61c40fe2ee35447c5c62e32819b8baff4de6b0d6d780a09ef05dd8b6f` |
