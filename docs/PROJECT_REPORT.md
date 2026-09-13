# Project Banner — Full Project Report

**Purpose of this document:** a single, self-contained orientation for an external
reader (human or AI) who needs to understand, review, or advise on Project Banner
without access to the repository.

**Repository state:** `github.com/JAYST3AM/project-banner` (private)
**Revision:** `2b987d9` on `main` — 7 commits, working tree clean
**Engine:** Godot 4.7.2-stable, GDScript only
**Status:** Steps 0–6 of the brief are complete; **the first major checkpoint (the
full vertical slice) is reached and verified.**

> This is a snapshot. `docs/CURRENT_STATE.md` in the repository is the living version
> and is updated every milestone.

---

## 1. What this project is

An original medieval sandbox strategy/RPG, in the structural genre of Sword &
Banner / Mount & Blade / Total War: a traversable world map, settlements you can
enter, individual persistent soldiers you recruit and take into battle, tactical
combat where those specific people can die permanently, and a campaign that saves
and reloads.

**The stated design principle, quoted from the brief:**

> Individual soldiers should feel like people rather than disposable numbers. […]
> If this soldier dies, the player should care. That persistence and emergent
> history should eventually become one of Project Banner's defining features.

**Original-IP constraint (from the brief, and respected):** no assets, maps, names,
factions, lore, UI, code or exact mechanics may be copied from the reference games.
All content in the repository is original. "Project Banner" is a working codename.

**Working method:** Hermes (an AI agent) implemented, tested, debugged and
documented the project; the user acted as director, gameplay tester and
decision-maker.

---

## 2. The vertical slice — what actually works today

```
NEW CAMPAIGN → WORLD MAP → TRAVEL → TOWN → RECRUIT → INDIVIDUAL SOLDIERS
→ WORLD MAP → BANDITS → TACTICAL BATTLE → CASUALTIES → XP → LOOT
→ WORLD MAP → SAVE → CLOSE GAME → LOAD → CONTINUE CAMPAIGN
```

Every step in that chain runs. Concretely, a player can:

- start a campaign with a name and a reproducible world seed, or Continue an
  existing one
- travel the world map in real time at Paused / Normal / Fast
- click a settlement to inspect it (owner, population, recruits, description) and
  travel to it
- enter a town, see who is willing to serve today, recruit named individuals with
  one click or five at a time, inspect any soldier's full record, and leave
- watch three bandit bands wander the map and close on them when they get near
- be stopped by an encounter prompt that **pauses the world** and shows both sides'
  strength, with Attack or Retreat
- fight a real-time tactical battle: units close, strike, miss, and die; the player
  selects units by click, shift-click or drag-box, and right-clicks to move or to
  attack a specific enemy
- see an after-action screen naming the fallen and crediting each survivor with
  their XP, kills and health
- find that those consequences are still there after quitting and relaunching

---

## 3. Repository scale

| Area | Files | Lines |
| --- | --- | --- |
| `scripts/` | 44 GDScript (+49 Godot-generated `.uid` sidecars) | 6,725 |
| `tests/` | 11 GDScript | 3,301 |
| `data/` | 7 JSON | 496 |
| `scenes/` | 8 `.tscn` | 197 |
| `docs/` | 6 Markdown (including this file) | 1,330 |
| **total tracked** | **157** | — |

GDScript is roughly two-thirds production code and one-third tests. The `.uid` files
are Godot-generated resource identifiers and are committed deliberately (Godot
rewrites them otherwise).

### Commit history

| Commit | Milestone |
| --- | --- |
| `dccf2d8` | milestone-00: bootstrap Godot development environment |
| `a56fa09` | milestone-01: establish project architecture and campaign foundation |
| `212cce0` | milestone-02: implement playable world map and settlement travel |
| `43507ad` | milestone-03: implement persistent soldiers, recruitment and party roster |
| `85bc3df` | milestone-04: connect world encounters to tactical battle scenes |
| `4770e6b` | milestone-05: complete first end-to-end combat gameplay loop |
| `2b987d9` | milestone-06: validate persistent campaign save and load |

