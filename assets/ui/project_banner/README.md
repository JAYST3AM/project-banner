# Project Banner UI kit — cut from the custom Medieval Fantasy sheet

The New Campaign screen's materials are sliced from the project's **own** generated sprite
sheet — no third-party asset pack. This folder is the production set; the tool that cut it
is `tools/slice_ui_sheet.gd`; the source lives at `assets/ui/source/medieval_ui_sheet.png`.

## Provenance and licence

- **Source:** `Medieval_Fantasy_Pixel_UI_Sprite_Sheet` (1448x1086, RGBA) — generated for
  Project Banner, provided by the owner 2026-10-02. **No third-party licence applies**;
  the artwork belongs to the project.
- An earlier pass had prepared Framewright Lite (Cabin Circuit) as the material set; by the
  owner's direction it was **not adopted**. That work is shelved on the local branch
  `framewright-skin-try` (vendor, recolour tool, theme) for reference only — nothing from it
  is mixed into this kit.

## How the sheet becomes assets (`tools/slice_ui_sheet.gd`)

The sheet is a generated atlas, not a grid, with anti-aliased edges. The tool:

1. **Hardens alpha** — a >= 128 keeps a pixel, everything below goes clear — so the soft
   generation halo cannot smear against the dark UI.
2. **Finds elements by connected-component analysis** on the alpha channel (8-connected,
   >= 24px) — slice rects come from the pixels, not from eyeballed coordinates.
3. Writes each component as a staged piece (review), then with `--bake` writes the **named
   production set** below.
4. **Closes hollow rings** — the large/medium/small frames and the input frame are drawn as
   rings with transparent middles; the tool floods them from the centre with the panel fill
   (`#161a21` panels, `#12161d` input) so the pieces are complete surfaces.
5. **Keep-boxes** — ornament crops that unavoidably swallowed a sliver of their frame edge
   are erased outside their measured keep rect.
6. **Crest patches** — the sheet drew a crest into the top-centre of `frame_large`,
   `header_bar` and `footer_bar`; a patch copies a neighbouring slice of the same artwork
   over it (rects in `PATCHES`), so nothing smears when the pieces stretch. The three crest
   ornaments are extracted separately for use as overlays.

## Cleanup recorded (all automatic, in the tool)

- alpha threshold (every piece); interior fills (4 pieces); keep-box erasure (5 ornaments);
  crest cover patches (3 pieces). No manual pixel painting beyond these ops.

## Structure

```
frames/    frame_large (editor), frame_medium, frame_small, header_bar, footer_bar
panels/    inset_panel (base panels), tile_parchment (selected step), tile_dark (locked steps, canvas frame, cards)
buttons/   primary_green (START), secondary_dark (base buttons)
inputs/    input_frame (LineEdits)
dividers/  divider_wide
ornaments/ crest_shield, crest_header, diamond_top, diamond_top_small, button_diamond,
           bracket_tl/tr/bl/br, diamond_ornate, square_crest, ring_plain, ring_crest, cross_gold
```

## Nine-slice margins (texture pixels; axis stretch = stretch, not tile — the generated
borders are not periodic, so tiling would seam)

| Piece | margins L,T,R,B | content L,T,R,B |
|---|---|---|
| frame_large (editor) | 61,61,61,61 | 28,30,28,30 |
| header_bar | 60,20,60,24 | 60,16,60,14 |
| footer_bar | 30,26,30,26 | 26,14,26,14 |
| inset_panel (base PanelContainer) | 22,22,22,22 | 20,14,20,14 |
| tile_parchment / tile_dark | 16,16,16,16 | 18,8,26,8 |
| primary_green / secondary_dark | 14,14,14,14 | 14,8,14,10 / 18,8,18,10 |
| input_frame | 12,12,12,12 | 16,8,16,8 |

The full theme is `themes/pb_theme.tres`: base `Button`/`PanelContainer`/`LineEdit` styles
from these pieces plus the type variations `IconButton` (flat, gold-ring pressed state),
`StartButton` (primary_green), `ActiveButton` (gold-ringed normal), `EditorFrame`,
`HeaderFrame`, `FooterFrame`, `TileParchment`, `TileDark`.

## Known limitations (recorded, not hidden)

- The crest cover patches leave a faint band-phase seam where they meet the original
  carving; on the header it sits under the crest overlay position, and it has not been
  visible at game scale in review screenshots.
- The corner brackets came out of the generator at slightly different sizes (58x58 vs
  42x49); they are kept as-is and were not used on this screen.
- Edges stretch (not tile) — at the sizes the screen actually draws, stretch factors stay
  near 1.0 on the pieces' long axes, so border thickness reads constant.
