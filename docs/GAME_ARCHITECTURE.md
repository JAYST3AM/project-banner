# Game Architecture

How Project Banner is put together: what owns what, who talks to whom, and why.
Update this file in the same commit as any structural change.

---

## 1a. Native code (Step 7.7, D-095)

**Native code in Project Banner is an accelerator for proven hot data-processing kernels, not a
second gameplay architecture.** GDScript retains orchestration and gameplay semantics unless
profiling demonstrates a narrower native boundary is necessary.

**Any native battlefield accelerator must preserve the locked deterministic result of its
GDScript reference implementation.** Performance alone is not grounds for changing tactical
outcomes.

One accelerator exists, and those two rules bound it:

| | |
| --- | --- |
| What is native | `NativeTargetQuery` (`native/`): the cell index built from a per-tick snapshot, the walk over it, the side and liveness filters, the exact squared-distance test, the tie-break |
| What is GDScript | everything else in the target path and in the game: the ladder's staging and ceiling, the D-087 proof, retained opponents, hysteresis, cadence, explicit orders, formation focus, the query margin, backend selection, overlap, movement, damage, persistence |
| Why it is allowed here | profiled to a measured boundary: the query is 85.7% of the target phase, its candidate scan is ~85% of that, and the accelerated kernel measured 5.94x faster with the tick 1.91x cheaper at 20K |
| Why it is bounded | moving a kernel native means mirroring whatever live state it reads. This one reads positions and liveness, so the battle mirrors its two mutation points - movement and death - and `COMPARE_FULL` plus the native suite exist to prove that mirror, because a missing hook is a silently wrong answer rather than a crash |
| Where it is not allowed | anywhere else without its own profile, its own boundary measurement and its own comparison mode. This decision is not a general licence for native code |

The GDScript walk is not deleted: `BattleSpatialGrid._collect_reference` is the reference, the
oracle and the fallback, and every suite run exercises it.

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

### Battlefield terrain (Step 7)

Terrain exists as **data first**. `BattlefieldTerrain` is a `RefCounted` holding a
coarse grid - one cell every `terrain.cell_size` world units - with a terrain type
index, an elevation, and a **resolved movement multiplier** per cell. Nothing in the
simulation asks a renderer anything; the renderer asks the terrain.

```
BattlefieldTerrain
  size, cell_size, cols, rows, terrain_seed, generation_version
  _type_index : PackedInt32Array   per cell, index into the catalogue
  _heights    : PackedFloat32Array per cell
  _move       : PackedFloat32Array per cell, resolved at generation
```

**Generation is a pure function of the seed.** `generate(terrain_seed, size, config)`
builds two value-noise fields - elevation and cover - by hashing each lattice
coordinate with `RngService.stable_hash`, then classifying cells against
`terrain.high_ground_threshold`, `terrain.woods_threshold` and `terrain.rough_threshold`.
Because a cell's value depends only on *where it is* and not on the order cells were
visited in, two runs of the same seed produce byte-identical ground, and generating a
battlefield cannot disturb any other random stream. `terrain.generation_version` is
mixed into the hash, so changing the generation algorithm changes the ground
deliberately rather than silently invalidating every recorded seed.

Four types, from `data/terrain/terrain_types.json`: open ground, rough ground, light
woods, high ground. The type table is a catalogue like any other - adding a fifth type
is a data change.

**Queries are array reads.** `move_multiplier_at(point)`, `height_at(point)`,
`type_id_at(point)`, `inside(point)` and `slope_between(from, to)` each resolve a cell
index and read a `Packed*Array`. No temporary objects are allocated, because these run
inside the per-soldier movement path. Out of bounds reads as open ground at zero
height, which is the forgiving answer and the one that keeps a soldier who has been
shoved off the field from changing speed for no reason the player can see.

**Where terrain is read:** exactly one place, `BattleSimulator._effective_speed()`, and
one more for the pace of a body, `BattleSimulator._formation_speed()`. Both multiply a
unit's own speed by the ground's modifier, so the rule has one home.

In this milestone terrain affects **movement only**. A defence modifier is where a
later milestone would put one, and the terrain type table is where it would live - but
adding one now would change the outcome of every seeded battle to no purpose, and
"make terrain matter" is answered by movement being real.

### Formations (Step 7)

A formation is a first-class object, not a preset and not a buff. `BattleFormation`
is a `RefCounted` that knows its own geometry:

```
id, side, type_id, anchor, facing, desired_facing, target_anchor, order
unit_ids : Array[int]     unit_ids[i] owns slots[i] - battle unit ids, never soldier ids
slots    : Array[Vector2] world-space target positions, regenerated when anything moves
file_count, rank_count, spacing, cohesion, move_factor, turn_rate_deg
```

**Geometry is generated, not tabulated.** A formation type supplies one number that
matters - `max_files`, how wide the shape is willing to spread - and everything else
follows:

