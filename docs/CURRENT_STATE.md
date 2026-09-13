# Current State

What is actually playable and verified **right now**. Update after every milestone.

**Last updated:** end of Step 3 (`milestone-03`)
**Engine:** Godot 4.7.2-stable
**Test status:** `400 assertions, 0 failures, 4 of 4 suites` -
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
| Enter a settlement | Yes | Once the party arrives |
| Inspect a settlement | Yes | Owner, population, recruits, date, gold, party size |
| **Recruit soldiers** | **Yes** | Named individuals with cost, traits, morale, loyalty |
| **Inspect a soldier** | **Yes** | Full record incl. traits and personal history |
| **See the party roster** | **Yes** | Live list with level, class, health |
| Save the campaign | Yes | "Save Game" or F5 |
| Debug panel | Yes | F1: teleport, gold, speed, coordinates |
| Encounter bandits | No | Step 4 |
| Fight a battle | No | Steps 4-5 |

### Recruiting

Walk into Greywatch or Brackenford. The middle column lists what is available
today, with the cost, the archetype's stats and - if you cannot afford one or the
town has none - a plain-English reason instead of a dead button. Recruit one, or
recruit five at a time. The right column is your party; click anyone to read their
full record: age, class, level, health, experience, kills, battles fought and
survived, morale, loyalty, traits, and a personal history log that already records
where and when they swore service.

Recruit pools deplete as you buy from them and restock every few days.

## What is verified, and how

All of the following are asserted by the headless suites or by a real windowed run,
not claimed by hand.

**`test_core_services.gd` (83)** - config loads and every tunable the code reads
exists; clock maths; RNG determinism per named stream; save/load round-trip.

**`test_campaign_flow.gd` (41)** - campaign creation, replacement, real scene
transitions preserving one `CampaignState`, one of each singleton, continue.

**`test_world_map.gd` (88)** - world built from data; party starts at the configured
town; `build_if_needed` never rebuilds over saved state; travel pace, arrival,
visited flags, speed states, wilderness rejection, party-size slowdown, no-op
orders; world survives save/load; full scene flow.

**`test_recruitment.gd` (188)** - unit and trait data load and validate; archetypes
are differentiated (recruits frailer and cheaper than spearmen, archers outrange
spearmen) and the progression curve raises HP and attack with level; names are
unique, deterministic per seed, different across seeds, and ages stay in band;
the factory fills every field and refuses unknown archetypes; trait modifiers
demonstrably shift starting morale and hit points; recruitment refuses when away
from the town, when the pool is empty, when gold is short and when the party is
full - each with a readable reason - and a refused recruit changes nothing;
a successful recruit deducts exactly once, decrements the pool, registers the
soldier, and adds them to the party; batch recruiting stops at the pool and at the
party cap across all three towns; soldiers survive travel and a save/load with
traits and history intact. Plus the milestone's own end-to-end path: enter town ->
recruit 3 -> inspect -> leave -> travel to another town -> come back -> the same
soldiers are still there.

**Windowed run (real rendering, real buttons)**

```
godotc --path "<project>" -- --autostart-campaign=4321 --autostart-town=greywatch --autorecruit=4
[Settlement] entered Greywatch
[Recruitment] recruited Selwin Eastmere (Peasant Recruit, 20 gold) at Greywatch - 230 gold remaining, 1/24 party
[Recruitment] recruited Wilkin Woolmer ... 2/24 party
[Recruitment] recruited Herrick Bexley ... 3/24 party
[Recruitment] recruited Jarl Carrow   ... 4/24 party
```
with no script errors. `--autorecruit` calls the same handler the Recruit button
does, so the UI rebuild path is exercised too.

## Known limitations

1. Combat and encounters do not exist yet (Steps 4-5). A recruited soldier cannot
   yet be taken into a fight.
2. Trait modifiers for attack and movement are stored in `data/traits/traits.json`
   but only the morale/loyalty/hit-point ones are applied so far; the combat ones
   are consumed when a fighting unit is built from a soldier in Step 5.
3. Recruit pools restock on entry to a settlement once `world.restock_days` have
   passed; there is no notification that a pool has restocked.
4. The world map is drawn procedurally - no terrain artwork, no fog of war.
5. Travel is a straight line; no overworld parties to meet yet.
6. Only the single default save slot is used.
7. `Settlement.market` and `Soldier.equipment` remain empty placeholders.
8. No export templates installed - the project runs from source only.

## Next milestone

**Step 4 - World encounters and the battle transition.** Bandit parties on the
overworld, the encounter prompt with both sides' strength, and a `BattleContext`
that carries everything the battle scene needs.
