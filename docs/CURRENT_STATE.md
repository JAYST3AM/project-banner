# Current State

What is actually playable and verified **right now**. Update after every milestone.

**Last updated:** end of Step 2 (`milestone-02`)
**Engine:** Godot 4.7.2-stable
**Test status:** `212 assertions, 0 failures` - `godotc --headless --path "<project>" res://scenes/dev/tests.tscn`

---

## What you can do today

| Action | Works? | Notes |
| --- | --- | --- |
| Launch the game | Yes | Boot splash -> main menu |
| Create a campaign | Yes | Name + optional reproducible world seed |
| Continue a campaign | Yes | Enabled only when a save exists; shows day, gold, party size |
| Travel the world map | Yes | Select a settlement, click Travel Here, watch the party set out |
| Watch campaign time pass | Yes | Advances during travel; Paused / Normal / Fast |
| Inspect a settlement | Yes | Click it: owner, population, recruits, description, distance |
| Enter a settlement | Yes | Enabled once the party arrives |
| Pan / zoom the map | Yes | WASD or arrows or middle-drag; mouse wheel zooms |
| Save the campaign | Yes | "Save Game" (or F5); `user://saves/slot_1.save` |
| Debug panel | Yes | F1: teleport, +100/+1000 gold, speed, live coordinates |
| Recruit soldiers | No | Step 3 (recruit pools already load from data) |
| Fight a battle | No | Steps 4-5 |

### World map controls

| Input | Action |
| --- | --- |
| Left click settlement | Select and inspect it |
| Left click empty land / Esc | Deselect |
| WASD / arrows / middle-drag | Pan the camera |
| Mouse wheel | Zoom |
| `1` `2` `3` | Paused / Normal / Fast |
| Space | Toggle pause (resumes at the pace you had chosen) |
| F5 | Save |
| R | Cancel travel |
| F1 | Toggle the debug panel |

### The starting region

| Settlement | Type | Owner | Population | Position |
| --- | --- | --- | --- | --- |
| Greywatch | town | House Caldreth | 1800 | (300, 620) - start |
| Brackenford | town | House Caldreth | 2400 | (1180, 300) |
| Redmoor | village | House Varengard | 420 | (620, 220) |
| Thornwood Hollow | wilderness | unclaimed | 0 | (880, 700) |

Four roads connect them: Greywatch-Redmoor-Brackenford, plus tracks from Greywatch
and Brackenford to Thornwood Hollow. Travel is not restricted to the roads; they
are a distance hint and a hook for later logistics.

## What is verified, and how

All of the following are asserted by the headless suites or by a real windowed run,
not claimed by hand.

**`tests/test_core_services.gd` (83 assertions)** - config loads and every tunable
the code reads exists; clock maths (2 real seconds = 1 game hour at normal, 3x at
fast, nothing while paused, midnight rollover); RNG determinism per named stream;
save/load round-trip of a soldier with level, XP, HP, kills, traits and history.

**`tests/test_campaign_flow.gd` (41 assertions)** - new campaign defaults, campaign
replacement, real scene transitions preserving one `CampaignState`, exactly one of
each singleton after transitions, continue-restores-everything.

**`tests/test_world_map.gd` (88 assertions)** - world built from data (4 settlements,
4 roads, all road endpoints resolve); the party starts at the configured settlement;
`build_if_needed` never rebuilds over saved state; travel sets the destination,
leaves the settlement, clears `current settlement`, covers exactly one hour of pace
per game hour, does not drift when stopped or given zero hours; a no-op travel order
does not cancel a journey in progress; wilderness is not a valid destination; party
size slows travel with a configured floor; arrival lands exactly on the settlement,
marks it visited, and enables entry; teleport sets exact coordinates; full scene flow
main menu -> world map -> settlement -> world map -> main menu with the world intact.

**Windowed run (real rendering, real frame loop)**

```
godotc --path "<project>" -- --autostart-campaign=4321 --autotravel=brackenford
[WorldMap] world map loading
[WorldBuilder] player party placed at Greywatch
[WorldBuilder] world built: 4 settlements, 4 roads
[Travel] travelling to Brackenford (936 units, ~6.2 game hours)
[Travel] arrived at Brackenford on Day 1 - 14:08     <- 13 s of real time later
```

## Known limitations

1. Combat, recruitment and encounters do not exist yet (Steps 3-5).
2. A settlement screen is a functional placeholder: it shows the town and lets you
   leave. Recruitment and the roster arrive in Step 3.
3. The world map is drawn procedurally (land, grid, roads, markers) - no terrain
   artwork, no rivers, no fog of war.
4. Travel is a straight line; the party is not obstructed and there are no
   overworld parties to meet yet.
5. Only the single default save slot is used.
6. `Settlement.market` and `Soldier.equipment` remain empty placeholders.
7. No export templates installed - the project runs from source only.

## Next milestone

**Step 3 - Soldiers and recruitment.** Unit archetypes from data, procedural names,
recruit pools that deplete, the party roster, and the soldier detail panel.
