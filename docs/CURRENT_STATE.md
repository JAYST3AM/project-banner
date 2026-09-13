# Current State

What is actually playable and verified **right now**. Update after every milestone.

**Last updated:** end of Step 5 (`milestone-05`)
**Engine:** Godot 4.7.2-stable
**Test status:** `1078 assertions, 0 failures, 7 of 7 suites` -
`godotc --headless --path "<project>" res://scenes/dev/tests.tscn`

---

## What you can do today

**The full vertical slice works.** You can start a campaign, travel to a town,
recruit named soldiers, take them into a fight, watch some of them die, earn
experience and gold, and see all of it reflected in their records afterwards.

| Action | Works? | Notes |
| --- | --- | --- |
| Launch, create or continue a campaign | Yes | Reproducible world seed |
| Travel the world map | Yes | Paused / Normal / Fast |
| Enter settlements, recruit named soldiers | Yes | Cost, traits, morale, loyalty, personal history |
| Inspect a soldier / the roster | Yes | Full record; casualties stay listed |
| See hostile parties wander | Yes | Three bands; they chase you when close |
| Meet bandits, pause, choose | Yes | Attack or Retreat, with both strengths shown |
| **Fight a real battle** | **Yes** | Units close, strike, miss, and die |
| **Select and order units** | **Yes** | Click, shift-click, box-drag; right-click to move or to attack |
| **Casualties, XP, kills, gold** | **Yes** | Written back to the individual soldiers |
| **Battle results screen** | **Yes** | Victory/defeat, losses named, survivors and their XP, loot |
| Retreat from a battle | Yes | Withdraws, pushes you clear, no reward |
| Save the campaign | Yes | "Save Game" or F5 |
| Full save/load validation across a restart | Step 6 | Persistence is implemented; the restart test is next |

### The combat loop in practice

Measured across 24 campaign seeds, five freshly recruited peasants against the
bandit bands the world actually spawns:

| Fight | Won | Notes |
| --- | --- | --- |
| vs the **weakest** band (what a careful player picks) | **20 / 24** | A reliable plan, not a certainty |
| vs the **strongest** band | **3 / 24** | Careless players get their party destroyed |

Fights are decisive, not stalemates: 122 and 77 enemy casualties respectively
across those runs. Three real windowed playthroughs produced a defeat (2 of 6
enemies down), a narrow victory (1 of 5 survivors, 6 of 6 enemies down, 102 gold)
and a solid victory (4 of 5 survivors, 5 of 5 enemies down, 88 gold, 280 XP).

### World map controls

| Input | Action |
| --- | --- |
| Left click settlement | Select and inspect it |
| Left click empty land / Esc | Deselect |
| WASD / arrows / middle-drag | Pan the map |
| Middle-drag | Pan (world map and battlefield) |
| Mouse wheel | Zoom |
| `1` `2` `3` | Paused / Normal / Fast |
| Space | Toggle pause (resumes at the pace you chose) |
| F5 | Save, `R` cancel travel, `F1` debug panel |

### Battlefield controls

| Input | Action |
| --- | --- |
| Left click a unit | Select it |
| Shift + left click | Add to the selection |
| Left-drag | Box-select |
| Left click empty ground / Esc | Clear the selection |
| Right click an enemy | Attack that unit |
| Right click open ground | Move there |
| WASD / arrows / middle-drag | Pan, mouse wheel to zoom |
| Space | Start the battle, `R` retreat |

## What is verified, and how

All of the following are asserted by the headless suites or by real windowed runs,
not claimed by hand.

**`test_core_services.gd` (83)** - config, clock, RNG determinism, save round-trip.
**`test_campaign_flow.gd` (41)** - campaign lifecycle, scene transitions, singletons, continue.
**`test_world_map.gd` (88)** - world from data, travel, arrival, speed states, persistence, scene flow.
**`test_recruitment.gd` (191)** - unit/trait data, names, factory, recruitment rules and transaction, party limits.
**`test_encounters.gd` (282)** - party spawning and determinism, movement and aggro, encounter detection and
cooldown, `BattleContext` contents and round-trip, deployment, simulator movement and determinism, the full
scene flow.

**`test_combat.gd` (266)** - blows land, some miss, deaths are counted and attributed exactly once;
defence demonstrably reduces damage; wiping out a side ends the battle with the right winner; a timeout
is a draw; **every melee archetype can reach past the separation distance** (the regression guard for the
bug described in D-025); the battle result's survivor/dead/gold/XP figures match config; the resolver
writes casualties, kills, battles, XP, survival counts and history entries onto the right soldiers, keeps
the fallen out of the line, destroys the beaten party, changes gold by exactly the spoils, and survives a
save/load; withdrawal and defeat pay nothing and kill nobody unnecessarily; the same seed fights the same
battle; and the opening fight is a genuine contest at both ends of the difficulty range.

**`test_e2e_loop.gd` (127) - the Step 5 critical end-to-end test**, run through the
real scenes: start a new campaign -> travel to a town -> recruit five soldiers ->
inspect the roster -> leave town -> walk into bandits -> attack -> the battlefield
loads with our five and theirs by name -> `Start Battle` through the scene's own
handler and `_process` driven as the engine would -> the battle concludes -> the
results screen loads -> return to the world map -> verify on the soldiers
themselves that casualties match the record, that survivors gained XP and count
their survival, that the party's kills equal the enemies put down, that gold moved
by exactly the recorded amount, and that the roster still lists everyone.

## Known limitations

1. **A battle is fought on flat ground.** `terrain_seed` is generated and carried
   in the context but nothing reads it yet; there is no cover, elevation or
   obstacle.
2. **No formations.** Units seek the nearest enemy and pile in. Spears have no
   anti-cavalry role because there is no cavalry.
3. **No morale or fleeing.** A unit fights to the last hit point; `morale` is
   tracked on soldiers but does not yet affect behaviour.
4. **Losing the whole party is not a game over.** The campaign continues with an
   empty party; you can recruit again. Prisoners and capture are future work.
5. **Wounded soldiers do not exist.** Survivors come back at whatever hit points
   they ended with; there is no recovery, treatment or time-based healing.
6. **Loot is sold immediately** (there is no inventory yet), so items appear as
   coin on the results screen.
7. Trait `attack_pct` and `move_speed_pct` are applied when a battle unit is built;
   `morale` and `loyalty` still have no mechanical effect beyond being displayed.
8. Only bandit parties exist; caravans, patrols and lord armies have the data model
   but no spawn data or behaviour.
9. Ammunition is unlimited, and there are no projectiles - ranged hits are applied
   immediately with a floating damage number.
10. Only the single default save slot is used.
11. `Settlement.market` and `Soldier.equipment` remain empty placeholders.
12. Battlefields and the world map are drawn procedurally; no artwork.
13. No export templates installed - the project runs from source only.

## Next milestone

**Step 6 - save/load validation.** The persistence layer is already implemented and
exercised; the milestone is to prove the whole vertical slice survives a real
application restart, and to write that proof down as a test.
