# M02 Slice B2a — BattleUnitDock extraction

Status: **implementation candidate; Godot verification pending**.
Base: main at 5f7eb223f5b0947dd7f329ffa38d44a01475e8aa.

## Contract

- Presentation-only friendly formation roster. No simulation, orders, GPU scene, campaign adapter or LOD changes.
- Each full snapshot replaces the previous roster: invalid/enemy IDs ignored, duplicate IDs ignored,
  removed formations have their cards removed, and incoming order is preserved.
- Destroyed friendly formations still present in a snapshot remain visible at 0 strength, but are
  disabled and cannot be selected. Removed IDs can no longer emit events.
- Selection is owned by the caller. The dock emits body_chosen(id, additive); it does not apply
  selection or mutate formation state. Shift-click is the additive UI gesture.
- Missing atlas art is a neutral class sign. A changed type_key rebuilds the portrait card.
- Casualty counts and strength bars derive from alive / started, with safe clamping.

## Verification required before accepting a new baseline

1. Native module, imports and Godot class cache must be staged in a clean isolated worktree.
2. Run test_battle_unit_dock alone; report Godot-measured assertion count, exit and script errors.
3. The 44 inherited suites remain exactly 10,864 assertions, with no drift or failures.
4. New suite count requires explicit baseline acceptance before extending the gate to 45 suites.
5. Windowed roster preview must demonstrate live, depleted and dead cards; neutral fallback;
   selection and clipping at 1280x720, 1920x1080 and 2560x1080.
6. No merge before combined-tree certification and visual review.

B2b BattleMinimap remains separate and must not import BattleGroundPainter from terrain Slice C.
