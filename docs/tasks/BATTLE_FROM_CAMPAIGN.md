# Task: the campaign's battles run on the compute path

Repo: `F:/VSC Projects/Project Banner` (Godot 4.7.2, GDScript, Vulkan compute).
Owner's directive: *"fix it so that the actual battle simulator that we named before is used when
entering battle; the old one on the campaign should be removed."* He means: a battle entered from the
campaign map must run on the compute path (`scripts/dev/gpu_crowd.gd` + `shaders/dev/crowd_sim.glsl`,
which he calls **Debug 2**), not on `scripts/battle/battle_simulator.gd` (the CPU battle).

**You cannot run Godot from your sandbox.** Write the code; the operator runs it. Do not claim
results you could not produce. Do not run the suite.

## The interface map (all of this is verified; you do not have to rediscover it)

**Where a battle starts, from the map:**
`scripts/world/world_map.gd:248` — `SceneManager.change_scene("battle", {"context": context})`.
The `context` is a `BattleContext` (`scripts/core/battle_context.gd`), built by
`scripts/world/encounter_service.gd:build_context()`. It carries `player_snapshot` and
`enemy_snapshot`: `Array[Dictionary]` of per-man records, plus `battle_seed`, `terrain_seed`,
`battle_id`, `world_party_id`, `enemy_party_id`, `player_party_id`, `enemy_display_name`,
`world_position`, `campaign_day`, `campaign_hour`, `weather`, `attacker`, `defender`, and the side
constants `SIDE_PLAYER` / `SIDE_ENEMY`.

**Turning the context into men:**
`scripts/battle/battle_setup.gd` — `BattleSetup.build_units(context) -> Array[BattleUnit]` (one
`BattleUnit` per man, with `soldier_id`, `display_name`, `level`, `unit_type_id`, `hp`, `max_hp`,
`attack`, `defence`, `move_speed`, `attack_range`, `attack_cooldown`, `ranged`, `position`,
`facing`, `alive`, and the tallies `kills`, `damage_dealt`, `killed_by_id`), and
`BattleSetup.build_units_prepared(context, config)` which also calls `deploy()` to lay them out.
**`BattleUnit` is one soldier, not a formation.**

**How a battle ends today, in the CPU scene (this is the code to mirror):**
`scripts/battle/battle.gd:971-975` —
```gdscript
var resolver := BattleResolver.build(state, _config)
result = resolver.build_result(_context, _simulator, _simulator.winner, _simulator.elapsed, retreated)
resolver.apply(result, _context)
```
then `SceneManager.change_scene("world_map", {"select_settlement_id": ""})` (line 958) and, for a
retreat, `EncounterService.apply_retreat(world_party)` (`scripts/world/encounter_service.gd:165`).

**What the resolver reads from the thing passed as `simulator` — the whole surface, two places:**
- `battle_resolver.gd:69` — `for unit in simulator.units:` then per unit `unit.side`,
  `unit.is_alive()`, `unit.soldier_id`, `unit.display_name`, `unit.level`, `unit.kills`,
  `unit.damage_dealt`, `unit.hp`, `unit.max_hp`.
- `battle_resolver.gd:165` — `simulator.find_unit(unit.killed_by_id)` to name a killer.
- and the two properties `simulator.winner` and `simulator.elapsed` from the call above.

**Scene registry:** `scripts/core/scene_manager.gd:22` — `"battle": "res://scenes/battle/battle.tscn"`.

**What the compute path already has (added today, commit `ebccbd7`):**
`scripts/dev/gpu_crowd.gd` reads back a per-man tally buffer: `tally(index) -> Vector4i` (x = kills,
y = hundredths of a hit point dealt, z = this tick's attacker, w = who killed him, -1 for none),
`kills_credited() -> int`, and the per-man state/meta arrays it already had. `_fallen` is the count.
It exposes `_alive: Vector2i` (player, enemy), `_tick`, and `tick_hz` (read from
`battle.tick_rate` in `data/config/game_config.json`, currently 30).

## What to build

1. **A game-side battle scene**, `scenes/battle/battle_field.tscn` + `scripts/battle/battle_field.gd`,
   whose script `extends "res://scripts/dev/gpu_crowd.gd"` (the dev scene's own .tscn is a single
   node with that script, so this keeps one implementation while the game stops pointing at a dev
   path). Nothing in the game's own files should reference `res://scripts/dev/` or the word "gpu"
   after this.

2. **The compute field must accept a battle from the campaign.** When the scene is entered with
   `{"context": BattleContext}` (read it the same way `scripts/battle/battle.gd` reads its own
   `_ready` parameters from `SceneManager`), it must:
   - build the men with `BattleSetup.build_units_prepared(context, config)`;
   - place the compute field's agents and bodies from those men — their per-man stats, their side,
     and their deployed positions from `BattleSetup.deploy` — instead of the synthetic
     `--agents=`, `--per-side=` layout the dev scene uses;
   - group men into **bodies** by side and by unit type (the campaign has no formation objects in
     this path yet), one body per (side, unit_type_id), ordered front-to-back as `deploy` laid them
     out. The shader's per-body lattice then keeps them in ranks as they march.
   - the existing dev CLI (`--agents=`, `--thirty`, `--seconds=`, `--per-side=`, `--bodies=`, …) must
     keep working exactly as it does now when no context is passed.

3. **The outcome must come back as the campaign's own result.** When the battle ends - one side has
   nobody left standing, the player or the enemy retreats, or the battle runs past its time limit -
   write the per-man outcome **back into the very `BattleUnit` objects built in step 2**: `alive`,
   `hp`, `kills`, `damage_dealt`, `killed_by_id` (from `tally(i).w`), `position`, `facing`. Then:
   ```gdscript
   var resolver := BattleResolver.build(state, config)
   var result := resolver.build_result(context, self, winner, elapsed, retreated)
   resolver.apply(result, context)
   SceneManager.change_scene("world_map", {"select_settlement_id": ""})
   ```
   For that, the field itself must satisfy the resolver's two calls: expose `units` (the array of
   `BattleUnit`s, alive and dead), `find_unit(id)`, `winner` (a side string, or `""` for a draw) and
   `elapsed` (battle seconds - the GPU clock ticks at `battle.tick_rate`, so `elapsed = ticks /
   tick_hz`). A retreat must end the battle the same way `battle.gd` does, including
   `EncounterService.apply_retreat`.

4. **The switch**: `scripts/core/scene_manager.gd` gets the new key (for example
   `"battle": "res://scenes/battle/battle_field.tscn"`), and `world_map.gd`'s encounter entry points
   at it. **The CPU battle scene and its code must stay in the repo and stay runnable** - the owner's
   earlier directive is that it is archived as the oracle, not deleted. It just must not be what a
   campaign battle uses. Do not delete, rename or edit `scripts/battle/battle_simulator.gd` or
   `scenes/battle/battle.tscn` in this task.

5. **Nothing else changes.** Do not touch the shader. Do not change the CPU battle's behaviour. Do
   not commit — leave the working tree for the operator to run and review.

## House rules that bite in this repo

- **`.gd` files are LF only.** A CRLF file breaks the project.
- **Warnings are errors.** Use `floorf()`/`ceilf()`, not `floor()`/`ceil()` (they return Variant).
- **Never kill Godot processes** - the owner has windows open. Not even "just the headless ones".
- `gpu_crowd.gd` is ~2,950 lines and builds all its nodes in code; read the arg parsing and the
  `_run_tick` / end-of-battle exit path before adding to it.

## What to report

The files you changed, the design of the two bridges in a few sentences, and anything you had to
assume because the code did not say. Do not report tests as passing; you cannot run them.
