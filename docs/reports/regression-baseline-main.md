# Regression baseline — main (pre-DIRECTIVE-001)

**Commit:** `70a6017f18f938d95ad272c5cf5a06fdf0733534` (main, no patch applied)
**Branch:** `regression-baseline-main` (worktree `.worktrees/t_fdb6039a`)
**Engine:** Godot_v4.7.2-stable_win64_console.exe, headless, `--require-native`
**Date run:** 2026-10-08 (Melbourne)

## Verdict

**Main is green.** 38/38 suites ran, 10,317 assertions, 0 failures, RESULT: PASS on every run.
Every suite was run in isolation (one engine process per suite) with raw output captured in `logs/`.

## Totals

| Suites run | Assertions | Failures | Crashed / hung / timed out |
|---|---|---|---|
| 38 of 38 | 10,317 | 0 | none |

## Per-suite results

Raw `(N assertions, M failures, T ms)` line per suite, verbatim.

| Suite | Result | Assertions | Failures | ms | Notes |
|---|---|---|---|---|---|
| `test_core_services` | PASS | 83 | 0 | 52 |
| `test_campaign_flow` | PASS | 41 | 0 | 670 |
| `test_banner` | PASS | 580 | 0 | 1193 |
| `test_world_map` | PASS | 116 | 0 | 920 |
| `test_world_chunks` | PASS | 11 | 0 | 626 |
| `test_world_sites` | PASS | 48 | 0 | 8589 |
| `test_settlement_details` | PASS | 28 | 0 | 208 |
| `test_settlement_buildings` | PASS | 33 | 0 | 123 |
| `test_trade_caravans` | PASS | 92 | 0 | 1540 |
| `test_sprite_list` | PASS | 2 | 0 | 179 |
| `test_settings` | PASS | 24 | 0 | 63 |
| `test_roads` | PASS | 90 | 0 | 6090 |
| `test_recruitment` | PASS | 191 | 0 | 933 |
| `test_party_semantics` | PASS | 51 | 0 | 1643 |
| `test_encounters` | PASS | 282 | 0 | 1444 |
| `test_combat` | PASS | 275 | 0 | 7112 |
| `test_battle_outcomes` | PASS | 224 | 0 | 1163 |
| `test_terrain` | PASS | 84 | 0 | 871 |
| `test_formation` | PASS | 328 | 0 | 729 |
| `test_formation_battle` | PASS | 132 | 0 | 7180 |
| `test_battle_view` | PASS | 8 | 0 | 605 |
| `test_spatial_grid` | PASS | 111 | 0 | 609 |
| `test_overlap` | PASS | 189 | 0 | 6927 |
| `test_overlap_oracle` | PASS | 4283 | 0 | 4162 |
| `test_target_acquisition` | PASS | 321 | 0 | 4167 |
| `test_formation_focus` | PASS | 99 | 0 | 2421 |
| `test_target_search` | PASS | 51 | 0 | 915 |
| `test_native_query` | PASS | 1273 | 0 | 4598 |
| `test_battle_hardening` | PASS | 95 | 0 | 232413 |
| `test_formation_engagement` | PASS | 206 | 0 | 150129 |
| `test_soldier_batch` | PASS | 24 | 0 | 49 |
| `test_battle_arrows` | PASS | 16 | 0 | 26 |
| `test_unit_sprites` | PASS | 460 | 0 | 619 |
| `test_enemy_persistence` | PASS | 121 | 0 | 589 |
| `test_e2e_loop` | PASS | 164 | 0 | 2686 |
| `test_persistence` | PASS | 121 | 0 | 588 |
| `test_legacy_menu` | PASS | 30 | 0 | 1355 |
| `test_runner_contract` | PASS | 30 | 0 | 78 (output contains the suite's own provoked fixture failures — expected) |

## Notes

- `test_runner_contract` printed `FAIL  a deliberately failing assertion` and one intentional
  `SCRIPT ERROR`: both are the suite's own self-test fixtures (it provokes a failure and an abort
  to prove the runner detects them). Suite classified PASS, 30 assertions, 0 failures.
- Two slow suites by the engine's own clock: `test_battle_hardening` 232,413 ms and
  `test_formation_engagement` 150,129 ms. Nothing hit the runner's 90-second stuck-suite
  watchdog (each suite ran in its own process; no kills, no timeouts, no crashes).
- `test_native_query` and `test_overlap_oracle` (the two suites CI gates with `--require-native`)
  both PASS. The `pb_native.windows.template_release.x86_64.dll` (built 2025-09-17) was copied
  from the main repository's `addons/pb_native/bin/` into this worktree because the dll is
  git-ignored. No native source was rebuilt or modified.
- Suite list source: the `SUITES` array in `tests/test_runner.gd` (38 entries), cross-checked
  against `.github/workflows/godot-tests.yml` and the `tests/` directory. `persistence_check` is
  a separate two-phase scene, not an entry in the SUITES array, and was not run as part of this
  baseline.

## Rerun

    <godot> --headless --path <worktree> res://scenes/dev/tests.tscn -- --suite=<name> --require-native
