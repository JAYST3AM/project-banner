# Slice C visual evidence — the battlefield ground painter

Captured from the candidate `610d35d4bf8bd95be47fb0632475313957fd364f`. The harness is dev-only
(`scripts/dev/battle_ground_preview.gd` and its scene) and deliberately not part of the painter's production
set, which is the painter, its suite and one runner registration.

| File | Size | Seed |
|---|---|---|
| `m02c-ground-1280x720.png` | 1280×720 | 70717 |
| `m02c-ground-1920x1080.png` | 1920×1080 | 70717 |
| `m02c-ground-2560x1080.png` | 2560×1080 | 70717 |
| `m02c-ground-altseed.png` | 1920×1080 | 70718 (same field, second seed) |

Every run exited 0 with no parse or render errors, and each image's dimensions were read back from the PNG
header rather than assumed.

## What each panel is for

GPT-6 asked for terrain variety, relief and the battlefield boundary, so the harness shows all three rather
than a generic corner:

- **Left, the whole battlefield.** The entire baked field from one seed, framed with a hard outline and
  labelled at its edge: this is where the image stops. Terrain variety is readable as blotches of sage,
  olive, grey-green, brown and khaki rather than a flat wash — 7 terrain types and 8 soils across the 375
  cells of the default 25×15 grid, at 6×6 texels per cell (the ceiling) for a 150×90 image.
- **Right, 4× on the roughest ground.** The harness scans the baked image for the window with the greatest
  brightness spread and zooms there, nearest-neighbour, so individual texels stay visible. Adjacent texels
  differing sharply in brightness is the illumination term: facets catching light beside shaded ones. This is
  where relief is legible, and it is why the zoom is chosen by measurement rather than by picking a corner.
- **The second seed** rebakes the same field under seed 70718. 90.6% of sampled full-panel pixels differ,
  which is what "the seed changes the grain, not the geometry" looks like in practice.

## Verified

46 inherited suites plus `test_battle_ground_painter` at 60 assertions, all passing in 681 ms. That suite
began at 43,070 ms; GPT-6's long, narrow 4100×8 battlefield fixture proves the same texel floor with a
1025×2 grid instead of a square field of over a million cells, which is a 63× saving on every future
certification run.

The painter itself was added unchanged: every `BattlefieldTerrain` method it calls already exists on main, so
this extraction introduced no new dependency, and nothing here touches `battle_view.gd`, `gpu_crowd.gd`, the
GPU field, shaders or LOD.

Status: candidate published, visual evidence published, **merge on hold** and Gate A/Gate B awaiting GPT-6's
acceptance of the 60-assertion count.
