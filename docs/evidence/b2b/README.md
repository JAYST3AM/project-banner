# B2b visual evidence — the tactical minimap

Captured from the candidate `e59bf67dfd7f964fee5af02b648525157a9991c9` (extraction plus the two boundary
requirements from review). Synthetic fixtures only: no battle, no campaign, no GPU battlefield, which is
what this slice is explicitly not wired to yet.

| File | Size | Terrain imagery |
|---|---|---|
| `b2b-terrain-1280x720.png` | 1280×720 | supplied |
| `b2b-terrain-1920x1080.png` | 1920×1080 | supplied |
| `b2b-terrain-2560x1080.png` | 2560×1080 | supplied |
| `b2b-noterrain-1280x720.png` | 1280×720 | none |
| `b2b-noterrain-1920x1080.png` | 1920×1080 | none |
| `b2b-noterrain-2560x1080.png` | 2560×1080 | none |

`.log` beside each capture is that run's engine output. Every run exited 0 with no parse or render errors,
and each image's dimensions were read back from the PNG header rather than assumed.

## What the captures are for

The terrain image is generated inside the harness — coarse blocks of two greens — and handed to the minimap
as a `Texture2D`. That the minimap draws it without knowing who painted it is the point of the slice: the
original called `BattleGroundPainter._paint_colour()`, a class that does not exist in `scripts/` on main, so
it could not compile outside the one worktree it came from.

The `--no-terrain` captures are the other half of that claim. No image is not an error state: the field
draws flat, and the formation markers, their colours, the gold selection outline and the camera-footprint
rectangle all still project correctly, because the world size is recorded independently of the image.

## What the captures show

- Friendly formations teal on the left, hostile red on the right.
- Exactly one footprint outlined in gold: the selected formation, whose facing is visible as the long axis
  of its marker.
- Formations 2 and 5 rotated to their diagonal facings, not axis-aligned.
- A thin pale rectangle marking the camera's true footprint — roughly 43% × 44% of the map, which is what
  `span (260,140)` in a `600×320` field should be.
- The destroyed formation is not drawn at all.
- No marker spills outside the map rectangle at any size.

The terrain and no-terrain captures are byte-for-byte the same size at matching resolutions, because the
fixtures sit in open field and the boundary clamp added in review only bites at the field's edge. The
screenshots are therefore valid for both `92e3825` and `e59bf67`.

These images are evidence, not assets: this branch exists so they stay out of the candidate and out of
main's history.

## Verified

46 suites, 10,980 assertions, 0 failures, assertion drift none, on both the candidate `e59bf67` and the
rehearsal merge `3cc17ef` (parents `b23df31` + `e59bf67`). The exact candidate `92e3825` was separately
certified at 46 suites, 10,963 assertions, 0 failures, drift none.
