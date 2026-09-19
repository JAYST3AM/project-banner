# Current State

What is actually playable and verified **right now**.

**Last updated:** Step 8 - roads as a living thing: tiers, traffic and decay on every link, with
the pace and the eta reading the drawn road and the priced grid left to price only the route (D-124).
**Engine:** Godot 4.7.2-stable
**Test status:** Step 8's suites are green - `test_roads` 74/0 (new) and `test_world_map` 116/0 -
plus `test_core_services` 83/0 with its clock read from the config. The rest of the tree is red
from the 2026-09-19 revert and its fallout: 30 suites, 5,884 assertions, 41 failures, 5 BROKEN -
and every one of those reproduces at the parent commit, verified suite by suite with the Step 8
work stashed. See **Known red**, below. The two-process restart check has not been re-run since
the revert.
**Independent gate:** GitHub Actions runs the suite on every push to `main`; it is red for the
same known reason until the battle-terrain cluster is dealt with.

**Note:** Steps 6.5, 6.6 and 7.1 were hardening passes, and Steps 7.2, 7.3, 7.4, 7.5 and 7.6 were
engineering milestones; none of them added gameplay. Step 7 added terrain and formations.
See [Step 7 - terrain and formation
foundation](#step-7---terrain-and-formation-foundation), [Step 7.1 - formation
hardening](#step-71---formation-hardening), [Step 7.2 - battle simulation scaling
foundation](#step-72---battle-simulation-scaling-foundation), [Step 7.3 - dense battle /
overlap scaling](#step-73---dense-battle--overlap-scaling), [Step 7.4 - target acquisition
scaling](#step-74---target-acquisition-scaling), [Step 7.5 - formation battlefield focus
scaling](#step-75---formation-battlefield-focus-scaling), [Step 7.6 - automatic target search
cost scaling](#step-76---automatic-target-search-cost-scaling) and [Step 7.7 - native spatial
query feasibility spike](#step-77---native-spatial-query-feasibility-spike) and [Step 7.8 -
separation-pass optimisation](#step-78---separation-pass-optimisation) below.

---

## Known red - the revert's fallout (all pre-existing)

The 2026-09-19 revert that took the other session's sweep out of the tree also deleted
`biome_catalog.gd`, `terrain_ground.gd`, `battlefield_decals.gd` and `terrain_bench.gd` - while
seven files still reference them, headed by `scripts/battle/battlefield_terrain.gd`. The battle
terrain cannot compile, and the suites built over it fail. Every line below reproduces at the
parent commit with the Step 8 work stashed:

| suite | state | what is known |
| --- | --- | --- |
| `test_terrain`, `test_formation_battle` | BROKEN | parse errors: `BiomeCatalog` does not exist |
| `test_battle_outcomes`, `test_battle_view`, `test_formation_focus` | BROKEN | ran no assertions - the battle scene does not come up |
| `test_target_acquisition` | 21 failures | battle phases come back 0 |
| `test_party_semantics` | 5 failures | the HUD shows `-` where the count belongs |
| `test_spatial_grid` | 2 failures | the grid signature is empty |
| `test_combat`, `test_e2e_loop`, `test_encounters` | 1 / 3 / 1 failures | the same cluster |

Also referencing the removed classes, outside the suites: `scripts/terrain/terrain_generator.gd`,
`terrain_overlay.gd`, `terrain_props.gd`, `scripts/dev/terrain_lab.gd`, `terrain_probe.gd`,
`ground_forge.gd`. Owner's call pending: restore the pre-sweep versions, or finish removing what
the revert broke. The world map, travel and the road network are unaffected.

## Roads (Step 8)

A link between two settlements carries a **tier** - `none | dirt | track | road`, speed bonus
1.0 / 1.1 / 1.5 / 2.0 - stored in the link's own `kind`, and the priced grid, the eta and the
walking pace all read it. A settlement founded later links itself to its nearest neighbour as a
dirt road; traffic (world units walked on the link) wears it up a tier; a long idle span - 3,650
game days per tier - wears it down, roadless at the floor, and traffic can wear even that back in.
Settings: `data/config/game_config.json` under `roads`. Model and measurements: D-120, D-121 and
the Step 8 section of `ROADMAP.md`. Nothing founds settlements at runtime yet - the road side is
`RoadNetwork.connect_settlement`, waiting on the settlement side.

Played-it follow-ups (D-122, D-123): the walk **hugs the drawn curves** - a route's road stretches
are spliced onto the link curves, so the marker walks the line (the on/off-road travel log measures
it: "0 u off its line" in the legs of a debug-1 run, against 15-31 u before). A **march to open
ground is a real march** again - a point order drops any route a previous settlement order left
behind, where before the stale geometry "arrived" on the first step and the party never moved. And
the debug panel's pace line now shows the **effective pace** with its ground factor
("~275 u/h (ground x2.00)" on a road) so the road bonus is visible in play. And the pace and the eta
read the **drawn road itself** (D-124): `RoadNetwork.bonus_at` answers with the corridor the wear
scan and the snap already use, the grid went back to only pricing the route - so speed changes
exactly at a road's visible edge, a march crossing one gets its blip, and a road-painted block can
no longer leak speed past the drawn line. And the pace counts a road by its **drawn width**
(`roads.pace_radius`, 10 u) rather than the wider wear shoulder (48 u, D-126) - so the speed flips
where the road visibly begins and ends; the wear credit and the snap keep the shoulder.

## The vertical slice is complete

Every step of the loop in the project brief works, and the consequences survive
closing the game and reopening it:

```
NEW CAMPAIGN -> WORLD MAP -> TRAVEL -> TOWN -> RECRUIT -> INDIVIDUAL SOLDIERS
-> WORLD MAP -> BANDITS -> TACTICAL BATTLE -> CASUALTIES -> XP -> LOOT
-> WORLD MAP -> SAVE -> CLOSE GAME -> LOAD -> CONTINUE CAMPAIGN
```

| Action | Works? |
| --- | --- |
| Launch, create a campaign (reproducible world seed), or Continue | Yes |
| Travel the world map at Paused / Normal / Fast | Yes |
| Enter settlements and recruit named, individual soldiers | Yes |
| Inspect a soldier: age, class, level, XP, kills, morale, loyalty, traits, history | Yes |
| See hostile parties wander the map and chase you | Yes |
| Meet bandits: the world pauses, both strengths shown, Attack or Retreat | Yes |
| Fight a real battle: units close, strike, miss, and die | Yes |
| Select and order units: click, shift-click, box-drag, move, attack | Yes |
| Casualties, XP, kills, levels and gold written to the individual soldiers | Yes |
| Battle results screen naming the fallen and crediting the survivors | Yes |
| Save, close the game, relaunch, and Continue | Yes |

## What is verified, and how

Everything below is asserted by an automated run, not claimed by hand.

**Twenty headless suites, 2831 assertions, 0 failures**

| Suite | Assertions | Covers |
| --- | --- | --- |
| `test_core_services` | 83 | config presence, clock maths, RNG determinism, save round-trip |
| `test_campaign_flow` | 41 | campaign lifecycle, scene transitions, singletons, Continue |
| `test_world_map` | 88 | world from data, travel, arrival, speed states, persistence |
| `test_recruitment` | 191 | unit/trait data, names, factory, recruitment rules, party limits |
| `test_party_semantics` | 51 | **roster membership vs active force**: travel pace, HUD wording, capacity, the dead kept on the record |
| `test_encounters` | 282 | spawning, movement, aggro, detection, `BattleContext`, deployment, simulator |
| `test_combat` | 276 | damage, death, attribution, victory conditions, results, resolver, balance |
| `test_battle_outcomes` | 224 | **victory / defeat / draw / withdrawal**, the retreat farming loop, timeout freezing the field, results-screen wording |
| `test_terrain` | 72 | **deterministic ground**: same seed same field, different seed different field, bounds, movement modifiers, terrain actually changing movement, the slope contract at the field's edge, independence from rendering |
| `test_formation` | 328 | **formations as physical objects**: geometry across seven facings, distinct slots, ownership and partial detachment, repeated transfers, movement without teleporting, turning, reformation, cohesion, casualties leaving gaps, rotated debug bounds |
| `test_formation_battle` | 132 | **both systems together**: both armies formed, the enemy on the same engine, the AI ignoring wiped-out bodies, contact belonging to a body rather than a side, terrain slowing a body, a formed battle resolving and being reproducible, the architecture guardrails, a 500-unit scale smoke |
| `test_spatial_grid` | 111 | **the proximity index**: cell boundaries, side filtering, equivalence against a brute-force scan, the snapshot contract, rebuild behaviour |
| `test_overlap` | 140 | **the separation pass**: exact separation, no launch, no permanent stacking, settled-interior skips, reverse-roster independence, cell-size sweeps |
| `test_target_acquisition` | 231 | **Step 7.4**: retention, invalidation by death and by distance, explicit orders, the cadence at every interval, staggered phases, roster-order independence, hysteresis, cell boundaries, the death storm, the provable skip, the counter partition, determinism |
| `test_formation_focus` | 99 | **Step 7.5**: the bounded selection proved against a full scan in live battles, summaries after movement and casualties, membership changes through the Step 7.1 APIs, empty bodies, deterministic ties, one pass per body per tick, zero soldier-originated scans, the repair path, the allocation audit, determinism, explicit orders |
| `test_enemy_persistence` | 121 | **the same enemy fought twice**: battle → campaign → save/load → second battle, enemy survivors and enemy dead |
| `test_e2e_loop` | 147 | **the Step 5 critical end-to-end path, through the real scenes** - including the real `BattleResult` reaching the real results screen |
| `test_persistence` | 154 | every field the milestone lists, migration, refusal, corrupt files, metadata for every save shape |
| `test_legacy_menu` | 30 | **the real main menu scene** against a legacy unversioned save: status text, Continue offered, real Continue migrating and opening |
| `test_runner_contract` | 30 | **the runner itself**: aborts, early returns, empty suites, non-suites, missing files, filter selection |

**The restart check** (`scenes/dev/persistence_check.tscn`) runs as two separate
Godot processes, because a same-process save/load only proves the serialiser
round-trips and not that the game can be closed and reopened:

```
godotc --headless --path "<project>" res://scenes/dev/persistence_check.tscn -- --phase=write
godotc --headless --path "<project>" res://scenes/dev/persistence_check.tscn -- --phase=verify
```

The first process recruits five soldiers, travels, fights a battle to a conclusion,
then breaks off from a second fight, records what the world looks like, saves and
exits. The second process is brand new: it calls the same `continue_campaign()` the
Continue button calls, and checks every recorded fact. It has no memory of the first
process except the save file.

Result: `26 soldiers restored, 9 of them dead` - every soldier identical in name,
archetype, level, XP, hit points, kills, battles fought and survived, status,
traits and history length; settlements, visited flags and depleted recruit pools
intact; enemy parties with their positions, rosters and `defeated` flags intact;
the battle chronicle intact, including the withdrawal and the rules it applied; the
active-force and roster counts both restored and agreeing with the main menu's own
summary; the world map opens on the restored campaign; and re-saving is stable.
It also wounds a specific enemy before breaking off (`s_0008: 28 -> 11 hp`) and the
next process confirms that exact soldier still has those hit points.
**95 checks, 0 failures.**

**A real windowed launch** driving the whole loop through the actual UI
(`--autostart-campaign --autotravel --autostart-town --autorecruit --autoleave
--autoengage --autoattack --autostart-battle`) walks

```
world_map -> settlement -> world_map -> battle -> battle_results
```

and logs `battle_0001: VICTORY - 4 of 5 survived, 5 of 5 enemies down (0 standing),
97 gold, 280 xp`, with **zero script errors or warnings**.

**An independent CI gate** (`.github/workflows/godot-tests.yml`) repeats the headless
suite and both persistence phases on a clean runner, so nothing can pass locally only.

**Opening-fight balance**, measured across 24 campaign seeds in a real simulator:

| Fight | Won | Enemy casualties |
| --- | --- | --- |
| vs the **weakest** bandit band (the careful choice) | 20 / 24 | 122 |
| vs the **strongest** bandit band | 3 / 24 | 77 |

## Step 6.5 - external audit remediation

Seven defects were reported by an external audit of Steps 0-6. All seven are fixed,
and **every fix has regression coverage that fails without it**. No new gameplay was
added; no working architecture was redesigned.

| # | Defect | Fix | Guarded by |
| --- | --- | --- | --- |
| 1 | Retreating from a battlefield still ran the survivor path: participation, survived-battle XP, `battles_survived`, survivor history. Enter a fight, press Retreat, repeat - a risk-free farming loop. | Withdrawal is its own outcome (D-033). `battles_fought` only, XP for kills only, no `battles_survived`, no spoils, enemy stays on the map. | `test_battle_outcomes.gd`: immediate retreat, a 6-cycle farm loop, retreat-after-combat, and the outcome matrix |
| 2 | `step()` finished the battle on timeout and then processed the rest of the same step, so units could still move, strike, take damage and die after the end. | Return immediately after `_finish("")` (D-035). | `test_battle_outcomes.gd`: hit points and positions frozen, no hit/death events, later steps inert |
| 3 | Travel pace used the roster size, so a party that had lost most of its strength still marched at full-company speed. The HUD showed roster-vs-capacity while recruitment counted only the living - `24 / 24` while replacements were still on offer. | Roster membership and active force are separate accessors (D-034); pace, capacity, encounter strength and markers use the force; UI states both. | `test_party_semantics.gd`: pace, the like-for-like "same force, more graves" comparison, HUD text, capacity agreement, and that the dead are still listed |
| 4 | `peek_metadata()` assumed `player_party` was already a dictionary, so the exact legacy shape the v0 migration exists to handle errored in the main menu before Continue was ever pressed. | Shape-tolerant, non-mutating metadata extraction (D-038), plus `party_active` / `party_lost`. | `test_persistence.gd`: current, legacy bare-array, corrupt, missing and too-new saves, then the real Continue path |
| 5 | The Step 5 end-to-end test queued a **second** `battle_results` transition with no payload, overwriting the first. The screen fell back to "No battle result was passed to this screen" and the test still passed. | `SceneManager.await_scene()` waits instead of causing (D-039); the test reads the screen's real payload and rendered text. | `test_e2e_loop.gd`: battle id, title, survivor/casualty/XP/gold/enemy counts against the campaign chronicle, then Continue back to the map |
| 6 | A `--suite=` filter matching nothing produced a zero-suite run that passed. | Empty selection is a failure (D-037). | `test_runner_contract.gd` plus a direct run of the bogus filter |
| 7 | A suite that aborted mid-run still reported `N assertions, 0 failures` and passed. | A suite must reach its completion marker (D-036). | `test_runner_contract.gd` drives the runner against fixtures that abort, return early, assert nothing, or are not suites at all |

**Also found and fixed during the pass** (not on the audit list): the restart check
identified its battle by `last_battle_summary()`, which stopped meaning "the battle
we care about" as soon as a second fight was on the record (D-040).

### How the runner was hardened, and how that was verified

The audit asked whether a runtime-aborted suite could still pass, and said not to
assume. It was measured directly against Godot 4.7.2 with a throwaway probe that
recorded three assertions, then read past the end of an empty array:

```
SCRIPT ERROR: Out of bounds get index '3' (on base: 'Array')
PROBE: await run() RETURNED
PROBE: checks=3  failures=0  completed=false
```

Control **does** return to the awaiting caller, and the suite comes back looking
healthy - 3 assertions, 0 failures. Only the completion marker survived the abort.
So the marker is the completion contract, and `test_runner_contract.gd` keeps it
honest by running the runner's own `evaluate()` against deliberately malformed
fixtures (an abort, an early return, an empty suite, a non-suite, a missing file).

One fixture raises a genuine runtime error on purpose and prints a `SCRIPT ERROR`
line. It is bracketed by banners in the output so it cannot be mistaken for a real
defect. **Every other line in a clean run is error-free** - that was checked, not
assumed.

## Step 6.6 - final foundation lock

Three gaps remained after Step 6.5, all of them persistence or infrastructure rather
than gameplay. Closing them is what makes the Steps 0-6 foundation safe to build on.

### 1. Enemy soldiers are persisted like the player's own

`BattleResult` described enemy **dead** but not enemy **survivors**, so `apply()`
wrote back only the deaths. An enemy damaged to 23 hit points and left standing -
because the player withdrew, lost, or the clock ran out - returned to the campaign at
**full health**, and the next meeting with the same band was a completely fresh fight.
Every withdrawal was a free reset for the enemy, so a hostile band could never be worn
down and "bloody them, pull out, come back stronger" was not a strategy the game
supported.

`BattleResult.enemy_survivors` now carries the same factual shape as a player
survivor entry (minus anything to do with progression - hostile soldiers have none in
Steps 0-6), and `apply()` writes it back. Same for the fallen: `_fallen_entry` had
always recorded an enemy's kills, and `apply()` had been discarding them, so a bandit
who cut down two of the player's soldiers before dying was remembered as having killed
nobody. **Battle consequences are now symmetric between the player's soldiers and the
enemy's.** See D-041.

The regression test walks all three boundaries in one pass rather than testing the
result object in isolation:

```
battle -> campaign          the fight's damage reaches the persistent soldier
campaign -> save/load       and survives the game being closed and reopened
campaign -> second battle   and the next encounter starts from it, not from full HP
```

### 2. The real main menu, against a legacy save

Step 6.5 fixed `peek_metadata()` and tested the Continue path through
`GameManager.continue_campaign()`. That left a gap: nothing proved the actual menu
*scene* could open a legacy save, and the menu is where a player meets the problem - it
reads metadata, decides whether to offer Continue, and formats its own status line.

`tests/test_legacy_menu.gd` now drives the real `main_menu.tscn` against an
unversioned, bare-array save and checks its real state through small **read-only**
accessors (`continue_available()`, `status_text()`), then presses the real Continue
action and follows it to the world map with the party intact. It also confirms the
newer-version refusal still wins and that no save means no Continue.

### 3. GitHub Actions

An independent gate now runs the full headless suite and both persistence phases on
every push to `main` and every pull request against it, pinned to Godot 4.7.2-stable by
explicit release URL - and asserts the installed engine actually reports that version.
No `continue-on-error` on any verification step, and `set -o pipefail` keeps the
engine's exit code through the log `tee`. See D-042.

It was also **proven to go red**, twice, on a throwaway branch and a pull request that
was closed without merging: once by a failing assertion (suite step fails, later steps
skipped) and once by a failing verify phase with the suite and write phase both green
(later step fails, job red). A gate that has only ever been seen to pass is not evidence
of anything.

## Step 7 - terrain and formation foundation

Two systems and a measuring tool. No shield wall, no phalanx, no bracing, no
projectiles, no cavalry, no morale, no advanced tactical AI, no large-battle
optimisation - those are future milestones, and Step 7 exists to make them possible
rather than to be them.

### 1. Battlefield terrain is data

`BattlefieldTerrain` is a `RefCounted` grid: a type index, an elevation and a resolved
movement multiplier per cell, at `terrain.cell_size` world units per cell. Four types in
`data/terrain/terrain_types.json` - open, rough, light woods, high ground.

Generation is a pure function of `BattleContext.terrain_seed`. Both noise fields come
from hashing lattice coordinates rather than from a generator's state, so the same seed
always produces the same ground regardless of the order anything is visited in, and
generating a battlefield cannot disturb any other random stream.

Terrain affects movement - `speed = base_speed * terrain.move_multiplier_at(position)` -
and nothing else. That is the deliberate scope: a defence modifier would move every
seeded balance measurement to no purpose yet. See D-045.

### 2. A formation is a geometry

`BattleFormation` carries anchor, facing, desired facing, frontage, depth, spacing, file
and rank counts, per-soldier slot positions, an order and a measured cohesion. LINE,
COLUMN and LOOSE come from `data/formations/formation_types.json` and differ through
generated geometry, not through bonuses:

| | files x ranks for 20 | frontage | depth | spacing |
| --- | --- | --- | --- | --- |
| line | 10 x 2 | 23.4 | 2.6 | 2.60 |
| column | 2 x 10 | 2.6 | 23.4 | 2.60 |
| loose | 6 x 4 | 22.1 | 13.3 | 4.42 |

Slots are generated in the formation's own frame and transformed into the world, so any
facing works. The tests drive seven facings including 37, 143.5 and -61 degrees.

Formations move as bodies (at the pace of the slowest soldier, so nobody is left
behind), turn at a rate rather than snapping, and reform by their soldiers *walking* to
new places. A test steps one frame after ordering a line-to-column change and asserts
that not one soldier moved - only the places did.

### 3. Two defects found by running it

- **A battle could stall forever.** A fight resolved to nine players against one enemy
  and then stopped for four simulated minutes. The survivor stood in the gap left by a
  fallen man, 2.6 units from the next soldier along - further than a sword reaches. Both
  bodies were engaged, both had stopped, neither would close. Fixed with one narrow rule:
  a stopped, engaged body whose side has *nobody* in contact lets its soldiers press
  forward. While anyone is fighting, dressing wins. See D-050.
- **The arrival tolerance was a waypoint tolerance.** A body closing on an enemy stopped
  0.6 units short of it, which is indistinguishable from stopping. Engaged bodies now
  close to 0.05.

### 4. Benchmark: what 100 to 5,000 soldiers actually costs

`scenes/dev/battle_benchmark.tscn`, headless, simulation stepped directly (no
rendering), Godot 4.7.2-stable, one machine:

| units | ticks run | per tick | ticks/sec |
| --- | --- | --- | --- |
| 100 | 600 | 4.78 ms | 209 |
| 500 | 109 | 110.3 ms | 9 |
| 1,000 | 28 | 440.0 ms | 2 |
| 2,500 | 12 | 2,684.6 ms | 0.4 |
| 5,000 | 6 | 10,988.0 ms | 0.05 |

The larger sizes ran fewer ticks because each run stops on a wall-clock budget - a fixed
tick count would have made the top of the range take hours. The counts achieved are
reported rather than hidden.

**Attribution** - the same battle re-run with the new systems switched off:

| units | units only | +terrain | +formations | both |
| --- | --- | --- | --- | --- |
| 100 | 3.271 ms | 3.269 ms | 4.583 ms | 4.783 ms |
| 500 | 108.145 ms | 108.776 ms | 108.690 ms | 110.337 ms |
| 1,000 | 432.896 ms | 427.976 ms | 430.173 ms | 439.993 ms |

Terrain is free and formations are within noise above 500 soldiers. **The cost is two
loops that compare every soldier with every other soldier** - `_choose_target()` and
`_resolve_overlaps()` - and both predate this milestone. From 100 to 5,000 soldiers is
50x the army and about 2,300x the time per tick.

This is measured and documented, not fixed: the brief forbids a large rewrite on the
strength of a slow number, and a spatial structure designed now would be shaped for this
field rather than for the one with cavalry on the wings that the large-battle milestone
will actually have to serve. What Step 7 does owe the future is not making it worse, and
every loop it adds is linear in soldiers.

**One thing the numbers do not say, stated plainly:** above 500 soldiers the measured
ticks ran out before the armies made contact, so those figures are the approach and
targeting phase rather than a melee. Both quadratic loops run every tick regardless of
contact, so the per-tick cost is representative - but it is an approach, not a battle.

### 5. Verification

| Check | Result |
| --- | --- |
| Headless suites | **16 of 16 reported, 2207 assertions, 0 failures** |
| New suites this milestone | `test_terrain` (72), `test_formation` (328), `test_formation_battle` (99) |
| Two-process restart | 95 checks, 0 failures - unchanged, and now with formations and terrain in the flow |
| Windowed smoke | campaign → settlement → recruit → battle → **formation drill** → results |
| Bogus `--suite=` | exit 1 |
| CI | **green** on `c4c2bd2` — [run 34744677802](https://github.com/JAYST3AM/project-banner/actions/runs/34744677802), read from the raw log: 16 of 16 suites, 2058 assertions, both persistence phases |

The windowed run takes the whole loop through the real UI with the development switches:
`world_map → settlement → world_map → battle → battle_results`, five recruits against
whatever band the seed produced, zero script errors. Four runs across four seeds produced
two victories and two defeats, tracking the size of the band — see §7 of the report for
the numbers and for what that measurement does *not* cover.

New coverage is behavioural rather than structural: the same enemy fought twice across
a restart, a real reformation that drops cohesion and recovers it, a line ordered into a
column with a one-frame "nobody moved" assertion, an arbitrary-facing geometry sweep,
terrain that measurably slows a body in proportion to its own data, and a stalled battle
that is required to reach a winner inside its step budget.

## Step 7.1 - formation hardening

A corrective pass over Step 7's edge cases. No new gameplay, no redesign: the six items
below are all cases of a formation being able to say something untrue about itself.

### 1. Membership changes now invalidate geometry, by construction

`BattleFormation` owns its own membership. `set_units()`, `remove_units()`,
`add_unit()` and `remove_unit()` are the only ways to change it, and every one of them
marks the geometry dirty, flags the body as reforming, and **rebuilds the slots before
returning**.

The bug this closes: `BattleSimulator.assign_formation()` used to edit a donor
formation's `unit_ids` directly and then call `ensure_slots()`, which rebuilt only if
something had already marked the geometry dirty - and nothing had. A player could
detach four men from a dressed twelve-man line and the line would go on reporting ten
files, two ranks and the frontage of a body four men larger, until some unrelated
operation happened to dirty it. The failure was not "the slots were stale for one
frame"; it was that they were stale indefinitely. See D-054.

The related fix: `set_type()` had the same shape of problem one layer over. It marked
the geometry dirty and left `file_count`, `rank_count`, `frontage()` and `depth()`
answering for the shape the body was walking *out of*. It now rebuilds immediately too,
which is why the HUD reports "Line: 7 files by 1 ranks" the instant the order is given.
A shape change or a transfer is a rare, deliberate act; the per-tick path stays lazy.

### 2. The AI no longer takes orders against corpses

`BattleAI` rejected candidates with `is_empty()`. A formation is never empty - casualties
are kept on the roll on purpose, so that a gap in a line stays a gap - so a wiped-out
body still held every id it had ever been given. An AI choosing by distance alone would
pick the body it had just finished destroying and order its soldiers to face dead men.
It now asks the same `has_living_units()` question the battlefield asks, so there is one
definition of an active body rather than two that can drift apart. See D-055.

### 3. Contact belongs to a body, not to a side

Contact is now tracked per formation (`BattleFormation.in_contact`) instead of as one
flag per side. The Step 7 version meant that *any* player soldier being in reach of
*any* enemy marked the whole player side as engaged, which suppressed the "press
forward" behaviour for a detached wing that had not reached anybody yet - it would sit
exactly where it was, forever, while the centre fought. A wing can now close on its own
opponent while the centre is engaged, and its contact turns on and off independently.
See D-056.

The flag is still set inside the per-soldier reach test that already had to be made, so
it costs a boolean rather than another battlefield-wide pass.

### 4. Debug bounds describe a rotated body

`bounds()` is derived from the actual slot positions instead of from frontage and depth
around the anchor. Those two are the body's size *along its own axes*, so at forty-five
degrees the slots rotated and the rectangle did not, and the overlay drew a thin
horizontal strip containing almost none of the men. See D-058.

### 5. The terrain slope contract is honoured

`slope_between()` documented "zero when either point is off the field" and only did so
when *both* were. Off-field ground reads as zero height, so one point inside and one
outside produced a fake slope - the edge of the field appearing to fall away into
nothing. The contract is now checked first. See D-057.

### 6. Verification

| Check | Result |
| --- | --- |
| Headless suites | **16 of 16 reported, 2207 assertions, 0 failures** (was 2058) |
| `test_formation` | 328, up from 203 - ownership, partial detachment, repeated transfers, rotated bounds, immediate shape reporting |
| `test_formation_battle` | 99, up from 78 - the AI ignoring wiped-out bodies, contact belonging to a body |
| `test_terrain` | 72, up from 69 - the slope contract at the field's edge |
| Two-process restart | **95 checks, 0 failures** - unchanged; no save-format change |
| Windowed smoke | campaign → settlement → recruit → battle → **scripted formation drill** → results, zero script errors |
| Bogus `--suite=` | exit 1 |
| CI | **green** on `ccf9cff` — [run 34746351217](https://github.com/JAYST3AM/project-banner/actions/runs/34746351217), read from the raw log: 16 of 16 suites, 2207 assertions, both persistence phases |

The windowed run now includes a **formation drill** (`--autoformations`) that drives the
scene's real order methods - select all, form line, detach three as a column, move them
separately, merge back, go loose, turn left, turn right, toggle the overlay, reform as a
line - and then reports whether any player body's geometry disagrees with the soldiers
it holds. It reported **3 player bodies, 0 inconsistencies**.

The same drill is what exposed fix 1's second half: the log said "ordered into Line: 6
files by 2 ranks", which is loose order's geometry, not a line's.

### Bugs found while making these fixes

- **Contact was cleared in the wrong place.** The first implementation cleared it at the
  *end* of a step, which wiped it before the formation orders - which run at the *top* of
  the next step - could read it. Every body would have believed itself unengaged
  forever, and the stalled-battle fix from Step 7 would have silently stopped working.
  Caught by the contact test on its first run.
- **`set_type()` did not rebuild geometry.** Described above; found by reading the
  drill's own log rather than by reading the code.
- **A Step 7 test was asserting against a default.** `_test_reformation_is_physical`
  checked that a line had "settled" and was "dressed" without ever starting the
  simulator. A battle in `DEPLOYING` does not step at all, so the body still held its
  creation-time cohesion of 1.0 and the assertions passed without measuring anything.
  Marking membership changes as reforming is what exposed it: the body was correctly
  reported as un-dressed, and the test had never actually dressed it.


## Step 7.2 - Battle simulation scaling foundation

Step 7 measured the problem and refused to guess at it: two loops compared every soldier
with every other soldier, and fifty times the soldiers cost about 2,300 times the time per
tick. Step 7.2 replaced both. It added **no gameplay**.

### 1. Every proximity question goes through one index

`BattleSpatialGrid` is a uniform grid over the battlefield, `battle.spatial_cell_size`
(4.0 world units) to a cell. `RefCounted`, data-first, battle-local, no rendering and no
physics: a soldier is still plain data. Buckets are a linked list held in two
`PackedInt32Array`s rather than an array per cell, so nothing is allocated after
`configure()`, and queries write into an array the caller owns and reuses.

Membership is a **snapshot rebuilt once per tick** - plus a second rebuild before overlap
resolution, which is the one phase where being a body's width behind actually matters.
The brief asked for this choice to be made on measurement rather than assumption, and the
measurement is lopsided: a rebuild costs **0.8 ms at 500 soldiers and 8.0 ms at 5,000**
against per-tick totals of tens and hundreds of milliseconds. Incremental maintenance
would buy nothing and add a way for the index to drift out of step with the units it
describes. There is no update path, so there is no update path to get wrong.

Queries answer in **cells, not circles**. A query returns everyone whose cell the search
box touches - a superset - in a defined order, and the caller measures. The caller has to
measure anyway, to pick a nearest or to push a pair apart, and a grid that sorted would
just be doing that work twice. The order is part of the contract because the overlap pass
resolves pairs in the order it meets them.

### 2. Target selection is local, and provably so

`_choose_target()` searches outward: 8 units first, widening to 32, and **within that bound
the answer is exactly what the exhaustive scan would have returned** - not approximately,
exactly, with ties going to the lower unit id. The proof is a property rather than a hope:
if the search stops at the first radius containing any enemy, the nearest enemy inside
that radius *is* the nearest enemy, because anything nearer would have been inside a
smaller radius that found nobody. A test checks it soldier-for-soldier against a
brute-force reference, on generated layouts and across eighty ticks of a moving battle.

Beyond the bound a per-soldier search stops being local - answering it means examining the
whole enemy army, per soldier, per tick - so a soldier with nobody near it is **pointed at
the fighting** instead: by its body, at the nearest enemy to the formation anchor, or
failing that by its side's centre of mass. Those are computed once per tick rather than
once per soldier.

This is a real trade and it is stated rather than buried. A soldier marching towards a
distant enemy faces the enemy its body is pointed at rather than its own private nearest.
Its *conduct* is unchanged - a formed soldier dressing to its slot does not steer by its
target at all - so the visible difference is the direction it faces while marching. Inside
the bound, which is where every soldier who is actually fighting lives, nothing changed.

### 3. Overlap resolution goes local, and reproduces the old answer

`_resolve_overlaps()` asks the grid for the soldiers near each one and resolves a pair
only when `other.id > unit.id`. The pair rule means each overlap is pushed once rather
than once per side. The processing order deliberately reproduces the exhaustive loop's
order, because positional relaxation is sequential - a different visit order would produce
different battles, which would mean an optimisation had quietly changed the game. Since a
pair that is out of range does nothing, skipping the far ones is a no-op, and the spatial
pass produces **the same positions** the old loop produced. A test checks that directly
against the exhaustive loop, on eight arrangements including a cell-boundary pair and two
soldiers standing in exactly the same place.

### 4. Two defects, both found by measurement rather than by reading

1. **Dead soldiers were still answerable.** The index is a snapshot taken at the start of a
   tick and soldiers die *during* that tick. A soldier processed late in the loop could be
   handed a comrade who fell earlier in the same tick and could select, face, chase or
   shove a corpse. The scan this replaced re-checked liveness on every candidate and the
   grid did not, so the grid returned a different nearest enemy in a real fight and a
   battle's outcome changed. Found by a probe comparing the two answers inside a live
   battle. See D-063.
2. **The escalation's premise was false.** The grid returns a box, and the box is
   deliberately larger than the circle, so the search "found" enemies slightly beyond the
   radius it had asked about - and stopped there. A soldier whose true nearest was 11.6
   units away was handed one at 13.1 because the first rung had returned *something*. Not
   a near miss: a different decision, in the first radius rather than the last. See D-065.

A third finding was a cost rather than a defect, and the profile is what surfaced it:
after the search was bounded, target selection still held four fifths of the soldier loop
because every query walked the soldier's own army and discarded it. One byte per cell
recording which sides are present took that from 794 ms of soldier loop to 58 ms. See
D-068.

### 5. Benchmark: Step 7 against Step 7.2

Same harness, same seed (70707), same layouts, same budget, this machine, headless:

| units | Step 7 ms/tick | Step 7.2 ms/tick | speedup | ticks/sec | busiest cell | contact |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 100 | 4.783 | **4.160** | 1.1x | 240 | 2 | yes |
| 500 | 110.337 | **36.165** | 3.1x | 28 | 8 | yes |
| 1,000 | 439.993 | **65.299** | 6.7x | 15 | 12 | yes |
| 2,500 | 2,684.557 | **254.277** | 10.6x | 4 | 27 | no |
| 5,000 | 10,988.004 | **703.456** | 15.6x | 1 | 52 | no |
| 10,000 | not measured | **2,872.690** | - | 0.3 | 105 | no |
| 20,000 | not measured | **12,016.796** | - | 0.08 | 210 | no |

**10,000 and 20,000 were both run.** 20,000 soldiers simulate at 12.0 seconds per tick,
and that is reported rather than extrapolated. It is not 60 FPS and is not claimed to be:
the largest size this machine simulates under a single 60 FPS frame is **100 soldiers**,
and the simulation need not update at render frequency at all - that decision is later
work.

Formations now *reduce* the cost rather than adding to it (at 500 soldiers: 51.9 ms
without them, 36.2 ms with), which is the intended shape. A formed soldier dresses to a
slot instead of steering by a target, so putting an army in formation removes work.

The spatial layer measured alone, at constant density so the curve is the algorithm's
rather than the battlefield's:

| units | field | rebuild | cells | query avg |
| ---: | --- | ---: | ---: | ---: |
| 1,000 | 35x35 | 1.481 ms | 81 | 0.0340 ms |
| 5,000 | 77x77 | 8.073 ms | 400 | 0.0551 ms |
| 10,000 | 110x110 | 16.987 ms | 784 | 0.0766 ms |
| 20,000 | 155x155 | 31.826 ms | 1,521 | 0.1105 ms |
| 50,000 | 245x245 | 81.964 ms | 3,844 | 0.1131 ms |

Fifty times the soldiers is fifty-five times the rebuild - linear - and a query at a fixed
radius stays flat, returning about fifty-five candidates whether the army is one thousand
or fifty thousand.

### 6. What is now the most expensive phase

By phase, ms per tick, clock on:

| units | grid | focus | formations | soldiers | of which target | overlap |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500 | 0.825 | 0.725 | 0.752 | 11.465 | 8.256 | 12.845 |
| 2,500 | 3.788 | 3.472 | 3.155 | 78.040 | 63.709 | 104.753 |
| 5,000 | 7.986 | 7.913 | 6.901 | 161.400 | 131.782 | 387.150 |

**Overlap resolution is now the dominant cost** - 66% of a tick at 5,000 soldiers, and it
overtakes target selection somewhere between 500 and 2,500. That is a genuinely new
finding rather than the old one restated: it was never visible under the quadratic
scan the old `_choose_target()` was doing.

It is a **density** limit, not an algorithmic one. `_resolve_overlaps()` asks each soldier
who is near it, and the answer grows with how many soldiers share a cell - which on a
fixed 100x60 battlefield grows with the army. The busiest cell at 5,000 soldiers holds 52
of them. The honest next question is whether the battlefield should grow with the army,
before anyone asks whether GDScript is fast enough - which is why the work stayed in
GDScript (D-069).

### 7. Verification

| | |
| --- | --- |
| Headless suites | **17 of 17 reported, 2364 assertions, 0 failures** (was 2207 across 16) |
| New suite | `test_spatial_grid` (127) - insertion, rebuild, empty, one, many, cell boundaries, radius queries, side filtering, dead-unit exclusion, query order, duplicates, dense cells, movement between cells, large-radius queries, the scratch buffer, brute-force agreement over 200 generated queries, and the margin |
| Extended | `test_formation_battle` 99 -> 132 - combat across a cell boundary and a cell corner, every soldier able to find a target over 40 ticks, a formed body pointed by its own focus, and a 300-soldier pile in one cell run twice |
| Two-process restart | **95 checks, 0 failures** - unchanged; no save-format change |
| Windowed smoke | campaign -> settlement -> recruit -> battle -> **formation drill** -> results, zero script errors, drill reported 3 player bodies and 0 inconsistencies |
| Bogus `--suite=` | exit 1 |
| CI | **green** on `b35d868` — [run 34749443509](https://github.com/JAYST3AM/project-banner/actions/runs/34749443509), read from the raw job log: 17 of 17 suites, 2364 assertions, both persistence phases |

## Step 7.3 - Dense battle / overlap scaling

Step 7.2 removed the quadratic proximity scans and reported what was left: at five thousand
soldiers, **66% of a simulation tick was the separation pass**. Step 7.3 attacked that. It
added **no gameplay**.

### 1. The measurement came before the change

The profile clock could say the pass cost 387 ms. It could not say what the pass *did*, and
"walking candidates that turn out to be far away" and "resolving genuine contacts" call for
opposite fixes. So the pass was given counters first. Measured at five thousand soldiers on
the fixed-area benchmark, before anything was restructured:

| | Step 7.2 |
| --- | ---: |
| candidates handed to the pass, per soldier | **95.6** |
| pairs actually touching, army-wide | 226 |
| broadphase share of the phase | 62-66% |
| broadphase cost as a share of the whole tick | 66% |

Twenty-one hundred candidates measured for every one that mattered. That number chose the
architecture; it was not reachable by reading the code, because every line of the old pass
looks reasonable.

Three structural problems, in descending order of size:

1. **The targeting grid was doing a separation's job.** It is built to answer a question
   eight units wide; a separation happens at 1.35. One cell size cannot be right for both,
   and 4-unit cells made the pass search a box several times the width of the distance it
   cared about.
2. **Every soldier asked its own question.** Each pair was therefore examined twice, once
   from each side, and each answer arrived in an array that had to be appended to.
3. **The armies were never on their slots.** In the fixed-area benchmark the formation
   slots run off the field entirely, so its soldiers march for the whole measured window -
   99.8% of them were away from their assigned place, some by 288 units. That is a property
   of the torture test rather than of the game, and it is one reason the second benchmark
   family exists.

### 2. A dedicated separation index

`BattleOverlapGrid` is a second index over the same battlefield, with its own cell size and
its own rebuild. Each occupied cell pairs itself with the **half-neighbourhood in front of
it** - one cell to the right, three below, and the diagonals between - so every physical
pair is produced exactly once, with no per-soldier query and no result array to go with it.
The neighbourhood radius is derived as `ceil(separation distance / cell size)` cells, so a
change to either number cannot silently produce a search that misses pairs.

### 3. Pushes are accumulated, not applied

This is the part that changed the relaxation deliberately, and it is documented as such.

Step 7.2 pushed each overlapping pair apart the instant it found it, so the second pair of a
cluster was measured against positions the first pair had already moved. That made the
outcome depend on the order pairs were visited in, which is why Step 7.2 had to reproduce
the exhaustive loop's visit order exactly and why its test compared *positions* against
that loop.

Step 7.3 sums every push into a per-soldier displacement and moves the field once, at the
end. There is no visit order to preserve because none reaches the result, and that is
checkable rather than asserted: the test reverses the entire roster and checks that nobody's
position moves by more than a thousandth of a unit.

**What is honestly different.** A simultaneous pass resolves a cluster over a tick or two
where a sequential one does it in one, because a sequential pass lets each soldier see the
corrections already made to its neighbours. Measured on a deliberately pathological pile of
three hundred soldiers in a six-unit square, two hundred passes leave under two per cent of
the original overlap and the closest pair back out at 91% of the separation distance - an
asymptotic convergence, not a stall. For a battle the trade is right: what matters is that
the pass separates soldiers at least as fast as they can walk into each other, and that is
tested by driving two lines into each other and checking the closest approach across a
hundred and sixty ticks.

A soldier's displacement is capped at `battle.max_separation_push` (1.35 units). A soldier
buried in a crush takes a push from every body it is inside and nothing bounds that sum; the
cap makes the pass bounded by construction and cannot slow an ordinary push down.

### 4. Formation geometry does the spacing

The pass skips cell-against-cell work where it can **prove** there is nothing there: every
soldier in both cells standing within `battle.separation_settle_epsilon` (0.15 units) of its
assigned place, both cells belonging to the same formation, and that formation's own slot
spacing clearing the separation distance plus twice the settle distance. Two soldiers on
their slots are a slot apart, and a slot is 2.6 units against a separation distance of 1.35.

It is checked three ways before it is taken, and it **never** applies across two bodies: two
friendly formations touching or crossing, and enemy contact, are measured pair by pair.
Where a battle actually presses bodies together the skip does nothing at all, which is the
point.

### 5. Benchmark A - the fixed-area torture test

Unchanged from Step 7 in seed (70707), dimensions, layouts, rules and budget, so the
comparison holds across three milestones.

| Soldiers | Step 7.2 ms/tick | **Step 7.3 ms/tick** | speedup | Step 7.3 ticks/sec | contact |
| ---: | ---: | ---: | ---: | ---: | --- |
| 100 | 4.160 | **3.651** | 1.14x | 274 | yes |
| 500 | 36.165 | **33.939** | 1.07x | 29 | yes |
| 1,000 | 65.299 | **57.537** | 1.13x | 17 | yes |
| 2,500 | 254.277 | **172.164** | 1.48x | 6 | yes |
| 5,000 | 703.456 | **425.177** | 1.65x | 2 | yes |
| 10,000 | 2,872.690 | **781.491** | 3.68x | 1 | no |
| 20,000 | 12,016.796 | **1,632.897** | 7.36x | 0.6 | no |

Overlap alone, the phase this milestone attacked, at the same sizes and settings:

| Soldiers | Step 7.2 overlap ms | Step 7.3 overlap ms | speedup |
| ---: | ---: | ---: | ---: |
| 500 | 12.845 | **2.789** | 4.6x |
| 2,500 | 104.753 | **21.841** | 4.8x |
| 5,000 | 387.150 | **60.912** | 6.4x |
| 20,000 | not separately recorded | **845.582** | - |

The overlap figures are the phase clock's own measurement, taken on a separate run from
the table above because the clock costs two reads per soldier.

Total simulation time improves at **every** size, which is the requirement: a milestone that
merely moved time between functions would not have been one.

Two things worth stating. **Contact is now reached at 2,500 and 5,000**, where Step 7.2's
slower ticks ran out of budget during the approach - so those rows are now measurements of
fights rather than of marches. And the 100-to-500 rows move least because at that size the
field is sparse, few soldiers are near each other, and the old pass had little to waste.

### 6. Benchmark B - battlefield scaled with the army

The torture test answers "what if an army is packed into a space far too small for it",
which is a genuinely useful question and is where the density limit shows. It is not the
question "what does a battle of twenty thousand soldiers cost", because past a few hundred
soldiers the field stops being a battlefield and becomes a crowd - at twenty thousand the
soldiers do not fit in it dressed.

Family B scales the ground with the army, holding density at the 500-on-100x60 reference
(0.0833 soldiers per square unit) and the standard 5:3 aspect. Each side deploys as several
formed bodies that **start standing on their slots**, and the two armies advance into each
other.

| Soldiers | field | density | ms/tick | ticks/sec | ticks | contact | combat ticks | armies |
| ---: | --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| 1,000 | 141x85 | 0.0833 | 145.160 | 7 | 83 | **yes** | 22 | 6 |
| 2,500 | 224x134 | 0.0833 | 511.941 | 2 | 59 | **yes** | 39 | 14 |
| 5,000 | 316x190 | 0.0833 | 1,182.920 | 1 | 51 | **yes** | 39 | 26 |
| 10,000 | 447x268 | 0.0833 | 2,953.324 | 0.3 | 21 | **yes** | 18 | 50 |
| 20,000 | 633x380 | 0.0833 | 5,852.212 | 0.2 | 11 | **yes** | 7 | 100 |

**Every size reached sustained contact and fought.** Twenty times the army costs 40.3 times
the time per tick at constant density - superlinear, but nothing like the fixed-area family's
447x for 200x, and the shape is a real battle rather than a crush.

### 7. What is now the most expensive phase

By phase, ms per tick, clock on:

| units | grid | focus | formations | soldiers | of which target | overlap | total |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500 | 0.749 | 0.674 | 0.670 | 15.523 | **12.684** | 2.789 | 21.103 |
| 2,500 | 3.962 | 3.864 | 3.343 | 112.968 | **97.195** | 21.841 | 150.169 |
| 5,000 | 8.560 | 9.043 | 7.499 | 282.044 | **248.542** | 60.912 | 377.448 |
| 20,000 | 38.155 | 44.436 | 39.539 | 569.973 | **429.207** | 845.582 | 1,579.954 |

**Target selection is now the dominant phase across the realistic range** - 66% of a tick
at five thousand soldiers, having been about the same share of a *much larger* total
before. Overlap is down from 66% of a tick to **16%**.

Overlap becomes dominant again only at twenty thousand on the fixed-area field, where the
army is several times denser than the field can physically hold and the separation pass is
fighting a crush rather than a battle. On the scaled battlefield - the case that resembles
a battle - the profile is the five-thousand shape, not the twenty-thousand one.

Where the remaining per-soldier cost goes is the next question, and it is a question about
how often a soldier needs to think rather than about how the work is distributed: every
soldier searches for a target every tick. That is what Step 7.4 should attack.

### 8. Verification

| | |
| --- | --- |
| Headless suites | **18 of 18 reported, 2490 assertions, 0 failures** (was 2364 across 17) |
| New suite | `test_overlap` - a pair separates, distant soldiers do not move, coincident soldiers resolve deterministically, cell boundaries including corners and exact edges, no pair resolved twice, order independence, repeatability, **no allocation after configure**, settled-formation skipping for line/column/loose, compression, two bodies crossing, enemy contact, flank contact, dense piles, no launches, convergence, brute-force agreement on sparse *and* dense deployments, and a cell-size sweep |
| Two-process restart | **95 checks, 0 failures** - unchanged; no save-format change |
| Windowed smoke | campaign -> settlement -> recruit -> battle -> **formation drill** -> results, zero script errors |
| CI | **green** on `e32bfbc` — [run 34754179794](https://github.com/JAYST3AM/project-banner/actions/runs/34754179794), and on every commit since — read from the raw job logs: 18 of 18 suites, 2490 assertions, both persistence phases |

## Step 7.4 - Target acquisition scaling

Step 7.3 took the separation pass off the top of the profile and reported what was left:
at five thousand soldiers **target selection alone cost 248.542 ms a tick - 66% of the
tick** - because every soldier asked the battlefield who was nearest to it on every
simulation tick. Step 7.4 attacked that. It added **no gameplay**.

### 1. The counters came first

A phase clock can say a phase costs 248 ms. It cannot say whether to make the work smaller
or to stop it happening, and those are different fixes. So target handling was counted
before it was changed, and the counters chose the milestone: the search was already local
(Step 7.2) and each look was not expensive. **There were simply far too many of them.**

To make that a measurement rather than an argument, the counters were first run against the
*unmodified* Step 7.3 code - the same harness, the same seed, the same fixed-area battles,
150 ticks - and then against the new code at the same windows. Counters are per soldier-tick
rates, so they compare directly:

| Soldiers | Step 7.3 looks/tick | Step 7.4 looks/tick | 7.3 looks/soldier/s | 7.4 looks/soldier/s | avoided |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 500 | 500.0 | 54.6 | 20.00 | 3.28 | **89.1%** |
| 2,500 | 2,500.0 | 409.4 | 20.00 | 4.91 | **83.6%** |
| 5,000 | 5,000.0 | 925.6 | 20.00 | 5.55 | **81.5%** |

And what the old looks were looking at, at the same windows, at five thousand soldiers:
**4,095 of 5,000 looks a tick found nobody at all**, and the 5,000 that remained saw an
average of **71.8 candidates** each to return one answer that was usually already known.
Two in every eighty-one candidates handed over by the broadphase named a soldier worth
naming. That number - not the milliseconds - is what chose the architecture.

### 2. A remembered opponent, and a staggered awareness tick

A soldier now keeps the enemy it is dealing with. The rule:

> Once a soldier acquires an automatic opponent, that opponent remains preferred while alive,
> hostile and locally relevant. Reacquisition happens immediately on invalidation, or
> according to a deterministic staggered awareness cadence, or when the soldier's own turn
> comes round - and an explicit player order outranks all of it.

The order of the questions is the design, and every step is cheaper than the one below it:

```
explicit order?          use it                     (a player instruction: no search)
remembered opponent?
    in reach?            use it                     (no search: the fastest path)
    not this soldier's turn yet?
                         use it                     (no search: still relevant)
turned to look?
    nearest local enemy, or the body's focus        (the only expensive answer)
```

A soldier that can reach the enemy in front of it never searches at all, which is why the
counters above fall by four fifths. A soldier that cannot reach anybody looks on its own
cadence and is pointed at the fighting in between by its formation's or its side's focus -
the answer the bodies have already worked out for themselves once a tick.

**The schedule is `unit.id % battle.target_reacquisition_ticks`**, four ticks by default,
against an integer simulation tick counter. Three consequences, all deliberate:

- **staggered** - a quarter of the army looks on any given tick, rather than the whole army
  on every fourth, which is the difference between a flat cost and a sawtooth;
- **deterministic** - the same seed, orders and roster produce the same schedule, and
  re-ordering the roster does not move a single soldier's phase (tested);
- **no clock** - not `Time.get_ticks_msec()`, not a render frame. Wall-clock timing in this
  project lives inside the benchmark's counters, behind a boolean, measuring rather than
  deciding.

### 3. The cadence is a latency bound, not merely a saving

An enemy that arrives immediately after a soldier's scheduled look is noticed on the next
one - one cadence minus the tick it arrived on - and the tests measure exactly that at every
cadence the sweep covered (1, 2, 3, 4, 6 and 8 ticks).

Measured in live battles, the cost of the cadence is small and it is bounded:

| Soldiers | reacquisitions sampled | average wait | within one cadence | worst |
| ---: | ---: | ---: | ---: | ---: |
| 500 | 1,014 | 2.7 ticks | 98.7% | 250 ticks |
| 2,500 | 5,831 | 1.3 ticks | 99.8% | 11 ticks |
| 5,000 | 11,503 | 1.4 ticks | 99.4% | 23 ticks |
| 20,000 | 19 | 2.5 ticks | 100.0% | 3 ticks |

The worst case is not the schedule arriving late: it is a soldier with nobody left to find -
standing at the edge of a battle where its side has already won. The distinction is counted
rather than excused (`latency_over_cadence`).

The sweep that chose the value, tick-matched so that every cadence measures the *same* 120
ticks of the same battle (2,500 and 5,000 soldiers, one run per value, no wall-clock cap that
would shorten a slower run's window):

| cadence (ticks) | looks/soldier/s at 5,000 | target ms/tick at 5,000 | total ms/tick at 5,000 | total at 2,500 |
| ---: | ---: | ---: | ---: | ---: |
| 1 (every tick) | 13.57 | 174.402 | 280.559 | 86.452 |
| 2 | 6.79 | 93.756 | 200.397 | 69.476 |
| 3 | 4.52 | 66.498 | 173.012 | 63.828 |
| **4 (shipped)** | **3.39** | **52.825** | **160.079** | **61.260** |
| 6 | 2.26 | 39.389 | 146.134 | 58.225 |
| 8 | 1.70 | 32.322 | 139.951 | 56.437 |

Four is **3.3x cheaper than every-tick on the target phase** (174.4 to 52.8 ms) at a
worst-case awareness latency of three ticks, and the cadences beyond it buy less and less: 6
and 8 are 8.7% and 12.6% cheaper in total than 4, for a hundred and two hundred milliseconds
more latency. The returns diminish because the target phase stops being most of the tick -
by eight ticks it is 23% of it - which is the milestone working.

### 4. The bound that stops a chase, and the margin that stops a twitch

`battle.target_retention_radius` is how far a remembered opponent may be before it stops
being worth continuing with. It ships at 32 units - **equal to the search ceiling on
purpose**, and the sweep says why: at 8, 16 and 24 a soldier acquires an enemy at long range
and releases it again on the very next tick, which is thrash dressed up as a rule. What the
bound is for is the opponent that genuinely leaves, and for that it only has to be finite.

The sweep, tick-matched the same way (2,500 and 5,000, 120 ticks, one run per value):

| retention radius | 5,000 total ms/tick | target ms/tick at 5,000 | releases per tick ("too far") |
| ---: | ---: | ---: | ---: |
| 8 | 157.077 | 52.315 | 127.1 |
| 16 | 156.608 | 52.256 | 110.7 |
| 24 | 157.357 | 52.463 | 68.9 |
| **32 (shipped)** | **157.397** | **52.624** | **0.1** |

The time is flat to within half a per cent across the whole sweep: the radius is *not* where
the milliseconds are, so the choice between these values is a choice about behaviour, and
only one of them produces no acquire-and-release loop.

`battle.target_switch_advantage` (1.25) is hysteresis: a new candidate has to be a quarter
closer before it takes over from the enemy a soldier already has. Two enemies at similar
range no longer swap the answer on alternate ticks, which is cheaper and less twitchy to
watch. Measured churn at five thousand soldiers in the fixed-area fight: **47.8 changes a
tick across five thousand soldiers** - about one change per soldier per hundred ticks.

### 5. Urgency: the one search that may run off the cadence

Exactly one situation brings a search forward: an opponent that stopped being valid while it
was **inside the soldier's own reach**. A soldier whose opponent falls in front of it should
not stand over the corpse waiting for its turn; a soldier whose opponent walked off, or that
never reached the one it was marching towards, waits like everything else. The rule is
configurable (`battle.target_immediate_on_contact_loss`), tested on and off, and bounded by
the size of the contact line rather than the size of the army.

The worst case it can produce is measured by a storm benchmark that kills an entire front
rank on one tick, in two lines already fighting, held still so that the storm is the only
thing that changes:

| Soldiers | front rank killed | average tick | storm tick | spike | next tick | looks: normal / storm |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 600 | 100 | 15.532 ms | 16.992 ms | 1.09x | 13.985 ms | 100 / 200 |
| 1,200 | 200 | 33.362 ms | 37.018 ms | 1.11x | 29.536 ms | 200 / 400 |
| 2,400 | 400 | 45.331 ms | 49.068 ms | 1.08x | 41.797 ms | 400 / 800 |

A storm tick carries double the ordinary number of looks and costs about a tenth more than
the tick it interrupts; the tick after it is cheaper than average. **No cliff.** The searches
that follow the storm are the ones the schedule was going to make anyway - the soldiers who
lost an opponent off the cadence were left to their own turn.

### 6. The look that is proved not worth making

Removing the repeated looks revealed what had been hiding behind them. Once the soldiers with
an enemy in reach stopped searching, the looks that remained were **self-selected for being
expensive**: a soldier with nobody within eight units escalates to a thirty-two-unit query,
and on a dense field that walks hundreds of cells to hand back candidates that are nearly all
beyond the radius. The average look cost roughly three times what it had in Step 7.3,
precisely because the cheap ones had been optimised away.

So a soldier now asks one question before looking: *could a look return anybody at all?* The
body's focus is the enemy nearest to the body's anchor, at a known distance, and the soldier
stands a known distance from that anchor, so

```
d(soldier, E) >= d(anchor, E) - d(soldier, anchor) >= focus_distance - offset
```

If that bound is already beyond the widest rung of the soldier's ladder, no look can find
anybody and the look is skipped. The grid's own query margin is subtracted, because both the
focus and the soldier may have moved since the focus was computed. It is **a proof, not a
threshold**: when the bound holds, the search would have returned nothing and the soldier
ends up pointed at its body's focus either way - the answer is identical, and only the
question is skipped. A test drives a formed battle for two hundred ticks and, for every
skipped look, checks *every enemy on the field* to confirm none was inside the soldier's own
bound.

Measured, it removes 7 to 16 per cent of the cheap path's work at the sizes benchmarked - and
it is what took the 5,000-soldier target phase from the 86.3 ms the first version of the
milestone measured to **81.3 ms**, with the same behaviour.

### 7. Benchmark A - the fixed-area torture test

Unchanged from Step 7 in seed (70707), dimensions, layouts, rules and budget, so the
comparison holds across four milestones and the historical figures are not touched.

| Soldiers | Step 7.3 ms/tick | **Step 7.4 ms/tick** | speedup | 7.4 ticks/sec | contact |
| ---: | ---: | ---: | ---: | ---: | --- |
| 100 | 3.651 | **1.987** | 1.84x | 503 | yes |
| 500 | 33.939 | **12.760** | 2.66x | 78 | yes |
| 1,000 | 57.537 | **30.746** | 1.87x | 33 | yes |
| 2,500 | 172.164 | **91.848** | 1.87x | 11 | yes |
| 5,000 | 425.177 | **235.303** | 1.81x | 4 | yes |
| 10,000 | 781.491 | **541.734** | 1.44x | 2 | yes |
| 20,000 | 1,632.897 | **1,141.059** | 1.43x | 0.9 | no |

Total simulation time improves at **every** size. Contact is now reached at 10,000 as well as
2,500 and 5,000, because the cheaper ticks fit more of the battle into the same budget;
20,000 on a field far too small for it still spends its whole window marching.

**And the phase this milestone attacked**, at matched windows (150 ticks, both builds, same
seed and layout, clock on):

| Soldiers | Step 7.3 target ms | **Step 7.4 target ms** | speedup | 7.3 total | 7.4 total | total speedup |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500 | 8.840 | **2.433** | **3.63x** | 18.021 | 11.076 | 1.63x |
| 2,500 | 79.784 | **22.839** | **3.49x** | 133.215 | 73.522 | 1.81x |
| 5,000 | 286.694 | **81.268** | **3.53x** | 403.398 | 196.244 | 2.06x |

The Step 7.3 column is a **probe build**: the tip of Step 7.3 with the same counters added and
nothing else changed, run on this machine with this harness. It is the only honest way to
compare counters and phases across a behaviour change, because the battles themselves evolve
differently once the behaviour differs.

### 8. Benchmark B - the battlefield scaled with the army

The torture test crams every army into the same small field; this family grows the ground
with the army so that density stays at the 500-on-100x60 reference and the numbers describe a
battle rather than a crowd. Same seed, layouts, rules and budget as Step 7.3's run.

| Soldiers | field | density | ms/tick | ticks/sec | ticks | combat ticks | deaths | armies |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 141x85 | 0.0833 | **71.379** | 14 | 169 | 74 | 135 | 6 |
| 2,500 | 224x134 | 0.0833 | **163.447** | 6 | 184 | 163 | 321 | 14 |
| 5,000 | 316x190 | 0.0833 | **452.613** | 2 | 133 | 121 | 319 | 26 |
| 10,000 | 447x268 | 0.0833 | **763.788** | 1 | 80 | 77 | 246 | 50 |
| 20,000 | 633x380 | 0.0833 | **2,572.922** | 0.4 | 24 | 20 | 25 | 100 |

Step 7.3 measured, on the same battles: 145.160, 511.941, 1,182.920, 2,953.324 and
5,852.212 ms a tick - so the realistic family improves by **2.0x, 3.1x, 2.6x, 3.9x and
2.3x**.

**Every size reached sustained contact and fought.** The 20,000-soldier battle measured 24
ticks in its sixty-second window, 20 of them with blows landing and 25 dead. At 2.57 seconds
a tick that is **nowhere near playable, and this milestone does not claim otherwise**: it is
2.3 times cheaper than it was, which is a large engineering step and not a finished
battle. Twenty thousand soldiers remain a goal, not a result.

### 9. What is now the most expensive phase

By phase, ms per tick, clock on, standard budget windows. Family A:

| units | grid | focus | formations | soldiers | of which target | overlap | total |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 500 | 0.731 | 0.665 | 0.652 | 8.808 | **6.428** | 2.067 | 13.607 |
| 2,500 | 3.673 | 3.389 | 3.078 | 59.416 | **45.899** | 20.544 | 93.717 |
| 5,000 | 7.902 | 7.654 | 6.622 | 167.676 | **137.591** | 55.951 | 253.908 |
| 10,000 | 15.925 | 18.025 | 14.882 | 312.539 | **234.591** | 238.681 | 649.560 |
| 20,000 | 33.453 | 37.989 | 34.258 | 359.590 | 163.603 | **995.016** | 1,516.293 |

Family B, which is the family that resembles a battle:

| units | grid | focus | formations | soldiers | of which target | overlap | total |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 1.275 | 1.906 | 1.350 | 19.248 | 15.634 | 4.384 | 29.496 |
| 2,500 | 3.649 | 11.968 | 3.493 | 101.015 | 88.576 | 18.262 | 142.340 |
| 5,000 | 7.301 | 45.314 | 6.980 | 220.460 | 194.212 | 45.765 | 333.558 |
| 10,000 | 15.264 | **188.332** | 14.787 | 423.027 | 366.789 | 105.409 | 762.818 |
| 20,000 | 31.890 | **881.765** | 34.925 | 808.431 | 692.196 | 202.048 | 1,992.731 |

**The next bottleneck is named by the measurement, not chosen in advance: formation focus.**
`_refresh_focus()` gives every body an answer to "where is the fighting" once a tick, by
scanning the enemy army once per body. That is linear in the army and linear in the number of
bodies, and family B has one body per two hundred soldiers - so the cost is quadratic in
(`bodies x army`) and it shows: 1.9 ms at one thousand soldiers, 45.3 at five thousand, 188.3
at ten thousand, **881.8 at twenty thousand - 44% of the tick and the single largest item in
the realistic family.**

It was invisible until this milestone, because target selection was larger. Now that target
selection is four times smaller, the pass that tells soldiers where the battle *is* has
become the most expensive thing in the battle. Any next step that does not start from that
number is guessing.

### 10. Verification

| | |
| --- | --- |
| Headless suites | **19 of 19 reported, 2,732 assertions, 0 failures** (was 2,490 across 18) |
| New suite | `test_target_acquisition` (231) - retention, invalidation by death and by distance, explicit orders, the cadence at every interval, staggered phases, roster-order independence, hysteresis, cell boundaries, the death storm, the provable skip, the counter partition, and determinism of the whole target sequence |
| Benchmark flags added | `--reacquire=`, `--retention=`, `--switch=`, `--immediate=`, `--spikes=`, `--storm=` |
| Two-process restart | **95 checks, 0 failures** - unchanged; no save-format change |
| Windowed smoke | campaign -> settlement -> recruit -> battle -> **formation drill** -> results, zero script errors |
| CI | **green** on the milestone tip - run id, head SHA and the raw job log's suite and assertion counts are in the milestone report |

## Step 7.5 - Formation battlefield focus scaling

Step 7.4's own measurement named the next bottleneck, and this milestone attacked it. It added
**no gameplay**: no projectiles, no cavalry, no morale, no new orders, no changes to how a
soldier fights. Formation focus used to be one pass over the whole army per body per tick; it
is now one summary pass over the bodies, a comparison of bodies against bodies, and a field
read by every soldier.

### 1. The measurement that chose the milestone

Before anything was changed, the focus path was instrumented. At twenty thousand soldiers on
the scaled battlefield - one hundred bodies, which is the realistic case - the counters said:

| | per tick |
| --- | ---: |
| focus evaluations (one per body) | 100.0 |
| whole-army walks (`_nearest_enemy_to_point`) | 109.5 |
| **of those, made on behalf of a single soldier** | **9.5** |
| soldiers walked by those walks | 2,189,412 |
| soldiers answered straight from their body's focus | 12,318.9 |
| focus answers that changed since the previous tick | 36.29 |

The phase cost **760 ms** of a 1,786 ms tick in that run - 43% of it. The arithmetic is exact and
uninteresting - **100 bodies x 20,000 soldiers = 2,000,000 soldier-visits a tick** - but the
second figure is the one worth naming: 9.5 of those walks a tick were made *on behalf of one
soldier*, because a body's answer that died mid-tick was recomputed by whoever noticed. That
work was billed to the target phase, where Step 7.4 had just spent a milestone making things
cheaper. See D-088.

### 2. What changed

- **A transient formation summary.** `BattleFormation` gains `living_count`, `centre`,
  `bounds_min`, `bounds_max` and a version stamp, rebuilt once a tick from the body's own roll
  of soldiers, plus `focus_body_index`/`focus_distance`/`focus_null_tick` for its answer. No
  nodes, no per-soldier objects, nothing in `to_dict()`, nothing in a save.
- **One summary pass over the army, and only when it is needed.** Bodies are counted from
  `unit_ids` - the list that is the authority on membership - and the walk over the whole army
  that collects the unformed soldiers and the side totals runs **only when the number the
  bodies counted does not match the number the battle believes are standing**. A deployed army
  has nobody unformed, so it pays one integer comparison instead of twenty thousand visits.
  That single change was 22 ms of the 55 ms focus phase at twenty thousand soldiers.
- **Formation-level enemy selection.** `_nearest_enemy_via_buckets` opens the candidate body
  whose box is nearest to the asking body's anchor, measures the soldiers inside it, and stops
  as soon as no remaining box could hold a nearer soldier. That stopping rule is a proof, so
  the answer is **the same soldier a full scan would have named** - not an approximation of it.
- **Soldier consumption is a field read.** `_focus_target` reads its body's answer. A body
  whose answer died mid-tick is repaired once, for the body; a body whose answer is "nobody" is
  not asked again inside the tick. `foc_scans_from_soldiers` - whole-army walks made on behalf
  of a soldier - went from 9.5 a tick to **zero**.
- **No retention rule, deliberately.** A body's answer changes 38 times a tick across a hundred
  bodies, and the pass now costs a fraction of what it did, so a hysteresis rule would be new
  behaviour bought with no measurable saving. See D-089.
- **Allocation audited.** Every buffer is sized when the army is handed over and reused; a test
  drives sixty ticks and asserts the focus path's allocation count does not move. See D-091.

### 3. Benchmark A - the fixed-area torture test

Unchanged from Step 7: same seed (70707), dimensions, layouts, rules and budget, so the
comparison holds across four milestones.

The Step 7.4 column is a **probe build**: the tip of Step 7.4 with the Step 7.5 counters added
and nothing else changed, run on this machine with this harness, one run at a time. Both
columns below are saved runs, taken back to back. They were re-taken because an earlier
rehearsal of this table was measured into a temporary file that the machine cleaned up, and a
number that cannot be re-read is not evidence.

| Soldiers | Step 7.4 ms/tick | **Step 7.5 ms/tick** | change | 7.5 ticks/sec | contact |
| ---: | ---: | ---: | ---: | ---: | --- |
| 100 | 1.972 | **2.025** | 0.97x | 494 | yes |
| 500 | 12.527 | **12.808** | 0.98x | 78 | yes |
| 1,000 | 28.832 | **29.659** | 0.97x | 34 | yes |
| 2,500 | 87.389 | **89.383** | 0.98x | 11 | yes |
| 5,000 | 228.245 | **231.812** | 0.98x | 4 | yes |
| 10,000 | 515.099 | **518.008** | 0.99x | 2 | yes |
| 20,000 | 1,073.773 | **1,092.018** | 0.98x | 1 | no |

**Read that change column as "within a few per cent", not as a result in either direction.**
These are wall-clock-budgeted runs: a faster build fits more ticks into the same sixty seconds
and ends its window further into the fight, so the window is different in every row. Three
measurements of the *same* Step 7.4 build on this machine gave 515.1, 541.7 (the figure recorded
when Step 7.4 shipped) and 618.0 ms a tick at ten thousand soldiers - a 20% spread on one row,
which is larger than any change the table is being asked to show. The matched-window table
below is the comparison of record: same tick count, both builds, no budget that can shorten a
slower run's window. The earlier rehearsal of this table reported 1.19x at ten thousand, which
was the fast side of that spread rather than an improvement.

Matched-window runs, twenty ticks each, both builds, so no wall-clock budget can shorten a
slower run's window:

| Soldiers | Step 7.4 ms/tick | **Step 7.5 ms/tick** | change | 7.4 focus ms | **7.5 focus ms** | focus change |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1.576 | **1.682** | 0.94x | 0.143 | **0.196** | 0.73x |
| 500 | 8.354 | **8.782** | 0.95x | 0.667 | **0.843** | 0.79x |
| 1,000 | 18.464 | **19.180** | 0.96x | 1.348 | **1.606** | 0.84x |
| 2,500 | 55.013 | **55.800** | 0.99x | 3.382 | **2.633** | **1.28x** |
| 5,000 | 136.179 | **135.985** | 1.00x | 7.095 | **5.454** | **1.30x** |
| 10,000 | 361.919 | **360.324** | 1.00x | 14.472 | **16.338** | 0.89x |
| 20,000 | 1,094.797 | **1,098.303** | 1.00x | 33.066 | **35.010** | 0.94x |

**The torture test is flat, and that is the honest result.** It was never what this milestone
was for: it crams every army into a 100x60 field, so a side is a *single body of ten thousand*
and formation focus was already a small part of its tick. What the matched runs show is that
the new pass costs about what the old one did there - and the small sizes are 4-6% slower,
because the layer now has a fixed per-tick cost (about 0.1 ms: four bodies' summaries and four
selections) where the old code had nothing to do at all. At 20,000 the two are within 0.3% of
each other. Family B is where the milestone was aimed and where it lands.

### 4. Benchmark B - the battlefield scaled with the army

Same seed, layouts, rules and budget as Step 7.4's run.

| Soldiers | field | density | 7.4 ms/tick | **7.5 ms/tick** | speedup | 7.5 ticks/sec | ticks | contact | combat ticks | deaths | bodies |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| 1,000 | 141x85 | 0.0833 | 28.484 | **26.629** | 1.07x | 38 | 451 | yes | 236 | 328 | 6 |
| 2,500 | 224x134 | 0.0833 | 135.335 | **126.656** | 1.07x | 8 | 238 | yes | 209 | 389 | 14 |
| 5,000 | 316x190 | 0.0833 | 323.154 | **290.426** | 1.11x | 3 | 207 | yes | 193 | 524 | 26 |
| 10,000 | 447x268 | 0.0833 | 1,165.812 | **544.414** | **2.14x** | 2 | 111 | yes | 108 | 386 | 50 |
| 20,000 | 633x380 | 0.0833 | 1,821.832 | **967.866** | **1.88x** | 1 | 62 | yes | 58 | 222 | 100 |

**Every size reached sustained contact and fought.** At the larger sizes the new build fits so
many more ticks into the same budget that the two runs are measuring different windows, which
is why the matched runs below are the ones to read for cost.

Matched-window runs, twenty ticks each, both builds:

| Soldiers | 7.4 ms/tick | **7.5 ms/tick** | speedup | 7.4 focus ms | **7.5 focus ms** | **focus speedup** |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 30.160 | **29.779** | 1.01x | 5.306 | **1.778** | **2.98x** |
| 2,500 | 105.459 | **97.875** | 1.08x | 54.161 | **4.593** | **11.79x** |
| 5,000 | 298.261 | **255.588** | 1.17x | 79.151 | **8.889** | **8.90x** |
| 10,000 | 742.119 | **563.960** | 1.32x | 177.232 | **20.198** | **8.77x** |
| 20,000 | 2,256.538 | **965.486** | **2.34x** | 763.172 | **41.603** | **18.34x** |

The milestone's target was three times better on the focus phase at twenty thousand soldiers.
**Measured, it is 18.3 times better**, and the total simulation cost of that battle is
**2.3 times smaller**. What that means in the units this project does not confuse with
rendering: **twenty thousand soldiers now simulate at about 1.0 ticks a second** - 1,003 ms a
tick in the matched window above, 968 ms in the budgeted one - and that is still nowhere near
playable. Twenty thousand soldiers remain a goal, not a result.

### 5. The focus phase, measured on its own

Family C is a synthetic harness that measures the formation layer against the *number of
bodies* rather than the number of soldiers, with the reference implementation run over the
same state so the two are compared like for like:

| bodies/side | soldiers | summaries | selection | layer total | reference | speedup | boxes/sel | soldiers/sel | agree |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 20 | 400 | 0.389 ms | 0.472 ms | **0.861 ms** | 2.646 ms | 3.1x | 19.0 | 20.0 | yes |
| 50 | 1,000 | 0.992 ms | 2.102 ms | **3.095 ms** | 16.496 ms | 5.3x | 49.0 | 20.0 | yes |
| 100 | 2,000 | 1.974 ms | 11.201 ms | **13.176 ms** | 66.693 ms | 5.1x | 146.0 | 39.6 | yes |
| 200 | 4,000 | 3.978 ms | 54.786 ms | **58.764 ms** | 269.019 ms | 4.6x | 391.1 | 59.4 | yes |
| 400 | 8,000 | 8.045 ms | 234.130 ms | **242.175 ms** | **1,113.566 ms** | **4.6x** | 885.6 | 69.5 | yes |
| 1,000 | 20,000 | 21.126 ms | 2,347.970 ms | **2,369.095 ms** | not measured | - | 3,678.1 | 128.7 | not measured |
| 2,000 | 40,000 | 42.556 ms | 39,485.791 ms | **39,528.347 ms** | not measured | - | 31,104.4 | 612.3 | not measured |

**Where comparing bodies against bodies stops being acceptable: somewhere past two hundred
bodies a side.** The selection is quadratic in bodies - each body compares itself against the
others - so 400 bodies a side costs 234 ms and 1,000 costs 2.3 seconds. A real battle fields
**fifty a side**. The 400-body row is the last one the harness pays for the reference
implementation on, and it is the row that gives "not affordable" a number: **one pass over the
army per body costs 1.11 seconds a tick at 400 bodies a side**, against 242 ms for the whole
layer. Above that it is reported as not measured rather than estimated: at 1,000 bodies a side
it is eighty million soldier-visits a pass, which is exactly why it was replaced.

This is the honest answer to "should there be a formation-level spatial index": not yet, and
the curve says when. If a future milestone fields five hundred bodies a side, the index becomes
worth its complexity; at a hundred it would be a structure, an invariant and a constant bought
to make a 0.4% share of the tick smaller.

### 6. What is now the most expensive phase

By phase, ms per tick, matched twenty-tick windows, clock on:

| units | grid | focus | formations | soldiers | of which target | overlap | accounted | total |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 1.463 | **1.778** | 1.244 | 20.468 | **17.090** | 5.205 | 30.158 | 31.496 |
| 2,500 | 3.668 | **4.593** | 3.200 | 71.530 | **61.741** | 17.250 | 100.241 | 103.709 |
| 5,000 | 7.193 | **8.889** | 6.442 | 192.063 | **169.444** | 43.602 | 258.189 | 265.243 |
| 10,000 | 14.684 | **20.198** | 13.739 | 421.682 | **371.642** | 100.659 | 570.961 | 585.676 |
| 20,000 | 30.682 | **41.603** | 32.100 | 677.963 | **575.052** | 190.307 | 972.654 | 1,003.413 |

**The next bottleneck is named by the measurement rather than chosen in advance: automatic
soldier target acquisition**, at 575.1 ms of a 1,003.4 ms tick at twenty thousand soldiers -
57% of it, and 85% of the soldier loop. Step 7.4 made looking cheaper and less frequent; the
looks that remain are the expensive ones, because they are the soldiers with nobody near them
widening their search. Formation focus, which was 43% of that same tick a milestone ago (44%
in the Step 7.4 report's own window), is now **4.1%**. See the entry in Known limitations.

### 7. Spikes

Every tick was sampled rather than averaged, on both the total and the phase this milestone
touched. At twenty thousand soldiers, milliseconds:

| phase | average | p50 | p95 | p99 | worst | worst/average |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **total (7.5)** | 984.066 | 960.628 | 1,108.113 | 1,113.522 | 1,113.522 | **1.13x** |
| **total (7.4)** | 1,759.026 | 1,660.225 | 2,135.630 | 2,207.572 | 2,207.572 | 1.26x |
| **focus (7.5)** | 41.603 | 41.479 | 43.694 | 43.863 | 43.863 | **1.05x** |
| target (7.5) | 575.052 | 551.723 | 678.228 | 681.844 | 681.844 | 1.19x |
| overlap (7.5) | 190.307 | 189.882 | 193.234 | 198.055 | 198.055 | 1.04x |

**A formation dying does not create a synchronised spike**, which was the risk of moving the
work to the formation layer: the focus phase's 99th percentile is 5% above its average, and the
counters say why - 136 repairs across the whole twenty-tick window at twenty thousand soldiers,
each one a bounded selection for one body rather than a search per soldier. The total's tail is
also healthier than Step 7.4's (1.13x against 1.26x).

### 8. What the focus path actually did

| Soldiers | bodies | evals/tick | **whole-army walks/tick** | **of those, per soldier** | soldiers walked/tick | soldiers answered/tick | repairs | changes/tick |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 6 | 6.0 | **0.0** | **0.0** | **0** | 78.0 | 0 | 0.90 |
| 2,500 | 14 | 14.0 | **0.0** | **0.0** | **0** | 320.6 | 0 | 3.80 |
| 5,000 | 26 | 26.0 | **0.0** | **0.0** | **0** | 1,425.8 | 29 | 10.20 |
| 10,000 | 50 | 50.0 | **0.0** | **0.0** | **0** | 4,630.1 | 80 | 21.70 |
| 20,000 | 100 | 100.0 | **0.0** | **0.0** | **0** | 12,356.4 | 136 | 38.85 |

One evaluation per body per tick, **no whole-army walks anywhere**, and none at all on behalf
of a soldier - against 109.5 walks and 2,189,412 soldier-visits a tick before. The counter the
brief asked for by name reads zero in every battle the suite drives.

### 9. Verification

| | |
| --- | --- |
| Headless suites | **20 of 20 reported, 2,831 assertions, 0 failures** (was 2,732 across 19) |
| New suite | `test_formation_focus` (99) - the equivalence of the bounded selection against a full scan in live battles, summaries after movement and after casualties, membership changes through the Step 7.1 APIs, an empty body holding no focus, deterministic tie-breaking, the pass running once per body per tick, zero soldier-originated scans, the repair path, the wiped-out case, the allocation audit, determinism, and explicit orders staying authoritative |
| Two-process restart | **95 checks + 6 checks, 0 failures** - unchanged; no save-format change |
| Windowed smoke | campaign -> settlement -> recruit -> battle -> **formation drill (3 bodies, 0 inconsistencies)** -> contact -> DEFEAT -> results, no script errors. Step 7.4's build was run the same way for comparison: identical outcome, identical log shape |
| CI | **green on the milestone tip `266d1b46`** - [run 34768187866](https://github.com/JAYST3AM/project-banner/actions/runs/34768187866) - and **green again on this documentation tip `5f02e11`** - [run 34768473517](https://github.com/JAYST3AM/project-banner/actions/runs/34768473517). Both runs of job *Headless suites and restart check* read `completed` / `success`, and the raw logs both say `suites: 20 of 20 reported   assertions: 2831   failures: 0`, `RESULT: PASS`, `persistence write: PASS (6 checks, 0 failures)`, `persistence verify: PASS (95 checks, 0 failures)` on `4.7.2.stable` |
| Leak check | 110 leaked objects found and fixed during development (a formation must not hold a reference to a soldier); the suite now exits with no `ObjectDB` leak warning |

## Known limitations

The honest list. None of these blocks the checkpoint; all of them are the natural
next work.

1. **Terrain affects movement and nothing else.** There is cover, elevation and a slope
   query, but no combat modifier, no obstacles, no line of sight and no ammunition.
   `terrain.generation_version` exists so a change to generation is deliberate.
2. **Formations exist as shapes, not yet as fighting styles.** LINE, COLUMN and LOOSE
   are geometry and movement; a formation's shape does not yet change how it fights. No
   shield wall, no phalanx, no bracing, no facing-dependent defence, no flank or rear
   bonus, no cavalry. Cohesion is measured and queryable but nothing consumes it.
3. **A stalled battle is resolved by pressing forward, not by pursuit.** A broken enemy
   does not rout and is not run down; the survivors are simply killed where they stand.
   Morale and fleeing will change this.
4. **No morale or fleeing.** A unit fights to its last hit point. `morale` is
   tracked and displayed but does not affect behaviour yet.
5. **Losing the whole party is not a game over.** The campaign continues with an
   empty party; you can walk back to a town and recruit again. Prisoners, capture
   and ransom are future work.
6. **Wounded soldiers do not exist.** Survivors return at whatever hit points they
   ended with. No treatment, no recovery time.
7. **Loot is sold immediately** for coin, because there is no inventory.
8. Trait `attack_pct` and `move_speed_pct` are applied when a battle unit is built;
   `morale` and `loyalty` have no mechanical effect beyond display.
9. **Only bandit parties exist.** Caravans, patrols and lord armies have the data
   model (`WorldParty`, `Party.kind`) but no spawn data or behaviour.
10. **No ambushes yet.** `BattleContext` supports them (`build_context(party, false)`
    flips attacker and defender) but nothing calls it that way.
11. Ammunition is unlimited and there are no projectiles; ranged hits apply
    immediately with a floating damage number.
12. Only the single default save slot is used. Multi-slot UI is not built.
13. `Settlement.market` and `Soldier.equipment` remain empty placeholders.
14. **No artwork.** The world map and battlefields are drawn procedurally. Terrain is
    flat-coloured cells and formations are debug markers.
15. No export templates installed - the project runs from source only.
16. Balance is deliberately rough. Fights work and are decisive; they have not been
    tuned for a long campaign, and the formation path has never been balance-measured
    the way the unformed path has.
17. ~~**Target selection is the most expensive phase.**~~ **Step 7.4 closed this in the
    way Step 7.3 suggested: by making soldiers look less often rather than by making the
    look cheaper.** Every soldier no longer searches every tick, so target selection is
    **3.5x cheaper** at the sizes where both builds were measured at the same window, and
    ten thousand soldiers now reach contact inside the same benchmark budget where Step 7.3
    ran out of it mid-march. What remains is stated in the entry below rather than claimed
    as solved.
18. ~~**Target selection is the largest phase.**~~ **Step 7.5 closed this in the way the
    measurement suggested: by making the phase above it cheap.** Formation focus was 43% of
    the realistic twenty-thousand-soldier tick and is now **4.1%** of it, which promotes target
    acquisition to the top of the profile at **575.1 ms of 1,003.4 ms**. It is not solved,
    only named. The cadence is a floor, not a solution: soldiers still look once every four
    ticks, and a soldier's look is still a spatial query over an escalating radius. Further
    reductions want a cheaper answer to "is anybody near me" rather than a cheaper schedule -
    which is a design question, not a tuning one, and it is the next milestone's question.
19. **The formation layer compares bodies against bodies, which is quadratic in bodies.** At
    fifty bodies a side - a real battle - the whole layer is a few milliseconds a tick. The
    synthetic family C harness puts the first uncomfortable figure at **400 bodies a side
    (233 ms a tick)** and impossibility at 1,000 (2.3 seconds). A formation-level spatial
    index is not built because nothing in the game is within an order of magnitude of needing
    one, and the curve in the Step 7.5 section says exactly where that changes.
20. **There is no retention rule on formation focus.** A body's answer is recomputed every
    tick, exactly as it was before this milestone, and changes 38 times a tick across a hundred
    bodies as soldiers jostle within the enemy line. A hysteresis rule was considered and
    declined: the pass is now cheap enough that the change would buy no measurable saving, and
    a rule about when a body changes its mind is a tactical change rather than a scaling one.
    See D-089.
21. **The fixed-area torture test pays about 0.1 ms a tick for the layer, and is 4-6% slower
    at a hundred to a thousand soldiers because of it.** That benchmark fields four bodies, so
    it had almost no formation-focus work to remove and now carries the fixed cost of
    summaries and selections that a deployed army needs. At 20,000 soldiers the two builds are
    within 0.3% of each other, and on the realistic family every size improved.
22. **The awareness cadence is a behaviour change, and it is a deliberate one.** A soldier
    faces the enemy it was dealing with rather than re-deriving the nearest one every tick,
    switches only when a new candidate is a quarter closer, and can be up to three ticks
    (150 ms) late to notice an enemy that has arrived. All three are documented in D-085 and
    covered by tests; they are listed here because "the battle got cheaper" is not the whole
    story of a milestone that changed when soldiers think.
23. **The fixed-area benchmark stops being a battle past a few hundred soldiers.** It
    crams every army into the same 100x60 field, so at twenty thousand the soldiers do not
    fit in it dressed and the measurement describes a crowd. It is kept because it is a
    useful torture test and because it is the only way to compare against earlier
    milestones; the scaled family is where a real twenty-thousand-soldier battle is
    measured. Both say whether contact was reached.
24. **Rendering is not in any of these measurements.** Both benchmark families step the
    simulation directly. Drawing twenty thousand soldiers on a 633x380 battlefield is a
    separate problem the large-battle milestone will also have to pay for, and nothing
    here claims otherwise.

## Recommended next milestone

The brief lists what comes after the checkpoint. In the order that builds most
directly on what already exists:

1. **Battlefield terrain and formations** - `terrain_seed` is already carried; this
   is the largest single improvement to how a fight *feels*.
2. **Ranged weapons and projectiles**, then cavalry and the spear's anti-cavalry
   role. The unit archetypes already carry `ranged`, `attack_range` and a reserved
   `upgrade_to`.
3. **Soldier depth** - equipment, wound recovery, and traits that do something
   mechanical. `Soldier.equipment` and the trait modifiers are already in place.
4. **Surfacing personal history** - the records exist and are already written; they
   need to be shown back to the player (a "so-and-so survived Greywatch" notice, a
   memorial for the fallen).
5. **Overworld life** - caravans, trade, settlement production.

---

## Step 7.6 - Automatic target search cost scaling

Step 7.5's own measurement named the next bottleneck, and this milestone attacked it. It
finished by leaving the search exactly as it was, and the reason is a measurement rather than a
preference: **every cheaper search that was written measured slower than the one already in
place.** Five exact re-implementations were built and benchmarked, in a micro-benchmark written
for the purpose and in live battles. What ships is the instrumentation that established that,
and no behavioural change at all.

### Where the target phase actually goes

Counted before anything was changed - a development counter per sub-phase, all of it behind the
profile flag - at twenty thousand soldiers on the scaled battlefield, in the matched twenty-tick
window the before-and-after comparison uses:

| component | ms/tick | share of the phase |
| --- | ---: | ---: |
| the spatial query | 516.8 | **85.7%** |
| answering with the formation (the focus path) | 19.8 | 3.3% |
| deciding whether a remembered opponent is worth keeping | 19.1 | 3.2% |
| deciding whether a look is worth making (the D-087 proof) | 7.8 | 1.3% |
| hysteresis and storing the answer | 2.6 | 0.4% |
| the rest of the target loop | 36.6 | 6.1% |
| **the target phase** | **602.7** | 100% |

Three runs measure the same split with the same shape: this window puts 85.7% of 602.7 ms in the
query, the Phase-1 sweep (about two hundred ticks) puts 86.1% of 601.3 ms, and a thirty-tick
window 85.2% of 598.5 ms.
The window is quoted with each figure because the phase wanders 1-4% between them, and the ratio
does not - which is the point of counting it.

### What one look costs

| | 5,000 soldiers | 10,000 | 20,000 |
| --- | ---: | ---: | ---: |
| looks per tick | 993.7 | 1,825.5 | 2,449.8 |
| grid queries per look | 1.79 | 1.68 | 1.71 |
| cells read per look | 232.4 | 233.2 | 242.5 |
| of those, ground walked twice by one look | 19.5 (8.4%) | 19.5 (8.4%) | 20.4 (8.4%) |
| candidates measured per look | 139.0 | 156.4 | 174.2 |
| looks answered by the first radius | 32.6% | 32.3% | 29.2% |
| looks answered after widening | 44.8% | 39.8% | 41.4% |
| looks that found nobody at all | 22.6% | 27.9% | 29.4% |

One table, one run: the numbers above are the matched twenty-tick window on the scaled
battlefield, the same run the rest of this milestone's figures come from. The Phase-1 sweep -
about two hundred ticks over the same battles - draws the same picture within a few percent: 1.77
queries, 260 cells, 171 candidates per look, and the same 8.4% of cells walked twice by one look.

A look is asked only on cadence, and **half of the looks a cadence of four implies never
happen**: 2,438 a tick against 5,000, the other 2,562 already answered - a retained opponent
still in reach, or the formation's answer, or the D-087 proof that the search would find nobody.
The log's own decomposition of the 17,486 avoided looks is 2,662 + 3,363 + 11,461 across those
three, and it settles what this phase is: not how many questions are asked, but **what one
question costs** - a second-rung rectangle walk of 289 cells handing over 171 candidates to keep
one.

### The five searches that were tried, and what they measured

Each was designed to inspect less than the ladder and stop as soon as no unopened cell could
hold a better answer. Each is exact - the micro-benchmark checks the answer against the ladder's
on every query point and reports disagreements, and reported none.

| implementation | shape | live battle, 20K target phase |
| --- | --- | ---: |
| Chebyshev ring walk | cells opened ring by ring outward from the soldier | **2.64x** |
| row walk, index order | rectangle pass with per-row reach windows | **3.20x** |
| row walk, nearest rows first | the same, rows and columns outward from the soldier | **2.82x** |
| rectangle walk with a cell bound | one distance test per cell before its bucket | not run in battle |
| block-indexed walk | a coarse 4x4-cell side mask walked before the cells | **3.73x** |

These are battle figures, quoted against one saved reference run, and they are the ones the
milestone decided on. The benchmark was used to isolate *why* the shipped look is cheap rather
than to score each candidate: the in-grid method kept one name through every rewrite, so no saved
log attributes a benchmark figure to a named candidate, and the per-candidate ratios in the
working notes came from console runs that were not kept. What the saved benchmark logs hold is
the shipped path and its isolates - the whole look at 46-64 us, a radius-32 box with no list at
226-235, one box of the new walk at 277-308, and the ladder's second rung collected and scanned
flat at 314-344.

The battle column is quoted against one reference - the ladder's 621.1 ms target phase at twenty
thousand soldiers, same session, same build, matched windows - and a second ladder run that
session measured 598.5 ms, so any row could be quoted 3-4% higher with the other reference. The
benchmark column spans a range where two placements were measured, because a uniform scatter
flatters a pruning walk and packed ranks are what a battle looks like.

Every one of them inspects *fewer* cells and fewer candidates than the ladder - the best of them
read 122 cells and measured 45 candidates per look against the ladder's 260 and 171 - and every
one of them is slower, by more in a real battle than in the micro-benchmark: a benchmark times
one query against a warm index, a battle times two and a half thousand a tick against an index
that is rebuilt every tick.

**The isolation run, which is where the milestone's conclusion actually comes from.** One
radius-32 box, asked about every query point on a twenty-thousand-soldier field at realistic
packing:

| implementation of the same single query | time |
| --- | ---: |
| the locked path - `collect_within` plus the flat nearest loop over the list it built | 344.5 us |
| the new walk - one rectangle pass keeping the best as it goes, no list at all | 306.8 us |
| the whole locked *look*, which is that same box preceded by a radius-8 one | **63.2 us** |

Two different walks of the same ground, within 12% of each other - and the full ladder, the same
outer box plus a small inner one, is **five times cheaper than either**, because nine looks in
ten are answered by the inner box and the outer one is never walked. So the box is the cost, not
the way the box is walked, and no traversal that still walks it can win. (Those standalone-box
figures ask the box about every point, including contact-zone points where it holds nearly six
hundred candidates; they compare two implementations of one query, which is what the isolation
was for, and they are not the ladder's second-rung population.)

In an interpreted loop a bound test costs about 0.3 us and
the empty cell it skips costs about 0.12 us to open and dismiss, so pruning inside the loop
cannot pay for itself. The ladder is cheap because its *first* rung is small and answers most
looks before the second rung is reached, not because of how it walks.

### What ships

- **The search itself: nothing.** Unchanged since Step 7.5, and that is the milestone's decision
  rather than an omission. The block-indexed attempt went with the block-level mask it needed -
  an addition on top of the per-cell side mask the grid has carried since Step 7.2, which stays.
  Removing that per-cell mask was measured rather than assumed, because a revert can leave a
  load-bearing line looking like a leftover: without it the realistic 20K target phase goes from
  **602.7 to 2,776.3 ms/tick** and the torture family's total from 1,138.6 to 3,349.0 ms. It
  costs 4.9 ms/tick in the rebuild and saves 2.16 s/tick in the query - four hundred times over.
  The removal was reverted and the tree restored to the locked shape; see D-094.
- **Search-shape counters** on the grid and the simulator: queries per look, cells read and
  cells walked twice, candidates split by rung, escalations, the distance an answer was found
  at, and exact per-search percentiles from one sample per search. Development-only.
- **Per-sub-phase timings** for the whole target loop, so the split above can be re-measured by
  anyone rather than believed.
- **`scripts/dev/search_bench.gd`**, a micro-benchmark that answers "what does one query cost"
  in seconds instead of "what does one tick cost" in two minutes, with the two box measurements
  that outlived the milestone in it.

### Result

The phase is unchanged, and it was measured rather than assumed. The realistic benchmark was run
matched - same tick count, both builds, one after the other in the same session - with the
locked tip checked out beside this one:

| soldiers | Step 7.5 | Step 7.6 | change |
| ---: | ---: | ---: | ---: |
| 1,000 | 30.024 ms | 30.277 ms | +0.8% |
| 2,500 | 100.329 ms | 100.257 ms | -0.1% |
| 5,000 | 262.319 ms | 264.932 ms | +1.0% |
| 10,000 | 582.194 ms | 583.738 ms | +0.3% |
| 20,000 | 991.379 ms | 995.693 ms | +0.4% |

Everything inside a percent, which is the run-to-run spread of this machine; the combat ticks
and casualty counts are identical, so it is the same battle. Both figures also sit about 2-3%
above the numbers recorded when Step 7.5 shipped, which is the drift between sessions rather
than anything in either build - and it is why the comparison above was taken back to back
rather than against the log from last time.

At twenty thousand soldiers the target phase is **602.7 ms/tick** profiled, **516.8 ms** of it
inside the spatial query, the simulation ~1,044 ms/tick profiled and ~996 ms/tick with the clock
off, and the next bottleneck is the same one this milestone was scoped to remove: the second
rung of the search. `STEP 7.6 CANDIDATE: NO` - the scoped reduction was not
achieved, and the measurement that says why is the deliverable. See D-094.

## Step 7.7 - Native spatial query feasibility spike

The target search's spatial kernel moved into a GDExtension - but only after the boundary was
measured twice, because the boundary turned out to be the question. Both measurements are
matched twenty-tick windows on the scaled, realistic battlefield, reference and accelerator
taken back to back in one session.

### The two boundary shapes, measured

| shape | what crosses the boundary | 20,000 soldiers: target phase | total |
| --- | --- | ---: | ---: |
| A - broadphase only | ~170 candidate slots per look | 591.27 -> 546.16 ms/tick | 996.65 -> 954.51 ms/tick (**1.04x**) |
| B - broadphase + exact test | one slot per search | 591.48 -> **99.49** ms/tick (**5.94x**) | 1,004.88 -> **525.51** ms/tick (**1.91x**) |

Shape B at every size, same windows: 1,000 soldiers 31.66 -> 18.33 ms/tick (**1.73x**), 2,500
105.20 -> 52.71 (**2.00x**), 5,000 270.40 -> 122.92 (**2.20x**), 10,000 591.73 -> 268.95
(**2.20x**). Ordinary battles do not pay for the stress case: every size is faster.

### What the sync costs, and what it buys

The spatial rebuild gets *more* expensive, not less - 35.02 -> 44.31 ms/tick at 20K - because a
tick now pushes its snapshot and mirrors its movements across the boundary. That is ~9 ms a tick
bought to remove ~490 ms of GDScript candidate scanning, and it is the trade the decision rests
on. In the 20K accelerated battle: 83,669 queries and 29.9 million candidates answered with **0
disagreements**.

### Family A - the fixed-area torture field

Matched twenty-tick windows, total ms/tick, reference -> shape B: 100 soldiers 1.82 -> 1.89
(**0.96x**), 500 9.36 -> 9.88 (**0.95x**), 1,000 32.38 -> 18.44 (1.76x), 2,500 105.70 -> 53.04
(1.99x), 5,000 276.47 -> 124.50 (2.22x), 10,000 616.74 -> 271.28 (2.27x), 20,000 1,028.87 ->
527.50 (1.95x). Below about a thousand soldiers the accelerator loses a few percent - the
snapshot and the mirror are paid for a search that costs almost nothing - so a battle picks its
backend once, before the first tick, from the size of the army it is about to run
(`BattleSimulator.TARGET_NATIVE_MIN_UNITS`, 1,000, which is where the measurement changes sign).
The two implementations agree on every answer either side of it; only who answers changes.

### Spikes at 20,000 soldiers (avg / p50 / p95 / p99 / worst, ms)

| phase | reference | shape B |
| --- | --- | --- |
| total | 1033.5 / 1004.3 / 1156.1 / 1157.8 / **1157.8** | 537.8 / 530.5 / 571.3 / 598.8 / **598.8** |
| target | 604.6 / 581.5 / 705.8 / 710.0 / **710.0** | 100.4 / 97.2 / 109.9 / 115.6 / **115.6** |
| grid | 35.2 / 35.2 / 35.8 / 36.0 / 36.0 | 44.3 / 44.0 / 44.9 / 48.3 / 48.3 |

No spike was introduced: the accelerated distribution is *tighter* relative to its average than
the reference's (tail-to-average 1.11x against 1.12x), and the worst tick falls from 1,157.8 to
598.8 ms.

### Fidelity, and how it is proven rather than asserted

`Backend.COMPARE_FULL` runs both implementations on the same rung of the same ladder and records
the first disagreement with the tick, the asking soldier, the radius and both answers.
`tests/test_native_query.gd` (1,261 assertions) compares candidate sets over generated layouts and
boundary cases, checks deaths and movement after the snapshot, runs a battle in compare mode and
runs whole battles both ways - the accelerated battle must reproduce the reference's survivors,
health, positions and targets unit by unit. It caught two real defects before any benchmark
quoted a number: a radius that silently included `query_margin` (a live battle at tick 15), and a
counter call that threw once per query while profiling (35x of error handling, not of kernel).

### What is native, and what is not

Native: the cell index from a per-tick snapshot, the walk, the side and liveness filters, the
exact squared-distance test, the tie-break. GDScript: the ladder's staging and ceiling, the
D-087 proof, retained opponents, hysteresis, cadence, explicit orders, formation focus, the query
margin, backend selection, and everything else in the simulation. The locked walk remains as
`BattleSpatialGrid._collect_reference` - reference, oracle and fallback - and runs in every
suite.

### Limits, stated plainly

20,000 soldiers at ~525 ms/tick is **~1.9 simulation ticks a second: not playable**, and it is
still an engineering stress target rather than a normal army size. None of these figures include
rendering and none of them are FPS. The accelerator's correctness is conditional on the mirror
being complete: the battle mirrors exactly two mutation points (movement and death), the suite
asserts the current count, and a new mutation point upstream is the one change that could break
it quietly.


## Step 7.8 - separation-pass optimisation

**What it is.** Steps 7.2-7.6 removed the quadratic loops and the repeated work from the battle
tick, and the first Step 7.8 pass measured what was left: the separation pass (the one that keeps
soldiers from standing inside each other) was the **largest single phase** - ~200.6 ms/tick at
20,000 soldiers on a realistic field, in a ~571.6 ms/tick instrumented total. That pass stopped
at measurement on purpose. This one fixes two profiler counters an audit found wrong, establishes
why the pass's own optimisation never fires, splits the phase's own cost, and then moves the pass
itself: onto packed GDScript arrays first, then - behind a measured threshold - into the native
accelerator as **shape C**, where the kernel performs the entire pass and returns one displacement
per soldier per axis.

**Realistic density (family B), matched 200-tick windows, no budget, one machine, seed 70707.**

| units | reference overlap | packed overlap | native overlap | native whole tick | native speedup |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 6.215 ms | 4.266 ms | **1.731 ms** | 15.926 ms (from 20.460) | 3.59x |
| 2,500 | 20.615 ms | 11.685 ms | **4.850 ms** | 47.922 ms (from 63.818) | 4.25x |
| 5,000 | 52.572 ms | 24.729 ms | **10.330 ms** | 106.529 ms (from 149.249) | 5.09x |
| 10,000 | 122.489 ms | 51.704 ms | **21.280 ms** | 226.003 ms (from 328.427) | 5.76x |
| 20,000 | 237.990 ms | 103.282 ms | **42.686 ms** | 454.725 ms (from 650.507) | 5.58x |

**The 20,000-soldier result, in the terms the milestone was set in:** overlap 200.6 -> **42.7
ms/tick** (the "strong" target was 65), whole tick 650.5 -> **454.7 ms/tick** measured in the same
window on the same machine (the historical 571.6 figure was a different window and is not
comparable), and the next-largest phase is now the per-soldier update loop at 246.6 ms/tick, of
which target selection is 106.2 ms.

**The exact pair work, measured rather than apportioned.** Three passes over one frozen field -
the real pass, the same pass without the push arithmetic, and the same without the distance test
either - give the phase's decomposition at 20,000 soldiers: rebuild 43.4 ms, same-cell traversal
18.6 ms, neighbour-cell traversal 154.8 ms, apply/clamp 9.0 ms, total ~231.6 ms; of which the
squared-distance test for every enumerated pair is ~85-103 ms and the push arithmetic for the
touching pairs is ~2-19 ms (a difference of differences, so the noisy end of the range).

**Why the settled-cell skip never fires (Step 7.3's one optimisation).** Counted over every tick of
a realistic battle rather than read off the last one: **95.3-98.2%** of the cell pairs that reach
the proof are rejected because at least one of the two cells holds a soldier who is not standing
on his assigned place. Soldiers are settled for ~4.8% of a 5,000-soldier battle's ticks and ~8.5%
of a 20,000-soldier one - the dressing and approach phases - and the skip does fire there. It is
not broken: it is exact, it is cheap, and a real fight simply has no settled soldiers in it. The
proof was left alone (D-097).

**Equivalence, not tolerance.** 1,500 generated states (sparse, dense, clustered, cell-boundary,
corner, edge, coincident, one body, two friendly bodies, enemies, loose, settled, unsettled, dead,
crossing) plus the named boundary arrangements are run through the packed pass and 600 of them
through the native pass, and compared against the locked reference **position for position and
counter for counter**; a 300-tick battle is fingerprinted under each pass. Zero disagreements,
zero drift, no tolerance to argue about - the candidates are the same arithmetic on the same
numbers (D-098, D-099).

**What did not change.** Every soldier is still simulated and every touching pair is still
resolved: no distance lowered, no pair skipped, no contact disabled, no targeting touched. The
300 v 300 showcase run on this build is the visual evidence - and it also documents a stalemate
the formation layer reaches at that scale, which reproduces identically on the pre-7.8 build and
is a finding rather than a regression (D-100).
## Step 7.8 (formation-driven engagement) - the hierarchy performs the searching

*(The brief that commissioned this work called it "Step 7.8 - formation-driven engagement / contact-zone
targeting". Step 7.8 in this repository is the locked separation-pass milestone, so the work is
recorded here as its own milestone and the locked history was not touched.)*

**What it is.** A spike that asked whether a large body of soldiers should stop asking the
battlefield a strategic question - *which individual enemy should I attack* - while its formation
already knows the strategic answer: *that body, ahead of us*. The answer, measured: yes, and the
saving is large. A soldier is now asked to look for an opponent of its own only when the fight
could actually be his: within a weapon's reach of an enemy body close enough to matter, having
just been struck, under an explicit order, or owing no body at all.

**The rule, in one paragraph.** Each tick, on a cadence of ten ticks, a body works out which enemy
body it is fighting - nearest by box distance, with the same switch-hysteresis a soldier's own
target gets, and an explicit order overriding it outright. From the two bodies' reaches it derives
a *contact band*, and its soldiers are allowed to search only inside that band, measured from the
soldier to the enemy body's box - a box distance rather than a frontage test, because a formation
can be taken on a flank or from behind. A soldier that has just been hit strikes back at whoever
hit it, which costs one index probe and no search at all. Everything is derived from geometry the
battle already computes: no new query, no scan, and the whole body pass costs **0.02 ms a tick at
six hundred soldiers**.

**Measured, in one build, on the same seed** (the layer is switchable off with
`battle.engagement_enabled` or `PB_ENGAGEMENT=off`, which puts the architecture this milestone
replaced back tick for tick):

| battle | searches with the hierarchy | without it | soldiers in individual mode | total ms/tick on -> off |
| --- | ---: | ---: | ---: | ---: |
| 300 v 300 showcase, 900 ticks | 20,783 | 99,174 | 168 of 566 (29.7%) | - |
| 500 v 500 showcase, 900 ticks | **17,112** | 169,738 | 143 of 962 (14.9%) | - |
| far apart | 0.0 a tick | 150.0 a tick | 0% | 11.67 -> 11.67 |
| approach | 0.0 a tick | 150.0 a tick | 0% | 11.81 -> 12.14 |
| partial contact | 2.8 a tick | 149.7 a tick | 21.0% | 11.73 -> 16.26 |
| full contact | 20.9 a tick | 144.0 a tick | 23.9% | 11.54 -> 18.45 |
| flank (two bodies on two sides) | 45.6 a tick | 123.5 a tick | 54.7% | 12.72 -> 17.41 |
| split during a fight | 18.1 a tick | 145.5 a tick | 31.8% | 11.97 -> 21.61 |

**It is not an optimisation that makes soldiers stupid.** The scenarios above run the same battles
to the same conclusions with and without the layer - 40 casualties against 43 at full contact, 103
against 103 in the flank case, 27 against 23 in the split case - and the suite pins the safety
property directly: over a whole battle, **every soldier whose look the hierarchy refused is checked
against every enemy on the field, and not one of them could have struck anybody**. Nor is a
soldier blind to being hit: the blow is recorded, and the man who took it strikes back without
being asked to look.

**Dynamic formations came with it.** A body is a roll of soldier ids plus the geometry that places
them, so `split_formation()` and `merge_formations()` are membership edits through the existing
`assign_formation` - no battlefield rebuild, **0.27 ms a split at six thousand soldiers and under
1 ms at six hundred**, with soldier ids, health, kills and history preserved and no soldier created,
destroyed, duplicated or lost (asserted across two thousand randomized transitions). Every living
soldier is in at most one body by construction, and `check_membership_invariants()` proves it
afterwards rather than trusting it.

**See also:** D-105 (the rule and its numbers), D-106 (split, merge and the ownership invariants),
and the engagement benchmark at `scenes/dev/engagement_bench.tscn`. Verified by 25 suites and 8,785
assertions with the native kernel required, persistence write 6/0 and verify 95/0, and CI run
`35013999526` on `38d794198bacb152c0f655b3bb7119dd32986c4c`.

## Step 7.8B - large-battle stalemate hardening


**What it is.** Step 7.8's showcase found that a formed 300 v 300 battle froze at half casualties
(D-100): 302 dead, 298 standing, nobody within reach of anybody, and no further casualties for as
long as the battle was allowed to run. This step reproduces that headlessly, measures it tick by
tick, fixes it at the formation layer, and proves the battle now fights to a decision - on eleven
seeds, headless and windowed.

**One battle, three callers.** The deployment the showcase has always used now lives in one place,
`scripts/dev/showcase_battle.gd`, and it prints a setup checksum. The windowed showcase, the
headless probe and the regression test all open that same battle, and all three report
`600:f8a81f4d` for six hundred soldiers - so the run that is watched and the run that is measured
cannot drift apart.

**The reproduction.** `scenes/dev/battle_stalemate_probe.tscn` drives the production simulator with
a fixed step and writes a timeline plus a per-soldier dump of the frozen state. On seed 780780 the
pre-fix build froze at **tick 9000 (450 s of battle)**: 153 v 145 standing, **0 of 298 soldiers
inside any reach**, nearest hostile **2.556 units**, no blow struck for **15,616 ticks (781 s)**
while both armies lived, and **zero** further casualties in the remaining 750 seconds of the run.

| at the freeze (seed 780780, pre-fix) | player_centre | player_left | player_right | enemy_centre | enemy_left | enemy_right |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| living | 47 | 55 | 51 | 52 | 45 | 48 |
| state reported | moving | moving | moving | moving | moving | moving |
| in contact | no | no | no | no | no | no |
| cohesion | 0.99 | 0.99 | 0.99 | 0.99 | 0.99 | 0.99 |
| mean distance from its own slot | 0.06 | 0.07 | 0.07 | 0.07 | 0.07 | 0.07 |
| distance to the enemy's centre | 0.050 | 0.050 | 0.050 | 0.050 | 0.050 | 0.050 |
| nearest living enemy | 2.61 | 2.56 | 2.60 | 2.61 | 2.56 | 2.60 |

**The mechanism, measured rather than guessed.** Two defects, nested.

1. **A body with nobody in contact steered at the enemy's *anchor*.** That rule (D-056) was written
   to let a wing that had not arrived keep closing, and what it actually did was drive the two
   centres onto one another: measured, they ended **0.050003 units apart**. With the centres
   together the two bodies' surviving ranks land on one lattice - and because both armies are laid
   out on the same file spacing, those ranks are exactly one spacing apart in the closing axis.
   Slot spacing is 2.6 units and melee reach is 2.4, so the two masses slid through each other
   without a single soldier ever being in reach, which is why `in_contact` was false everywhere
   while 298 men stood in the same 23-unit box.
2. **The body then could not stop, so it could not let anybody move.** The centre was 0.050003
   units from its station - `ENGAGE_EPSILON` (0.05) plus 3.05e-6 - and the step needed to close
   that gap is finer than a single-precision `Vector2` can express at a coordinate of 104, so
   `advance()` computed a movement, applied it, and changed nothing. `is_moving()` therefore
   reported `moving` for the rest of the battle, and `is_moving()` is one of the conditions on the
   press-forward rule - the one mechanism that could have restarted the fight. Before the fix,
   press-forward never fired once in a 300 v 300: its count was zero in every sample of a
   24,000-tick run.

**The fix: the station is where the surviving fronts meet (D-101), and an unexpressible step is an
arrival (D-102).** `_engage_target_for()` now places an engaged body's centre at
`max(0, own surviving front + enemy surviving front) + contact gap` in front of the hostile centre,
where a surviving front is the forward-most place in the body's own slot layout that still holds a
living man. A body can never steer inside the enemy's centre, and a body whose ranks have been
killed walks its next rank in - one spacing per rank lost - instead of standing at the depth of a
body it no longer has. `advance()` treats a movement too fine for the centre to express as an
arrival, so "has this body stopped" has an answer in every reachable state.

**What did not change.** For two intact bodies the new station is the old one exactly (the sum of
their depths plus the contact gap), so nothing about an un-fought battle moved. Formations, slots,
spacing, ownership, casualties on the roll, facing, contact semantics, the press-forward rule's own
conditions, target acquisition, the native target kernel, the separation pass and the save format
are all untouched. HOLD still holds: a held body's centre does not move at all, and none of its
soldiers may press forward. The regression suite asserts each of those.

**300 v 300, seed 780780, after the fix:** the battle resolves at **tick 12,222 (611.1 s of battle
time)** - 596 casualties of 600, the player's last man dead, 4 enemy soldiers standing, 4,772 blows
struck, contact gained 302 times and lost 300, and the **longest stretch with both armies alive and
nobody struck was 24 ticks (1.2 s)**. Zero stall windows. Under the *production* 600-second clock
the same battle is cut off eleven seconds before its decision, **still fighting**: 1 v 5 standing
and the last blow 23 ticks before the cut. That is worth saying plainly - the stalemate is gone,
and a six-hundred-second clock on a six-hundred-soldier battle is now a game-design question rather
than a bug, because there is no longer anything for the clock to hide.

**Eleven seeds, same battle, clock raised to 3,600 s so the fight rather than the timer decides:**

| seed | result | battle time | ticks | casualties | survivors | longest quiet | stall windows |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 780780 | enemy wins | 611.1 s | 12,222 | 596 | 0 v 4 | 24 ticks | 0 |
| 1001 | enemy wins | 661.7 s | 13,234 | 583 | 0 v 17 | 27 ticks | 0 |
| 2026 | player wins | 581.8 s | 11,636 | 593 | 7 v 0 | 16 ticks | 0 |
| 3141 | player wins | 597.6 s | 11,952 | 592 | 8 v 0 | 27 ticks | 0 |
| 4321 | enemy wins | 600.2 s | 12,004 | 585 | 0 v 15 | 20 ticks | 0 |
| 5555 | enemy wins | 642.8 s | 12,856 | 595 | 0 v 5 | 100 ticks | 0 |
| 6060 | player wins | 623.2 s | 12,464 | 596 | 4 v 0 | 29 ticks | 0 |
| 7100 | enemy wins | 670.5 s | 13,410 | 593 | 0 v 7 | 31 ticks | 0 |
| 8888 | enemy wins | 598.8 s | 11,976 | 572 | 0 v 28 | 28 ticks | 0 |
| 90210 | enemy wins | 596.3 s | 11,926 | 587 | 0 v 13 | 17 ticks | 0 |
| 4711 | enemy wins | 597.4 s | 11,948 | 592 | 0 v 8 | 17 ticks | 0 |

Every one of them ends with one army destroyed and the other reduced to between four and
twenty-eight men: **eleven resolutions by annihilation, zero stalemates, zero battles still
disconnected at the end, and 272-368 contact transitions each** - i.e. the formations lose and
regain contact hundreds of times per battle and keep fighting through it.

**Small battles, unchanged in shape and behaviour:**

| battle | result | battle time | casualties | survivors | longest quiet | stall windows |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 6 v 6 | enemy wins | 44.7 s | 4 | 0 v 2 | 63 ticks | 0 |
| 20 v 20 | enemy wins | 48.1 s | 17 | 0 v 3 | 4 ticks | 0 |
| 50 v 50 | enemy wins | 91.4 s | 47 | 0 v 3 | 17 ticks | 0 |
| 100 v 100 | player wins | 102.7 s | 93 | 7 v 0 | 6 ticks | 0 |

**Determinism, and the frame-pacing defect it found (D-103).** The same-seed divergence the
showcase report suspected is real: the battle scene fed the simulator `delta * battle_speed` from
`_process`, so the simulation's step size *was* the last frame's duration, and the same seed fought
a different battle on a different machine. The runtime now runs on `BattleClock`: real frame time
accumulates, whole fixed steps come out (`battle.tick_rate`, corrected to 20.0 - the rate every
measurement in this repository was taken at), at most eight ticks per frame, with a backlog beyond
half a second dropped rather than queued. Frame pacing now decides how many ticks a frame runs and
nothing else: the suite runs the same battle at 60 fps and at 20 fps and asserts the two reach an
identical state, soldier for soldier, at the same tick. Battle speed multiplies real time rather
than the step, so `--battlespeed=8` is eight times as many identical ticks rather than one
eight-times-larger step.

**And the strongest check of that:** the windowed 300 v 300 showcase and the headless probe, driving
the same build through different code - one rendering a window and capturing screenshots, one
writing JSON - produce the **same battle to the tick**: 12,222 ticks, 596 casualties, the enemy
left with 4. Rendering does not touch the simulation at all.

**What the fix costs at 20,000 soldiers.** Interleaved matched windows on one machine, final build
against the locked tip:

| family | window | before | after | change |
| --- | --- | ---: | ---: | ---: |
| A - fixed-area torture field | 30 ticks | 363.5 / 368.1 / 367.3 ms/tick | 366.1 / 369.8 / 370.7 ms/tick | **+2.6 ms/tick (+0.7%)** |
| B - battlefield scaled with the army | 60 ticks | 383.2 / 385.9 ms/tick | 393.9 / 393.6 ms/tick | **+9.2 ms/tick (+2.4%)** |

The formation phase itself goes 36.5 -> 37.3 ms/tick in the same windows; the rule's own cost was
+31.7 ms/tick when it walked the roll and is 0.9 now that it reads the summary the tick had already
built (D-104). No new query, no quadratic loop, one linear pass over men the battle was already
counting. This host's twenty-thousand-soldier numbers move by tens of per cent with CPU state, so
the pairs above were taken back to back with each other rather than against older logs.

**The next bottleneck is unchanged, and was not touched.** Family B profile, 20,000 soldiers,
60-tick window, final build: **grid 44.5, focus 47.7, formations 41.8, soldiers 231.7 (of which
target selection 104.5), overlap 40.4, total 437.1 ms/tick** instrumented. The largest phase is
still the per-soldier update loop, and inside it automatic target selection - the same two the
Step 7.8 report named. The suspected O(deaths x army) explicit-order cleanup in `_attack()` remains
a hypothesis and was deliberately not investigated or touched.

**The dev-only battle journal (off unless asked for).** A long battle needed a way to
be read afterwards, so `scripts/battle/battle_journal.gd` records the transitions that decide one:
battle start, contact gained and lost per body, casualty milestones, which enemy body each body is
facing, the state every 1,500 ticks, and how it ended. Its lines go through `DebugLogger` - the
project's existing funnel - and the journal subscribes to that funnel and appends to a file; there
is no second logger. Nothing constructs one unless a run passes `--battlelog` or
`--battlelog=<path>`, which is how the normal game writes nothing: verified by running the
windowed showcase, the headless probe, the benchmark and the full campaign battle path without the
flag and finding no journal anywhere in `user://`.

**Tests.** A new suite, `tests/test_battle_hardening.gd`, covers the mechanism rather than only the
headline: the station follows the surviving front by one spacing per rank killed; the station is
never inside the enemy; a line whose front rank has been killed restarts the fighting within a few
hundred ticks and keeps it; pressing forward is allowed exactly when the line has stopped and is
withdrawn the moment contact returns; the frozen numbers themselves arrive instead of reporting
movement; HOLD holds; a wiped body is not chased and the living one becomes the target; contact
stays formation-local; the same seed fights the same battle; frame pacing does not change it; three
hundred a side resolves by annihilation with the clock raised; the production clock is shown to
interrupt a live fight rather than a freeze; the journal says what happened; and no soldier ever
has a non-finite position, crosses the field in a tick, or stands inside another.

## Step 7.9 - the kill-cleanup walk, measured inside real ticks

**What it is.** A measurement milestone. Every death walks the entire roster to clear the explicit
attack orders that were hunting the soldier who fell, which is O(roster) per death - the last
suspected quadratic path inside the per-soldier update loop, the largest measured phase. It was
suspected for two milestones and never proved. It is proved now, and nothing was optimised: this
project's rule is that a measurement establishes the need before an optimisation is written.

**Measured inside ticks the game ran** (`scenes/dev/death_storm_probe.tscn`, seed 70909, one `step()`
per row, ordered attackers against one-hit-point enemies):

| soldiers | deaths in that tick | entries inspected | the cleanup | the whole tick | share |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 388 | 388,000 | 36.3 ms | 46.7 ms | **77.8%** |
| 5,000 | 1,915 | 9,575,000 | 1,027.3 ms | 1,093.5 ms | **93.9%** |
| 20,000 | 7,542 | 150,840,000 | 23,599.0 ms | 24,003.6 ms | **98.3%** |

**And the scaling**, killing a known number of soldiers at 20,000 through the production `_attack()`
path: one death 20,000 entries and 4.0 ms, fifty 1,000,000 and 194.8 ms, four hundred 8,000,000 and
1,596.9 ms. Entries inspected per death equals the roster size exactly at 100, 1,000, 5,000 and
20,000 soldiers, so the cost is deaths x army. Order density barely moves the time - raising the
orders cleared at 20,000 from 9,999 to 19,999 left the timing unchanged - because the inspections
dominate and the clears are free.

Against the measured 437.1 ms tick at twenty thousand soldiers, one death is invisible and a
front-rank-death tick is entirely this walk. **The order index that would fix it is the next
milestone**, and this table is its brief. See D-110.

**An independent audit rejected the first version**, and two of its three findings were code: the
disabled path kept a counter test per roster entry (now two loops, one instrumented and one exactly
the loop it always was), and the storm's "all living units" workload only ordered one side (now every
soldier but the victim). Its third finding is why the first table is measured inside `step()`: a storm
batched by hand can show a total but cannot claim a share of a tick.

**What is verified.**

| Check | Result |
| --- | --- |
| Headless suites | **26 of 26 reported, 8878 assertions, 0 failures** |
| New coverage | six tests in `test_target_acquisition.gd`, +26 assertions: one kill walks the whole roster once; a kill clears exactly the orders hunting the fallen soldier and no others; a death nobody was hunting still costs the full walk; repeated deaths accumulate one roster each; the counters are inert with profiling off; and entries inspected per death follows the roster size |
| Two-process restart | **write 6/0, verify 95/0** - unchanged; no save-format change |
| Windowed run | the DevFlags loop deploys five against five by name, resolves the battle, no script errors. The run is ended by the harness `timeout`, as this project's windowed convention does, so the engine prints its teardown notices for a killed process afterwards - static-string and navigation-parser lines no project code caused (the project never touches navigation). The suite, which exits on its own, reports **zero** leak lines: that is the leak gate, and it is clean |
| Probe | prints a setup checksum, a per-size per-density cleanup report, and the storm-tick table |

**Not touched.** Battle outcomes, targeting cadence, target-search logic, formation-driven engagement,
explicit-order precedence, movement, separation, balance data, saves, and the locked Step 7.8 overlap
optimisation and its native kernel. The order-lapse behaviour is asserted by the new tests, so the
counters cannot have been added by changing it.


## Step 7.10 - the hunters of a fallen soldier are a chain, not a scan

**What it is.** The fix Step 7.9's measurement asked for. Every death used to walk the whole roster to
clear the orders hunting the soldier who fell - O(deaths x army), 98.3% of a twenty-thousand-soldier
tick on a mass-casualty storm. The soldiers holding an order are now chained onto the man they were
ordered to kill, once a tick, so a death walks its own chain and inspects nobody else.

**Measured, paired, in one build and on one seed** (`scenes/dev/death_storm_probe.tscn`, seed 70909):

| at 20,000 soldiers | Step 7.9 | **Step 7.10** |
| --- | ---: | ---: |
| 50 deaths, no orders | 1,000,000 inspections, 160.5 ms | **0 inspections, 0.011 ms** |
| 50 deaths, every soldier ordered at one man | 1,000,000 inspections, 162.8 ms | **19,999 inspections, 16.2 ms** |
| a storm tick, 7,542 deaths | 23,599.0 ms of a 24,003.6 ms tick (**98.3%**) | **7.6 ms of a 230.1 ms tick** (**3.3%**) |

The storm tick is **104 times cheaper**. The cost follows the orders rather than the army: one hunter
costs one inspection at a roster of ten or sixty thousand, which is the exact inverse of Step 7.9.

**The equivalence is proved, not asserted.** The suite performs the reference scan itself and checks
that the indexed cleanup clears exactly what a full walk would, that every hunter's order lapses, and
that an order aimed at a living soldier does not move. The behaviour assertions from Step 7.9 are
unchanged, because the milestone changed what the cleanup costs, not what it does. The chains are
rebuilt when the tick's index is stale, because the probe and the suites call `_attack()` directly and
an unbuilt index would have silently cleared nothing - the failure mode the Step 7.5 focus work hit.

**What is verified.** 26 suites / 8,895 assertions / 0 failures headless - the target suite grew from
268 to 285 with the equivalence, inverse-scaling, chain and no-hunter tests - the two-process restart
check unchanged, and the windowed DevFlags loop resolving a battle with no script errors. See D-111.

## Step 7.11 - the per-soldier loop, counted by path and priced by operation

**What it is.** A measurement milestone, in the shape Step 7.9 established: count what the per-soldier
loop actually does, price each operation it performs, and only then name a fix. Nothing changes
behaviour. Step 7.9 and 7.10 left the per-soldier loop the largest phase of a tick - 203.1 ms of a
399.0 ms instrumented tick at 20,000 soldiers in the fixed-area benchmark - of which automatic target
selection is 72.1 ms, leaving about 131 ms attributed to nothing.

**What the army actually does** (the benchmark's own counters, at 20,000 soldiers, per tick):

| path | per tick | share of soldiers |
| --- | ---: | ---: |
| through the per-soldier loop | 20,000 | 100% |
| resolved a target (so paid the facing normalise and the range check) | 20,000 | 100% |
| already in attack range | 0 | 0% |
| took the formed path | 20,000 | 100% |
| computed a formation slot | 20,000 | 100% |
| moved (a terrain lookup and a native call each) | 20,000 | 100% |
| **calls into the native accelerator** | **20,000** | one per moving soldier |

A path nobody walks cannot be the missing time, and every path here is walked by every soldier.

**What one call costs** (`scenes/dev/unit_price_probe.tscn`, 200,000 iterations each, live state):

| operation | us per call | per tick at 20,000 |
| --- | ---: | ---: |
| an empty control function (the act of calling) | 0.2707 | 5.4 ms |
| [code]_can_press_forward()[/code] | 1.4697 | **29.4 ms** |
| the terrain multiplier | 0.9422 | 18.8 ms |
| [code]formation_slot()[/code] | 0.6661 | 13.3 ms |
| [code]native_moved()[/code] | 0.5441 | 10.9 ms |
| the range check | 0.2279 | 4.6 ms |
| the facing normalise (two square roots) | 0.2071 | 4.1 ms |
| **together** | | **81.1 ms of the ~131 ms** |

Six such calls happen per soldier per tick, so about 32.5 ms of that total is the act of calling rather
than the work - which is itself a finding about how a per-soldier loop is written, not a footnote.

**What it means.** The largest single item is a side-contact check run once per formed soldier per tick,
and it answers a question about the whole *side*, not the soldier - so it belongs to the side, computed
once. Reading it explains the price: six field reads delivered through four function calls, at roughly
0.37 us each, which is the measured cost of *calling* rather than of checking. The same is true of the
next three items, and it is the milestone's real finding: a per-soldier loop of twenty thousand
soldiers pays for every call it makes, and the way to make it cheaper is to make fewer calls per
soldier - cache the side-contact answer per body per tick, apply the body's own step to the soldiers
already in their places (which is where the slot, terrain and position arithmetic disappear), and
mirror moved soldiers into the accelerator once a tick instead of twenty thousand times. See D-112.

**Not touched.** Battle outcomes, targeting cadence and search, formation-driven engagement, explicit
order precedence, movement semantics, separation (Step 7.8 is locked), balance data, saves, and the
native kernel's interface. The counters are inert with profiling off; both instruments live under
[code]scripts/dev[/code] and [code]scenes/dev[/code].


## Step 7.12 - the per-soldier loop's calls, part one (in progress)

**What it is.** The fix Step 7.11 asked for, taken in slices, because each slice has to prove it changed
cost and not behaviour. Three slices so far, each keeping its previous shape in the same build behind a
switch, so every number below is a paired run rather than a comparison against an older log.

| slice | what it removes | switch | measured at 20,000 soldiers, one seed |
| --- | --- | --- | --- |
| 1. the press-forward gate decided per body | three calls per formed soldier (D-113) | `PB_PRESS_CACHE=off` | soldiers 204.365 -> 193.643 ms, tick 399.965 -> 389.244 ms: **10.7 ms** |
| 2. the native mirror's guard spelled out | one call per moving soldier (D-114) | `PB_NATIVE_GUARD=call` | soldiers 190.484 ms against 193.639 ms: **3.2 ms** |
| 3. the terrain path collapsed to one call | four calls per moving soldier (D-114) | `PB_TERRAIN_FAST=off` | soldiers 169.468 ms against 191.260 ms: **21.8 ms** |

**Where the loop stands.** The soldiers phase at twenty thousand soldiers has gone from 204.4 ms to
169.4 ms - about 17 per cent - and the whole tick from about 400 ms to about 363 ms. Target selection,
the other large phase, was not touched: this milestone is only about what the per-soldier loop spends
outside it.

**What is proved rather than asserted.** Slice 1's equivalence is a test that drives one showcase battle
twice, forty ticks with both commanders thinking, comparing every soldier's answer, every soldier's
position, and the per-tick count of soldiers allowed to press forward - the count being what catches the
mid-loop contact case. Slices 2 and 3 hold no state, so their equivalence is by construction - the same
reads, in the same order, at the same point in the tick - and their evidence is the paired measurement.
An independent reviewer shaped all of this: it asked for the mid-loop fixture, for the reference to stay
in the build, and for the native case to be established rather than assumed, and it was right each time.

**Not touched.** Movement semantics, iteration order, separation (Step 7.8 is locked), D-108's rigid
path, balance data and saves. Every switch is development-facing and every shipped default is on.

**Next.** The two items that need proofs rather than inlining: the body transform - a body's slot lattice
is an exact anchor-centred rigid transform of the previous tick's, verified on real battles to 1.7e-5,
but it needs a long-battle drift fixture before anything may depend on it - and the native batch, which
replaces twenty thousand boundary crossings a tick with one and is architectural work against D-095.


## Step 7.13 - the target phase's calls (in progress)

**What it is.** The other large phase. Step 7.12 took the per-soldier loop from 204.4 ms to 169.4 ms and
left target selection alone, and said so; this milestone starts on it with the same rule: price the
operation, remove the call, keep the previous shape in the build as a reference, and prove identity
rather than plausibility.

| slice | what it removes | switch | measured (20,000 soldiers, one seed) |
| --- | --- | --- | --- |
| 1. the formed-soldier focus fast path | four calls per question, for an answer the body already has (D-115) | `PB_FOCUS_INLINE=method` | target phase 72.101 -> 56.410 ms, soldiers 170.411 -> 154.531 ms: **15.7 ms** |
| 2. the per-soldier sub-item timers gated | two to three timed reads a soldier, instrument inside the thing being measured (D-116) | `PB_TGT_TIMING=off` | whole tick 352.600 -> 346.275 ms: the instrument costs **6.3 ms**; the sub-item breakdown reads zero |

**Where the loop stands.** The soldiers phase at twenty thousand soldiers is now 154.5 ms instrumented -
about 151 ms with the instrument's per-soldier timers off, D-116 - down from 204.4 ms before Step 7.12,
and the whole tick 346.3 ms with the timers off against 352.6 ms with them on. The target phase is 56.4 ms
of that, having been 72.1 ms.

**What was abandoned, and why it stays in the record.** The turning-body transform - a body's slot
lattice is an exact anchor-centred rigid transform of the previous tick's, verified over 80,000 samples
to 1.7e-5 - was measured for coverage before anything was built on it, and priced out: at the game's own
arrival epsilon only 1.4 per cent of soldier-ticks are on a body whose facing changed, which is the only
case the existing rigid step path does not already cover. That is about a millisecond a tick in exchange
for a change to the most sensitive path in the game, so the reviewer's ruling was to abandon it rather
than leave a half-verified idea lying around.

**Next.** Whatever else the counters name inside the target phase, then the native mirror batch - one
boundary crossing a tick instead of twenty thousand, which needs a method on the C++ side and work
against D-095.

| 3. the native mirror batched | one bridge crossing per moving soldier (D-118) | `PB_NATIVE_BATCH=off` | soldiers 156.864 -> 153.703 ms and tick 352.953 -> 350.570 ms: **3.16 ms off the phase, 2.38 ms off the tick** |

**The lesson the three slices taught about prices.** An isolated price ranks candidates and does not size
them: the press-forward cache was predicted at 16-18 ms from its price and measured 10.7; the terrain
collapse was predicted at 10-16 and measured 21.8; the native batch was predicted near twenty and
measured 3.2. Every slice is chosen on its price and accepted on its paired run, which is why every
switch keeps its reference in the same build.
