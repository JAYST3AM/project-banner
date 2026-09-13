# Roadmap

The plan of record. Each step ends with a commit, a tested build and updated docs.

Status legend: `DONE` / `IN PROGRESS` / `TODO`

| Step | Milestone | Status |
| --- | --- | --- |
| 0 | Bootstrap Godot development environment | **DONE** |
| 1 | Project architecture and campaign foundation | **DONE** |
| 2 | Playable world map and settlement travel | **DONE** |
| 3 | Persistent soldiers, recruitment, party roster | **DONE** |
| 4 | World encounters and tactical battle transition | **DONE** |
| 5 | First functional tactical combat | **DONE** |
| 6 | Persistent campaign save/load validation | **DONE** |
| 6.5 | External audit remediation (hardening pass, no new gameplay) | **DONE** |
| 6.6 | Final foundation lock (enemy persistence, legacy menu, CI) | **DONE** |
| — | **First major checkpoint: the full vertical slice** | **DONE** |
| 7 | Tactical Combat 2.0: terrain and formation foundation | **DONE** |
| 7.1 | Formation hardening (membership, contact, bounds, slope) | **DONE** |
| 7+ | Post-checkpoint systems (see below) | TODO |

---

## Step 0 - Development environment (`milestone-00`)

Godot 4.7.2-stable installed and on `PATH`; repository created; boot scene runs
headless and windowed; the edit -> run -> test -> commit -> push loop verified.
See `DEVELOPMENT_ENVIRONMENT.md`.

## Step 1 - Architecture and campaign foundation (`milestone-01`)

**Goal:** the game launches into a main menu and can create a placeholder campaign.

- Core services: `DebugLogger`, `GameData`, `SaveManager`, `SceneManager`, `GameManager`
- Data model: `CampaignState`, `Party`, `Soldier`, `Settlement`, `WorldParty`, `CampaignClock`, `RngService`
- Main menu: New Campaign (name + seed) / Continue (disabled without a save) / Quit
- Scene registry with transition payloads; world map placeholder scene
- Save format v1 with a version field and migration hook
- Headless test harness (`tests/`, `scenes/dev/tests.tscn`)
- Documentation: this file plus architecture, current state and decisions

**Definition of done:** project launches, main menu works, New Campaign creates
state, the world-map placeholder loads, no duplicated globals across transitions,
architecture documented. Verified by `tests/test_campaign_flow.gd`.

## Step 2 - World map prototype (`milestone-02`)

**Goal:** the first playable overworld; the player can travel between locations.

- `WorldMap` scene with a placeholder party icon and persistent world coordinates
- Settlements: Greywatch (town), Brackenford (town), Redmoor (village), Thornwood Hollow (wilderness)
- Roads drawn between settlements; click to select, inspect, and travel
- "Enter Settlement" available once the party arrives
- Campaign time advances during travel, with Paused / Normal / Fast speed states
- World HUD: gold, party size, day/time, destination, game speed
- Debug panel: teleport, add gold, change speed, show coordinates/destination/time
- Camera pan (WASD/arrows/middle-drag) and zoom (wheel)
- `DevFlags` command-line switches (`--autostart-campaign`, `--autotravel`) so the
  real rendered world map can be driven without a mouse

**Definition of done:** Main Menu -> New Campaign -> World Map -> select Brackenford
-> travel -> arrive -> Enter Settlement. Verified headlessly (88 assertions in
`tests/test_world_map.gd`) and in a windowed run that logs
`arrived at Brackenford on Day 1 - 14:08`.

## Step 3 - Soldiers and recruitment (`milestone-03`)

**Goal:** recruit persistent, named, individual soldiers.

- Settlement screen: town info, gold, party size, available recruits, recruit
  controls, party roster, leave town
- Data-driven unit archetypes: Peasant Recruit, Spearman, Archer
- Procedural medieval name pools (`data/names/`)
- Recruitment: availability check, gold check, cost deduction, soldier creation,
  party add, pool decrement, UI refresh
- Party roster with a soldier detail panel
- Soldiers persist everywhere: world map, settlement, battle, save/load

**Definition of done:** enter town -> recruit -> inspect -> leave -> travel ->
return -> the same soldiers are still there. Verified by 188 assertions in
`tests/test_recruitment.gd`, including that exact path end to end, and in a
windowed run that recruits four soldiers through the real button handler.