```
file_count = min(count, max_files)
rank_count = ceil(count / file_count)
lateral    = (file - (file_count - 1) / 2) * spacing
depth      = ((rank_count - 1) / 2 - rank) * spacing
slot       = anchor + right * lateral + forward * depth
```

Slots are computed in the formation's **own** frame and transformed into the world, so
facing is a rotation of the geometry rather than a special case per direction. This is
what makes arbitrary facings work, and it is the groundwork for the directional
mechanics - shields, phalanx frontage, flanking - that will need exactly this later.

With `max_files` of 10 for line, 2 for column and 6 for loose at 1.7x spacing, the
consequences fall out rather than being asserted: a line is wide and shallow, a column
is narrow and deep, loose order is spread further apart and reaches further back.

**A soldier belongs to one formation.** `assign_formation()` rebuilds the body's roster
from the list it is given and removes those soldiers from any other body first, so a
detachment is a transfer rather than a duplication.

**Assignment is by index, and a casualty leaves a gap.** `unit_ids[i]` owns `slots[i]`
for the life of the assignment, so a formation change preserves every soldier's place -
they walk to a new position in the same body rather than being reshuffled. When a
soldier falls it is **not** removed from `unit_ids`: its slot stays reserved and the
line keeps its frontage with a hole in it. Closing the files up would be a re-dress of
the whole body on every death, and more importantly a gap in a formation is a physical
fact that later mechanics - shield wall integrity, phalanx gaps - will want to read.
`has_living_units()` is how anything asks whether a body is still a body.

### Orders, stances, and the stalled battle

A formation's `order` is one of three things:

| Order | Meaning | Soldiers |
| --- | --- | --- |
| `engage` | close with the enemy and keep closing | dress while the body moves; press forward when it has stopped and nobody is fighting |
| `hold` | stand on this ground | always dress to slots |
| `move` | go to `target_anchor`, then revert to `hold` | always dress to slots |

`engage` is the default, and it is what makes a battle resolve when the player gives no
orders at all - which is the behaviour the game had before formations existed and has to
keep having.

**A soldier's place is its whole job.** A formed soldier whose enemy is in reach fights;
otherwise it walks to its slot. It does not pick its own ground and it does not run off
after a target. This is what keeps a line a line, and it is also what keeps a large
battle affordable: most soldiers are doing arithmetic rather than deciding anything.

**The station: where an engaged body's centre goes (Step 7.8B, D-101).** A body told to `engage`
steers its centre at a point `max(0, own surviving front + enemy surviving front) + contact gap`
in front of the hostile body's centre, measured along the closing direction. A *surviving front* is
the forward-most place in the body's own slot layout that still holds a living man: casualties stay
on the roll, so a killed rank is a hole, and a hole is not a front. Two intact bodies stop at
exactly the old numbers - the sum of their depths plus the contact gap - which is why an un-fought
battle behaves as it always did. A worn one walks in one spacing per rank destroyed, so a line
whose front rank has been killed takes its next rank into the enemy rather than standing at the
depth of a body it no longer has. The clamp is the other half of the rule: a body's centre is never
steered inside - let alone through - the body it is closing on. That was not always true, and the
state it produced is recorded in D-100.

**Arriving (D-102).** `advance()` moves a centre by at most the distance left to its station, so a
body converges on its station rather than overshooting it. A movement too fine for a single
precision `Vector2` to express counts as having arrived: without that, a body can sit a rounding
error short of its station and report `moving` for ever - measured in a frozen battle, 0.050003
units short, for fifteen thousand ticks.

**Pressing forward: the one exception to a soldier's place.** During Step 7 testing a battle
resolved to nine players against one enemy and then stopped for four simulated minutes. The last
enemy was standing in a gap where the soldier opposite it had fallen: two point
six units from the next man along, which is further than a sword reaches. Both bodies
were in `engage`, both had stopped, and neither would close - so neither could reach.
The fight had stopped happening and nothing was going to restart it.

The rule is deliberately narrow, and it is a formation-level rule rather than a
per-soldier one. A body that has *stopped*, has been told to `engage`, and has nobody in contact
lets its soldiers press forward out of their places until contact returns - at which point the
dressing wins again, so a battle cannot dissolve into a crowd. Contact is a property of the body
and not of a side (D-056), so a wing that has not arrived may press forward while the centre is
fighting. The gate is `is_moving()`, which is why D-102 - a body that could not express its last
step - mattered: it disabled this rule permanently. A body told to `hold` holds whatever the enemy
does.

**Turning is not teleportation.** `facing` and `desired_facing` are separate, and
`advance()` walks `facing` toward `desired_facing` at `turn_rate_deg` per second. The
slots rotate with it and the soldiers follow the moving slots, so a formation ordered to
about-face takes a second or two and the men are seen to do it.

**Cohesion** is the answer to the only question that matters about a formation, which is
whether it is still one. It is derived, not stored as progress: the mean distance
between each soldier and the slot it was given, normalised by
`formation.cohesion_reference_spacing`, inverted and clamped - `1.0` dressed, `0.0`
scattered. `is_reforming()` is true from the moment a new shape is ordered until
cohesion recovers past `formation.settled_cohesion`.

