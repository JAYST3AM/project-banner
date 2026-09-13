# Current State

What is actually playable and verified **right now**. Update after every milestone.

**Last updated:** end of Step 4 (`milestone-04`)
**Engine:** Godot 4.7.2-stable
**Test status:** `685 assertions, 0 failures, 5 of 5 suites` -
`godotc --headless --path "<project>" res://scenes/dev/tests.tscn`

---

## What you can do today

| Action | Works? | Notes |
| --- | --- | --- |
| Launch the game | Yes | Boot splash -> main menu |
| Create a campaign | Yes | Name + optional reproducible world seed |
| Continue a campaign | Yes | Enabled only when a save exists |
| Travel the world map | Yes | Select a settlement, click Travel Here |
| Watch campaign time pass | Yes | Paused / Normal / Fast |
| Recruit named soldiers | Yes | Cost, traits, morale, loyalty, personal history |
| Inspect a soldier / the roster | Yes | Full record and live party list |
| See hostile parties on the map | Yes | Three bandit bands, drawn as red diamonds with sizes |
| Watch parties move and chase | Yes | Wander near home, close on you when near |
| Meet bandits | Yes | The world pauses: name, both strengths, Attack / Retreat |
| **Fight on a battlefield** | **Partly** | Armies deploy and advance; no damage yet (Step 5) |
| Select and order units | Yes | Click, shift-click, box-drag; right-click to move |
| Retreat from a battle | Yes | Pushes you clear and sets a cooldown |
| Return to the same campaign | Yes | Same soldiers, same world, same battle count |
| Save the campaign | Yes | "Save Game" or F5 |
| Encounter resolution, XP, loot | No | Step 5 |
| Full save/load validation | No | Step 6 |

### World map controls

| Input | Action |
| --- | --- |
| Left click settlement | Select and inspect it |
| Left click empty land / Esc | Deselect |
| WASD / arrows / middle-drag | Pan |
| Mouse wheel | Zoom |
| `1` `2` `3` | Paused / Normal / Fast |
| Space | Toggle pause (resumes at the pace you had chosen) |
| F5 | Save, `R` cancel travel, `F1` debug panel |

### Battlefield controls

| Input | Action |
| --- | --- |
| Left click a unit | Select it |
| Shift + left click | Add to the selection |
| Left-drag | Box-select |
| Left click empty ground / Esc | Clear the selection |
| Right click | Order selected units to that point |
| WASD / arrows / middle-drag | Pan |
| Mouse wheel | Zoom |
| Space | Start the battle, `R` retreat |

## What is verified, and how

All of the following are asserted by the headless suites or by real windowed runs,
not claimed by hand.

**`test_core_services.gd` (83)** - config, clock maths, RNG determinism, save round-trip.
**`test_campaign_flow.gd` (41)** - campaign lifecycle, scene transitions, one of each singleton, continue.
**`test_world_map.gd` (88)** - world from data, travel, arrival, speed states, world persistence, scene flow.
**`test_recruitment.gd` (191)** - unit/trait data, names, factory, recruitment rules and
transaction, party limits, soldiers surviving travel and saving, and the Step 3
definition-of-done path.

**`test_encounters.gd` (282)** - hostile parties spawn from data with 5-8 soldiers each
and are idempotent; the same campaign seed spawns the same parties; parties wander
inside their radius, do not move when the world is paused, and close on the player
inside aggro range; a party with no living soldiers is removed from the map;
encounter detection only fires when the player is on top of a party, retreat pushes
the player clear and starts a cooldown that expires with game time, and a party on
cooldown is not re-detected; the `BattleContext` carries ids, seeds, time, weather,
sides and both rosters, keeps every soldier id resolvable in the campaign, applies
trait attack modifiers, flips sides for an ambush, gives each battle its own id and
seed, and round-trips through a dictionary; deployment puts players left facing
right and enemies right facing left with unique unit ids; the simulator refuses to
run before Start, closes the two lines, keeps units on the field, honours and clears
move orders, and produces identical positions across two identical runs. Plus the
milestone path end to end: travel -> encounter -> attack -> the real battle scene
loads from the payload -> its simulator holds exactly the campaign's own soldiers on
both sides -> return to the same campaign.

**Windowed run (real rendering, real frame loop)**

```
godotc --path "<project>" -- --autostart-campaign=4321 --autostart-town=greywatch \
        --autorecruit=4 --autoleave --autoengage --autoattack
[Recruitment] recruited Wilkin Carrow (Peasant Recruit, 20 gold) at Greywatch ... 4/24 party
[Overworld]   spawned Road Bandits (8 soldiers) near Thornwood Hollow
[WorldMap]    encounter with Road Bandits (8 soldiers) at Day 1 - 08:04
[Encounter]   battle battle_0001 at 890,550: player (4) vs enemy (8), clear, seed 3864013254
[Battle]      deployed 4 player and 8 enemy units: player:Wilkin Carrow, player:Gervase
              Dunhollow, player:Roderick Foxley, player:Nyle Chetwood, enemy:Anselm
              Millbrook, ... enemy:Gunther Ironwell
```

with no script errors. Re-running the same command as a separate process produced
identical soldier names and an identical battle seed, confirming that a campaign
seed really does reproduce the world.

## Known limitations

1. **A battle does not resolve yet.** Armies deploy and advance on each other and
   move orders work, but nothing takes damage, so there is no winner, no XP and no
   loot. This is Step 5 and is the single biggest gap in the vertical slice.
2. Hostile parties are always the attacker's opponent; there is no ambush trigger
   yet (the context supports it - `build_context(party, false)` - but nothing calls
   it that way).
3. Only bandit parties exist. Caravans, patrols and lord armies have the data model
   (`WorldParty`, `Party.kind`) but no spawn data or behaviour.
4. Battlefield terrain is a flat rectangle; `terrain_seed` is generated and carried
   but nothing reads it yet.
5. Weather is a placeholder string in the context.
6. Retreating from a battlefield does not cost anything - no morale or loyalty hit.
7. Overworld parties are not drawn with their aggro radius, and there is no
   indication of which are hostile beyond their colour.
8. The world map and battlefields are drawn procedurally; no artwork.
9. Only the single default save slot is used.
10. `Settlement.market` and `Soldier.equipment` remain empty placeholders.
11. No export templates installed - the project runs from source only.

## Next milestone

**Step 5 - the first functional combat loop.** Damage, death, a `BattleResult`,
XP and kills written back to the individual soldiers who earned them, a battle
results screen, and the full end-to-end path demanded by the milestone.
