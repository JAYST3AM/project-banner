# Game Architecture

How Project Banner is put together: what owns what, who talks to whom, and why.
Update this file in the same commit as any structural change.

---

## 1. Layers

```
+---------------------------------------------------------------+
|  UI / Scenes            main menu, world map, settlement,      |
|                         battle, battle results                 |
+---------------------------------------------------------------+
|  Gameplay systems       travel, encounter, recruitment,        |
|                         battle simulation, battle resolution   |
+---------------------------------------------------------------+
|  Data model             CampaignState, Party, Soldier,         |
|                         Settlement, WorldParty                 |
+---------------------------------------------------------------+
|  Services               config, RNG, save, scene, logging      |
+---------------------------------------------------------------+
```

The dependency arrow only ever points downward. Scenes read and call gameplay
systems; gameplay systems mutate the data model; the data model depends on
nothing but the services.

**Gameplay logic never lives in a scene script.** The battle is the clearest
example: `BattleSimulator` resolves combat as pure data, and `battle.tscn` only
draws its state and forwards player orders into it. That is what makes the whole
combat loop testable headlessly.

---

## 2. Singletons (autoloads)

Registered in `project.godot`, in this order:

| Autoload | Script | Owns |
| --- | --- | --- |
| `DebugLogger` | `scripts/core/debug_logger.gd` | log ring buffer, categories, levels |
| `GameData` | `scripts/core/game_data.gd` | the loaded `GameConfig` and cached `data/` JSON |
| `SaveManager` | `scripts/core/save_manager.gd` | reading/writing save files, version migration |
| `SceneManager` | `scripts/core/scene_manager.gd` | every scene transition + transition payloads |
| `GameManager` | `scripts/core/game_manager.gd` | **the active `CampaignState`** |

There are exactly five, and the rule is: a system becomes a singleton only if it
must outlive a scene transition. Everything else - combat maths, travel,
recruitment, name generation - is a plain class instantiated by whoever needs it.

`GameManager` deliberately owns the campaign rather than being the campaign
itself: `CampaignState` is a plain `RefCounted`, so a test can build one without
touching global state.

Autoload scripts must **not** declare `class_name` (Godot rejects a class name
that collides with a singleton name). Only the data/model classes do.

---

## 3. State ownership

| State | Owner | Lifetime |
| --- | --- | --- |
| Campaign data (gold, clock, soldiers, settlements, parties) | `CampaignState` held by `GameManager` | whole session |
| Soldiers | `CampaignState.soldiers` (id -> `Soldier`) | whole campaign, including after death |
| Party membership | `Party.member_ids` | whole campaign |
| Scene-local view state (selection, camera, hover) | the scene node | one scene |
| Battle-local state (`BattleUnit` hp/position/target) | `BattleSimulator` | one battle |

### The one rule that matters

> A soldier's identity lives in `CampaignState.soldiers` and **nowhere** else.
> Battle units hold a `soldier_id` reference, never a copy.

This is what makes "recruit a soldier, fight with them, watch them die, and still
see their name in the roster history" work across scenes, saves and loads.

---

## 4. Scene hierarchy and flow

```
main.tscn                      boot/splash; hands off to the main menu
 └── ui/main_menu.tscn         New Campaign / Continue / Quit
      └── world/world_map.tscn travel, settlements, encounters, HUD, debug panel
           ├── settlements/settlement.tscn   town screen; recruitment; roster
           └── battle/battle.tscn            tactical battle
                └── battle/battle_results.tscn   casualties, XP, loot
                     └── back to world_map
```

`SceneManager.SCENES` is the single registry of scene keys -> paths. No script
hardcodes a scene path, and `SceneManager.change_scene("world_map")` is the only
way a scene changes. (The one exception: the test harness and `main.tscn` call
`SceneManager.adopt_initial_scene()` because Godot loaded them directly.)

### Transition payloads

Scenes never guess why they were opened. The caller passes a payload and the
incoming scene consumes it exactly once:

```gdscript
SceneManager.change_scene("battle", {"context": battle_context})
# in battle.gd
var context: BattleContext = SceneManager.consume_payload().get("context")
```

This is how the battle scene receives its `BattleContext` instead of reaching
into global state to rebuild an army - the architectural requirement for future
ambushes, sieges and scripted battles.

