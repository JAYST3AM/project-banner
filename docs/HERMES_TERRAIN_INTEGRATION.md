# Hermes ↔ GPT terrain integration handoff — 2026-10-08

## Collaboration boundaries

**Hermes owns the art factory** under `F:/ProjectBanner-AI/scripts/` and
`outputs/project_banner/terrain/`: generation, crop, edge matching, palette
normalisation, contact sheets and true-scale scene comparisons.

**GPT owns the draft battle rendering/controller integration** on
`feature/battle-command-overview-v1` (draft PR #2).
Coordinate before editing the same renderer, map, or battle-control files.

This document does not authorize copying or replacing unapproved art in
`assets/terrain/`.

## Contract — no alternate tile size or filenames

- Source of truth: `data/terrain/biomes.json`.
- Seven biomes: plains, forest, highlands, swamp, arid, tundra, coastal.
- Every biome currently defines 4 *variant concepts*, but only plains
  currently enumerates the full 16 concrete 64×64 ground PNG paths.
  The other six biomes deliberately have empty variant art lists until
  Hermes' outputs are approved and the catalogue is updated.
- Source images are 64×64, seamless, and base ground is opaque. Never
  invent another biome's filenames merely from a naming convention.
- Four overlays × two source files per biome, following catalogue paths.
- `variant_scale` 4.0 world units; `overlay_scale` 3.0 world units;
  `terrain.visual_pixels_per_unit` 1.0.
- Source textures retain nearest-neighbour pixel information. Never shrink a
  1024² render to 64² and call it new detail.
- Visual art files are independent from gameplay terrain cells.

## Ground integration fixes currently on the draft branch

1. `scripts/battle/terrain_ground.gd` takes ground-map resolution from
   `GameConfig.get_float("terrain.visual_pixels_per_unit", 1.0)`;
   it no longer calls the reverted/missing
   `BattlefieldTerrain.visual_pixels_per_unit(config)`.
2. `TerrainGround._build_type_map(ppu)` produces three visual material masks
   from **existing** `BattlefieldTerrain.type_id_of_cell()` values:
   R=water, G=cliff, B=mud.
   The terrain simulation model remains unchanged.
3. `shaders/battle/ground.gdshader` has been supplied to replace a missing
   shader resource and reads the existing generated RGB variant weights,
   height, overlay masks and type masks.
4. The shader selects a deterministic hashed sub-tile index by world repeat
   coordinate. **This is not the final UV-phase/de-grid solution.** Test
   repetition and visual seams on Hermes' actual 64px texture set.
5. Missing optional overlays and shared water/rock/mud art are tolerated,
   retaining material-tinted fallback colours. Missing first-variant art
   causes `show_field()` to return false and the procedural fallback to draw.
6. Unit cards/minimap/formation overlays now build full snapshots only on
   simulation ticks or LOD transitions; camera motion updates separately.
   Re-benchmark on local GPU against Hermes' published floor.

## Known limits — do not claim solved

- Current authored shader's look, shader compile status, 64px art quality
  and real GPU performance must be verified in **windowed Godot**, not only
  in headless tests.
- The hashed sub-tile selection changes between repeats and may itself reveal
  borders. A candidate UV-phase or stochastic blend must be reviewed with
  4×4 mosaics and full battlefield pictures before approval.
- Ground/prop gameplay collision and soldier-level routing on the GPU
  remain incomplete. Formation-anchor routefinding exists separately.
- Existing unit sprites are 64² and cannot magically gain near-camera
  detail from image upscaling.
- Unreviewed tiles remain outside `assets/`. Build pipeline source art and
  `.uid` files must be committed intentionally after approval.

## Suggested next art QA

- Index the 16 plains ground sub-tiles and 8 overlay sub-tiles by exact filename.
- Repeated 4×4 mosaics for each variant and the overlay masks.
- True-scale screenshot with actual unit atlas and transparent props.
- Same-camera before/after for texture and shader sampling candidates.
- 1080p and 1440p battle screenshots, including formation close, medium,
  and whole-map strategic zoom.
- Separate technical seam measurements from *perceived* square-grid boundaries.
- Report shaders, sprites, files and captured Godot errors with exact
  branch and commit hashes.

## Release discipline

PR #2 stays a draft until the latest Godot CI and a real rendered battle
both pass. Passing headless tests does not prove battlefield visual quality.

## Tile-import verification on this branch

- `scripts/battle/battle_terrain_art_audit.gd` reads only art paths already
  present in the catalogue and checks existing textures for native 64×64
  dimensions, exact wrap-edge compatibility, and base-ground opacity.
- `tests/test_battle_terrain_art_audit.gd` enforces the contract on current
  installed art, with deliberately missing assets reported but not treated
  as errors.
- The first Plains batch contains 16 declared ground PNG paths and 8
  declared overlay PNG paths. Unapproved tile files remain in Hermes'
  factory and should not be copied into `assets/` without review.