**The stalled battle this shape came from.** During Step 7 testing a battle resolved to nine
players against one enemy and then stopped for four simulated minutes. The last enemy was standing
in a gap where the soldier opposite it had fallen: two point six units from the next man along,
which is further than a sword reaches. Both bodies were in `engage`, both had stopped, and neither
would close - so neither could reach. The fight had stopped happening and nothing was going to
restart it. The press-forward rule above is the answer to that case, and D-101/D-102 are the answer
to the larger version of it that a 300 v 300 battle reached.

### Formation-driven engagement (Step 7.8)

**The rule.** A body knows which enemy body it is fighting. Each soldier of that body is allowed to
look for an opponent of its own only when the fight could actually be his, and there are exactly
four ways to be allowed:

* the player has ordered him at something (an explicit order is authoritative and is resolved
  before anything else, as it always was);
* he has just been struck - and then he strikes back at whoever struck him, which the damage step
  recorded, for one index probe and no search;
* he stands inside his body's *contact band*: within his own body's furthest reach plus the enemy
  body's plus one rank of slack, measured from him to the *enemy body's box*;
* or he has no body at all, in which case he is his own formation and keeps the pre-formation
  behaviour exactly.

**Why a box and not a frontage.** Measured from the enemy's bounding box, the band answers a
formation taken on the flank or from behind as readily as one taken at the front, and it costs six
comparisons per soldier with no query at all. A frontage band would have made a body blind to
anything that walked around it, which is the failure D-105 exists to avoid.