### Freeing rule

`SceneManager` frees only the scene *it* created (`_managed_scene`). A scene that
Godot loaded directly is never freed, which is what lets the headless test runner
drive real scene transitions without freeing itself mid-test.

---

## 5. Data model

| Class | File | Notes |
| --- | --- | --- |
| `CampaignState` | `scripts/core/campaign_state.gd` | root of everything persistent |
| `Soldier` | `scripts/units/soldier.gd` | one persistent person, incl. traits + personal history |
| `Party` | `scripts/units/party.gd` | membership only (soldier **ids**, not objects) |
| `Settlement` | `scripts/world/settlement.gd` | position, faction, recruit pool, market placeholder |
| `WorldParty` | `scripts/world/world_party.gd` | an overworld party marker (bandits, caravans, armies) |
| `CampaignClock` | `scripts/core/campaign_clock.gd` | day/hour/speed, and the only time conversion |
| `GameConfig` | `scripts/core/game_config.gd` | dotted-path access to `data/config/game_config.json` |
| `RngService` | `scripts/core/rng_service.gd` | named, deterministic RNG streams |
| `DataUtils` | `scripts/core/data_utils.gd` | JSON <-> Godot type helpers (no dependencies) |

### Overworld layer (Step 2)

| Class | File | Notes |
| --- | --- | --- |
| `WorldBuilder` | `scripts/world/world_builder.gd` | builds settlements/roads from `data/settlements/`; idempotent |
| `TravelService` | `scripts/world/travel_service.gd` | pure travel logic: destination, pace, per-step movement, arrival |
| `WorldMapView` | `scripts/world/world_map_view.gd` | Node2D that draws the overworld; reads state, never mutates it |
| `WorldHud` | `scripts/ui/world_hud.gd` | status panel, speed controls, action bar; emits intent |
| `SettlementPanel` | `scripts/ui/settlement_panel.gd` | inspect a settlement; Travel / Enter |
| `DebugPanel` | `scripts/ui/debug_panel.gd` | F1 dev tools; emits signals rather than mutating state |
| `UiTheme` | `scripts/ui/ui_theme.gd` | shared colours and widget factories |
| `DevFlags` | `scripts/core/dev_flags.gd` | command-line dev switches for automated runs |

`world_map.tscn` is deliberately tiny (root + `View` + `Camera2D` + `HUD`); the HUD
builds its own controls. See D-013 in `DECISIONS.md` for why.

### Units and soldiers (Step 3)

| Class | File | Notes |
| --- | --- | --- |
| `UnitDefinition` | `scripts/units/unit_definition.gd` | one archetype; owns the HP/attack progression curves |
| `UnitCatalog` | `scripts/units/unit_catalog.gd` | loads and validates `data/units/unit_types.json` |
| `TraitCatalog` | `scripts/units/trait_catalog.gd` | loads `data/traits/traits.json`; sums modifiers |
| `NameGenerator` | `scripts/units/name_generator.gd` | deterministic names from seed + soldier index |
| `SoldierFactory` | `scripts/units/soldier_factory.gd` | rolls one new `Soldier`; touches no campaign state |
| `RecruitmentService` | `scripts/units/recruitment_service.gd` | the recruitment transaction and its refusals |

The split is deliberate: the **factory** decides what a person is (name, age,
traits, health) and the **service** decides whether the player may have them
(gold, pool, party cap, presence). The service registers the soldier through
`CampaignState.register_soldier`, which is what guarantees a soldier has exactly
one owner.

### Overworld parties and battle (Step 4)

| Class | File | Notes |
| --- | --- | --- |
| `OverworldService` | `scripts/world/overworld_service.gd` | spawns hostile parties from data; wanders/chases them; deterministic |
| `EncounterService` | `scripts/world/encounter_service.gd` | when a meeting is an encounter, builds the `BattleContext`, records retreats |
| `BattleContext` | `scripts/core/battle_context.gd` | **the only channel** between campaign and battle |
| `BattleUnit` | `scripts/battle/battle_unit.gd` | one fighting body; holds a `soldier_id`, never a `Soldier` |
| `BattleSetup` | `scripts/battle/battle_setup.gd` | builds units from a context and deploys both lines |
| `BattleSimulator` | `scripts/battle/battle_simulator.gd` | the fight as pure data; the scene is a view over it |
| `BattleView` | `scripts/battle/battle_view.gd` | draws the field, units, health bars and the selection box |
| `EncounterDialog` | `scripts/ui/encounter_dialog.gd` | the pause-and-decide prompt |

