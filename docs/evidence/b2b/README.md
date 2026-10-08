# B2b visual evidence — the tactical minimap

Captured from the candidate `cabf891ecc64b764640c6c0e259b5f5ef1de5605` — the extraction plus every boundary
and rendering-contract requirement raised in review, including the facing-tip clamp. Synthetic fixtures only:
no battle, no campaign, no GPU battlefield, which is what this slice is explicitly not wired to yet.

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
diagonally, and the camera is parked on the bottom-right corner with a tiny span.

**The facing tip, measured rather than eyeballed.** The tip is a 1.3-pixel dot on a separate draw path from
the marker polygon, so it can leave the map even when every polygon corner is clamped - which is exactly what
it did. Counting pixels of the three tip colours inside the panel but outside the map rectangle, with the map
bounds derived from the image rather than assumed:

| Capture | Tip-coloured pixels outside the map |
|---|---|
| before the tip clamp | **26** - the first at (49,249), one pixel left of the map edge at x=50, i.e. formation 1 on the left edge facing outward |
| after the tip clamp | **0** |

The same counting over the marker polygons and the camera footprint: nothing outside the border, and the
footprint at the corner is wholly inside it rather than crossing it, which is what it did before the minimum
size was applied before the position clamp.

Only the two edge-stress captures changed between those revisions. The six open-field ones are byte-identical,
which is the evidence that the tip clamp bites only at the boundary.

These images are evidence, not assets: this branch exists so they stay out of the candidate and out of
main's history.

## Verified

46 suites, 11,037 assertions, 0 failures, assertion drift none, on both the candidate `cabf891` and the
rehearsal merge `956dc9c1b76db8623a3afe72fbe2f9172641db1f` (parents `34d8e348` + `cabf891`). The minimap
suite alone asserts 123.

Certification inputs, identical for both gates: suite list sha256 `00b32134876a6a2f` |
baseline sha256 `d80b35ece548644f` | runner sha256 `8efd3adf674e61a4`.

Every suite is still at +0 against the baseline, all 46 of them. The minimap suite has moved four times
through review — 49, 66, 90, 123 — and no other suite has ever moved at all.

Progression of the artefact, all superseded: the extraction as first written (`92e3825`) certified at 10,963;
after the first two boundary requirements (`e59bf67`) at 10,980; after the three rendering-contract gaps
(`0eaccb44`, now integrated into main as its second parent) at 11,004; and after the facing-tip clamp
(`cabf891`, this capture set) at 11,037.

Jay's dirty working tree has remained at 56 entries throughout.