**The body's own thinking.** Once per ten-tick cadence a body picks its enemy: nearest living body
of the other side by box distance, keeping the answer it had unless a rival is clearly nearer
(`battle.engagement_switch_advantage`, the same hysteresis idea a soldier's target gets in D-081),
and never overriding an explicit order while the body that order names is alive. The same pass
derives the band, the handful of enemy bodies near enough that its soldiers may need to answer to
them, and a state - `NONE`, `APPROACHING`, `NEAR_CONTACT`, `IN_CONTACT`, `DISENGAGING` - that the
development overlay and the reports read. It costs **0.02 ms a tick** at six hundred soldiers.

**What it does not touch.** A soldier keeps the opponent he already had: retention, the awareness
cadence, the search ladder, the retention radius, the switch margin, the native target kernel, the
separation pass and every explicit order are exactly as they were. The deferral is a *postponed*
look, not a cancelled one - the next awareness tick asks again - and the accounting that Step 7.4
established now has a sixth term, because *every soldier-tick is exactly one of them* is an
invariant this architecture has to keep, not to relax.

**Switchable.** `battle.engagement_enabled` (or `PB_ENGAGEMENT=off`) puts the architecture this
replaced back, in the same build and tick for tick, which is how every figure in this milestone is
a pair of runs rather than a comparison against an older log.

### Dynamic formations: split, merge, ownership (Step 7.8)

**A body is a roll.** `BattleFormation` holds a list of soldier ids and the geometry that places
them; every soldier holds a reference back to its body and its own place in it. That is the whole
of the membership model, and it is why splitting is cheap: `split_formation()` and
`merge_formations()` move rolls through `assign_formation`, which takes a soldier off whatever roll
held him before it adds him to another. Measured, a split of an engaged body is **0.27 ms at six
thousand soldiers**, and no part of it is a battlefield rebuild.

**What is preserved.** A split or a merge moves rolls, never soldiers: ids, names, health, kills,
damage and history travel with the man. A split body inherits its parent's type, order, facing and
movement intent and then becomes a real independent actor - its own anchor, facing, layout,
formation target, contact state, cohesion and reform state - and either half may be given its own
orders, targets and even its own disengagement. Nothing is created, destroyed, duplicated or lost,
which the suite asserts across repeated surgery and two thousand randomized transitions.

**Ownership is checked, not assumed.** `check_membership_invariants()` returns sentences: a soldier
standing in two bodies, a soldier pointing at a body that does not roll him, a slot index that
disagrees with the roll, a living count that disagrees with what the body rolls, a target body that
is gone or empty. It builds the summaries first and it walks every soldier, so it belongs to the
tools and the tests rather than to a tick.

**A merge takes a body off the battlefield**, so the bodies are re-indexed (the focus and summary
arrays are addressed by index) and anybody who was facing the donor has its target cleared rather
than left naming something that is gone.

**Cohort compatibility.** Nothing here assumes a body is indivisible: a Cohort is a sub-roll of
soldiers with its own sub-block of the layout and its own summary, and the contact band is already
per soldier rather than per body. Partial contact, local casualty tracking, local target assignment
and multirate simulation all have somewhere to live without moving a soldier - none of it was
built in this milestone, and none of it is blocked.

### Proximity: the battlefield index (Step 7.2)

Every proximity question a battle asks goes through one object. `BattleSpatialGrid` is a
uniform grid over the battlefield, one cell per `battle.spatial_cell_size` world units
(4.0), and it holds index positions and nothing else.

**The rule it exists to enforce:**

> Battlefield-local spatial queries are the authoritative broadphase for soldier
> proximity. Systems must not reintroduce full battlefield scans inside per-soldier hot
> loops.

A soldier does not ask which of every soldier on the battlefield is near it. It asks
which soldiers are near its position, and the grid answers that without looking at the
rest of the field.

**Shape.** `RefCounted`, not a node. Data-first: no rendering, no physics, usable
headlessly. Battle-local: a battle builds one, and it does not outlive the battle.
Buckets are a linked list in two `PackedInt32Array`s - a head per cell, a next per slot -
rather than an array per cell, so nothing is allocated after `configure()`.

**Membership is a snapshot, rebuilt once per tick and again before overlap resolution.**
The brief asked for this to be chosen on measurement rather than assumption, and the
measurement is unambiguous: a rebuild is one linear pass writing into preallocated arrays,
and it costs 0.7 ms at five hundred soldiers and 3.8 ms at two thousand five hundred,
against per-tick totals in the tens and hundreds of milliseconds. Incremental maintenance
would buy nothing and would add a way for the index to drift out of step with the units it
describes. There is no update path, so there is no update path to get wrong.

**Dead soldiers are not in it**, and are not returned from it either. The index only
admits the living, and a query re-checks liveness, because soldiers die *during* the tick
whose index was taken at its start (D-063). A casualty still keeps its place on its
formation's roll so that a gap in a line stays a gap (D-048); it simply has no answers.

**Queries answer in cells, not circles.** `collect_within(position, radius, side, out)`
returns every indexed unit whose cell the search box touches, in a defined order, into a
caller-supplied array that keeps its capacity between calls. It is a superset of the
circle and it is not sorted. Callers measure - the target search discards anyone beyond
the radius it asked about (D-065), and the overlap pass measures the exact gap before
pushing. Returning a sorted or exact result would make the grid do per-candidate work the
caller has to do anyway.

**The order is part of the contract** (D-059). Two callers depend on it: the overlap pass
resolves pairs in the order it meets them, and the equivalence tests pin that order
against the loop it replaced. A structure whose iteration order is unspecified cannot make
that promise, so the order is specified and the implementation preserves it - including
through the occupied-cell shortcut (D-066).

`collect_within()` chooses between two ways of walking the same cells and takes whichever
visits fewer: every cell in the box, or the list of cells that actually hold somebody.
On a sparse field a wide search covers hundreds of empty cells, and reading empty bucket
heads to find a handful of soldiers is work proportional to the battlefield rather than to
the army (D-066). Cells also carry a one-byte record of which sides are present, so a
query can skip a bucket holding only the other army without walking it (D-068).

#### Target selection

`_choose_target()` searches outward from the soldier: `battle.target_search_radius` (8)
first, widening by `battle.target_search_escalation` (4) to a bound of
`battle.target_search_max_radius` (32). Within the bound the answer is **exactly** the
nearest living enemy, ties to the lower id, and provably identical to the exhaustive scan
it replaced (D-061) - that equivalence is tested soldier-for-soldier against a brute-force
reference, on generated layouts and across eighty ticks of a moving battle.

Beyond the bound a per-soldier search stops being local: answering it means examining the
whole enemy army, per soldier, per tick, which is the quadratic cost this milestone
removed. So a soldier with nobody near it is *pointed at the fighting* instead - by its
body, at the nearest enemy to the formation anchor, or failing that by its side's centre
of mass. Those are computed once per tick rather than once per soldier (D-067).

This is a deliberate trade and it is stated plainly: a soldier marching towards a distant
enemy faces the enemy its body is pointed at rather than its own private nearest. Its
conduct is unchanged - a formed soldier dressing to its slot does not steer by its target
at all - so the difference is the direction it faces while marching. Within the bound,
which is where every soldier who is actually fighting lives, nothing changed.

The radius is deliberately not tied to melee reach: archers, long spears and cavalry
threat detection all want to search further than they can hit, and widening the ladder is
a config change (D-061). Step 7.2 adds none of those systems.

#### Why this search is shaped the way it is (Step 7.6)

Step 7.6 set out to replace the ladder with a cheaper exact search and left it alone, because
five re-implementations - a ring walk, two row walks, a rectangle walk with a cell bound and a
walk over a coarse block index - all inspected **less** ground than the ladder and all measured
**slower**. The reason is now a recorded number rather than an opinion: one radius-32 box costs
about 300 us however it is walked, a bound test in a loop body costs about 0.3 us in this
interpreter, and the empty cell it skips costs about 0.12 us to open and dismiss. A search that
prunes per cell pays more for the pruning than it saves on the skipping.

What makes the ladder cheap is its *staging*, not its walk: the first rung is a 25-cell box and
it answers a third of looks outright, so the expensive rung is only reached by looks that had
nothing nearby - which is why the milestone's own numbers (below) are dominated by the looks
that find nobody. A future attempt on this phase has two honest options and no third: stop
asking the question (a formation-level proof that a neighbourhood is clear, which the focus
bucket hierarchy is too coarse to give during contact), or change what the answer is allowed to
be (bounding the search by the formation's own focus distance, which is *not* equivalent to the
locked answer and would be a gameplay decision rather than an optimisation). See D-094.

#### What one look cost (Step 7.6 instrumentation)

The target path carries development-only counters, all behind `profile_enabled`, and the
benchmark's `=== SEARCH SHAPE ===` table reads them: grid queries per look (one per rung),
cells read and how much of that ground one look walked twice, candidates measured split by
rung, how many looks escalated to the ceiling rung, the distance an answer was found at, and
exact per-search percentiles taken from one sample per search. Per-sub-phase timings cover the
rest of the target loop - deciding whether a remembered opponent is worth keeping, deciding
whether a look is worth making, the hysteresis, and answering with the formation - so that "the
query is 85% of the phase" is a measurement anybody can repeat rather than a claim to believe.
`scripts/dev/search_bench.gd` measures one query in isolation, in seconds, at a chosen density
and spacing.

#### How often a soldier looks (Step 7.4)

Step 7.2 made the search *local*. Step 7.4 made it *rare*, and the two rules it serves are
worth stating in full because everything in the section follows from them:

> **Automatic battlefield targets are persistent local engagements, not a nearest-enemy
> query recomputed every simulation tick.** Soldiers retain a valid opponent and reacquire
> deterministically when local circumstances require it.

> **Expensive soldier awareness work must be staggered deterministically so army scale
> does not create synchronized simulation spikes.**

The shape of a soldier's decision is a ladder of questions, ordered by cost. Every one of
them is answered from data the soldier is already holding until the last:

```
explicit order?          use it                     (a player instruction: no search)
remembered opponent?
    in reach?            use it                     (no search: the fastest path)
    not this soldier's turn yet?
                         use it                     (no search: still relevant)
turned to look?
    nearest local enemy, or the body's focus        (the only expensive answer)
```

A soldier who can reach the enemy in front of it therefore never searches at all: the tick
that would have discovered "the same enemy is still standing there" is not spent. A soldier
who cannot reach anybody is re-examined on its own cadence, and between looks it is pointed
at the fighting by its formation's or its side's focus - the answer the bodies have already
worked out for themselves once this tick (D-067), which is why a soldier far from the
fighting does not need a private spatial query to know which way to march.

**Formation battlefield awareness is calculated at the formation layer.** Soldiers consume
cached formation-level focus information rather than independently scanning the battlefield
for formation guidance. Each body keeps a transient summary of itself - how many of its
soldiers are standing, where their centre is, and a box around them - rebuilt in one pass per
tick, and each body's focus is chosen by comparing those summaries against each other rather
than by walking the enemy army. A soldier reads its body's answer; it never searches for one.

**Formation summaries are transient simulation data and are updated deterministically from
current battle state.** Invalid or destroyed formation targets are repaired at the formation
layer rather than triggering global soldier-level searches. A body whose answer dies mid-tick
is corrected once, for the body, by the first soldier that asks; a body whose answer is that
there is nobody left is not asked again inside the same tick, because nothing comes back to
life inside one. The counter that proves it is `foc_scans_from_soldiers` - whole-army walks
made by the focus logic on behalf of a soldier - and its value in every measured battle is
zero. See D-088 through D-091.

**Where the schedule lives.** `BattleUnit.next_search_tick` is an integer simulation tick,
and the phase a soldier starts on is `unit.id % battle.target_reacquisition_ticks`. Three
consequences, all deliberate:

- it is **staggered** - a quarter of the army looks on any given tick rather than the whole
  army on every fourth, which is what keeps the cost per tick flat instead of spiky;
- it is **deterministic** - the same seed, roster and orders produce the same schedule, and
  re-ordering the roster changes the order soldiers are updated in, not when any one of
  them looks;
- it reads **no clock** - not `Time.get_ticks_msec()`, not a render frame. Wall-clock
  timing exists in this project only inside the benchmark's counters (D-080).

**The schedule is a latency bound, not merely a saving.** An enemy that arrives immediately
after a soldier's scheduled look is noticed on the next one, one cadence minus the tick it
arrived on; `tests/test_target_acquisition.gd` measures that at every cadence the sweep
covered. What the cadence must never do is delay a *player*: an explicit attack order is
resolved before the automatic path is even reached, it is answered on the tick it is given,
and a soldier holding an order does not advance its awareness clock at all (D-085).

**Losing an opponent.** A remembered opponent stops being the answer when it dies, when it
turns out not to be an enemy, when it is gone from the roster, or when it has moved beyond
`battle.target_retention_radius`. The first three are facts about the opponent; the fourth
is the bound that stops a soldier running after one enemy across a battlefield it is no
longer fighting in.

The one case that is allowed to search **off** the cadence is a loss that happened inside
the soldier's own reach: an opponent killed while this soldier could have struck it is a
fight in progress, and making it wait for its slot would leave it standing over a corpse.
That rule is a decision rather than an accident - it is configurable, it is tested both on
and off, and the worst tick it can produce is measured by the death-storm benchmark, in
which an entire front rank is killed on one tick (D-083).

**The search itself is unchanged.** `_nearest_local_enemy()` still answers exactly what a
whole-field scan answers inside its bound, still ties to the lower id, and is still the
function the brute-force equivalence tests drive. Step 7.4 changed how often that answer is
asked for, never what it says (D-085).

**Where a wider awareness will go.** A unit carries `awareness_radius` - zero meaning "use
the battle's configured ladder". A soldier that one day carries a bow says how far it can
see on itself; the retention radius follows the same number so a unit never keeps less than
it can find. Nothing in the target path branches on what a unit is carrying, and a test
asserts that a soldier called an archer behaves exactly like one called a spearman (D-086).

### The separation pass: keeping bodies apart (Step 7.3)

Every soldier is a body on the ground. Two of them cannot stand in the same place, and
the system that enforces that is `BattleOverlapGrid`.

**The architectural rule it serves:**

> Formation geometry is the primary mechanism for maintaining normal friendly soldier
> spacing. Spatial overlap resolution is a local corrective system for genuine physical
> conflicts and contact, not a substitute for formation geometry.

That sentence is the whole design. A dressed formation is already spaced — a slot grid's
closest two places are one `formation spacing` apart, and a spacing is 2.6 units against a
separation distance of 1.35. The pass is not there to hold a formation together; it is
there for the moments when the formation's geometry is not enough: a compress under
contact, a body crossing another, a flank arriving, a crush.

#### Why it has its own index

Step 7.2 used the targeting grid for separation. It was the wrong shape for the job, and
the measurement said so in a way no amount of reading could have: at five thousand
soldiers the pass was handed **95.6 candidates per soldier** and found **226 touching
pairs army-wide**. Twenty-one hundred candidates measured for every one that mattered,
with the broadphase alone 62 to 66 per cent of the phase.

The cause was a mismatch of distances. A target search starts at 8 units and wants to be
generous; a separation happens at 1.35. One cell size cannot serve both, and 4-unit cells
made the pass search a box several times the width of the distance it cared about.

So the two are separate grids, with separate cell sizes, rebuilt separately:

| | `BattleSpatialGrid` | `BattleOverlapGrid` |
| --- | --- | --- |
| Answers | "who is near this soldier" | "who is standing inside whom" |
| Distance that matters | 8 units (target search) | 1.35 units (separation) |
| Cell size | `battle.spatial_cell_size` (4.0) | `battle.overlap_cell_size` (0.9) |
| Pair production | one query per soldier, filling a reused result array | each occupied cell against the half-neighbourhood in front of it |
| Used by | `_choose_target`, `_refresh_focus` | `_resolve_overlaps` |

The second grid enumerates **cell against cell** rather than soldier against soldier. Each
occupied cell pairs itself with the half of its neighbourhood that lies in front of it —
one cell to the right, three below, and so on — so every physical pair is produced exactly
once by construction, with no id comparison and no per-soldier query to go with it.

The neighbourhood radius is **derived, not configured**:
`ceil(separation distance / cell size)` cells. A pair closer than the separation distance
cannot be more than that many cells apart on either axis, however the two straddle a
boundary, so a change to either number cannot silently produce a search that misses pairs.

#### Pushes are accumulated, not applied

Step 7.2 pushed each overlapping pair apart the instant it was found. That made the result
depend on the order pairs were visited in — the second pair of a cluster was measured
against positions the first pair had already moved — and it is why Step 7.2 had to
reproduce the exhaustive loop's visit order exactly, and why its test compared positions
against that loop.

Step 7.3 sums every push into a per-soldier displacement and moves the field once, at the
end. There is no visit order to preserve because there is no visit order that matters, and
that is checkable rather than asserted: the order-independence test reverses the entire
roster and checks that nobody's position moves by more than a thousandth of a unit.

Each soldier's displacement is capped at `battle.max_separation_push` (1.35 units, one
separation distance). A soldier buried in a crush takes a push from every body it is
inside, and nothing in the arithmetic bounds that sum; the cap turns "usually stable" into
"bounded by construction", and cannot slow an ordinary push down because an ordinary push
is smaller than a body.