## Step 4 - Encounters and battle transition (`milestone-04`)

**Goal:** connect the overworld to tactical combat.

- Overworld party architecture covering player, bandit, caravan and army parties
- Bandit parties of 5-8 soldiers that wander near their spawn region
- Encounter trigger: pause the world, show BANDITS with both strengths and Attack / Retreat
- `BattleContext`: battle id, both parties, world position, terrain seed, battle
  seed, campaign time, weather placeholder, attacker, defender
- Battle scene: placeholder markers, camera pan/zoom, Start Battle, Retreat

**Definition of done:** travel -> encounter bandits -> Attack -> battlefield loads
with the correct units -> return to the same campaign. Verified by 282 assertions in
`tests/test_encounters.gd`, including that exact path through the real battle scene,
and in a windowed run that recruits four soldiers, meets eight bandits, attacks, and
logs all twelve of them by name on the field.

## Step 5 - First functional combat (`milestone-05`)

**Goal:** units move, fight, die, and the outcome sticks.

- `BattleSimulator`: HP, speed, damage, range, cooldown, target, team, alive/dead,
  and a persistent soldier id per unit - pure logic, no nodes
- Selection: click, box-drag, move order, attack order
- Basic combat AI: seek, close, attack, retarget
- Death recorded against the soldier, but campaign data is only mutated at
  resolution via `BattleResult` (never mid-fight)
- `BattleResult`: winner, survivors, dead, casualties, kills per soldier, XP, gold,
  loot, duration
- Battle results screen; Continue returns to the world map
- Configurable XP for participation, kills, survival and victory

**Definition of done:** the Step 5 end-to-end path, driven headlessly in
`tests/test_e2e_loop.gd` (127 assertions, through the real scenes) and played by
hand in windowed runs. Balance measured across 24 seeds: 20/24 wins against the
weakest bandit band, 3/24 against the strongest.

## Step 6 - Save/load validation (`milestone-06`)

**Goal:** the vertical slice survives a complete application restart.

- Persist campaign metadata, seed, time, position, destination, gold, party,
  soldiers, XP, kills, level, alive/dead, settlements, recruit pools and enemy parties
- Versioned saves with a migration path, and a refusal for saves from a newer build
- `tests/test_persistence.gd` (129 assertions) covering every listed field
- `scenes/dev/persistence_check.tscn`: a **two-process** restart check, because a
  same-process save/load does not prove the game can be closed and reopened

**Definition of done:** New Campaign -> recruit -> fight -> earn XP -> save -> quit
-> relaunch -> Continue, with every value intact. Verified by 91 cross-process
assertions (`26 soldiers restored, 9 of them dead`, every field identical) and by a
real windowed launch driving the whole loop through the UI.

---

## Step 6.5 - External audit remediation (`milestone-06.5`)

**Goal:** nothing new. Harden what Steps 0-6 built, after an external review found
seven defects, and leave a regression test behind for every one.

Not a milestone with a feature; a pass over work already thought finished. It was
worth doing because six of the seven were **silent** - the game kept running and
looked fine while behaving wrongly.

- **Retreat was a progression loop.** Pressing Retreat on a battlefield still ran
  the normal survivor path, so participation and survived-battle XP could be farmed
  at no risk. Withdrawal is now its own outcome: `battles_fought` yes, XP for kills
  only, no `battles_survived`, no spoils, enemy stays.
- **A timeout did not stop the fight.** The finishing step carried on processing a
  full delta of combat against a battle already declared over; units could still
  move, strike and die. Now it returns immediately.
- **Dead soldiers slowed the party.** Travel pace used the roster count rather than
  the active force, so casualties made the column no faster; the HUD showed roster
  against capacity while recruitment counted the living. Membership and force are
  now separate, named quantities.
- **Legacy saves could break the main menu.** `peek_metadata()` assumed the current
  shape, so the exact save the v0 migration exists to handle errored before Continue
  was pressed. Metadata extraction is now shape-tolerant and never writes.
- **The Step 5 end-to-end test proved nothing about the results payload.** It queued
  a second `battle_results` transition with no payload, replacing the real one, then
  asserted the scene existed. It now waits rather than causes, and checks the real
  result against the campaign chronicle and against what the screen renders.