---

## 4. Architecture

### 4.1 Layers

```
UI / scenes      main menu, world map, settlement, battle, battle results
gameplay         travel, overworld parties, encounters, recruitment,
                 battle simulation, battle resolution
data model       CampaignState, Party, Soldier, Settlement, WorldParty
services         config, RNG, save, scene, logging
```

The dependency arrow only points downward. **Gameplay logic never lives in a scene
script** — the battle is the clearest case: `BattleSimulator` resolves combat as
pure data and `battle.tscn` only draws its state and forwards player orders into
it. That is what makes the whole combat loop testable headlessly.

### 4.2 Autoloads (exactly five)

| Autoload | Owns |
| --- | --- |
| `DebugLogger` | categorised, levelled logging with a ring buffer |
| `GameData` | the loaded `GameConfig` and cached `data/` JSON |
| `SaveManager` | save files, version migration |
| `SceneManager` | every scene transition + one-shot transition payloads |
| `GameManager` | **the active `CampaignState`** |

The rule applied: a system becomes a singleton only if it must outlive a scene
transition. Combat maths, travel, recruitment and name generation fail that test
and are ordinary classes — which also makes them directly testable.

`GameManager` deliberately *owns* the campaign rather than *being* it, so a test can
build a `CampaignState` without touching global state.

Autoload scripts must not declare `class_name` (Godot rejects a class name that
collides with a singleton name).

### 4.3 Load-bearing rules

These are the invariants the design hangs on. Breaking any of them reintroduces a
bug class that has already been seen.

1. **A soldier's identity lives in `CampaignState.soldiers` and nowhere else.**
   `Party` stores **ids**, not objects. If a party held `Array[Soldier]`, one person
   would be serialised twice and a load could produce two live objects for one
   soldier.
2. **`BattleContext` is the only channel between campaign and battle.** The battle
   scene never reads `GameManager.campaign` and never consults a unit catalog. Its
   rosters arrive as snapshots carrying `soldier_id` *and* fully resolved stats.
   Adding an ambush, a siege or a scripted battle later means building a different
   context, not changing the battle scene.
3. **A battle is described before it is applied.** `BattleResolver.build_result()`
   computes the entire outcome and mutates nothing; `apply()` is the only function
   in the project that lets a battle change the campaign. A quit, crash or debug
   exit mid-fight therefore cannot leave a soldier half-dead in a save file.
4. **Time conversion exists only in `CampaignClock`.** Movement and AI ask the clock
   how many game hours elapsed; they never convert seconds themselves.
5. **All balance numbers live in `data/*.json`**, read by dotted path with an
   explicit default (`config.get_float("xp.per_kill", 20)`). A typo'd path silently
   returns the default instead of crashing, so a test asserts that every path the
   code reads actually exists.

### 4.4 Data model

| Class | Notes |
| --- | --- |
| `CampaignState` | root of everything persistent |
| `Soldier` | one person: name, age, archetype, level, XP, HP, kills, battles fought/survived, morale, loyalty, traits, status, **personal history log** |
| `Party` | membership only (soldier ids) |
| `Settlement` | position, type, owner faction, population, recruit pool + base pool, market placeholder |
| `WorldParty` | an overworld marker: kind, behaviour, position, home, wander radius/count, encounter cooldown, defeated flag |
| `CampaignClock` | day, hour, speed (Paused/Normal/Fast), resume-speed memory |
| `GameConfig` | dotted-path access to the JSON config |
| `RngService` | named, deterministic RNG streams |
| `DataUtils` | JSON ↔ Godot type helpers, dependency-free |

### 4.5 Scene flow

```
main.tscn (boot splash)
 └── ui/main_menu.tscn
      └── world/world_map.tscn
           ├── settlements/settlement.tscn
           └── battle/battle.tscn
                └── battle/battle_results.tscn  →  back to world_map
```

