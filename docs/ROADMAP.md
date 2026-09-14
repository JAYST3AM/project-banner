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

## Step 7.4 - Target acquisition scaling (`milestone-07.4`)

**Goal:** remove the next measured bottleneck. Step 7.3 took the separation pass off the
top of the profile and reported what was left: at five thousand soldiers **target selection
alone was 248.542 ms a tick, 66% of the tick**, because every soldier looked for an enemy
on every simulation tick. An engineering milestone: no new gameplay, nothing from Step 8,
no threads, no C++, no GDExtension, no multi-rate simulation.

- **The counters came first.** Target handling was instrumented before it was changed, and
  what the counters said chose the milestone: the search was not too slow, it happened far
  too often. See D-079.
- **Target persistence.** A soldier keeps a valid opponent - alive, hostile, still nearby -
  instead of asking for the nearest enemy every tick. `BattleUnit.auto_target_id` and
  nothing more elaborate than an id and a tick: no node references, no timers, no
  coroutines, no per-soldier dictionaries, no signals, and nothing that reaches a campaign
  save. See D-080, D-085.
- **A deterministic staggered cadence.** `battle.target_reacquisition_ticks` (4), phased as
  `unit.id % interval`, so a quarter of the army looks on any given tick rather than the
  whole army on every fourth. Simulation ticks, never a wall clock. See D-080, D-081.
- **A retention radius**, so a remembered opponent is finite: past
  `battle.target_retention_radius` a soldier stops continuing with it rather than running
  after it across a battlefield. Shipped equal to the search ceiling, on purpose, and swept
  at 8, 16, 24 and 32 first. See D-082.
- **Hysteresis** (`battle.target_switch_advantage`, 1.25): an opponent is not abandoned
  because something else is a hundredth of a unit closer. See D-081.
- **Urgency, and one kind of it.** The only search allowed to run off the cadence is one for
  an opponent lost inside the soldier's own reach. Configurable, tested on and off, measured
  by a death-storm benchmark that kills an entire front rank on one tick. See D-083.
- **The search itself untouched.** The local search, its ladder and its tie-breaking are
  Step 7.2's, and the brute-force equivalence tests still drive them. See D-085.
- **Generic foundations for the ranged milestone**, with no archers in this one: a unit
  declares `awareness_radius`, and nothing in the target path branches on what it carries.
  See D-086.
- **A spike analysis**, because a staggered system is exactly the kind that can average
  well and spike: per-tick phases are sampled and reported as average, p50, p95, p99 and
  worst. See D-084.

**Definition of done:** measured; **19 suites, 2732 assertions, 0 failures**; 95 restart
checks, 0 failures; the windowed flow clean; CI green. Total simulation time improves at
every size of both benchmark families (1.43x to 2.66x on the fixed-area torture test, 2.0x to
3.9x at realistic density), and target acquisition itself is **3.5x cheaper** at the sizes
where both builds were measured at the same window. The next bottleneck is named by the
measurement rather than guessed: formation focus. See D-079 through D-087.

---

## Step 7.5 - Formation battlefield focus scaling (`milestone-07.5`)

**Goal:** remove the next measured bottleneck, and this time the measurement is
unambiguous: at twenty thousand soldiers on a battle-sized field, **formation focus cost
760 ms of a 1,786 ms tick**, with an earlier run of the same build putting it at 856 ms of a
1,940 ms tick. Step 7.4 had just made target selection four times cheaper, and
what that revealed was the same shape of work one level up - every body answering "where is
the fighting" with a fresh walk of the whole army. An engineering milestone: no new
gameplay, nothing from Step 8, no projectiles, no cavalry, no morale, no threads, no C++, no
GDExtension, no ECS, no second multi-rate system.

- **The counters came first, again.** The focus path was instrumented before it was changed,
  and what the counters said chose the architecture: 100 whole-army walks a tick for 100
  bodies, 2,205,806 soldier-visits, and ten of those walks made on behalf of a single soldier
  from inside the target loop. See D-088.
