# UI art request manifest — New Campaign / FOUND YOUR COMPANY

**Project:** Project Banner (Godot 4.7.2) · **Repo:** JAYST3AM/project-banner
**Measured:** 2026-10-03, engine `--layout-debug` probe (full Control tree dump, 139 elements;
minimum-size chains and viewport env included). Values are exact engine measurements, not
screenshot estimates.
**Scope:** bespoke artwork for the current (restored "kit_v1") look. **No layout changes** —
rects define the screen and artwork conforms to them. Text and icons stay engine elements in
every case.

---

## Resolution framework (read first)

- **Logical coordinate space = 1280 x 720** (measured: viewport 1280x720, margin container
  1280x720 exactly). The game renders this space via Godot `canvas_items` stretch; the
  measured window pair at 1440p = 2560x1440 (2.0x), at 1080p = 1920x1080 (1.5x).
- **1080p rendered size = logical x 1.5.** **1440p rendered size = logical x 2.0.**
- **Recommended source art:** illustrated pieces - at least **x3 logical** (supersamples both
  targets; downscale is safe). Prefer bigger over smaller. Sheets/atlases welcome.
- **Pixel-art pieces** (anything drawn in the project's pixel language - icons, carved
  frames, ornaments): keep the **pixel grid honest**. Recommended source = logical x **4**
  (integer), delivered crisp with hard edges (no anti-aliasing, no soft shadows). They import
  with **nearest-neighbour** filtering and **integer scaling**; do not deliver "smooth" art
  for these. Where a piece is fixed-size (swatch, tool button), source = logical x4 minimum.
- **Illustrated (non-pixel) art is acceptable only where called out** (backdrops behind map
  preview, header crest if requested as painting); everything else must live in the pixel
  language. When in doubt: pixel.
- **Format:** PNG, sRGB, alpha channel. No JPG. No baked text.
- Deliver with transparent margins trimmed to the piece's **visible** bounds; ornaments are
  separate files (see Safe margins / Ornaments).
- Naming/destination: `assets/ui/requests/<group>/<name>.png` (Hermes places them into the
  production folders after import review).

Global safe margins: frames and tiles must survive 9-slice stretching; keep **outer 2px of
source clear of critical detail** for pixel pieces (import filtering eats a hairline), and
**16px clear** on illustrated pieces.

---

## 1. Header

### 1.1 Header centerpiece pair (title flanking ornaments)
- **Region:** header bar, either side of the title. **Purpose:** the strongest identity mark
  at the top of the screen; currently procedural diamonds.
