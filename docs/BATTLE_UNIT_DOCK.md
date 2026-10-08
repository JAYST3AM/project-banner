# M02 Slice B2a — BattleUnitDock extraction

Status: **INTEGRATED into main at 131daf76d57e3b4988e129ab058006e20ea1c463**.
Merge: first parent 5f7eb223f5b0947dd7f329ffa38d44a01475e8aa (the main it was reconciled against), second
parent 7035b08141e3d9391d647c789eaa80b43050f9a1 (the certified candidate).

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

## Verification performed (accepted baseline: 45 suites / 10,914 assertions)

1. Native module, imports and Godot class cache staged in a clean isolated worktree — done; the gate
   refuses a worktree that differs from HEAD, so the tree certified is the commit certified.
2. test_battle_unit_dock alone: PASS, **50 assertions**, 0 failures, 0 script errors, Godot-measured.
3. The 44 inherited suites remain exactly 10,864 assertions, no drift, no failures.
4. The new suite's count was measured and explicitly accepted before the baseline moved to 45. Measured
   first at 28 against an independently built suite, then 50 against the fuller suite that became the
   candidate — the superseded number was never carried forward.
5. Windowed roster preview demonstrated live cards, a depleted card in the low-strength colour, a dead
   card dimmed and disabled, the neutral fallback sign for an unknown class, the gold selection outline
   and no clipping at 1280x720, 1920x1080 and 2560x1080. Captures: branch `tests/b2a-evidence`,
   `docs/evidence/b2a/`.
6. Combined-tree certification and visual review completed before the merge.

Certifications: Gate A (candidate `7035b08`) and Gate B (combined `131daf7`) — both **45 suites, 10,914
assertions, 0 failures, zero assertion drift, gate exit 0**, certified under suite list `7d2745cefb9a7a03`,
baseline `0d809b8b9f1ea017`, runner `996b8da8efa9f0f6`.

B2b BattleMinimap remains separate and must not import BattleGroundPainter from terrain Slice C.
