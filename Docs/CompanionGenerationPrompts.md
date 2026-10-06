# Companion generation prompts

## Scout — My Hero Academia × Hunter x Hunter

Added October 5, 2026 using the built-in `image_gen` tool (edit mode, transparent
background) with the inspected Pitou atlas as the layout/pose reference. No API
key or external image provider was used. Scout replaces Gon in the gallery;
`gon-v1` and its resource remain available for saved appearances.

Selected source: `exec-7e60089d-f594-4226-a954-1f72b85b0264.png`, 1027 × 1531 RGBA.
Source SHA-256: `eebf48c7b2df26175e26da72dec8358219260e1e168adea755266e5988321ca6`.
Project asset: `Locus/Resources/Companions/Scout.png`, 1536 × 2288 RGBA, 73 frames.
Output SHA-256: `071d3ee67b64b0f7ce9bf2d9c3f2215a3a8366ebfa4f424ad0d14355230b995a`.

`Tools/PrepareCompanionAtlases.py --version 2` packs all eleven rows using a
single 1.3545431145431148 scale and translation. Source silhouettes were complete,
with no canvas clipping. It retains actual generated expressions and sixteen
head directions; no missing pose is synthesized. Low-alpha matte residue is
removed by the established atlas compiler. The visible idle height is 181 pixels
versus Pitou's 193, before fitting both into the same UI frame.

Final prompt:

```text
Use case: precise-object-edit. Asset type: production transparent desktop companion sprite atlas. Image 1 is the EDIT TARGET and exact pose/layout reference. Replace Pitou with a NEW My Hero Academia × Hunter x Hunter miniature companion named Scout: a charming Gon/Deku fusion, compact spiky forest-green hair (wide rounded spiky silhouette, not overly tall), emerald eyes, tiny freckles, small fluffy fox ears, confident kind expression, green hunter jacket with red piping and cream hero neck guard, green shorts, small rounded cream gloves, red ankle boots and a short attached forest-green tail. No text or logos. Cohesive 2.5-head-tall anime chibi illustration with crisp fine outlines and softly cel-shaded volume, matching Pitou's large head, small body and strong readability. Keep the same identity, clothes, head size and bodily scale across ALL frames. Preserve every corresponding pose and facing direction from reference, including real changed head direction in last two rows. EXACT GRID: 8 columns × 11 rows, 1536x2288 canvas, 192x208 cells. Occupancy per row 6,8,8,4,5,8,6,6,6,8,8. First row idle/blink. Next run right, run left, wave, jump, disappointed/crouch, attention/wait, thinking, review. Last 16 cells hold head-look directions clockwise starting UP: row10 up, up-right-ish, up-right, right-up, right, right-down, down-right, down-right-ish; row11 down, down-left-ish, down-left, left-down, left, left-up, up-left, up-left-ish. Every character full body, complete hair ears boots tail, within its cell with transparent safety margin. Common floor baseline in corresponding nonjump poses. Character should occupy approximately 80 percent cell height and 70 percent cell width, not become tiny. Empty cells fully transparent, entire background actual alpha, no grid, no captions, no panel border, no backdrop/shadow, no colored fringe or glow, no particles or detached objects. Match the provided atlas's layout and exact animation poses rather than inventing a different grid.
```

## Initial v4 Clover, Shadow, and Pirate state atlases

This section records the original 57-frame state artwork. The current bundled
files retain those pixels and add the sixteen look poses documented in the
[directional-gaze supplement](CompanionDirectionalGaze.md).

Created October 5, 2026 with the built-in `image_gen` tool in edit mode and `transparent_background: true`. The sole edit target was the user-selected Pitou atlas, inspected before editing. No external provider API/CLI was used; no ChatGPT pet was created or published. The requested final identities are Clover (Asta × Fullmetal Alchemist), Shadow (Sung Jinwoo × Kaiju No. 8), and Pirate (Luffy × Dragon Ball Z).