**What is honestly different from Step 7.2.** This is not the same relaxation. A sequential
pass resolves a cluster harder in a single tick, because each soldier sees the corrections
already made to its neighbours. A simultaneous pass has everyone react to where everyone
stood, and takes more ticks over the same cluster — measured on a deliberately
pathological pile of three hundred soldiers in a six-unit square, two hundred passes leave
under two per cent of the original overlap and the closest pair back out at 91% of the
separation distance. For a battle that is the right trade: what matters is that the pass
separates soldiers at least as fast as they can walk into each other, and that is tested
directly by driving two lines into each other and checking the closest approach across a
hundred and sixty ticks.

#### Formation-aware skipping

The pass skips cell-against-cell work where it can *prove* there is nothing there:

- every soldier in both cells is standing within `battle.separation_settle_epsilon`
  (0.15 units) of the place its formation gave it; **and**
- both cells belong to the same formation; **and**
- that formation's own slot spacing exceeds the separation distance plus twice the settle
  distance.

The claim is exact: two soldiers standing within ε of their assigned places are at least
`spacing - 2ε` apart, and the closest two places in a slot grid are one spacing apart. If
that exceeds the separation distance, no pair across two settled cells of one body can be
touching, so neither a distance nor a push needs computing. A cramped formation does no
skipping — the test is against the body's own spacing, not a constant. A body with one
soldier out of place does no skipping in the cells that soldier touches.

