# PB-213 — Feature branch decomposition: dependency map

Branch to decompose: `feature/battle-command-overview-v1` @ ebc2f23c3cb3e4ee931fb1bb79f9d7e650af2910
Base: `main` @ 70a6017f18f938d95ad272c5cf5a06fdf0733534 (merge-base = main HEAD — branch is clean fast-forward content, no rebase needed).
Diff footprint: 32 files, +3379/-115, 87 commits (newest-first list preserved in `feature_commit_map.json`).
Feature branch stays as source-of-truth archive; no history rewrite, no merge by anyone on this board.

## Hot files (collision risk)
- `scripts/dev/gpu_crowd.gd` — touched by 21 commits across 5 different functional systems. Slice by hunks, never whole-file cherry-picks; never two slices editing it concurrently.
- `tests/test_runner.gd` — registration diff is exactly 10 added suite lines (main..feature @ ebc2f23); each slice adds its own lines only, sequential rebase required.
- `scripts/battle/battle_field.gd` (5 commits, 3 systems), `scripts/battle/battle_view.gd` (1 commit), `shaders/dev/crowd_sim.glsl` (2 commits).
- Jay's dirty working tree touches 4 of the 32 files (`gpu_crowd.gd`, `battle_view.gd`, `battle_field.gd`, `crowd_sim.glsl`) — extraction must rebase onto main 70a6017, not on Jay's uncommitted state.

## Slices (GPT-6's PR-A..F order, now commit-pinned)

### PR-A — Navigation, placement, cohesion (deps: main) — 1632 test lines
Commits (oldest→newest):
- Planning/core: c80fb0c, 49e57ce, 0a3469b, 31addc9, a9a2bb9, e5dd50c, d931412, 01531dd, 7d89da9, 38469ab, 559cf97
- Placement: 72a0800, f1425c2, 89e2cef, 4b7c6e9
- Cohesion: 7e45c2a, 06d70ae, 78b680a, ebc2f23
- gpu_crowd.gd hunks: move-order routing (49e57ce, a9a2bb9, d931412, 38469ab), waypoint tolerance, right-drag frontage + group destinations (f1425c2), cohesion anchor slowdown (06d70ae).
- Files: `battle_formation_navigator.gd`, `battle_placement_planner.gd`, `battle_formation_cohesion.gd`, gpu_crowd.gd hunks, tests `test_battle_formation_navigator.gd` (232), `test_battle_placement.gd` (78), `test_battle_formation_cohesion.gd` (44), + test_runner.gd registration lines.
- Note: the "blocked-command fix" named in the ticket = frontendage/invalid-order rejection work (d931412, f1425c2). `wt/nav-blocked-command` @ a4a42b8 is separate; check overlap before slicing.

### PR-B — Ground painter, terrain art, scenery, deployment zones (deps: main) — 1049 test lines
Commits:
- Ground: 132dfdc, 989b513, 339454e, 7098085, c49df8b, afdff92, 2e07199, 634247f, 2f4a3b7, 5331ccd
- Ground shader/masks: bdc6258, e482733, e10d371
- Art audit: 92c91c4, 35eda62, e66691f, a9af3d4
- Scenery: 3777e82, d3b36be, a9c1e6c, 219e092, 794681e
- Deployment: 4919a4a, be46929, 008b468, a0b7ca4, 6e6a04d, 0e8763f
- gpu_crowd.gd hunks: ground bake paths, biome generation vs fallback, scenery rendering, deployment frontline viz.
- Files: `battle_ground_painter.gd`, `terrain_ground.gd`, `shaders/battle/ground.gdshader`, `battle_terrain_art_audit.gd`, `battle_scenery.gd`, `battle_deployment_overlay.gd`, gpu_crowd.gd hunks, 5 test suites (~1049 lines), test_runner.gd lines.
- Deal-breaker cut line: move the ground-shader/mask trio (bdc6258, e482733, e10d371) to PR-D if PR-B won't compile green without PR-D's mask consumer — verify at extraction time, document whichever way it lands.

### PR-C — UI layer (deps: PR-A for selection semantics) — 574 test lines
Commits:
- eb02c81, 35071ff, b74a14b, f5ed98d, 7f5e82d, 0832be0, 27492e4, f0b0951, fcfeaa1, 3724ff8, 6770c94, c1e2dd2, e576ba6, 7454541, da1dc95, 0fe2ac2, 4ea81a5, ca88043, a4f1065
- gpu_crowd.gd hunks: selection wiring (b74a14b), archetype names in cards (f5ed98d), command HUD swap (f0b0951), minimap camera wiring (6770c94), LOD snapshot gating (4ea81a5).
- Files: `battle_command_bar.gd`, `battle_unit_dock.gd`, `battle_minimap.gd`, `battle_tactical_overview.gd`, gpu_crowd.gd hunks, 4 test suites (test_battle_minimap 41, test_battle_tactical_overview 29, test_battle_deployment_overlay already in PR-B — check), test_runner.gd lines.

### PR-D — GPU terrain mask + collision (deps: PR-A and PR-B consumers)
Commits: fe1d7d0, 572efe3, b7f6c03, ba7dfda, 0235342, 313358c, 85312bd, ac65073, bb1f8f6, 310c43b
- gpu_crowd.gd hunks: mask build + upload (b7f6c03), collision gating (ba7dfda), traversal pre-clearing (6e6a04d belongs to PR-B but touches the same region — sequence B before D).
- Files: `battle_terrain_gpu_mask.gd`, `shaders/dev/crowd_sim.glsl`, gpu_crowd.gd hunks, `test_battle_terrain_gpu_mask.gd` (141), test_runner.gd lines.

### PR-E — Remaining gpu_crowd.gd integration hunks (deps: PR-A/C/D)
Commits leftover after A/B/C/D assignment: 02c3027, 856e415, 7149065 (GPU sprite atlas archetypes; touches gpu_crowd.gd + battle_field.gd + test_unit_sprites.gd/godot (5 lines)).
- This is the "everything in gpu_crowd.gd that consumers depend on" bucket. If hunks prove independent during extraction, they may fold into D instead — Smith decides with evidence, documents the choice.

### PR-F — Documentation & hardening (deps: all prior)
- 11c4b73 (HERMES_TERRAIN_INTEGRATION.md), a9af3d4, 85312bd (BATTLE_VISUAL_TARGET.md bullets)
- Final `tests/test_runner.gd` sweep: all 10 suite lines registered exactly once.

## Scheduling constraints
- PR-A and PR-B are independent: may run in parallel worktrees, but both touch gpu_crowd.gd — Smith must serialize the hunk extraction, not the test runs.
- Registration: one slice owner at a time touches test_runner.gd; each rebase re-applies only that slice's lines. Sequential order A → B → C → D → E keeps conflicts zero.
- C overlaps A on selection semantics; land A before C's final verification pass.

## Facts for the coverage-discrepancy ticket
- main @ 70a6017: 38 suites / 10,317 assertions / 0 failures (regression baseline c59f991, remote branch `regression-baseline-main`) — note: CURRENT_STATE.md's 10,115 figure is stale by 202 assertions as of 2026-10-08.
- feature @ ebc2f23: 38 + 9 = 47 suites in runner after the +10-line registration diff (one line — test_battle_formation_navigator — is registered by commit 31addc9 in the chronological map; recount at extraction). Exact per-slice counts belong to Warden's runs.

## Untested / unverified
- All commit assignments are from git metadata, not code reading. Smith must verify each slice compiles + tests green headlessly before opening its PR. Nothing here is verified gameplay.