- **Logical rect (each):** 14 x 34 at x=436 and x=843, y=16.
- **1080p:** 21 x 51 · **1440p:** 28 x 68 · **Src rec:** 56 x 136 (pixel, x4).
- **Aspect:** 0.41 wide. **Format/alpha:** PNG, hard alpha. **Behaviour:** fixed-size.
- **Safe margins:** 1px. **9-slice:** no. **Layering:** above bar texture.
- **Text/icons separate:** yes. **Replaces:** procedural `PixelStyle` diamond ornament.
- **Description:** small cast-bronze finial - a spearhead/diamond with a stem, one strong
  silhouette, readable at 14px wide; light on the top-left bevel, dark undersides; matches
  palette bronze (#9c7b52 / #d9a441 highlights, #3c2f23 shadow).

### 1.2 Header bar texture (refresh)
- **Region:** header bar, full span. **Purpose:** carved top bar behind title/subtitle.
- **Logical rect:** 1248 x 68 at 16,10. **1080p:** 1872 x 102 · **1440p:** 2496 x 136.
- **Src rec:** 3744 x 204 (illustrated/pixel hybrid, x3; 9-slice safer at x4 for pixel edges).
- **Aspect:** 18.35:1. **Format/alpha:** PNG. **Behaviour:** **9-slice** (corners 32x32,
  edges 32px bands, centre stretch/tile flat) — the current piece is a ring with crest patch;
  keep a clean stretchable middle. **Safe margins:** 32px all sides inside slice margins.
- **Layering:** behind text. **Text separate:** yes. **Replaces:** `frames/header_bar.png`.
- **Description:** dark iron-wood rail with restrained bronze ribs at the ends; the centre
  stays quiet (title sits there); no crest baked in (crest is a separate overlay if ever
  needed).

---

## 2. Left campaign rail

### 2.1 Active step tile frame ("COMPANY")
- **Region:** rail, first tile. **Purpose:** the selected step material.
- **Logical rect:** 232 x 60 at 32,96 (inner content 188x34).
- **1080p:** 348 x 90 · **1440p:** 464 x 120. **Src rec:** 928 x 240 (pixel, x4).
- **Aspect:** 3.87:1. **Format/alpha:** PNG. **Behaviour:** **9-slice** (corners 24x24,
  edges 24px, centre stretch). **Safe margins:** 24px slice margins.
- **Layering:** behind icon+text. **Text separate:** yes. **Replaces:** `panels/tile_parchment.png`.
- **Description:** aged parchment plate set in the carved chassis: warm cream field with
  faint mottling, a soft dark inner shadow where it meets the frame; corner brackets stay
  part of the piece only if they hold crisp at 9-slice - otherwise brackets are overlays
  (see Shared).

### 2.2 Locked step tile frame
- **Region:** rail, steps 2-9. **Purpose:** locked/coming-soon rows.
- **Logical rect:** 232 x 48 at 32,168 (tiles pitch 52: y 168/220/272/324/376/428/480/532).
  **1080p:** 348 x 72 · **1440p:** 464 x 96. **Src rec:** 928 x 192 (pixel, x4).
- **Aspect:** 4.83:1. **Format/alpha:** PNG. **Behaviour:** **9-slice** (corners 24x24).
  **Safe margins:** 24px slice margins. **Layering:** behind icon+text.
- **Text separate:** yes. **Replaces:** `panels/tile_dark.png`.
- **Description:** dark recessed slate plate with a subtle top-edge shadow and faint
  vertical striation (carved stone/iron); distinctly darker than the parchment tile; same
  chassis language.

### 2.3 Step icon set (9 icons)
- **Region:** rail tiles. **Purpose:** each campaign step's icon.
- **Logical rect (each):** 24 x 32 slot (usable 24x24 glyph, centred), x=50.
  **1080p:** 36 x 48 slot · **1440p:** 48 x 64 slot. **Src rec:** 96 x 128 per icon (x4).
- **Aspect:** 0.75. **Format/alpha:** PNG, hard alpha. **Behaviour:** fixed-size, nearest.
- **Layering:** above tile. **Text separate:** yes. **Replaces:** `PixelIcons` glyphs
  (company/founder/appearance/backstory/culture/class/subclass/starting/rules).
- **Description:** one visual family: single-weight chunky pixel silhouettes with 1px dark
  outline and a single highlight tone - banner+quill (company), helm (founder), mirror
  (appearance), book (backstory), mask (culture), sword (class), shield (subclass), pack
  (starting), scroll+seal (rules). Dimmed states are done in engine (modulate), so deliver
  the full-brightness version only.

### 2.4 Rail footer emblem (rule + mark)
- **Region:** bottom of rail (above the caption). **Logical rect:** 232 x 2 rule at 32,609 +
  a small mark up to 232 x 29 zone at 32,576 (optional, empty today).
- **1080p:** rule 348 x 3 · **1440p:** 464 x 4. **Src rec:** 928 x 8 + mark 928 x 116.
- **Behaviour:** rule = fixed-height, stretch-width (or 9-slice with 8px end caps);
  mark = optional, fixed. **Layering:** above rail panel. **Text separate:** yes.
- **Replaces:** flat `ColorRect` rule.
- **Description:** a fine bronze rule with a tiny centred lozenge; nothing crying for
  attention (caption text sits under it).

---

## 3. Banner Editor

### 3.1 Editor frame ornament overlay set (4 corners + 2 mid finials)
- **Region:** the big Banner Editor frame (680x466 at 286,176) - but the frame itself stays
  the kit's piece; this is the **separate ornament set** allowed to overlay it.
- **Purpose:** depth on the screen's largest object without heavy re-carving.
- **Logical rect (each corner):** up to 48 x 48 at the frame's corners; mid finials up to
  24 x 32 centred on top/bottom edges. **1080p:** 72x72 / 36x48 · **1440p:** 96x96 / 48x64.
- **Src rec:** corners 192x192, finials 96x128 (pixel, x4).
- **Format/alpha:** PNG, hard alpha. **Behaviour:** fixed-position overlays (anchored to the
  frame corners in engine), never stretched. **Layering:** above frame, below content.
- **Text separate:** yes. **Replaces:** nothing (new).
- **Description:** corner brackets in cast bronze: an L-bracket with a rivet and one step
  detail; the finials echo the header pair at smaller scale. Must read on the dark frame.

### 3.2 Tool icon set (8 icons)
- **Region:** editor tools row (left column, 190 wide). Icon slots 22 x 22 at y=344 row.
  **1080p:** 33 x 33 · **1440p:** 44 x 44. **Src rec:** 88 x 88 each (x4), delivered as one
  8-cell strip or atlas. **Format/alpha:** PNG hard alpha. **Behaviour:** fixed, nearest.
- **Text separate:** yes (tooltips). **Replaces:** `PixelIcons` pencil/fill/eraser/mirror/
  wind/grid/undo/clear.
- **Description:** same family as the step icons; ON state is the theme's gold ring (do not
  bake a selected ring into the art).

