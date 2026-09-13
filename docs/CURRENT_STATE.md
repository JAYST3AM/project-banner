# Current State

What is actually playable and verified **right now**. Update after every milestone.

**Last updated:** end of Step 1 (`milestone-01`)
**Engine:** Godot 4.7.2-stable
**Test status:** `124 assertions, 0 failures` - `godotc --headless --path "<project>" res://scenes/dev/tests.tscn`

---

## What you can do today

| Action | Works? | Notes |
| --- | --- | --- |
| Launch the game | Yes | Boot splash -> main menu |
| Create a campaign | Yes | Name + optional reproducible world seed |
| Continue a campaign | Yes | Enabled only when a save exists; shows day, gold, party size |
| Save a campaign | Yes | `Save & Quit to Menu` on the world-map placeholder; writes `user://saves/slot_1.save` |
| See the world map | Placeholder | A summary panel; the real overworld is Step 2 |
| Move on the world map | No | Step 2 |
| Visit a settlement | No | Step 2 |
| Recruit soldiers | No | Step 3 |
| Fight a battle | No | Steps 4-5 |

## What is verified, and how

All of the following are asserted by the headless suites, not claimed by hand:

**`tests/test_core_services.gd` (83 assertions)**

- `data/config/game_config.json` parses, and every tunable the code reads exists
  (a typo'd config path fails the build rather than silently defaulting)
- Clock: 2 real seconds = 1 game hour at normal speed, 3x at fast, nothing while
  paused; midnight rollover; clock survives a save round-trip
- RNG: the same campaign seed replays the same sequence; named streams do not
  interfere with each other
- Save/load round-trip on a campaign containing a soldier with level, XP, HP,
  kills, battle counts, traits and personal history, plus a settlement and an
  enemy party - every field comes back, and the next generated soldier id does
  not collide with a loaded one

**`tests/test_campaign_flow.gd` (41 assertions)**

- New campaign applies config defaults (gold, day, hour, speed, empty party)
- A second campaign fully replaces the first (no leaked soldiers or state)
- Real scene transitions: world map -> main menu -> back, with the same
  `CampaignState` object throughout
- Exactly one instance of each of the five singletons exists after transitions
  (no duplicated globals)
- Continue: save -> drop the live campaign -> load, with campaign id, gold, day,
  position, party membership and soldier identity all intact

## Known limitations

1. The world map is a placeholder panel; there is no movement, no settlements on
   screen and no time advancing in the world yet (Step 2).
2. Combat, recruitment and encounters do not exist yet (Steps 3-5).
3. `SaveManager.SLOT_DEFAULT` is the only slot used; multi-slot UI and
   `MIGRATIONS` are wired but empty until the save shape actually changes.
4. The debug panel (teleport/gold/speed) is Step 2.
5. `Settlement.market` and `Soldier.equipment` are intentionally empty
   placeholders; nothing reads them yet.
6. No export templates installed - the project runs from source only.

## Next milestone

**Step 2 - World map prototype.** Travel, four settlements, roads, campaign time
advancing during travel, world HUD, and the debug panel.
