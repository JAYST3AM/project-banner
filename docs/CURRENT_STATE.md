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

## Known limitations

The honest list. None of these blocks the checkpoint; all of them are the natural
next work.

1. **A battle is fought on flat ground.** `terrain_seed` is generated and carried in
   the context but nothing reads it yet. No cover, elevation or obstacles.
2. **No formations.** Units seek the nearest enemy and pile in.
3. **No morale or fleeing.** A unit fights to its last hit point. `morale` is
   tracked and displayed but does not affect behaviour yet.
4. **Losing the whole party is not a game over.** The campaign continues with an
   empty party; you can walk back to a town and recruit again. Prisoners, capture
   and ransom are future work.
5. **Wounded soldiers do not exist.** Survivors return at whatever hit points they
   ended with. No treatment, no recovery time.
6. **Loot is sold immediately** for coin, because there is no inventory.
7. Trait `attack_pct` and `move_speed_pct` are applied when a battle unit is built;
   `morale` and `loyalty` have no mechanical effect beyond display.
8. **Only bandit parties exist.** Caravans, patrols and lord armies have the data
   model (`WorldParty`, `Party.kind`) but no spawn data or behaviour.
9. **No ambushes yet.** `BattleContext` supports them (`build_context(party, false)`
   flips attacker and defender) but nothing calls it that way.
10. Ammunition is unlimited and there are no projectiles; ranged hits apply
    immediately with a floating damage number.
11. Only the single default save slot is used. Multi-slot UI is not built.
12. `Settlement.market` and `Soldier.equipment` remain empty placeholders.
13. **No artwork.** The world map and battlefields are drawn procedurally.
14. No export templates installed - the project runs from source only.
15. Balance is deliberately rough. Fights work and are decisive; they have not been
    tuned for a long campaign.

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
