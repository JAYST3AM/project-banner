# Current State

What is actually playable and verified **right now**.

**Last updated:** end of Step 7.2 - battle simulation scaling foundation
**Engine:** Godot 4.7.2-stable
**Test status:** `2364 assertions, 0 failures, 17 of 17 suites` headless, plus
`95 checks, 0 failures` in a genuine two-process restart check.
**Independent gate:** GitHub Actions runs both of those on every push to `main` and
every pull request against it, pinned to Godot 4.7.2-stable.

**Note:** Steps 6.5, 6.6 and 7.1 were hardening passes and Step 7.2 was an engineering
milestone; none of them added gameplay. Step 7 added terrain and formations. See [Step 7 -
terrain and formation foundation](#step-7---terrain-and-formation-foundation), [Step 7.1 -
formation hardening](#step-71---formation-hardening) and [Step 7.2 - battle simulation
scaling foundation](#step-72---battle-simulation-scaling-foundation) below.

---

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

**Seventeen headless suites, 2364 assertions, 0 failures**

| Suite | Assertions | Covers |
| --- | --- | --- |
| `test_core_services` | 83 | config presence, clock maths, RNG determinism, save round-trip |
| `test_campaign_flow` | 41 | campaign lifecycle, scene transitions, singletons, Continue |
| `test_world_map` | 88 | world from data, travel, arrival, speed states, persistence |
| `test_recruitment` | 191 | unit/trait data, names, factory, recruitment rules, party limits |
| `test_party_semantics` | 51 | **roster membership vs active force**: travel pace, HUD wording, capacity, the dead kept on the record |
| `test_encounters` | 282 | spawning, movement, aggro, detection, `BattleContext`, deployment, simulator |
| `test_combat` | 266 | damage, death, attribution, victory conditions, results, resolver, balance |
| `test_battle_outcomes` | 224 | **victory / defeat / draw / withdrawal**, the retreat farming loop, timeout freezing the field, results-screen wording |
| `test_terrain` | 72 | **deterministic ground**: same seed same field, different seed different field, bounds, movement modifiers, terrain actually changing movement, the slope contract at the field's edge, independence from rendering |
| `test_formation` | 328 | **formations as physical objects**: geometry across seven facings, distinct slots, ownership and partial detachment, repeated transfers, movement without teleporting, turning, reformation, cohesion, casualties leaving gaps, rotated debug bounds |
| `test_formation_battle` | 99 | **both systems together**: both armies formed, the enemy on the same engine, the AI ignoring wiped-out bodies, contact belonging to a body rather than a side, terrain slowing a body, a formed battle resolving and being reproducible, the architecture guardrails, a 500-unit scale smoke |
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
17. **Overlap resolution is the most expensive phase**, once the quadratic scans were
    removed in Step 7.2 (see the profile above). It is bounded by how many soldiers share
    a grid cell, and the battlefield is a fixed 100x60 however many soldiers are on it,
    so density - not the algorithm - is now the limit. 20,000 soldiers simulate at 12.0
    seconds a tick, measured rather than extrapolated.
18. **Rendering is not in any of these measurements.** The benchmark steps the simulation
    directly. Drawing twenty thousand soldiers is a separate problem the large-battle
    milestone will also have to pay for, and nothing here claims otherwise.

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
