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

### Why parties store ids

If a `Party` held `Array[Soldier]`, then a save would serialise each soldier twice
once, and a load could produce two live objects for one person. Storing ids and
resolving through `CampaignState.soldier(id)` makes that class of bug impossible.

Helper accessors on `CampaignState`: `party_members()`, `active_members()`,
`fallen_members()`, `soldiers_with_status()`.

---

## 6. Data-driven content

Everything tunable lives in `data/`, loaded once by `GameData`:

```
data/config/game_config.json      time scaling, travel speeds, XP curve, rewards, encounters
data/units/                       unit archetypes (Step 3)
data/items/                       loot/equipment definitions
data/settlements/                 the world's settlements
data/encounters/                  enemy party templates
data/names/                       procedural name pools
data/traits/                      soldier trait definitions
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
* Version: `save_version` (currently 1, `SaveManager.SAVE_VERSION`).
* Migration: `SaveManager.MIGRATIONS` maps *from-version* -> `Callable`. Any
  document older than the current version is walked forward one step at a time.
* `CampaignState.from_dict()` reads every field with `.get(key, default)`, so
  additive changes never need a migration - only removals/renames do.

`SaveManager.peek_metadata()` reads the header fields without building a
`CampaignState`, which is how the main menu can enable "Continue" cheaply.

---

## 9. Communication between systems

| From | To | Mechanism |
| --- | --- | --- |
| UI | gameplay | direct method calls / signals on the scene's script |
| scene | scene | `SceneManager.change_scene(key, payload)` |
| gameplay | campaign data | mutate `GameManager.campaign` through the data classes |
| any | any (one-off notification) | signals (`GameManager.campaign_started`, `SceneManager.scene_changed`) |

Signals are used for notifications, not for state. If a system needs state, it
reads the object; if it needs to know something *happened*, it connects to a signal.

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