The tool returned native 1027 × 1531 RGBA PNGs despite the prompts requesting 1536 × 2288. The source filenames below identify the selected originals. `Tools/PrepareCompanionAtlases.py` compiled these variants to the established **v1 1536 × 1872 layout: 8 columns, 9 rows, 192 × 208 cells, 57 actual state frames**, with per-row counts **6, 8, 8, 4, 5, 8, 6, 6, 6**. The 15 unused cells were exactly transparent. The initial release omitted the generated direction/look rows because it did not support pointer tracking for these variants and one source had cropped feet in its final look row. The follow-up uses separately generated, inspected look poses. No missing frames are synthesized or duplicated. Pitou retains its exact original v2 artwork.

Compilation performs deterministic connected-silhouette extraction to recover existing pixels crossing nominal generated cell boundaries, removes alpha ≤ 4 matte residue, keeps original colors and nearby antialias pixels, and applies one common scale/translation to all frames in each resource with a 15% safety inset. It does not redraw characters or normalize individual pose scale/baseline. The script validates occupancy, canvas clipping, dimensions, and transparent margins; source/output SHA-256 hashes are recorded in its JSON report.

Generated variants were requested as anime-inspired personal companion designs; generation does not establish any franchise license. The earlier single-series Clover/Shadow/Pirate outputs and the interim Luffy × Bleach result remain in the built-in generation library as superseded sources and are not selected release assets.

### Clover — selected final prompt

Project asset: `Locus/Resources/Companions/Clover.png`.
Native source filename: `exec-adfa2b1c-d327-47d1-9350-406c18be56ee.png`.

```text
Use case: precise-object-edit.
Asset type: production transparent desktop companion sprite atlas.
Image1 is the exact EDIT TARGET. Replace only the character design consistently across all occupied cells. Preserve the original's poses, facing directions, expression sequence, tiny proportions, frame positions, row spacing, and empty cells exactly.
LOCK THE LAYOUT:1536x2288canvas;8columns by11rows;each cell192x208. Row occupancies top to bottom:6,8,8,4,5,8,6,6,6,8,8 (73occupiedframes). Row1 blink/idle. Rows2and3 eight-frame running right/left. Row4 four-frame wave. Row5 five-frame jump. Row6 eight-frame sleep. Rows7through9 six expressive/thinking poses each. Lasttwo rows16head/lookdirections. Empty cells must have zeroalpha. Never mergeframes, shiftrowpositions, addframes or crop the feet/hair. Each complete figure has at least8pixels transparent margin within its own cell.
Style: polished charming anime chibi, crisp consistent clean ink outlines and smooth cel shading. All anatomy and clothes must remain firmly attached in every animationframe. Backdrop: real alpha transparency, no checkerboard, no halos, mattefringes, floatingcoloredspeckles, aura, particles, cloudshadows or ground.
Constraints: no words, captions, UI, symbols resembling text, logos, extra props, detached limbsoverlays, effectvignettes. No entire-sheet redesign. Output complete transparent spriteatlas with poses matching the edit target.
New hybrid character: Asta from Black Clover crossed with Fullmetal Alchemist. A tiny silver-haired wolf-eared chibi alchemist with spiky silver hair, black headband, eager green eyes, short red alchemist coat over compact black-and-gold uniform, one clearly articulated silver metal automail RIGHTarm permanently attached to the shoulder, normal leftarm, little dark wolf ears and a compact attached darktail. Keep automail on the anatomical RIGHTarm across right/left/headturns, simplified roundedmetalhand and segments. Coat is red in everyframe and remains close to body. No giant sword, armor suit, alchemycircles, floating sparks or detached gear. Match the reference's expressive friendly chibi face and all73poses exactly. This must read as the same tiny companion in everycell.
```

### Shadow — selected final prompt

Project asset: `Locus/Resources/Companions/Shadow.png`.
Native source filename: `exec-dc27ff11-2a82-478a-b8a5-f0cd6eac8d61.png`.

