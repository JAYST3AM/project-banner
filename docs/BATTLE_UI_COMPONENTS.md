# M02 Slice B1 — isolated battle presentation components

Status: **candidate; Hermes verification pending**. Based on accepted main
`391de01d38462ee9616a5ba4feea422893b80446`.

## Scope

- `BattleCommandBar`: emits action strings, displays stage, force counts,
  selection, map/pause state. It does not execute orders.
- `BattleDeploymentOverlay`: draws the same bounded deployment zones used
  for deployment clearing; does not mutate the terrain.
- `BattleTacticalOverview`: draws simulation-supplied formation footprints,
  facing, selection and surviving strength at medium/full-map distance.
- Three headless suites and a standalone windowed preview scene.

These are **presentation-only** components. They are **not connected** to the
production GPU battlefield, the campaign adapter, selection logic or LOD.
They must not be reported as a playable battle HUD. No `gpu_crowd.gd`,
`battle_field.gd`, `battle_view.gd`, shader or game configuration change is
included. Jay's uncommitted LOD work is deliberately outside this branch.

## Deferred B2 dependencies

- `BattleUnitDock`: portrait/roster and selection events, to be extracted with
  explicit tests for missing atlas, casualty and selection state.
- `BattleMinimap`: source feature branch calls `BattleGroundPainter` from
  terrain Slice C. It must be decoupled through a terrain-image input or a
  standalone fallback before extraction. Do not silently pull Slice C into B.

## Verification

1. Import resources in this worktree; use this worktree's own class cache.
2. Run `test_battle_command_bar`, `test_battle_deployment_overlay`,
   `test_battle_tactical_overview` separately with `--require-native`.
3. Run all inherited suites separately with native module staged and a
   41-suite / 10,800-assertion warm-cache baseline. Inherited assertion drift
   must be zero; new suites must complete with nonzero assertions.
4. Run `res://scenes/dev/battle_ui_preview.tscn` windowed at 1280×720,
   1920×1080 and 2560×1080. Capture screenshots, inspect clipping,
   orientation, labels, selected outlines, strength strips and legibility.
5. Verify action signals and state text change correctly. Confirm preview
   has no campaign/simulation side effects and no parser/render errors.

No merge before GPT review of raw evidence. Do not integrate the live GPU
battlefield during B1.