**It never applies across two bodies.** Two friendly formations touching or crossing are a
real physical event — a reserve advancing through a gap, a line passing behind another —
and so is enemy contact. Every pair between two bodies is measured, settled or not, and
the tests for both are the ones that matter most.

#### What the pass costs, and where it goes

Counters behind `profile_enabled` report what the pass did rather than only what it cost:
cell pairs considered and skipped, pairs measured, pairs touching, clamped displacements,
settled soldiers, interior cells. They are what selected this architecture — see D-071 —
and they are what says when the next change should be made.

No allocation happens in a pass. Bucket heads, tails, occupancy, cell state, displacement
accumulators and the offset tables are all persistent storage sized on first use; the
rebuild clears only the cells the previous pass occupied, because filling a battlefield of
hundreds of thousands of mostly-empty cells is work proportional to the ground rather than
to the army. A test runs five hundred passes and asserts static memory grew by less than a
page.

---
#### Instrumentation

`BattleSimulator` carries phase accumulators behind `profile_enabled` (D-064): grid
rebuild, focus refresh, formation update, the per-soldier loop and the share of it spent
choosing targets, and overlap resolution. Off by default and free when off; the one loop
that would otherwise cost a call per soldier without profiling simply has two copies. The
benchmark prints the profile on request, labelled as profiled, because two clock reads per
soldier are affordable but not free.