```text
Use case: precise-object-edit.
Asset type: production transparent desktop companion sprite atlas.
Image1 is the exact EDIT TARGET. Replace only the character design consistently across all occupied cells. Preserve the original's poses, facing directions, expression sequence, tiny proportions, frame positions, row spacing, and empty cells exactly.
LOCK THE LAYOUT:1536x2288canvas;8columns by11rows;each cell192x208. Row occupancies top to bottom:6,8,8,4,5,8,6,6,6,8,8 (73occupiedframes). Row1 blink/idle. Rows2and3 eight-frame running right/left. Row4 four-frame wave. Row5 five-frame jump. Row6 eight-frame sleep. Rows7through9 six expressive/thinking poses each. Lasttwo rows16head/lookdirections. Empty cells must have zeroalpha. Never mergeframes, shiftrowpositions, addframes or crop the feet/hair. Each complete figure has at least8pixels transparent margin within its own cell.
Style: polished charming anime chibi, crisp consistent clean ink outlines and smooth cel shading. All anatomy and clothes must remain firmly attached in every animationframe. Backdrop: real alpha transparency, no checkerboard, no halos, mattefringes, floatingcoloredspeckles, aura, particles, cloudshadows or ground.
Constraints: no words, captions, UI, symbols resembling text, logos, extra props, detached limbsoverlays, effectvignettes. No entire-sheet redesign. Output complete transparent spriteatlas with poses matching the edit target.
New hybrid character: Sung Jinwoo from Solo Leveling crossed with Kaiju No8. A tiny confident black-haired violet-eyed cat familiar with darkcat ears, compact attached blacktail, a short compact blackcoat with visible purplelining, small bone-white kaiju jawmask markings along the jaw (face and mouth remain expressive), thin turquoise bioluminescent chestseams drawn as solid turquoise costume accents with NO external glow, and ONE compact darkmonster clawedhand firmly attached to itsarm. The other hand remains a small normal paw. Keep all markings/coat/clawedhand consistent across all73poses, blink/sleep/wave/running/directional frames. No detached monster silhouettes, smoke, aura, energywings or particles. Charming animechibi with sharpviolet eyes, not frightening horror.
```

### Pirate — selected final prompt

Project asset: `Locus/Resources/Companions/Pirate.png`.
Native source filename: `exec-05ca8569-5b1f-4171-a74e-675c78b91bc6.png`.

```text
Use case: precise-object-edit.
Asset type: production transparent desktop companion sprite atlas.
Image1 is the exact EDIT TARGET. Replace only the character design consistently across all occupied cells. Preserve the original's poses, facing directions, expression sequence, tiny proportions, frame positions, row spacing, and empty cells exactly.
LOCK THE LAYOUT:1536x2288canvas;8columns by11rows;each cell192x208. Row occupancies top to bottom:6,8,8,4,5,8,6,6,6,8,8 (73occupiedframes). Row1 blink/idle. Rows2and3 eight-frame running right/left. Row4 four-frame wave. Row5 five-frame jump. Row6 eight-frame sleep. Rows7through9 six expressive/thinking poses each. Lasttwo rows16head/lookdirections. Empty cells must have zeroalpha. Never mergeframes, shiftrowpositions, addframes or crop the feet/hair. Each complete figure has at least8pixels transparent margin within its own cell.
Style: polished charming anime chibi, crisp consistent clean ink outlines and smooth cel shading. All anatomy and clothes must remain firmly attached in every animationframe. Backdrop: real alpha transparency, no checkerboard, no halos, mattefringes, floatingcoloredspeckles, aura, particles, cloudshadows or ground.
Constraints: no words, captions, UI, symbols resembling text, logos, extra props, detached limbsoverlays, effectvignettes. No entire-sheet redesign. Output complete transparent spriteatlas with poses matching the edit target.

IMPORTANT safety margin: each complete character is at most70%ofcellwidth and70%ofcellheight, centered horizontally with a consistent baseline so there is15%transparent inset on eachside. Preserve corresponding jump and running pose changes without letting any hat,feet,tail orhand touch a cellboundary.
New final hybrid character: Luffy from One Piece crossed with Dragon Ball Z martial-arts styling. A tiny cheerful monkey/pirate familiar with black spiky hair, small rounded monkeyears, friendly dark eyes, snug golden strawhat with a plain redhatband, red open piratevest, orange martialarts gi TROUSERS, darkblue waistsash and darkblue wristbands, small sandals and a compact curved attached monkeytail. The orange trousers and darkblue sash/wristbands are the visible DragonBall-inspired elements; keep strawhat and redvest clearly recognizable in everyframe. No insignia, kanji, lettering, logos, weapons, glowingenergy, aura, effects, detachedprops or background. No blackkimono and no whitesash. Keep all garmentdetails/anatomy firmly attached and consistent, hat follows everyheadturn, with fullbody visible in every73occupiedframe. Preserve the exact referenceposes and truly transparent background and unusedcells.
```

