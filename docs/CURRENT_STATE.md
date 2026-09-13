# Current State

What is actually playable and verified **right now**.

**Last updated:** end of Step 6 (`milestone-06`) - **the first major checkpoint**
**Engine:** Godot 4.7.2-stable
**Test status:** `1207 assertions, 0 failures, 8 of 8 suites` headless, plus
`75 checks, 0 failures` in a genuine two-process restart check.

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

**Eight headless suites, 1207 assertions, 0 failures**

| Suite | Assertions | Covers |
| --- | --- | --- |
| `test_core_services` | 83 | config presence, clock maths, RNG determinism, save round-trip |
| `test_campaign_flow` | 41 | campaign lifecycle, scene transitions, singletons, Continue |
| `test_world_map` | 88 | world from data, travel, arrival, speed states, persistence |
| `test_recruitment` | 191 | unit/trait data, names, factory, recruitment rules, party limits |
| `test_encounters` | 282 | spawning, movement, aggro, detection, `BattleContext`, deployment, simulator |
| `test_combat` | 266 | damage, death, attribution, victory conditions, results, resolver, balance |
| `test_e2e_loop` | 127 | **the Step 5 critical end-to-end path, through the real scenes** |
| `test_persistence` | 129 | every field the milestone lists, migration, refusal, corrupt files |

**The restart check** (`scenes/dev/persistence_check.tscn`) runs as two separate
Godot processes, because a same-process save/load only proves the serialiser
round-trips and not that the game can be closed and reopened:

```
godotc --headless --path "<project>" res://scenes/dev/persistence_check.tscn -- --phase=write
godotc --headless --path "<project>" res://scenes/dev/persistence_check.tscn -- --phase=verify
```

The first process recruits five soldiers, travels, fights a battle to a conclusion,
records what the world looks like, saves and exits. The second process is brand new:
it calls the same `continue_campaign()` the Continue button calls, and checks every
recorded fact. It has no memory of the first process except the save file.

Result: `26 soldiers restored, 9 of them dead` - every soldier identical in name,
archetype, level, XP, hit points, kills, battles fought and survived, status,
traits and history length; settlements, visited flags and depleted recruit pools
intact; enemy parties with their positions, rosters and `defeated` flags intact;
the battle chronicle intact; the world map opens on the restored campaign; and
re-saving is stable. **75 checks, 0 failures.**

**A real windowed launch** with a save present logs `main menu: continue offered`.

**Opening-fight balance**, measured across 24 campaign seeds in a real simulator:

| Fight | Won | Enemy casualties |
| --- | --- | --- |
| vs the **weakest** bandit band (the careful choice) | 20 / 24 | 122 |
| vs the **strongest** bandit band | 3 / 24 | 77 |

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