- **A transient formation summary.** Living count, centre and a box, rebuilt once per tick
  from each body's own roll, with the soldiers no body claimed collected as each side's loose
  run. No nodes, no per-soldier objects, no persistence. See D-089.
- **Formation-level enemy selection.** Bodies are compared against bodies, nearest box first,
  and the search stops as soon as no remaining body could hold a nearer soldier - which makes
  it the *same answer* a full scan gives rather than a cheaper approximation of it. See
  D-089.
- **Soldiers consume the cached answer.** A soldier reads its body's focus: a field read, not
  a search. Its body's answer dying mid-tick is corrected once for the body, and a body with
  nobody left to watch is not asked again inside the same tick. See D-090.
- **No global soldier fallback, and a counter that proves it.**
  `foc_scans_from_soldiers` counts whole-army walks made by the focus logic on behalf of a
  soldier. It was 10.3 per tick at twenty thousand soldiers; it is now zero, in every battle
  the suite drives.
- **Allocation audited rather than asserted.** Every buffer is sized when the army is handed
  over and reused; a test drives sixty ticks and asserts the allocation count does not move.
  See D-091.
- **No retention rule, deliberately.** A body's answer changes 38 times a tick across a
  hundred bodies, and the pass is now cheap enough that a hysteresis rule would be new
  behaviour bought with no measurable saving. Declining it is a decision with a reason rather
  than an omission. See D-089.

**Definition of done:** measured; **20 suites, 2831 assertions, 0 failures**; 95 restart
checks, 0 failures; the windowed flow clean; CI green. See D-088 through D-091.

## Step 7.6 - Automatic target search cost scaling (`milestone-07.6`)

**Goal:** remove the next measured bottleneck. Step 7.5 left the profile unambiguous - at
twenty thousand soldiers on the realistic benchmark, target acquisition cost 575 ms of a 965 ms
tick, 57% of the simulation - and this milestone set out to make the local search cheaper
without changing a single answer it gives. It finished by leaving the search exactly as it was,
because every cheaper one measured slower. The milestone's product is the measurement that
establishes that, and the instruments that make it checkable.

**Where the target phase actually goes.** Counted before anything was changed, at twenty
thousand soldiers:

| component | ms/tick | share of the phase |
| --- | ---: | ---: |
| the spatial query | 509.7 | **85.2%** |
| answering with the formation (the focus path) | 21.2 | 3.5% |
| deciding whether a remembered opponent is worth keeping | 19.4 | 3.2% |
| deciding whether a look is worth making (the D-087 proof) | 7.7 | 1.3% |
| hysteresis and storing the answer | 2.6 | 0.4% |
| the rest of the target loop | 37.9 | 6.3% |
| **the phase** | **598.5** | 100% |

And the query itself, per look: **1.77 grid queries** (one per rung), **260 cells read**, **171
candidates measured** to keep one, 24% of looks answered by the first radius, 44% after
widening, 32% by nobody at all. The second rung is 78% of the query time.

**What was tried.** Five exact re-implementations of the search, all of them designed to
inspect less ground than the ladder, all of them measured against it in a purpose-built
micro-benchmark (`scripts/dev/search_bench.gd`) and in live battles:

| implementation | measured |
| --- | --- |
| Chebyshev ring walk, outward from the soldier | 2.6x slower |
| rectangle walk, per-cell distance bound | 2.3x slower |
| row walk, nearest rows first | 1.9x slower |
| row walk with an exact reach | 1.9x slower |
| block-indexed walk over a coarse side mask | 3.9x slower |

The best of them read 122 cells and measured 45 candidates per look - **half the ladder's work**
- and was still nearly twice as slow. The reason is the interpreter and it is now a recorded
number: one radius-32 box costs about 300 us however it is walked, a bound test in a loop body
costs about 0.3 us, and the empty cell it skips costs about 0.12 us to open and dismiss. Pruning
inside the loop cannot pay for itself; the ladder is cheap because its *first* rung is small and
answers most looks before the second one is reached.

- **The search is unchanged, and that is the decision.** No re-implementation ships. The
  block-indexed attempt went with the block mask it required, because the mask cost a write per
  soldier per tick in the spatial rebuild for a path that never runs. See D-094.