### 3.3 Palette cell frame (swatch chrome) + selected ring
- **Region:** palette grid (2 rows of 10), swatch 17 x 17, pitch 19 (col x300, rows y391).
  **1080p:** 26 x 26 · **1440p:** 34 x 34. **Src rec:** 68 x 68 cell + 68 x 68 ring (x4).
- **Behaviour:** fixed; ring overlays the cell when selected. **Layering:** ring above cell.
- **Replaces:** flat button cell + gold focus style.
- **Description:** swatch = a thin dark iron bezel with 1px inner shadow (colour fills the
  centre in engine); selected ring = cast bronze square ring with a corner-notch detail.

### 3.4 Detail level button frame (8x10 / 16x20 / 32x40)
- **Region:** detail row in the tools column; three buttons ~56 x 24, row 190 x 36.
  **1080p:** 84 x 36 · **1440p:** 112 x 48. **Src rec:** 224 x 96 per button (x4).
  **Behaviour:** **9-slice** (corners 8x8) or fixed-size; selected state = engine ring.
  **Text separate:** yes (the sizes are text). **Replaces:** current flat utility buttons.
- **Description:** small iron plaques with a shallow bevel; quieter than the tiles.

### 3.5 Starter template buttons (5)
- **Region:** starters row, tools column; five small square buttons ~22-24px, row under the
  detail row. **1080p:** ~34 x 34 · **1440p:** ~46 x 46. **Src rec:** 96 x 96 each (x4).
  **Behaviour:** fixed; hover/press states in engine. **Replaces:** current icon glyphs.
- **Description:** mini banner thumbnails (5 distinct cloth pattern previews: pale bar,
  chevron, cross, quartered, blank) in the same pixel weight as the tool icons.

### 3.6 Paint canvas surround (the recessed well)
- **Region:** canvas column; medium tile behind the paint grid.
- **Logical rect:** 204 x 242 at 502,303 (grid 160x200 at 520,311). **1080p:** 306 x 363 ·
  **1440p:** 408 x 484. **Src rec:** 816 x 968 (pixel, x4).
  **Behaviour:** **9-slice** for the medium frame (corners 24x24) with a flat centre.
  **Layering:** behind the grid; grid draws on top with its own 1px cell lines.
- **Replaces:** `tile_dark` piece used here today.
- **Description:** the cloth's bench: a dark recessed well with a very subtle inner shadow;
  NOT bright, NOT a white frame - the painted cloth must be the brightest thing here.
  The 16x20 cells stay exactly 8px each at runtime; art must not imply a different grid.

---

## 4. Banner preview cards (right column of the editor)

### 4.1 Banner-on-pole card frame (hero preview card)
- **Region:** editor preview column, top card. **Logical rect:** 234 x 248 at 718,239
  (banner view 190x232 inside at 736,247).
  **1080p:** 351 x 372 · **1440p:** 468 x 496. **Src rec:** 936 x 992 (pixel, x4).
  **Behaviour:** **9-slice** (corners 28x28). **Layering:** behind view. **Text separate:** yes.
  **Replaces:** `tile_dark` in this slot.
- **Description:** a display alcove for the finished banner: dark slate with a faint radial
  vignette toward the centre (light gathers around the cloth), thin bronze inner bevel; must
  not compete with the banner art itself.

### 4.2 Banner view backdrop (behind the pole render)
- **Region:** inside 4.1; the 190 x 232 view. **1080p:** 285 x 348 · **1440p:** 380 x 464.
  **Src rec:** 760 x 928 (pixel or gently illustrated, x4). **Behaviour:** fixed, behind the
  banner render; must leave the centre dark so the cloth pops. **Replaces:** current flat
  card interior.