- **A typo in `--suite=` produced a green run with no tests.** Now a failure.
- **A suite that aborted mid-run could pass.** Reaching a completion marker is now
  required; verified against Godot 4.7.2 rather than assumed.

**Definition of done:** all seven fixed, each with a test that fails without the
fix; all suites green; the two-process restart check green; a windowed run of the
whole loop clean. **1557 assertions, 0 failures, 11 of 11 suites** headless, and
**91 checks, 0 failures** across the restart. See D-033 to D-040.

---

## Step 6.6 - Final foundation lock (`milestone-06.6`)

**Goal:** close the last persistence and infrastructure gaps so Steps 0-6 can be
declared foundation-locked. Still no new gameplay - nothing from Step 7, no
formations, terrain, cavalry, projectiles or morale.

Three gaps, each one a case of the game knowing something and not writing it down:

- **Enemy soldiers were persisted one-sidedly.** `BattleResult` described enemy dead
  but not enemy survivors, so a band that survived a fight - through a withdrawal, a
  defeat, or a timeout - came back to the campaign at full strength. Every withdrawal
  was a free reset *for the enemy*, and a hostile band could never be worn down. Enemy
  survivors now return with their real remaining hit points, their kills and their
  battle count; enemy dead keep the kills they made before falling, which
  `_fallen_entry` had been recording and `apply()` discarding.
- **The real main menu was never tested against a legacy save.** Step 6.5 fixed
  `peek_metadata()` and tested the Continue *path*, but not the menu scene the player
  actually meets - which reads metadata, decides whether to offer Continue, and
  formats its own status line. Now driven directly.
- **No independent CI gate.** Local tests cannot catch a suite that depends on a
  local import cache, a leftover save, or a working directory. GitHub Actions now runs
  the suite and both persistence phases on a clean runner, pinned to Godot 4.7.2-stable.