- **What ships is the measurement.** Search-shape counters (queries per look, cells read and
  cells walked twice, candidates split by rung, escalations, the distance an answer was found
  at, exact per-search percentiles), per-rung query timings, and sub-phase timings for the rest
  of the target loop. All of it is development-only, behind the profile flag, and the shipped
  simulation pays nothing for it.
- **Nothing else changed.** Same suite, same battles, same numbers as Step 7.5 - which is the
  regression argument for a milestone whose only code changes are instruments.

**Definition of done:** measured; **21 suites, 2881 assertions, 0 failures**; the restart check
unchanged; the windowed flow clean; CI green. The target phase is unchanged at ~598 ms/tick and
the next bottleneck is the same one: the second rung of the search. See D-094.

---

## Standing design principle

Individual soldiers should feel like people rather than numbers. `Soldier`
already carries the fields this needs - age, traits, loyalty, level, kills,
battles survived, and an open-ended `history` log. The systems that fill that log
come later; the storage for it exists now so those systems never have to
retro-fit identity onto a stat block.

## Step 7.7 - Native spatial query feasibility spike (`milestone-07.7`)

The question was where the boundary should sit, not whether to write C++: the target search's
spatial kernel was measured twice - broadphase only, and broadphase plus the exact test - and the
two answers were 1.04x and 1.91x on the realistic twenty-thousand-soldier tick. The second shape
ships; the first is kept as a mode because its exactness is structural.

Done: the `NativeTargetQuery` accelerator with both boundary shapes, the two mirror hooks that
keep its live state true, a comparison backend that diffs the implementations per rung, an
equivalence suite that caught two real defects before any benchmark quoted a number, a
bridge-cost benchmark, matched before/after tables for both families, a spike distribution, the
toolchain pin and a CI build that proves the native class loaded.

Not done, and not this milestone: threads, ECS, per-soldier nodes, any second native kernel, or
any change to what the simulation decides. The GDScript reference remains the authority and the
fallback, and `CURRENT_STATE.md` carries the measured numbers.

## Step 7.8 - separation-pass optimisation (`milestone-07.8`)

**Done.** The Step 7.8 first pass measured the tick and found the separation pass to be the largest
single phase at realistic scale (~200.6 ms/tick at 20,000 soldiers). This pass:

- corrected the two profiler counters the audit found wrong (`dev_coincident` counted touching
  pairs; `dev_usec_pairs` was never assigned) and added the assertions that pin them (D-096);
- diagnosed the settled-cell skip rather than assuming it: it fires during dressing and approach
  and cannot fire at contact, because a real fight has almost no settled soldiers in it. The proof
  was left exactly as it was (D-097);
- split the phase's own cost by measurement - rebuild, same-cell traversal, neighbour traversal,
  apply, and the exact pair work by subtraction (D-096);
- measured a packed GDScript candidate (2.3-3.7x the reference's phase, bit-for-bit equivalent on
  1,500 generated states) and shipped it as the portable fast path (D-098);
- built a native shape-C kernel that performs the whole pass and returns one displacement per
  soldier per axis: **42.7 ms/tick at 20,000 on a realistic field, against 238.0 for the
  reference, a 5.6x overlap speedup and a whole-tick 650.5 -> 454.7 ms/tick in matched windows**
  (D-099);
- ran the 300 v 300 windowed showcase the brief asked for, which found a formation-layer stalemate
  at that scale and documents it with numbers rather than impressions (D-100).

**Next measured bottleneck:** the per-soldier update loop - 246.6 ms/tick of the 474.6 ms/tick at
20,000 soldiers, of which automatic target selection is 106.2 ms. The next largest phases are the
formation focus layer (49.0 ms) and the spatial grid rebuild (45.3 ms). One suspicion is already
located and not yet proved: `BattleSimulator._attack()` walks the whole roster on every kill to
clear hunting orders, which is O(deaths x army) per tick.

**Not started:** Step 7.9, and any optimisation of the above.