- **Description:** optional atmosphere: a dark wall niche with a subtle floor shadow where
  the pole meets it; NO texture noise behind the cloth silhouette.

### 4.3 Founder placeholder card + silhouette
- **Region:** editor preview column, middle card. **Card rect:** 234 x 46 at 718,493
  (content row 190 x 30: icon 26 x 30 at 748,501, texts 132 wide).
  **1080p:** 351 x 69 card · **1440p:** 468 x 92 card. **Src rec:** card 936 x 184 (x4);
  silhouette 104 x 120 (x4). **Behaviour:** 9-slice card (corners 16x16); icon fixed.
  **Replaces:** `tile_dark` + `PixelIcons.founder`.
- **Description:** reserved-slot card: quiet slate plate with a dashed or notched inner edge
  reading as "not yet"; silhouette = a hooded figure bust, dimmed tones, clearly a
  placeholder.

### 4.4 Map preview card + true-scale backdrop
- **Region:** editor preview column, bottom card. **Card rect:** 234 x 86 at 718,545
  (view 190 x 70 at 736,553). **1080p:** 351 x 129 card, view 285 x 105 ·
  **1440p:** 468 x 172 card, view 380 x 140. **Src rec:** card 936 x 344 (x4);
  backdrop 760 x 280 (x4 illustrated acceptable). **Behaviour:** 9-slice card; backdrop
  fixed behind the small banner render; keep centre contrast low.
- **Description:** a patch of campaign-map ground in the game's palette (muted greens
  #3f5a35/#6b8f52 + dark soil), a tiny horizon; the mini banner hangs above it at true
  scale - the backdrop must never outshine it.

---

## 5. World settings

### 5.1 Panel frame (World Settings)
- **Region:** right column top panel. **Logical rect:** 292 x 197 at 972,84.
  **1080p:** 438 x 296 · **1440p:** 584 x 394. **Src rec:** 1168 x 788 (x4).
  **Behaviour:** 9-slice (corners 28x28). **Replaces:** current primary panel piece.
  **Description:** mid-weight carved frame - second tier: aged iron with bronze edging,
  less ornament than the editor frame; the title strip area (y96 h16 + rule) stays clean.

### 5.2 Seed input frame
- **Logical rect:** 224 x 34 at 988,152. **1080p:** 336 x 51 · **1440p:** 448 x 68.
  **Src rec:** 896 x 136 (x4). **Behaviour:** **9-slice** (corners 10x10), centre flat dark
  for text. **Replaces:** flat input style. **Text separate:** yes (the seed value).
- **Description:** shallow recessed field with 1px bronze inner line; focused state = engine
  ring, not baked.

### 5.3 Dice button
- **Logical rect:** 30 x 34 at 1218,152. **1080p:** 45 x 51 · **1440p:** 60 x 68.
  **Src rec:** 120 x 136 (x4). **Behaviour:** fixed; hover/press engine-side.
  **Replaces:** `PixelIcons.dice` glyph on a flat button.
- **Description:** small iron tile with a die face (three pips, offset for charm).

### 5.4 Randomise Seed button frame
- **Logical rect:** 260 x 36 at 988,235. **1080p:** 390 x 54 · **1440p:** 520 x 72.
  **Src rec:** 1040 x 144 (x4). **Behaviour:** 9-slice (corners 10x10). **Replaces:**
  current button art. **Text separate:** yes.
- **Description:** a working button, not a hero: iron plate, thin bronze rim, subtle down
  bevel; the dice icon in the label is separate.

---

## 6. Campaign preview

### 6.1 Panel frame (Campaign Preview)
- **Logical rect:** 292 x 162 at 972,287. **1080p:** 438 x 243 · **1440p:** 584 x 324.
  **Src rec:** 1168 x 648 (x4). **Behaviour:** 9-slice (corners 28x28). **Replaces:**
  current piece. **Description:** twin of 5.1 for visual rhythm.

### 6.2 Banner thumbnail frame
- **Logical rect:** 52 x 38 at 1032,353. **1080p:** 78 x 57 · **1440p:** 104 x 76.
  **Src rec:** 208 x 152 (x4). **Behaviour:** fixed; thumbnail (the mini banner) renders
  inside; frame stays quiet. **Replaces:** current thumb style. 