**Definition of done:** the same persistent enemy can be damaged, withdrawn from,
saved, reloaded and fought again without resetting; the real menu opens a legacy save
and Continue migrates it; CI is green on the pushed commit. **1708 assertions, 0
failures, 13 of 13 suites** headless, **95 checks, 0 failures** across the restart,
windowed flow clean. CI green on the first run —
[run 34741699176](https://github.com/JAYST3AM/project-banner/actions/runs/34741699176).
See D-041 and D-042.

---

# First major checkpoint - REACHED

The loop the brief calls the game's first real vertical slice:

```
NEW CAMPAIGN -> WORLD MAP -> TRAVEL -> TOWN -> RECRUIT -> INDIVIDUAL SOLDIERS
-> WORLD MAP -> BANDITS -> TACTICAL BATTLE -> CASUALTIES -> XP -> LOOT
-> WORLD MAP -> SAVE -> CLOSE GAME -> LOAD -> CONTINUE CAMPAIGN
```

Every step is implemented, verified by automated runs, and documented. The
consequences of a fight - who died, who earned what, what was taken - are written
to individual soldiers and survive closing and reopening the game.

---

# After the checkpoint

Deliberately not implemented before Steps 0-6 work. Ordered roughly by how much
they lean on what already exists:

1. **Combat depth** - formations, spears, archery, cavalry, shields, weapons,
   armour, fatigue, wounds, morale effects
2. **Soldier depth** - equipment, inventory, troop upgrade trees, named captains,
   traits that do things, loyalty, aging, permadeath, personal history surfacing
3. **Battlefield** - terrain, procedural battlefields, weather, siege maps
4. **Overworld life** - AI parties, caravans, trade, settlement production,
   supply and demand, world events
5. **Grand strategy** - faction ownership, lords, armies, wars, diplomacy,
   territory, castles, sieges, prisoners, mercenaries, kingdom creation
6. **World generation** - procedural map and political simulation, relationships

---

## Step 7 - Tactical Combat 2.0: terrain and formation foundation (`milestone-07`)

**Goal:** turn a collection of individually moving combatants into the beginning of a
real formation-based battlefield system, on deterministic terrain, with an architecture
that can grow toward very large battles. Still a foundation milestone: it deliberately
implements no shield wall, no phalanx, no bracing, no projectiles, no cavalry, no morale,
no advanced tactical AI and no large-battle optimisation.

This begins item 1 of the post-checkpoint list above. Three systems, all of them
load-bearing rather than decorative:

- **Deterministic battlefield terrain.** `BattlefieldTerrain` is a data grid - type,
  elevation and a resolved movement multiplier per cell - generated from
  `BattleContext.terrain_seed` by hashing lattice coordinates, so the same seed always
  produces the same ground and generating it cannot disturb any other random stream.
  Four types (open, rough, light woods, high ground) from a JSON catalogue. Terrain
  affects movement, which is a real consequence, and nothing else - see D-045 for why a
  defence modifier is deliberately absent.
- **A generic formation engine.** `BattleFormation` is a first-class object with real
  geometry: anchor, facing, desired facing, frontage, depth, spacing, file and rank
  counts, generated slot positions, an order, and a measured cohesion. LINE, COLUMN and
  LOOSE come from a data table and differ in ways the tests measure rather than assert.
  Slots are generated in the formation's own frame, so arbitrary facing works and the
  directional mechanics that come later have the hook they need.
- **A benchmark harness.** `scenes/dev/battle_benchmark.tscn` runs the same battle at
  100 to 5,000 soldiers, reports cost per tick and a setup checksum for cross-commit
  comparison, and attributes the cost by re-running with terrain and formations switched
  off. It exists so that "is this getting slower?" has an answer that is a number.

**The architectural change, stated plainly:** a soldier's formation slot is its whole
job. It fights what it can reach, otherwise it walks to the place it was given. It does
not pick its own ground and does not chase. Formations move as bodies, turn rather than
snap, and reform by their soldiers walking into a new shape. `BattleAI` sits above them
and does the only thing a commander does at this stage - face the enemy and order the
body to engage.

**Two defects found by running it, not by reading it:**

- **A battle could stall forever.** Nine players against one enemy, stopped for four
  simulated minutes: the survivor stood in the gap left by a fallen man, 2.6 units from
  the next soldier along, which is further than a sword reaches. Both bodies were engaged
  and both had stopped, so neither closed and neither could reach. Fixed with a narrow
  rule - a stopped, engaged body whose side has *nobody* in contact lets its soldiers
  press forward - which cannot dissolve a fighting line into a crowd because the contact
  check turns it off the moment anyone is actually fighting. See D-050.
- **The formation arrival tolerance was a waypoint tolerance.** A body closing on an
  enemy stopped six tenths of a unit short of it, which is indistinguishable from
  stopping. Engaged bodies now close to 0.05.

**Definition of done:** deterministic terrain as data, influenced by `terrain_seed`;
LINE, COLUMN and LOOSE with deterministic slots and arbitrary facing; formations that
move, turn, reform physically and measure their own cohesion; the same engine used by
both sides; player formation orders; **2058 assertions across 16 suites, 0 failures**;
the two-process restart check unchanged; the windowed flow clean; CI green. See D-043
through D-053.

---

## Step 7.1 - Formation hardening (`milestone-07.1`)

**Goal:** close the edge cases an external audit found in Step 7 before it is locked. No
new gameplay, no redesign, and nothing from Step 8.

Five fixes and one piece of test tooling:

- **Formation membership invalidates its own geometry.** `set_units()`, `remove_units()`,
  `add_unit()` and `remove_unit()` are the only ways to change a body's roster, and each
  one rebuilds the slots before returning. Step 7 let the simulator edit a donor's
  `unit_ids` directly and then call `ensure_slots()`, which rebuilds only if something
  has already marked the geometry dirty - and nothing had. A player detaching four men
  from a dressed twelve-man line left that line reporting ten files, two ranks and the
  frontage of a body four men larger, indefinitely. `set_type()` had the same defect one
  layer over and is fixed the same way. See D-054.
- **The AI stops taking orders against corpses.** `is_empty()` and `has_living_units()`
  are different questions: a wiped-out body is not empty, because casualties stay on the
  roll so a gap in a line stays a gap. The AI now asks the same question the battlefield
  asks. See D-055.
- **Contact belongs to a body, not to a side.** A wing that has not reached the enemy can
  close while the centre is fighting, instead of being told it is engaged because
  somebody else is. See D-056.
- **Debug bounds describe a rotated body**, derived from the slots rather than from the
  body's own axes. See D-058.
- **`slope_between()` honours its contract** and returns zero when *either* endpoint is
  off the field, not only when both are. See D-057.
- **A formation drill for automated runs** (`--autoformations`) drives the battle scene's
  real order methods - select, detach, move, merge, turn, reshape, toggle the overlay -
  and reports whether any body's geometry disagrees with the soldiers it holds.

**Definition of done:** membership cannot change without invalidating geometry; a partial
detachment rebuilds the donor correctly and leaves every soldier on exactly one roll;
repeated transfers stay correct; the AI ignores all-dead bodies; contact is per
formation; rotated bounds contain every slot; **2207 assertions across 16 suites, 0
failures**; 95 restart checks, 0 failures; the windowed flow clean with the drill; CI
green. See D-054 through D-058.


## Step 7.2 - Battle simulation scaling foundation (`milestone-07.2`)

**Goal:** remove the architectural bottleneck the Step 7 benchmark exposed. An
engineering milestone: no new gameplay, and nothing from Step 8.

The Step 7 measurement put the cost precisely: fifty times the soldiers was about
2,300 times the time per tick, from two loops that compared every soldier with every
other soldier. Both predated Step 7.

- **A battlefield proximity index.** `BattleSpatialGrid` is a uniform grid, `RefCounted`
  and data-first, `battle.spatial_cell_size` units to a cell, rebuilt in one linear pass
  per tick. Buckets are a linked list in packed arrays, so nothing is allocated after
  configuration and a query writes into a caller-supplied array. It answers in cells
  rather than in circles and the order is part of its contract, because two callers
  depend on it. See D-059, D-060, D-066, D-068.
- **Target acquisition searches outward and stops.** Within
  `battle.target_search_max_radius` the answer is *provably identical* to the exhaustive
  scan it replaced, and a test proves it soldier-for-soldier against a brute-force
  reference. Beyond that bound a soldier is pointed at the fighting by its body rather
  than measuring the whole battlefield for itself. See D-061, D-065, D-067.
- **Overlap resolution goes local**, with a pair resolved once by the lower id and in the
  order the old loop used, so it produces the same positions rather than merely a
  defensible set. See D-062.
- **Dead soldiers are excluded at query time, not only at index time** - a defect the
  equivalence probe found in a live battle, not by reading the code. See D-063.
- **Phase instrumentation**, off by default and free when off. See D-064.
- **The benchmark reports before and after**, at Step 7's sizes plus 10,000 and 20,000,
  with the busiest cell and whether contact was reached, and measures the spatial layer
  alone at constant density.

**Definition of done:** measured; 17 suites, **2364 assertions, 0 failures**; 95 restart
checks, 0 failures; the windowed flow clean; CI green. See D-059 through D-069.


## Step 7.3 - Dense battle / overlap scaling (`milestone-07.3`)

**Goal:** remove the next measured bottleneck. Step 7.2 replaced the quadratic proximity
scans and reported that 66% of a tick at five thousand soldiers was the separation pass.
An engineering milestone: no new gameplay, nothing from Step 8.

- **The measurement came first.** The separation pass was given counters before it was
  changed, and they said it was handed **95.6 candidates per soldier to find 226 touching
  pairs** army-wide, with the broadphase 62-66% of the phase. See D-071.
- **A dedicated separation index.** `BattleOverlapGrid`, with its own cell size
  (`battle.overlap_cell_size`, 1.35 - one body's width, chosen by a sweep), enumerating
  cell against cell so every pair is produced once with no per-soldier query. See D-073,
  D-078.
- **Pushes accumulated rather than applied**, which removes order dependence from the
  physics entirely and makes order independence a property that can be checked instead of
  preserved. It is a deliberate change in relaxation and is documented as one. See D-074.
- **A displacement ceiling**, so a crush cannot fling a soldier across the field. D-075.
- **Formation geometry does the spacing.** Settled interiors of a body are skipped on a
  proof, never across two bodies, and never where the formation's own spacing is tight.
  See D-076.
- **Two benchmark families**, because one battlefield cannot answer both "what if an army
  is packed into too small a space" and "what does a battle of twenty thousand cost".
  See D-077.
- **Two Step 7.2 hardening fixes**: the grid's bucket tails are persistent storage rather
  than a per-rebuild allocation (D-070), and an explicit attack order is resolved before
  the automatic target search rather than after it (D-072).

**Definition of done:** measured; **18 suites, 2490 assertions, 0 failures**; 95 restart
checks, 0 failures; the windowed flow clean; CI green. Total simulation time improved at
every size, 1.07x to 7.36x. See D-070 through D-078.


## Step 7.3 - Dense battle / overlap scaling (`milestone-07.3`)

**Goal:** remove the next measured bottleneck. Step 7.2 replaced the quadratic proximity
scans and reported that 66% of a tick at five thousand soldiers was the separation pass.
An engineering milestone: no new gameplay, nothing from Step 8.

- **The measurement came first.** The separation pass was given counters before it was
  changed, and they said it was handed **95.6 candidates per soldier to find 226 touching
  pairs** army-wide, with the broadphase 62-66% of the phase. See D-071.
- **A dedicated separation index.** `BattleOverlapGrid`, with its own cell size
  (`battle.overlap_cell_size`, 1.35 - one body's width, chosen by a sweep), enumerating
  cell against cell so every pair is produced once with no per-soldier query. See D-073,
  D-078.
- **Pushes accumulated rather than applied**, which removes order dependence from the
  physics entirely and makes order independence a property that can be checked instead of
  preserved. It is a deliberate change in relaxation and is documented as one. See D-074.
- **A displacement ceiling**, so a crush cannot fling a soldier across the field. D-075.
- **Formation geometry does the spacing.** Settled interiors of a body are skipped on a
  proof, never across two bodies, and never where the formation's own spacing is tight.
  See D-076.
- **Two benchmark families**, because one battlefield cannot answer both "what if an army
  is packed into too small a space" and "what does a battle of twenty thousand cost".
  See D-077.
- **Two Step 7.2 hardening fixes**: the grid's bucket tails are persistent storage rather
  than a per-rebuild allocation (D-070), and an explicit attack order is resolved before
  the automatic target search rather than after it (D-072).

**Definition of done:** measured; **18 suites, 2490 assertions, 0 failures**; 95 restart
checks, 0 failures; the windowed flow clean; CI green. Total simulation time improved at
every size, 1.07x to 7.36x. See D-070 through D-078.


## Step 7.3 - Dense battle / overlap scaling (`milestone-07.3`)

**Goal:** remove the next measured bottleneck. Step 7.2 replaced the quadratic proximity
scans and reported that 66% of a tick at five thousand soldiers was the separation pass.
An engineering milestone: no new gameplay, nothing from Step 8.

- **The measurement came first.** The separation pass was given counters before it was
  changed, and they said it was handed **95.6 candidates per soldier to find 226 touching
  pairs** army-wide, with the broadphase 62-66% of the phase. See D-071.
- **A dedicated separation index.** `BattleOverlapGrid`, with its own cell size
  (`battle.overlap_cell_size`, 1.35 - one body's width, chosen by a sweep), enumerating
  cell against cell so every pair is produced once with no per-soldier query. See D-073,
  D-078.
- **Pushes accumulated rather than applied**, which removes order dependence from the
  physics entirely and makes order independence a property that can be checked instead of
  preserved. It is a deliberate change in relaxation and is documented as one. See D-074.
- **A displacement ceiling**, so a crush cannot fling a soldier across the field. D-075.
- **Formation geometry does the spacing.** Settled interiors of a body are skipped on a
  proof, never across two bodies, and never where the formation's own spacing is tight.
  See D-076.
- **Two benchmark families**, because one battlefield cannot answer both "what if an army
  is packed into too small a space" and "what does a battle of twenty thousand cost".
  See D-077.
- **Two Step 7.2 hardening fixes**: the grid's bucket tails are persistent storage rather
  than a per-rebuild allocation (D-070), and an explicit attack order is resolved before
  the automatic target search rather than after it (D-072).

**Definition of done:** measured; **18 suites, 2490 assertions, 0 failures**; 95 restart
checks, 0 failures; the windowed flow clean; CI green. Total simulation time improved at
every size, 1.07x to 7.36x. See D-070 through D-078.

---

## Standing design principle

Individual soldiers should feel like people rather than numbers. `Soldier`
already carries the fields this needs - age, traits, loyalty, level, kills,
battles survived, and an open-ended `history` log. The systems that fill that log
come later; the storage for it exists now so those systems never have to
retro-fit identity onto a stat block.