### Combat outcome (Step 5)

| Class | File | Notes |
| --- | --- | --- |
| `BattleResult` | `scripts/battle/battle_result.gd` | a full description of what a battle produced |
| `BattleResolver` | `scripts/battle/battle_resolver.gd` | builds the result (mutates nothing), then applies it |
| `BattleResultsScreen` | `scripts/ui/battle_results_screen.gd` | the after-action report |

**Resolution is two-phase, and that is the point.** `build_result()` reads the
battle and the campaign and returns a `BattleResult` without changing anything;
`apply()` is the only function in the project that lets a battle alter the
campaign. A quit, a crash or a debug exit mid-fight therefore cannot leave a
soldier half-dead in a save file, because nothing has been written yet.

`BattleResolver.apply()` is where a battle becomes consequences: kills and battles
fought, XP and level-ups, hit points, survival counts, a history entry per person,
the gold, and whether the beaten party still exists on the map. A small JSON-safe
chronicle of the last 40 battles is kept in `CampaignState.flags["battle_log"]`.

**The battle scene never looks anything up.** It receives a `BattleContext` through
the scene payload, and that context already contains both rosters as snapshots with
resolved stats. Adding ambushes, sieges or scripted battles later means building a
different context, not changing the battle scene. See D-019 and D-020.

### Battle outcomes

Every battle ends in exactly one of four outcomes, and `BattleResult.withdrawal` is
set once in `build_result()` so the rules below are never re-derived from a string:

| Outcome | Gold | XP | `battles_survived` | Enemy party |
| --- | --- | --- | --- | --- |
| **Victory** | spoils + victory bonus | participation + kills + survived + victory | +1 | removed from the map |
| **Defeat** | none | participation + kills + survived | +1 | stays; player pushed clear, cooldown set |
| **Draw** (timeout) | none | participation + kills + survived | +1 | stays; player pushed clear, cooldown set |
| **Withdrawal** | none | **kills only** | **unchanged** | stays unless actually destroyed |

`battles_fought` increments for everyone who took the field in all four cases,
casualties on both sides persist in every case, and the survivors' hit points are
written back in every case.

**Withdrawal is deliberately the strictest.** Anything else hands a player a
risk-free progression loop: walk onto a battlefield, press Retreat, collect
participation and survived-battle experience, repeat. Kills are the one exception,
because a soldier who cut someone down before the line broke really did that and
erasing it would rewrite the record. The behaviour is pinned down by
`tests/test_battle_outcomes.gd`, including a six-cycle attempt to farm the loop.
See D-033.

**A timeout ends the battle where it stands.** `BattleSimulator.step()` returns
immediately after finishing on timeout - no unit updates, no attacks, no overlap
resolution, no victory check - so nothing can move, strike, take damage or die after
the fight is over. See D-035.

### Battle consequences are symmetric

Enemy soldiers are persistent `Soldier` objects in `CampaignState`, exactly like the
player's. So `BattleResult` carries **four** rosters, and `apply()` writes back all
four:

| Roster | Meaning | Written back as |
| --- | --- | --- |
| `player_survivors` | our soldiers still standing | kills, HP, XP, levels, `battles_fought`, `battles_survived`, history |
| `player_dead` | our fallen | kills made before falling, dead, `battles_fought`, history |
| `enemy_survivors` | their soldiers still standing | kills, **remaining HP**, `battles_fought`, `battles_survived`, history |
| `enemy_dead` | their fallen | kills made before falling, dead, `battles_fought`, history |

**Enemy soldiers get no progression.** No XP, no levels, no loyalty, no morale
progression, no equipment damage. They have no XP curve in Steps 0-6, and inventing
one here would be a new system rather than a record of what happened.

**Enemy survivors keep their real remaining hit points.** This is the part that
matters most: without it, a band that survived a fight came back at full strength and
was a completely fresh fight next time, so a hostile party could never be worn down
and withdrawing was a free reset *for the enemy*. The next `BattleContext` is built
from `_snapshot_party()`, which reads `soldier.hp` - so once the campaign record is
right, the second battle is right too, with no extra plumbing.

