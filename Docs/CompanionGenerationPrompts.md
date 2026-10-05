# Companion generation prompts

## Selected Clover, Shadow, and Pirate hybrid atlases

Created October 5, 2026 with the built-in `image_gen` tool in edit mode and `transparent_background: true`. The sole edit target was the user-selected Pitou atlas, inspected before editing. No external provider API/CLI was used; no ChatGPT pet was created or published. The requested final identities are Clover (Asta × Fullmetal Alchemist), Shadow (Sung Jinwoo × Kaiju No. 8), and Pirate (Luffy × Dragon Ball Z).

The tool returned native 1027 × 1531 RGBA PNGs despite the prompts requesting 1536 × 2288. Native originals remain at the source paths below. `Tools/PrepareCompanionAtlases.py` compiles the selected generated variants to the established **v1 1536 × 1872 layout: 8 columns, 9 rows, 192 × 208 cells, 57 actual state frames**, with per-row counts **6, 8, 8, 4, 5, 8, 6, 6, 6**. The 15 unused cells are exactly transparent. The generated direction/look rows are deliberately omitted, because the new variants do not advertise pointer tracking and a root-generated variant had cropped feet in its final look row. No missing frames are synthesized or duplicated. Pitou retains its exact original v2 artwork.

Compilation performs deterministic connected-silhouette extraction to recover existing pixels crossing nominal generated cell boundaries, removes alpha ≤ 4 matte residue, keeps original colors and nearby antialias pixels, and applies one common scale/translation to all frames in each resource with a 15% safety inset. It does not redraw characters or normalize individual pose scale/baseline. The script validates occupancy, canvas clipping, dimensions, and transparent margins; source/output SHA-256 hashes are recorded in its JSON report.

Generated variants were requested as anime-inspired personal companion designs; generation does not establish any franchise license. The earlier single-series Clover/Shadow/Pirate outputs and the interim Luffy × Bleach result remain in the built-in generation library as superseded sources and are not selected release assets.

### Clover — selected final prompt

Project asset: `Locus/Resources/Companions/Clover.png`.
Native source: `/Users/nahid/.codex/generated_images/01a10a18-8714-78e0-8e57-bc9a5e1f8602/exec-adfa2b1c-d327-47d1-9350-406c18be56ee.png`.

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
Native source: `/Users/nahid/.codex/generated_images/01a10a18-8714-78e0-8e57-bc9a5e1f8602/exec-dc27ff11-2a82-478a-b8a5-f0cd6eac8d61.png`.

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
Native source: `/Users/nahid/.codex/generated_images/01a10a18-8714-78e0-8e57-bc9a5e1f8602/exec-05ca8569-5b1f-4171-a74e-675c78b91bc6.png`.

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