`SceneManager.SCENES` is the single registry of keys → paths. No script hardcodes a
scene path. Scenes never guess why they were opened: the caller passes a payload
and the incoming scene consumes it exactly once.

---

## 5. Determinism

A campaign is defined by `CampaignState.campaign_seed`. `RngService` derives a
separate named stream per subsystem, so the same seed always produces the same
world and one system consuming randomness cannot shift another's results.

Seeds use a hand-written FNV-1a hash rather than Godot's built-in `hash()`, because
the built-in makes no cross-version stability guarantee — a campaign seed that
changed meaning after an engine upgrade would silently rewrite a saved world.

Two systems that need randomness without storing generator state derive it from a
counter instead:

- **soldier names** from `seed :: name:<soldier_index>:<attempt>`
- **party wander targets** from `seed :: wander:<party_id>:<wander_count>`

Verified empirically: two separate processes with seed 4321 produced byte-identical
soldier names and an identical battle seed.

---

## 6. The content data (verbatim from `data/`)

### 6.1 Unit archetypes

| id | HP | atk | def | range | cooldown | move | cost | recruitable |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `peasant_recruit` | 34 | 5 | 2 | 1.8 | 1.25 | 5.6 | 20 | yes |
| `spearman` | 42 | 7 | 4 | 2.4 | 1.50 | 5.0 | 55 | yes |
| `archer` | 28 | 6 | 1 | 9.0 | 2.00 | 5.4 | 45 | yes |
| `bandit_ruffian` | 28 | 4 | 1 | 1.8 | 1.40 | 5.2 | — | no |
| `bandit_brigand` | 40 | 7 | 3 | 2.2 | 1.60 | 4.8 | — | no |
| `bandit_archer` | 24 | 6 | 0 | 9.0 | 2.20 | 5.5 | — | no |

Ranged units attack from range without closing. Melee ranges are deliberately larger
than the minimum gap the overlap resolver maintains (1.35) — see §10, bug 1.

### 6.2 The starting region

1600 × 900 world space.

| Settlement | Type | Owner | Pop | Position | Recruit pool |
| --- | --- | --- | --- | --- | --- |
| Greywatch | town | House Caldreth | 1800 | (300, 620) | 7 recruit / 3 spear / 2 archer |
| Brackenford | town | House Caldreth | 2400 | (1180, 300) | 9 recruit / 4 spear / 3 archer |
| Redmoor | village | House Varengard | 420 | (620, 220) | 4 recruit / 2 archer |
| Thornwood Hollow | wilderness | unclaimed | 0 | (880, 700) | — |

Roads: Greywatch–Redmoor–Brackenford, plus tracks from Greywatch and Brackenford to
Thornwood Hollow. Travel is **not** restricted to roads; they are a distance hint
and a hook for later logistics. Pools deplete as you buy and restock every 4 days.

### 6.3 Hostile parties

| Spawn | Template | Size | Composition | Behaviour |
| --- | --- | --- | --- | --- |
| near Thornwood Hollow | Road Bandits | 5–8 | ruffian 6 / brigand 1 / archer 1 | wander 120 units |
| near Greywatch | Road Bandits | 5–8 | as above | wander 120 units |
| near Redmoor | The Broken Men | 6–8 | brigand 4 / ruffian 4 / archer 2 | wander 90 units |

Aggro radius 190 units; encounter trigger radius 26; 3-hour cooldown after a retreat.

### 6.4 Traits

| Trait | Polarity | Modifiers |
| --- | --- | --- |
| cowardly | negative | morale −18 |
| brave | positive | morale +14 |
| steady | neutral | — |
| loyal | positive | loyalty +18 |
| greedy | negative | loyalty −14 |
| tough | positive | hp +12 % |
| frail | negative | hp −12 % |
| keen_eyed | positive | attack +8 % |
| clumsy | negative | attack −8 % |
| quick | positive | move speed +8 % |

