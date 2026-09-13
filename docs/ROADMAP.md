# Roadmap

The plan of record. Each step ends with a commit, a tested build and updated docs.

Status legend: `DONE` / `IN PROGRESS` / `TODO`

| Step | Milestone | Status |
| --- | --- | --- |
| 0 | Bootstrap Godot development environment | **DONE** |
| 1 | Project architecture and campaign foundation | **DONE** |
| 2 | Playable world map and settlement travel | **DONE** |
| 3 | Persistent soldiers, recruitment, party roster | TODO |
| 4 | World encounters and tactical battle transition | TODO |
| 5 | First functional tactical combat | TODO |
| 6 | Persistent campaign save/load validation | TODO |
| — | **First major checkpoint: the full vertical slice** | TODO |
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
return -> the same soldiers are still there.

## Step 4 - Encounters and battle transition (`milestone-04`)

**Goal:** connect the overworld to tactical combat.

- Overworld party architecture covering player, bandit, caravan and army parties
- Bandit parties of 5-8 soldiers that wander near their spawn region
- Encounter trigger: pause the world, show BANDITS with both strengths and Attack / Retreat
- `BattleContext`: battle id, both parties, world position, terrain seed, battle
  seed, campaign time, weather placeholder, attacker, defender
- Battle scene: placeholder markers, camera pan/zoom, Start Battle, Retreat

**Definition of done:** travel -> encounter bandits -> Attack -> battlefield loads
with the correct units -> return to the same campaign.

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
`tests/test_e2e_loop.gd` and played by hand.

## Step 6 - Save/load validation (`milestone-06`)

**Goal:** the vertical slice survives a full application restart.

- Persist campaign metadata, seed, time, position, destination, gold, party,
  soldiers, XP, kills, level, alive/dead, settlements, recruit pools, enemy parties
- Versioned save + migration path

**Definition of done:** New Campaign -> recruit -> fight -> earn XP -> save -> quit
-> relaunch -> Continue, with every value intact.

---

# First major checkpoint

Do **not** significantly expand the game until this loop is stable:

```
NEW CAMPAIGN -> WORLD MAP -> TRAVEL -> TOWN -> RECRUIT -> INDIVIDUAL SOLDIERS
-> WORLD MAP -> BANDITS -> TACTICAL BATTLE -> CASUALTIES -> XP -> LOOT
-> WORLD MAP -> SAVE -> CLOSE GAME -> LOAD -> CONTINUE CAMPAIGN
```

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

## Standing design principle

Individual soldiers should feel like people rather than numbers. `Soldier`
already carries the fields this needs - age, traits, loyalty, level, kills,
battles survived, and an open-ended `history` log. The systems that fill that log
come later; the storage for it exists now so those systems never have to
retro-fit identity onto a stat block.
