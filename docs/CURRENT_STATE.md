# Current State

What is actually playable and verified **right now**.

**Last updated:** end of Step 6.6 - final foundation lock
**Engine:** Godot 4.7.2-stable
**Test status:** `1708 assertions, 0 failures, 13 of 13 suites` headless, plus
`95 checks, 0 failures` in a genuine two-process restart check.
**Independent gate:** GitHub Actions runs both of those on every push to `main` and
every pull request against it, pinned to Godot 4.7.2-stable. Green on the foundation
lock commit —
[run 34741699176](https://github.com/JAYST3AM/project-banner/actions/runs/34741699176).

**Note:** Steps 6.5 and 6.6 were hardening passes over Steps 0-6, not new gameplay.
See [Step 6.6 - final foundation lock](#step-66---final-foundation-lock) below.

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

**Thirteen headless suites, 1708 assertions, 0 failures**

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
| Headless suites | **16 of 16 reported, 2058 assertions, 0 failures** |
| New suites this milestone | `test_terrain` (69), `test_formation` (203), `test_formation_battle` (78) |
| Two-process restart | 95 checks, 0 failures - unchanged, and now with formations and terrain in the flow |
| Windowed smoke | campaign → settlement → recruit → battle → results → campaign |
| Bogus `--suite=` | exit 1 |
| CI | green on the pushed commit |

New coverage is behavioural rather than structural: the same enemy fought twice across
a restart, a real reformation that drops cohesion and recovers it, a line ordered into a
column with a one-frame "nobody moved" assertion, an arbitrary-facing geometry sweep,
terrain that measurably slows a body in proportion to its own data, and a stalled battle
that is required to reach a winner inside its step budget.

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
17. **The battle simulation is quadratic in soldiers.** `_choose_target()` and
    `_resolve_overlaps()` compare every soldier with every other soldier, which is why
    5,000 soldiers costs eleven seconds a tick. Measured, documented, and the first task
    of the large-battle milestone - see D-053 and the benchmark table above.

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