#### What it costs now

The benchmark in `scenes/dev/battle_benchmark.tscn` reports cost per tick from 100 to
5,000 soldiers at the sizes Step 7 measured, plus larger sizes, and compares against Step
7's recorded figures. It runs the same battle four times with terrain and formations
switched off to attribute the cost, reports the busiest single cell so that saturation is
visible rather than inferred, and prints whether the armies actually reached each other so
an approach measurement is never passed off as a fight. `--grid-scale=1` measures the
spatial layer alone at constant density, which is the only configuration in which the
shape of the curve can be seen rather than the shape of a saturated battlefield.

**Step 7's quadratic pair is gone.** What is left is proportional to the army and to how
crowded each soldier's own neighbourhood is.

Two limits that remain, and are not claims to the contrary:

- **Density is not constant.** The battlefield is a fixed 100 x 60 however many soldiers
  are on it, so the soldiers-per-cell column grows with the army. A crowd packed into one
  cell degrades a uniform grid towards the scan it replaced; that is inherent to a uniform
  grid, it is measured rather than assumed, and the honest answer at that point is a
  larger battlefield or a finer cell, not a different data structure.
- **No threading, no ECS.** The battle loop is GDScript, step for step, and it is stepped in
  one go (D-069). The one place native code appears is the pair of kernels in section 1a, and
  each of them was profiled before it was allowed to exist.

#### Three implementations of the same pass (Step 7.8)

The pass has one interface - `configure`, `resolve`, `report`, and the counters beside them -
and three implementations behind it. A battle selects one **once, before its first tick**, from
the size of the army it is about to run, and never switches:

| Implementation | What it is | When it runs |
| --- | --- | --- |
| `BattleOverlapGrid` | the locked GDScript reference, object by object | below the packed threshold, and always in the oracle suite and CI |
| `BattleOverlapGridPacked` | the same arithmetic over packed per-slot arrays | above the packed threshold, and wherever the native library is not built |
| `BattleOverlapNative` | shape C: the whole pass in the kernel, one displacement per soldier returned | above the native threshold, when the library is loaded |

All three produce the **same field**, bit for bit, which is not a claim but a suite: 1,500
generated states and the named boundary arrangements are run through each candidate and
compared against the reference position for position, and a 300-tick battle is fingerprinted
under each pass. That is what allows the choice to be a cost decision rather than a
behavioural one.

**What the native pass owns: nothing.** It is handed a packed snapshot of the living soldiers -
positions, body codes, body spacings, settled flags - and it returns one displacement per
soldier per axis. It holds no `BattleUnit`, no formation, no battle rule and no persistent
state, so unlike the targeting kernel it has no live-state mirror and no mutation points to
keep true. GDScript remains authoritative for everything else: soldiers, bodies, damage,
targeting, movement, campaign state and saves. No native state enters a save file, and if the
library is missing the battle runs the packed pass - or, below the thresholds, the reference -
without noticing anything except a slower tick.