**The rule for `battles_survived` is the same on both sides:** taking the field counts
as `battles_fought`, and breaking off does not count as surviving (see the withdrawal
rule above). The entry carries an explicit `survival_credited` flag so `apply()` never
has to infer it. See D-041.

`build_result()` still mutates nothing. The split between describing a battle and
applying it (D-024) is what made this a small change: the battle already knew
everything that had happened to every unit on both sides; only the write-back was
missing.

### Why parties store ids

If a `Party` held `Array[Soldier]`, then a save would serialise each soldier twice
once, and a load could produce two live objects for one person. Storing ids and
resolving through `CampaignState.soldier(id)` makes that class of bug impossible.

Helper accessors on `CampaignState`: `party_members()`, `active_members()`,
`active_member_count()`, `roster_member_count()`, `fallen_member_count()`,
`fallen_members()`, `soldiers_with_status()`.

### Roster membership versus active force

A party keeps its dead, on purpose: casualties must stay inspectable, because the
design principle is that soldiers are people rather than counters. That means **two
different quantities describe one party**, and using the wrong one fails quietly.

| Quantity | Accessor | Means |
| --- | --- | --- |
| Historical membership | `Party.size()`, `roster_member_count()` | everyone who ever belonged, the dead included |
| Active force | `active_member_count()` | alive and fit to take the field |
| Casualties | `fallen_member_count()` | members who have died |

**Anything that measures strength uses the active force**: travel pace, party
capacity, encounter strength, hostile-party markers on the map, and every
"how strong is this" label. The roster screen lists the *membership* - it is a
record - and states both, as `8 / 24 active, 4 lost`. See D-034.

When adding code that sizes a party, decide which of the three you mean. Do not
reach for `size()` because it is the shortest to type.

---

## 6. Data-driven content

Everything tunable lives in `data/`, loaded once by `GameData`:

```
data/config/game_config.json      time scaling, travel speeds, XP curve, progression,
                                  recruitment, rewards, encounters, camera, debug
data/units/unit_types.json        soldier archetypes
data/items/                       loot/equipment definitions
data/settlements/settlements.json the world's settlements and roads
data/encounters/                  enemy party templates (Step 4)
data/names/name_pools.json        procedural name pools
data/traits/traits.json           soldier traits and their modifiers
```

`GameConfig` is read by **dotted path with an explicit default**:

```gdscript
config.get_float("travel.world_units_per_game_hour", 150.0)
```

Two consequences worth knowing:

1. Rebalancing is a JSON edit; no code change, no recompile.
2. A typo'd path silently returns the caller's default instead of crashing - so
   `tests/test_core_services.gd` asserts that every path the code reads actually
   exists in the file. Add new tunables to that list when you add them.

**Time conversion exists in exactly one place**: `CampaignClock`. Movement and AI
ask the clock how many game hours elapsed; they never convert seconds themselves.

---

## 7. Determinism

A campaign is defined by `CampaignState.campaign_seed`. `RngService` derives a
separate stream per subsystem name, so:

* the same seed always produces the same world, and
* one system consuming randomness cannot shift another system's results.

Seeds use a hand-written FNV-1a hash rather than Godot's built-in `hash()`,
because the built-in is not guaranteed stable across engine versions and a seed
that changes meaning after an engine upgrade would silently rewrite a saved world.

---

## 8. Saving

* Format: indented JSON at `user://saves/slot_N.save` (readable, hand-editable).
* Version: `save_version` (currently 1, `SaveManager.SAVE_VERSION`), plus the
  writing build's `app_version` for diagnostics.
* Migration: `SaveManager.migrations` maps *from-version* -> `Callable`, populated
  in `_ready()`. Any document older than the current version is walked forward one
  step at a time. A real v0 -> v1 step exists (an unversioned document, whose party
  membership may be a bare array).
* A save from a **newer** build is refused rather than misread, and the main menu
  says so instead of offering a Continue that cannot work.
* `CampaignState.from_dict()` reads every field with `.get(key, default)`, so
  additive changes never need a migration - only removals/renames do.