## Additional selected variants

### Gon × JJK / Hell’s Paradise

Final selected generated source: `exec-f13ec90f-1c6b-41b8-a890-b716dc89ea71.png`. Only the complete first nine rows are compiled; later look rows were excluded. The subsequent whole-atlas repair was not selected.

```text
Use case: stylized-concept. EDIT TARGET: attached original Pitou sprite sheet, transform it into a new anime crossover miniature companion. Keep exactly8columns11rows on a1536x2288 transparent PNG, cells192x208. Occupied frames per row6,8,8,4,5,8,6,6,6,8,8; unused trailingcells must be totally transparent. Keep same pose sequence and readable facialexpressions: idleblinks/runright/runleft/wave/happyjump/disappointed/waitforattention/chin-in-handthinking/review/16lookdirections. CONSISTENT sameidentity in all73poses. Use Pitou's tiny expressive 2.5headstall anime-chibi illustration style, inkedoutlines softlyshadedvolume, largeeyes. IMPORTANT fit every completecharacter within the central80% of its cell with transparent safety margin; ears/hair/feet/tail never reachcellboundaries; no clipping. Full-body eachcell, no text, logos, particles, effects, glows, halos, shadows, coloredmattefringes, checkerboard, gridlines, busybackground. Subject: Gon Freecss × Jujutsu Kaisen with Hell's Paradise shinobi details. Mini forest-cat familiar with distinctive tallspiky darkgreen-black Gon hair, small green cat ears and short darkfluffytail, Gon amber-browneyes and energetic determinedface. Green shorts and green shortjacket with redtrim, wornopen over a darknavy JJK highcollar uniform, clear small Sukuna-style black angularcheekmarks. Bandaged forearms and a pale gray shinobi neckwrap tied with a thin redcord inspired by Gabimaru from Hell's Paradise. No changedhaircolor; Gon instantlyrecognizable. Outfit allconsistent and simple. No weapons.
```

### Naruto × Chainsaw Man

Final selected generated source: `exec-797ea430-f449-4094-88b0-f0a06cbc14d4.png`. The first nine animation rows are compiled into `Ninja.png`.

```text
Use case: stylized-concept. EDIT TARGET: attached original Pitou sprite sheet, transform it into a new anime crossover miniature companion. Keep exactly8columns11rows on a1536x2288 transparent PNG, cells192x208. Occupied frames per row6,8,8,4,5,8,6,6,6,8,8; unused trailingcells must be totally transparent. Keep same pose sequence and readable facialexpressions: idleblinks/runright/runleft/wave/happyjump/disappointed/waitforattention/chin-in-handthinking/review/16lookdirections. CONSISTENT sameidentity in all73poses. Use Pitou's tiny expressive 2.5headstall anime-chibi illustration style, inkedoutlines softlyshadedvolume, largeeyes. IMPORTANT fit every completecharacter within the central80% of its cell with transparent safety margin; ears/hair/feet/tail never reachcellboundaries; no clipping. Full-body eachcell, no text, logos, particles, effects, glows, halos, shadows, coloredmattefringes, checkerboard, gridlines, busybackground. Subject: Naruto × Chainsaw Man cute fox-puppy ninja familiar. Golden spiky Naruto hair with golden foxears, blueeyes, three whiskermarks eachcheek, warmcheerfulface, orangeblack ninjajacket and trousers with darkboots. A distinct compact orange Pochita-style helmetcap fitted behind the hair, with one shortgray rounded chainsawtoothcrest angled upward like an attached headaccessory; brownpullcordring attached centrally to chestjacket, and shortfluffyorangetail with darkstripe. The Pochita cap has tinyfriendly blackeyes on it, but is an attachedhelmet not a separate pet. Clear readable crossover; no gore, threateningpose, extraarms, hugeweapon, or detachedobjects.
```