---

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

### The simulation step (Step 7.8B, D-103)

Rendering and simulation are separated by `BattleClock`. The battle scene hands it real frame time
(multiplied by the player's battle speed) and receives whole simulation ticks of one fixed size -
`1 / battle.tick_rate`, which is 0.05 s. Before this, the scene passed the rendered frame delta
straight to `BattleSimulator.step()`, so the step size *was* the frame time and the same seed fought
a different battle on a different machine. One frame may run at most eight ticks, and no more than
half a second of un-run time is ever queued: a machine that cannot keep up sees the battle take
longer in real time rather than fight differently. `BattleSimulator.step(delta)` itself is
unchanged - the tests, the benchmark and the showcase drive it at whatever step they choose - so the
fixed step is a property of the running game rather than of the simulation.

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

**The battle journal (Step 7.8B).** A long battle needed to be readable afterwards, and the
transitions that decide one - contact gained and lost per body, casualty milestones, which enemy
body each body is facing, the clock running out - were not written anywhere; a log of blows and
deaths cannot tell a frozen battle from a thinking one. `BattleJournal` writes exactly those lines
and nothing else: a hundred for a six-hundred-soldier battle, where a per-blow log would need five
thousand. It is a *subscriber* of the funnel above rather than a logger of its own - its lines go
through `DebugLogger` and it appends the battle category's entries to a file - and nothing
constructs one unless a run asks, with `--battlelog` or `--battlelog=<path>`. Release play writes
nothing to disk.

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

---

## 12. Standing design constraints

These are long-term constraints rather than descriptions of what is built. They are
recorded here because they constrain decisions in milestones that do not exist yet, and
because a constraint that only lives in a conversation is a constraint nobody can be
held to.

### Formation warfare

> Formations are physical battlefield systems defined by geometry, facing, spacing,
> cohesion, equipment and terrain. They are not cosmetic layouts or passive buff
> buttons.

The practical consequence, whenever a new formation is proposed: **its value has to come
from its shape.** A shield wall should be hard to break through because its men are
close together and facing the right way, not because a flag adds fifteen per cent to a
defence number. If a proposed formation cannot be described in terms of what its
soldiers are physically doing, it is not a formation yet.

This is already load-bearing in the code. A type in
`data/formations/formation_types.json` supplies geometry and movement parameters and
nothing else, and there is no field for a bonus to go in.

### Dynamic reformation

> Formations may change shape and facing while combat is underway. A reformation is
> executed physically by soldiers moving to new slots rather than teleporting.

The practical consequence: `set_type()` changes a formation's *intent* and its geometry,
and moves nobody. Every soldier then walks to the place it has been given, at its own
speed, over whatever ground is in the way. A test asserts exactly this - one frame after
a line-to-column order, not one soldier has moved.

The rule: formations must never be architected as deployment-only information. A shape
an army cannot change in contact is a shape that has no tactical meaning.

### Massive battle target

> Project Banner has a future engineering target of approximately 20,000 active
> battlefield soldiers at stable 60 FPS on the target development hardware.
> Architecture should preserve a path toward this without prematurely optimizing
> unmeasured systems.

The consequences that bind current work:

- **A soldier is gameplay data first, not an autonomous Godot scene.** `BattleUnit` and
  `BattleFormation` are `RefCounted`. No `Node2D`, no `CharacterBody2D`, no
  `NavigationAgent2D` per soldier, no per-soldier high-level AI, no per-soldier
  collision against every other soldier. A test asserts the types, so the rule is
  checked rather than hoped for.
- **Thinking belongs above the soldier.** Army decides, formation decides, soldiers
  execute cheap local instructions. The reverse shape - twenty thousand independent
  tactical planners - is the architecture this project is avoiding, and it is much
  cheaper to avoid on purpose than to unwind later.
- **Measure before optimising.** `scenes/dev/battle_benchmark.tscn` exists so that a
  performance claim is a number with a checksum beside it. Do not assert a capacity that
  has not been measured; the current measurement is in `docs/CURRENT_STATE.md`.
- **Optimise against a target, not a theory.** The known quadratic loops are documented
  and deliberately left alone until the large-battle milestone can design against the
  battle it actually needs to run.

### What Step 7 deliberately does not implement

Recorded so that the next milestone does not have to guess what was left undone on
purpose, and so that nobody mistakes an absence for an oversight:

shield wall · pike phalanx · spear bracing · flank and rear bonuses · directional shield
blocking · projectiles and ammunition · cavalry and charge physics · morale and routing ·
unit capabilities and equipment-driven formations · pursuit · advanced commander AI ·
sieges and faction warfare · equipment overhaul and wounds · ECS · GDExtension ·
multithreading · MultiMesh · the 20,000-soldier optimisation · finished art and
animations.

The interfaces those need are the ones Step 7 built: a formation knows its own geometry
and facing, cohesion is queryable, a soldier's position relative to its formation's
frame is available, and terrain answers questions about itself. Nothing in that list
requires unpicking something built here.