Recruits roll 1–2 traits; 35 % chance per slot of drawing from the negative pool.
**Morale, loyalty and hp modifiers are applied at recruitment. Attack and move-speed
modifiers are applied when a battle unit is built from a soldier.** Morale and
loyalty currently have no mechanical effect beyond display.

### 6.5 Config values that matter

| Key | Value |
| --- | --- |
| starting gold / max party | 250 / 24 |
| real seconds per game hour | 2.0 |
| speed multipliers | paused 0, normal 1, fast 3 |
| travel pace | 150 world units per game hour |
| party-size speed penalty | 1.2 % per soldier, floor 55 % |
| arrival radius | 16 units |
| battle field | 100 × 60, deploy depth 20, margin 8 |
| separation radius | 1.5 (× 0.9 = 1.35 minimum gap) |
| hit chance | 0.75 |
| defence mitigation | 5 % per point, capped at 70 % |
| max battle duration | 600 s |
| XP | participation 10, per kill 20, survived 15, victory 25 |
| level curve | 100 × 1.35^(level−1), max level 40 |
| per level | +3 max HP, +1 attack |
| recruitment age band | 17–33 |
| rewards | 8–14 gold per enemy defeated, +25 victory, 0–2 loot rolls |

---

## 7. The combat model (precisely, so it can be reasoned about)

**Damage.** `raw = attack × random(0.85 … 1.15)`; `reduction = min(0.7, defence ×
0.05)`; `damage = max(1, round(raw × (1 − reduction)))`. A separate roll against
`base_hit_chance` decides whether the blow lands at all.

**Targeting.** A unit seeks the nearest living enemy, closing until within
`attack_range`, then stands and strikes on its cooldown. Dead targets are dropped and
re-targeted. An explicit player attack order overrides automatic selection until the
ordered target dies.

**Orders.** Left click selects, shift-click adds, drag-box selects; a click on empty
ground clears. Right-click on an enemy orders an attack; right-click on open ground
orders a move. Orders may be issued before `Start Battle`.

**Deaths.** `take_damage` returns whether the blow was the killing one; the killer's
kill count increments exactly once (a target struck down earlier in the same step is
never hit again, which prevents double-crediting).

**End conditions.** One side with nobody standing wins; the 600-second cap produces a
draw; the player may retreat at any time, which is a distinct outcome (the enemy
holds the field, nobody was routed).

**Resolution.** `BattleResolver.build_result()` computes winner, survivors and fallen
(each with kills and damage), XP per survivor, and — on victory only — gold from the
fallen, a victory bonus, and 0–2 looted items sold immediately for coin. `apply()`
then writes: battles fought/survived, kills, hit points, XP with level-ups (+3 max HP
per level, current HP raised by the same amount), a human-readable history entry per
soldier, the gold, and the fate of the enemy party. A bounded JSON-safe chronicle of
the last 40 battles is kept in the campaign.

**Balance as measured.** Across 24 campaign seeds, five freshly recruited peasants:

| Opponent | Won | Enemy casualties |
| --- | --- | --- |
| the weakest bandit band (the careful choice) | **20 / 24** | 122 |
| the strongest bandit band | **3 / 24** | 77 |

Player choice therefore matters more than luck. Fights are decisive, not stalemates.
Three real windowed playthroughs produced: a defeat (2 of 6 enemies down), a narrow
victory (1 of 5 survivors, 6 of 6 enemies down, 102 gold), and a solid victory (4 of 5
survivors, 5 of 5 enemies down, 88 gold, 280 XP).

---

## 8. Persistence

- **Format:** indented JSON at `user://saves/slot_1.save` — readable and
  hand-editable, which is worth far more during development than a compact blob.
- **Versioning:** `save_version` (currently 1) plus the writing build's
  `app_version`. A save from a **newer** build is refused rather than misread, and
  the main menu says so instead of offering a Continue that cannot work.
- **Migration:** a table of *from-version* → `Callable`, walked forward one step at a
  time. A real v0 → v1 step ships (an unversioned document whose party membership may
  be a bare array). Beyond that, additive schema changes need no migration at all,
  because `from_dict` reads every field with a default.
