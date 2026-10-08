# B2b visual evidence — the tactical minimap

Captured from the candidate `0eaccb4466a124fbf23bacfe8ba3a45fdf436efd` — the extraction plus every boundary
and rendering-contract requirement raised in review. Synthetic fixtures only: no battle, no campaign, no GPU
battlefield, which is what this slice is explicitly not wired to yet.

| File | Size | Layout | Terrain imagery |
|---|---|---|---|
| `b2b-terrain-1280x720.png` | 1280×720 | open field | supplied |
| `b2b-terrain-1920x1080.png` | 1920×1080 | open field | supplied |
| `b2b-terrain-2560x1080.png` | 2560×1080 | open field | supplied |
| `b2b-noterrain-1280x720.png` | 1280×720 | open field | none |
| `b2b-noterrain-1920x1080.png` | 1920×1080 | open field | none |
| `b2b-noterrain-2560x1080.png` | 2560×1080 | open field | none |
| `b2b-edgestress-1280x720.png` | 1280×720 | edge stress | supplied |
| `b2b-edgestress-2560x1080.png` | 2560×1080 | edge stress | supplied |

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

The edge-stress captures exist because the open-field layout cannot demonstrate the boundary and footprint
fixes at all. In them, formations sit ON all four edges facing outward, one sits in a corner facing out
diagonally, and the camera is parked on the bottom-right corner with a tiny span. Read back from the
2560x1080 capture: markers sit flush on the left, right, top and bottom edges; no part of any marker
extends over the map's border; and the camera footprint in the bottom-right corner is wholly INSIDE the
border rather than crossing it — which is exactly what it did before the fix, because only the rectangle's
corner was clamped and the rest of it escaped.

These images are evidence, not assets: this branch exists so they stay out of the candidate and out of
main's history.

## Verified

46 suites, 11,004 assertions, 0 failures, assertion drift none, on both the candidate `0eaccb44` and the
rehearsal merge `34d8e348` (parents `b23df31` + `0eaccb44`). The minimap suite alone asserts 90.

Earlier in the same slice, both superseded by the review's three rendering-contract fixes — which is why the
captures here come from `0eaccb44`: the extraction as first written (`92e3825`) certified at 46 suites /
10,963 assertions / 0 failures / drift none, and the same tree after the first two boundary requirements
(`e59bf67`) at 10,980.

All 45 suite counts inherited from main are unchanged through every one of those revisions; only
`test_battle_minimap` moved, 49 to 66 to 90.
