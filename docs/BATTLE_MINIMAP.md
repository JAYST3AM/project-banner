# M02 Slice B2b — BattleMinimap extraction

**Status:** INTEGRATED into main at `956dc9c1b76db8623a3afe72fbe2f9172641db1f`.

The tactical minimap was recovered from `scripts/battle/battle_minimap.gd` in the owner's scratch worktree.
In its original form it could not compile against main at all: `set_terrain()` called
`BattleGroundPainter._paint_colour()`, and that class does not exist anywhere in `scripts/` on main. That
coupling is precisely what this slice removes.

## Contract

**It displays battlefield state; it does not generate terrain and it does not own camera movement.**

- **Terrain imagery is an OPTIONAL INPUT.** `set_terrain_texture(texture: Texture2D, world_size: Vector2)`
  takes an image the caller painted, and accepts `null`. The world size is recorded independently of the
  image, so with no imagery at all the formations, their colours, the selection highlight and the camera
  rectangle all still project correctly. Absence of imagery is a first-class state, not a fault.
- **No terrain dependency.** The class references no ground painter and no terrain slice. This is enforced by
  a test that reads the source with its comments stripped and asserts those names do not appear in the code.
- **Navigation is a request, never an action.** Clicking or dragging the map emits
  `navigate_requested(world: Vector2)`. Nothing in the class moves a camera.
- **Pure statics carry the maths**, so the behaviour can be asserted without a renderer: `world_to_map`,
  `map_to_world`, `facing`, `marker_polygon`, `facing_tip`, `marker_ink`, `marker_outline`,
  `marker_tip_colour` and `viewport_rect`. `_draw()` composes them and does nothing else.
- **Nothing draws outside the map.** Marker footprints, their facing tips and the camera footprint are all
  clamped into the map rectangle, each with a named constant so the drawn and clamped geometry cannot drift.

## Verification performed (accepted baseline: 46 suites / 11,037 assertions)

The suite `tests/test_battle_minimap.gd` asserts **123** checks across eleven areas: projection both ways and
its clamping at every edge; markers and facing, including the no-facing fallback; marker size floors; the
boundary clamp at four corners and four edge midpoints; tip clamping at those same eight positions against all
four cardinal facings plus an open-field control; the camera footprint across span, zoom, the minimum-size
floor, every corner and oversized spans; selection colour, including that a hostile formation can never
receive it; click and drag navigation through synthetic input events; resize behaviour; and the no-imagery
state end to end.

The count moved four times under review, and **no other suite has ever moved**:

| Revision | Commit | Minimap | 46-suite total |
|---|---|---|---|
| extraction as first written | `92e3825` | 49 | 10,963 |
| two boundary requirements | `e59bf67` | 66 | 10,980 |
| three rendering-contract gaps | `0eaccb44` | 90 | 11,004 |
| facing-tip clamp | `cabf891` | 123 | 11,037 |

Merged to main twice, each time as the certified rehearsal pushed as-is:

| Merge | main | parents |
|---|---|---|
| B2b | `34d8e348` | `b23df31` + `0eaccb44` |
| facing-tip correction | `956dc9c` | `34d8e348` + `cabf891` |

Every inherited suite reports `+0` against the baseline, all 46 of them, in both gates of the final round.
Certification inputs for the accepted baseline: suite list `00b32134876a6a2f`, baseline
`d80b35ece548644f`, runner `8efd3adf674e61a4`.

Screenshots and their findings live on `tests/b2b-evidence` (currently
`1320ea944d4371f98638f533f2fe15574420c1bf`), deliberately on a branch based on main so the images are never
ancestors of the candidate or of production history. That evidence includes the facing-tip measurement that
caught what the polygons alone did not: counting tip-coloured pixels inside the panel but outside the map
gives 26 before the clamp and 0 after it.

## Integration points

`battle_view.gd` and the `gpu_crowd` dev scene are the two callers in the original worktree; neither is
wired up by this slice. The minimap is not yet connected to the live GPU battlefield - that is Slice E - and
the terrain imagery it will consume is Slice C's to supply, through the optional input above.

## Outstanding

- Not wired to the live GPU battlefield (Slice E).
- No terrain imagery is supplied in-tree yet; Slice C produces it.
- The minimap's own `_draw()` is exercised visually through `scenes/dev/battle_minimap_preview.tscn` with
  synthetic fixtures, not by the suite, which asserts the pure statics and the input handling.
