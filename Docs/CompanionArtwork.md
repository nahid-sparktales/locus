# Companion artwork

## Pitou and bundled sprite characters

`Locus/Resources/Companions/Pitou.png` is the exact custom pet artwork requested
by the repository owner on October 5, 2026. The selected profile's display name
is Pitou; its underlying connected pet record was listed as Aura. The profile
and record were matched before importing the file. This is user-selected custom
artwork, not an official OpenAI character or logo. Its original PNG bytes are
preserved, with no recoloring, redrawing, resampling, or synthetic articulation.
The source contains only PNG IHDR, IDAT, and IEND chunks and no prompt, text,
EXIF, URL, or local-path metadata.

Pitou SHA-256:
`57622683e6c527c1bb3df63aecad27bcca3bc993d512b5632ecd6b2cc02d5257`.

The owner also requested Gon, Ninja, Clover, Shadow, and Pirate variants.
These are image-generated edits of that reference art, with native sprite-frame
playback. Any deterministic normalization of their generated output is recorded
with the verification artifacts. They are not official franchise assets. The
owner requested inclusion in this repository; no independent third-party
redistribution license is asserted for the supplied or inspired artwork, and
this implementation does not publish a release. The procedural-art license
statement below applies to the original six local characters, not these files.

Pitou retains its original v2 eight-column, eleven-row transparent PNG atlas,
1536 × 2288 pixels, with 73 populated frames. The five generated variants use
v1 eight-column, nine-row atlases, 1536 × 1872 pixels, with 57 populated frames.
Their first nine animation rows are normalized into canonical 192 × 208 pixel
cells. Unverified generated look-direction rows are omitted; no substitute
look frames are invented. All sheets use the same 192 × 208 pixel cells, and
only populated cells are available to playback. ImageIO decodes each bundled resource once, and immutable
cell crops are shared by visible instances. Atlas files do not pass through the
256-pixel portrait importer. There are no remote artwork fetches at startup.

Playback uses idle, greeting, active work, approval waiting, failure, and a
single jump for a new completion. Queued work uses calm idle plus the queue
badge; directional running is never substituted for active work. Paused and
unavailable states use a static frame. Pitou's original look-direction frames
are preserved. Movement and review frames remain in all atlases without
fabricating those interactions.
Locus uses local playback timing with longer idle rests for occasional blinks; this is not a
claim about undocumented ChatGPT production timing. Reduced motion, app hiding,
window occlusion, minimization, closing, and view removal stop playback.

Pitou is the default for new drafts. Persisted selections keep their explicit
asset references. Missing or unsupported art shows the procedural robot without
changing the saved agent identity or selecting a different pet.

## Original local characters

The six companion characters (robot, spark, cat, fox, frog, and explorer) are
original procedural artwork authored for Locus in `Locus/CompanionCharacterView.swift`.
Their silhouettes, faces, shading, palettes, and accessories are defined by native
SwiftUI Canvas paths and gradients. They contain no third-party character art,
trademarks, downloaded assets, fonts, or generated-image service output. The artwork
is distributed as Locus source under the repository's Apache 2.0 license (see `LICENSE`); no separate
asset license, attribution, paid generation service, or remote download is required.

The six shapes are intentionally distinct. Rendering works on macOS 14 and needs
neither Agent World nor an image provider. Character appearance references are
versioned, validated against the bundled catalog, and persisted once. A missing
reference falls back to the robot visually without changing the saved agent ID.

Built-in faces blink and limbs wave. Imported and generated raster pictures are
static art: they receive only subtle whole-image movement and real status badges,
never simulated face or limb articulation. The cancellable view task respects Reduce
Motion, the app's animation preference, scene inactivity, per-window occlusion/minimization, app hiding, and view disappearance.
Window closure and renderer detachment remove all native visibility observers.
Status labels remain accessible with motion off. Decorative breathing does not
represent agent activity or invoke a model.

Custom art remains in the existing agent portrait data store. Imports accept an
explicit raster allowlist, at most 20 MB, at most 16,384 pixels on either side and
40 million decoded source pixels. ImageIO downsamples before decoding the thumbnail,
then copies pixels into a 256-pixel PNG with a 256 KB storage bound. Re-encoding
preserves transparency and removes source metadata. SVG/HTML and arbitrary file
references are not accepted or sent through plugin presentation snapshots.