`SaveManager.peek_metadata()` reads the header fields without building a
`CampaignState`, which is how the main menu can enable "Continue" cheaply.

### Proving a restart

`scenes/dev/persistence_check.tscn` runs in two **separate processes**:

```
phase=write    play a campaign, fight a battle, record the world, save, exit
phase=verify   a brand-new process loads it via continue_campaign() and checks
               every recorded fact against the save
```

A same-process save/load only proves the serialiser round-trips; it cannot prove
the game survives being closed. The witness file is what makes the second phase
meaningful - it has no memory of the first except the save and the recorded
expectations. See D-030.

---

## 9. Communication between systems

| From | To | Mechanism |
| --- | --- | --- |
| UI | gameplay | direct method calls / signals on the scene's script |
| UI panel | scene controller | signals only (`SettlementPanel.travel_requested`, `WorldHud.speed_requested`, ...) |
| scene | scene | `SceneManager.change_scene(key, payload)` |
| gameplay | campaign data | mutate `GameManager.campaign` through the data classes |
| any | any (one-off notification) | signals (`GameManager.campaign_started`, `SceneManager.scene_changed`) |

Signals are used for notifications, not for state. If a system needs state, it
reads the object; if it needs to know something *happened*, it connects to a signal.

**Overworld update order**, once per frame in `world_map.gd`:

```
clock.advance_real_seconds(delta)  ->  game_hours
travel.step(game_hours)            ->  report {moved, arrived, settlement_id}
overworld.step(game_hours)         ->  hostile parties wander or chase
encounters.detect()                ->  a party the player is standing on, or null
on encounter: pause the clock, show the prompt, wait for Attack or Retreat
view.queue_redraw()                (presentation only)
```

Only the controller mutates; the view and the HUD are read-only consumers.

---

## 10. Debug tooling

`DebugLogger` is the logging funnel; every meaningful transition or gameplay event
logs through it with a category (`SaveManager`, `SceneManager`, `Battle`, ...).
The Step-2 debug panel reads `DebugLogger.recent()` to show this in-game.

Debug-only features are gated behind `debug.enabled` / `debug.debug_build_only`
in the config, so shipping a build with them off is a data change.

---

## 11. Testing

`tests/` holds headless suites; `scenes/dev/tests.tscn` runs them.

```
godotc --headless --path "<project>" res://scenes/dev/tests.tscn
```

* Suites extend `TestCase` and override `run()`.
* Assertions record failures and keep going, so one run reports every problem.
* Exit code 0 = pass, 1 = failure. Milestones gate on this.
* Suites may `await` - they can drive real scene transitions and real save files.
* Suites must not leave saves behind (`SaveManager.delete_all_saves()`).
* **Every suite must end its `run()` with `_complete()`.**

**A suite that cannot load, cannot compile, runs zero assertions, or never reaches
its completion marker is a FAILURE, not a pass.** GDScript aborts a function on a
runtime error and has no try/catch, so without those guards a broken suite would look
identical to a passing one - a silent false green. See D-018 and D-036.

The completion marker is not belt-and-braces. Measured against Godot 4.7.2: when a
coroutine raises a runtime error, **control returns to the awaiting caller as though
the function had simply ended**, and the suite comes back reporting
`3 assertions, 0 failures`. A runner that checked only the failure count would call
that a pass. `_complete()` is a statement the aborted function never reaches, so it
is the one signal that survives.

Beyond the suites, the runner itself is tested: `tests/test_runner_contract.gd`
drives the runner's own `evaluate()` against deliberately malformed fixtures in
`tests/fixtures/` - a suite that aborts mid-run, one that returns early, one that
asserts nothing, a script that is not a suite at all, and a missing file. Those
fixtures are deliberately **not** in the runner's `SUITES` list, since several of
them are meant to fail.

**A `--suite=` filter that matches nothing is also a failure.** With no suites
selected every count is zero and the run looks immaculate, so a typo in a milestone
command would silently disable the gate. See D-037.

**Tests wait for transitions; they never cause them.** `SceneManager.await_scene(key)`
waits for a transition that has already been requested and returns the instantiated
scene. Calling `change_scene_and_wait()` on a scene the code under test already
transitions to queues a *second* transition carrying no payload, which replaces the
first - the scene ends up empty and the test proves nothing while looking thorough.
See D-039.