- **Description:** tiny display card: 1px bronze rim, dark field.

### 6.3 Row icon plate
- **Logical rect:** 32 x 38 at 1092,353 (gear/options row). **1080p:** 48 x 57 ·
  **1440p:** 64 x 76. **Src rec:** 128 x 152 (x4). **Behaviour:** fixed. **Replaces:**
  flat icon slot. **Description:** small iron plate hosting the row icon.

---

## 7. Footer / actions

### 7.1 Back to Main Menu button frame
- **Logical rect:** 230 x 44 at 42,657. **1080p:** 345 x 66 · **1440p:** 460 x 88.
  **Src rec:** 920 x 176 (x4). **Behaviour:** 9-slice (corners 12x12). **Text separate:** yes.
  **Replaces:** current carved default. **Description:** dark iron plate with bronze edge;
  full state set drawn in engine via modulate.

### 7.2 START CAMPAIGN button frame (the one green action)
- **Logical rect:** 300 x 44 at 938,657. **1080p:** 450 x 66 · **1440p:** 600 x 88.
  **Src rec:** 1200 x 176 (x4). **Behaviour:** 9-slice (corners 12x12). **Text separate:** yes.
  **Replaces:** `buttons/primary_green.png`. 
- **Description:** the screen's single loud object: forest-green enamel (#3f5a35 family)
  inset in cast bronze, a shallow dome, one clean highlight; no glow, no gradients beyond
  the enamel; must still read as carved, not as a mobile-game button.

### 7.3 Footer centre emblem
- **Region:** between the two buttons (spacer 646 x 44 at 282,657); emblem ~40 x 44 centred.
  **1080p:** 60 x 66 · **1440p:** 80 x 88. **Src rec:** 160 x 176 (x4). **Behaviour:** fixed.
  **Replaces:** procedural diamond. **Description:** a small crest lozenge with the banner
  motif, echoing the header pair; kept dim so START stays the focus.

---

## 8. Shared / reusable assets

### 8.1 Corner bracket overlay set
- **Use:** any panel that needs more depth without a new frame (editor, right panels).
  **Logical rect:** 24-48px pieces. **Src rec:** 96-192px (x4). **Behaviour:** fixed overlays.
  **Description:** L-brackets in cast bronze, 2 thicknesses, mirrored set (4 files per size).

### 8.2 Divider kit
- **Use:** panel title rules (measured: 2px high rules under titles, e.g. 260x2, 652x2,
  1128x2). **Src rec:** 1024 x 8 / 2048 x 12 masters (pixel, x4-x8), cropped by engine.
  **Behaviour:** stretch-width, fixed-height; optional 8px end caps. **Description:** fine
  bronze line with a slightly brighter centre; quiet.

### 8.3 Focus / selection ring set
- **Use:** palette swatch selection, input focus, active detail button.
  **Sizes:** ~26px, ~36px, ~44px squares. **Src rec:** x4. **Behaviour:** fixed overlay.
  **Description:** 1px-offset bronze square rings with corner notches; single-weight.

---

## Priorities

**P0 — visually necessary** (the screen is seen constantly in these):
1.1 header pair · 2.1/2.2 rail tile frames · 3.2 tool icons · 4.1 banner card frame ·
5.2 seed input + 7.2 START frame · 8.2 divider kit (chrome lines everywhere).

**P1 — major polish:**
1.2 header bar refresh · 2.3 step icon set · 3.3 palette cell + ring · 3.4 detail buttons ·
4.3 founder card + silhouette · 5.1/6.1 right panel frames · 7.1 back button · 8.3 rings.

**P2 — optional atmosphere:**
3.1 editor corner ornaments · 4.2 banner backdrop · 4.4 map backdrop · 5.3 dice · 5.4
randomise frame · 6.2/6.3 preview chrome · 7.3 footer emblem · 8.1 corner brackets ·
2.4 rail footer emblem.

---

## Provenance

All rects measured in-engine 2026-10-03 via `--layout-debug` (full Control-tree dump;
`measured_rects.txt` holds all 139 entries with 1080p/1440p conversions). Logical space:
1280x720; screen grid: outer margin 16 (top/bottom 10) · gutter 6 · rail 264 · centre 680 ·
right 292 · header 68 · footer 62. Art conforms to these rects; panels never move for art.