- **Persisted:** campaign metadata, seed, day/hour/speed, world position, destination
  in progress, gold, party membership and order, every soldier (name, age, archetype,
  level, XP, HP, kills, battles fought and survived, morale, loyalty, traits,
  alive/dead status, full history), settlements with visited flags and depleted
  recruit pools, every enemy party with positions, rosters and defeated flags, the
  battle chronicle, and an arbitrary extension bag.

---

## 9. How the project is verified

The working rule is: **never claim something works unless it has been run.**

### 9.1 Headless suites — 8 suites, 1,207 assertions, 0 failures

| Suite | Assertions | Covers |
| --- | --- | --- |
| `test_core_services` | 83 | config presence, clock maths, RNG determinism, save round-trip |
| `test_campaign_flow` | 41 | campaign lifecycle, scene transitions, singletons, Continue |
| `test_world_map` | 88 | world from data, travel, arrival, speed states, persistence |
| `test_recruitment` | 191 | unit/trait data, names, factory, recruitment rules, party limits |
| `test_encounters` | 282 | spawning, movement, aggro, detection, `BattleContext`, deployment, simulator |
| `test_combat` | 266 | damage, death, attribution, victory conditions, results, resolver, balance |
| `test_e2e_loop` | 127 | **the Step 5 critical end-to-end path, through the real scenes** |
| `test_persistence` | 129 | every persisted field, migration, refusal, corrupt files |

Suites may `await`, so they drive real scene transitions and real save files. The
end-to-end suite loads the actual battlefield scene and drives its `_process` the way
the engine would.

### 9.2 The restart check — 75 checks, 0 failures

A genuine **two-process** test, because a same-process save/load only proves the
serialiser round-trips and not that the game can be closed and reopened:

```
phase=write    play a campaign, fight a battle to a conclusion, record every fact
               about the resulting world, save, exit
phase=verify   a brand-new process calls the same continue_campaign() the Continue
               button calls, and checks every recorded fact
```

It asserts, among other things, that the loaded world was **not** rebuilt over the
save, and that re-saving is stable. Result: `26 soldiers restored, 9 of them dead`,
every field identical.

### 9.3 The test harness guards against false greens

This is worth stating plainly, because it happened. GDScript has no exceptions: when
`script.new()` was called on a suite that had failed to compile, the runtime error
aborted the runner *before* it could record a failure, and the run printed
`RESULT: PASS` with 212 green assertions while a 188-assertion suite had not run at
all. The runner now refuses to pass a suite that fails to load, fails to compile, or
records zero assertions, and fails the run if fewer suites reported than expected.

**A test harness that can report a silent false green is worse than no harness,
because it converts "I did not check" into "I checked and it is fine."**

### 9.4 Windowed verification

Development switches let the real, rendered game be driven without a mouse
(`--autostart-campaign`, `--autostart-town`, `--autorecruit`, `--autoleave`,
`--autoengage`, `--autoattack`, `--autostart-battle`, `--battlespeed`). They exercise
the real button handlers, and the log records the outcome so it can be read back.

---

## 10. Bugs found, and how

Recording these because they indicate where the risk actually lives.

### Bug 1 — melee combat was completely inert (found by the balance test)

`_resolve_overlaps()` pushed units apart to 1.35 units every step. Melee
`attack_range` was 1.0–1.6. So a melee unit closed, was pushed back, and **never
satisfied the in-range condition** — it could not land a blow.

This hid well. Bandit *archers* (range 9.0) kept working, so fights looked
functional: the player's party would be shot to death and the fight would end. The
tell was the casualty count, not an error: **24 simulated openings produced 24 losses
and 0 enemy casualties.** A number that is impossible is easier to notice than a
number that is merely wrong.

Fixed by raising melee ranges above the separation gap, and guarded by two
assertions — one that every non-ranged archetype's range exceeds
`separation_radius × SEPARATION_FACTOR`, and one that a melee-only fight produces
damage. Either alone would have caught it.

