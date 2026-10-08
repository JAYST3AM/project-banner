# Formation command foundation — clean main-based integration slice

The formation planners were isolated from the unreviewed battle-command feature
branch for independent review. These files are reusable, headless-testable
algorithms; this commit **does not** wire them into the live GPU battlefield.

## Contracts

- `BattleFormationNavigator`: deterministic A* formation-anchor routes over
  authoritative traversability and movement cost, with rotation-safe radius
  clearance. An unreachable destination produces an empty path. The six-line
  self-tile blocked-command fix from commit `a4a42b8` is included.
- `BattlePlacementPlanner`: right-click translation and drag-to-frontage
  preserve independent formation IDs and centre spacing. Boundary handling
  shifts all selected formation centres together rather than individually
  clamping them onto the same tile. Impossible group widths produce an empty
  plan, not overlapping destinations.
- `BattleFormationCohesion`: a bounded, monotonic movement multiplier based
  solely on measured soldier-to-slot error; no morale or combat changes.

Only formation centres are bounded by the planner. Full soldier footprint
clearance remains the responsibility of the navigator and downstream caller.
Terrain navigation grids are static until the next `setup()`.

## Exact verification commands (Godot 4.7.2)

```sh
godotc --headless --path . res://scenes/dev/tests.tscn -- --suite=battle_formation_navigator
godotc --headless --path . res://scenes/dev/tests.tscn -- --suite=battle_formation_cohesion
godotc --headless --path . res://scenes/dev/tests.tscn -- --suite=battle_placement
godotc --headless --path . res://scenes/dev/tests.tscn
```

## Integration and ownership

The feature branch still owns live `gpu_crowd.gd` integration; that
unreviewed file is intentionally not included here. Do not merge the full
feature branch into main just to use these modules. No Godot result is
claimed until Hermes executes the above commands locally and reports logs.