### Bug 2 — fallen soldiers' kills were never written back

`apply()` wrote kills for survivors but not for the fallen. Found by an end-to-end
assertion that the party's total kills must equal the enemies put down (5 dead, 4
recorded). A soldier who killed someone before they fell did so; losing that
quietly rewrites the record of a fight that actually happened.

### Bug 3 — the test runner could report a false green

Described in §9.3.

### Also encountered (recipe-level)

`log()` collides with the global natural-log function; `trait` is a reserved GDScript
keyword; adding a `class_name` script requires re-running `--import` to refresh the
global class cache; and a function containing `await` must be awaited by its caller
even when it returns a value.

---

## 11. What is *not* implemented

The honest list of gaps.

**Combat depth**

1. **Flat battlefields.** `terrain_seed` is generated and carried in the battle
   context and read by nothing. No cover, elevation, obstacles or rivers.
2. **No formations.** Units seek the nearest enemy and pile in. No ranks, no lines,
   no held formation.
3. **No morale behaviour or fleeing.** A unit fights to its last hit point. Morale is
   tracked and displayed but does not affect anything.
4. **No cavalry and no anti-cavalry role** for the spear, which the brief anticipated.
5. **No projectiles.** Ranged hits apply immediately with a floating damage number;
   ammunition is unlimited.
6. **No wounds, fatigue, or weather effects.** Weather is a placeholder string in the
   context.

**Soldier depth**

7. **No equipment or inventory.** `Soldier.equipment` and `Settlement.market` are
   empty placeholders. Loot is sold for coin on the spot.
8. **No recovery.** Survivors return at whatever hit points they ended with; no
   treatment, no healing over time.
9. **Traits are partially mechanical** (see §6.4).
10. **No troop upgrade trees**, despite `upgrade_to` being authored on the archetypes.
11. **No character aging, permadeath-of-retirement, or relationships.**

**Campaign depth**

12. **A wiped party is not a game over.** The campaign continues with an empty party
    and you can walk back to a town and recruit again. Prisoners, capture and ransom
    are future work.
13. **Only bandit parties exist.** Caravans, patrols and lord armies have the data
    model (`WorldParty`, `Party.kind`) but no spawn data or behaviour.
14. **No ambushes** — the context supports them (`build_context(party, false)` flips
    attacker and defender) but nothing calls it that way.
15. **No factions, diplomacy, wars, territory, castles, sieges or kingdom creation.**
16. **No trade, production, or supply and demand.**
17. **No procedural world generation** — the starting region is authored data.
18. **No world events, politics or relationships.**

**Presentation and tooling**

19. **No artwork.** The world map and battlefields are drawn procedurally with
    `_draw()`.
20. **Single save slot.** Multi-slot UI is not built.
21. **No export templates installed** — the project runs from source only.
22. **Balance is deliberately rough.** Fights work and are decisive; they are not
    tuned for a long campaign.

---

## 12. Design decisions worth knowing (the ones that would be expensive to reverse)

| # | Decision | Why |
| --- | --- | --- |
| D-005 | The data model was completed in Step 1, ahead of its milestones | Growing a data class is cheap; changing the serialised shape of a save after saves exist is not |
| D-016 | Names derive from seed + index, not a stored generator | No generator state in the save, and generating a name never disturbs another system's stream |
| D-019 | `BattleContext` is the only campaign↔battle channel | An ambush, siege or scripted battle becomes a different context object and nothing else |
| D-020 | Battle snapshots carry identity *and* resolved stats | Satisfies two opposing needs: know exactly who is on the field, without mutating them or reaching into a catalog |
| D-024 | A battle is described before it is applied | Makes the failure mode "the battle did not happen" rather than "the battle half-happened" |
| D-027 | Balance is asserted as a range at both ends, and printed | A test that reports what the game currently *feels like*, not just whether the code runs |
| D-030 | Persistence is proven across two processes | A same-process round-trip can pass while the game cannot actually be reopened |
| D-031 | A save from a newer build is refused, not read | Reading it anyway silently discards what it does not understand, which is the worst player outcome |

Decisions D-006 to D-032 are recorded in full in `docs/DECISIONS.md`.

---

## 13. Working backwards from here

The brief lists post-checkpoint systems. Ordered by how much they lean on what
already exists:

1. **Battlefield terrain and formations.** `terrain_seed` is already carried through
   the context; this is the largest single improvement to how a fight feels.
2. **Ranged projectiles, then cavalry and the spear's anti-cavalry role.** The
   archetypes already carry `ranged`, `attack_range` and a reserved `upgrade_to`.
3. **Soldier depth: equipment, wound recovery, and traits that do something
   mechanical.** `Soldier.equipment` and the trait modifier table are already in
   place; the modifiers just need consuming.
4. **Surfacing personal history.** The records are *already being written* — every
   recruit gets "swore service at Greywatch", every fight writes "Killed 3 at
   Thornwood Hollow and lived" or "Killed at the hands of Anselm Millbrook". The
   machinery for soldiers-as-people exists and is persisted; it simply is not shown
   back to the player yet. This is the shortest path to the brief's stated defining
   feature.
5. **Overworld life:** caravans, trade, settlement production, supply and demand.
6. **Grand strategy:** factions, lords, armies, wars, diplomacy, territory, castles,
   sieges, prisoners, mercenaries, kingdom creation.
7. **World generation:** procedural map and political simulation.

---

## 14. Open questions a reviewer could usefully weigh in on

1. **Balance direction.** The opening fight is currently 20/24 winnable against the
   weakest band and 3/24 against the strongest. Is that the right shape for a game
   where soldiers are meant to matter — or should the early game be harsher, or
   gentler?
2. **Party wipe.** Losing everyone currently leaves you with an empty party and no
   penalty beyond that. Is that acceptable, or does the vertical slice need a real
   consequence (capture, ransom, a fresh start) before the loop feels meaningful?
3. **What to build next.** Terrain and formations versus soldier-depth and history
   surfacing. The second is closer to the brief's stated defining feature; the first
   is more visible value per unit of work.
4. **Morale.** It is tracked on every soldier and displayed, but does nothing. Should
   it drive fleeing, or affect combat rolls, or both?
5. **Where the prototype's seams show.** Which of §11's gaps are load-bearing for the
   game's identity and which are genuinely deferrable?

---

## 15. How to run any of this

```bash
PROJ="F:/VSC Projects/Project Banner"

# play
godot --path "$PROJ"

# every test suite (exit 0 = pass)
godotc --headless --path "$PROJ" res://scenes/dev/tests.tscn
# one suite
godotc --headless --path "$PROJ" res://scenes/dev/tests.tscn -- --suite=combat

# prove a campaign survives closing the game (two processes, on purpose)
godotc --headless --path "$PROJ" res://scenes/dev/persistence_check.tscn -- --phase=write
godotc --headless --path "$PROJ" res://scenes/dev/persistence_check.tscn -- --phase=verify

# drive the real rendered game without a mouse
godotc --path "$PROJ" -- --autostart-campaign=2026 --autostart-town=greywatch \
        --autorecruit=5 --autoleave --autoengage --autoattack \
        --autostart-battle --battlespeed=8
```

**Godot 4.7.2-stable.** `godotc` is the console build; the plain `godot` executable
detaches from the console on Windows and prints nothing.

| Document | Contents |
| --- | --- |
| `docs/GAME_ARCHITECTURE.md` | core systems, state ownership, scene hierarchy, communication |
| `docs/ROADMAP.md` | milestone plan and progress |
| `docs/CURRENT_STATE.md` | what is playable and how it is verified (living) |
| `docs/DECISIONS.md` | 32 recorded technical and design decisions |
| `docs/DEVELOPMENT_ENVIRONMENT.md` | toolchain, paths, full command reference |
