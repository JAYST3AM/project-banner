# Project Banner — Full Project Report

**Purpose of this document:** a single, self-contained orientation for an external
reader (human or AI) who needs to understand, review, or advise on Project Banner
without access to the repository.

**Repository state:** `github.com/JAYST3AM/project-banner` (public)
**Revision:** `main` at the Step 7.1 formation hardening — 16 commits, working tree clean
**Engine:** Godot 4.7.2-stable, GDScript only
**Status:** Steps 0–6 of the brief are complete and independently foundation-locked
(6.5 audit remediation, 6.6 lock), **Step 7 — Tactical Combat 2.0: terrain and formation
foundation** is complete, and **Step 7.1** has hardened its edge cases. **The first major
checkpoint (the full vertical slice) is reached and verified**, on a clean CI runner as
well as locally.

> This is a snapshot. `docs/CURRENT_STATE.md` in the repository is the living version
> and is updated every milestone.

**Read this first if you are reviewing:** section 10 is the most useful part. Step 6.5
was a hardening pass over work already thought finished, triggered by an external
review that found seven defects, and **six of the seven were silent** — the game ran
and looked correct while behaving wrongly. Section 10.4 covers them, including which
one was found only by asking "could a broken test suite still pass?" and measuring the
answer instead of assuming it.

Step 7 added two systems and a measuring tool, and section 10.6 covers the two defects
it found — one of which was **a battle that could not end**, found by running the game
rather than by reading it. Section 7 covers what terrain and formations do, and
section 9.1 reports what they cost at 100 to 5,000 soldiers, measured rather than
asserted.

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
| `scripts/` | 50 GDScript (+55 Godot-generated `.uid` sidecars) | 9,243 |
| `tests/` | 25 GDScript (16 suites, 2 harness files, the restart check, 6 fixtures) | 6,688 |
| `data/` | 9 JSON | 586 |
| `scenes/` | 9 `.tscn` | 203 |
| `.github/workflows/` | 1 YAML | 100 |
| `docs/` | 6 Markdown (including this file) | 3,900+ |
| **total tracked** | **190+** | — |

GDScript is roughly three-fifths production code and two-fifths tests. The `.uid`
files are Godot-generated resource identifiers and are committed deliberately (Godot
rewrites them otherwise).

The fixtures under `tests/fixtures/` are deliberately malformed suites — one aborts
mid-run, one returns early, one asserts nothing, one is not a suite at all — used by
`test_runner_contract.gd` to prove the runner detects them. They are kept out of the
runner's `SUITES` list, since several are meant to fail.

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
| `a0bf817`, `cf9c69a` | the full project report, and a README for a public reader |
| `24ae05d`, `484b4a8` | milestone-06.5: harden the vertical slice after an external audit |
| `128d07e`, `2d7d65c` | milestone-06.6: lock the Steps 0–6 foundation |
| `17afd2b` | docs: the CI gate was proven able to go red, not only green |
| `c4c2bd2` | milestone-07: establish terrain and formation warfare foundation |
| `ccf9cff` | milestone-07.1: harden formation ownership and contact semantics |

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

**Formation.** A soldier in a formation fights what it can reach and otherwise walks to
the slot its formation gave it — it does not pick its own ground and does not chase. A
formation moves as a body at the pace of its slowest soldier, turns toward
`desired_facing` at its type's turn rate, and reforms by its soldiers walking to new
slots. Its order is `engage` (default), `hold` or `move`. Cohesion — the mean distance
between each soldier and its slot, normalised and inverted, so `1.0` is dressed — is
recomputed every step and consumed by nothing yet. See D-046 through D-050.

**Ground.** Terrain multiplies a unit's speed by the cell it is standing on, and a
formation's pace by the cell under its centre. In woods (0.6) a body crosses at
three-fifths the speed it manages on open ground. Terrain has no other effect.

**Orders.** Left click selects, shift-click adds, drag-box selects; a click on empty
ground clears. Right-click on an enemy orders an attack; right-click on open ground
orders the selected formations to move — or, if the selection is part of one, detaches
those soldiers into a body of their own and sends that. `1`/`2`/`3` order line, column
or loose on the selection; `Q`/`E` turn it; `H` holds; `G` engages; `F3` shows the
formation overlay. Orders may be issued before `Start Battle`, and a formation given a
shape before the start walks into it when the fighting begins.

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

**Balance as measured.** Across 24 campaign seeds, five freshly recruited peasants,
fighting **without formations** (this is the pre-Step-7 measurement, and it is the
unformed path that `test_combat` still gates):

| Opponent | Won | Enemy casualties |
| --- | --- | --- |
| the weakest bandit band (the careful choice) | **20 / 24** | 122 |
| the strongest bandit band | **3 / 24** | 77 |

Player choice therefore matters more than luck. Fights are decisive, not stalemates.
Three real windowed playthroughs produced: a defeat (2 of 6 enemies down), a narrow
victory (1 of 5 survivors, 6 of 6 enemies down, 102 gold), and a solid victory (4 of 5
survivors, 5 of 5 enemies down, 88 gold, 280 XP).

**The formed path is a separate, smaller measurement**, because formations change the
shape of a fight and the 24-seed figure above does not cover them. Four windowed runs of
five recruits against whatever band the seed produced: two victories (5 of 5 survivors,
6 of 6 and 5 of 5 enemies down, 89 gold and 350–370 XP) and two defeats (one against five
enemies with 4 of 5 down, one against eight with only 3 of 8 down). Outcomes track the
size of the band, which is the right behaviour and not evidence of a systematic swing.
**A proper formation-path balance sweep is not done** and is listed as an open item in
§11 — the number above should not be read as covering it.

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

### 9.1 Headless suites — 16 suites, 2,207 assertions, 0 failures

| Suite | Assertions | Covers |
| --- | --- | --- |
| `test_core_services` | 83 | config presence, clock maths, RNG determinism, save round-trip |
| `test_campaign_flow` | 41 | campaign lifecycle, scene transitions, singletons, Continue |
| `test_world_map` | 88 | world from data, travel, arrival, speed states, persistence |
| `test_recruitment` | 191 | unit/trait data, names, factory, recruitment rules, party limits |
| `test_party_semantics` | 51 | **roster membership vs active force** — travel pace, HUD wording, capacity, the dead kept on the record |
| `test_encounters` | 282 | spawning, movement, aggro, detection, `BattleContext`, deployment, simulator |
| `test_combat` | 266 | damage, death, attribution, victory conditions, results, resolver, balance |
| `test_battle_outcomes` | 224 | **victory / defeat / draw / withdrawal**, the retreat farming loop, timeout freezing the field, results-screen wording |
| `test_terrain` | 72 | **deterministic ground** — same seed same field, different seed different field, bounds, movement modifiers, terrain actually changing movement, the slope contract at the edge of the field, independence from rendering |
| `test_formation` | 328 | **formations as physical objects** — geometry across seven facings, distinct slots, ownership and partial detachment, repeated transfers, movement without teleporting, turning, reformation, cohesion, casualties leaving gaps, rotated debug bounds |
| `test_formation_battle` | 99 | **both systems together** — both armies formed, the enemy on the same engine, the AI ignoring wiped-out bodies, contact belonging to a body rather than a side, terrain slowing a body, a formed battle resolving and being reproducible, the architecture guardrails, a 500-unit scale smoke |
| `test_enemy_persistence` | 121 | **the same enemy fought twice** — battle → campaign → save/load → second battle |
| `test_e2e_loop` | 147 | **the Step 5 critical end-to-end path**, through the real scenes — including the real `BattleResult` reaching the real results screen |
| `test_persistence` | 154 | every persisted field, migration, refusal, corrupt files, metadata for every save shape |
| `test_legacy_menu` | 30 | **the real main menu scene** against a legacy save — status text, Continue offered, Continue migrating and opening |
| `test_runner_contract` | 30 | **the runner itself** — aborts, early returns, empty suites, non-suites, missing files, filter selection |

Suites may `await`, so they drive real scene transitions and real save files. The
end-to-end suite loads the actual battlefield scene and drives its `_process` the way
the engine would; the legacy-menu suite loads the actual main menu and presses its real
Continue button.

### 9.2 The restart check — 95 checks, 0 failures

A genuine **two-process** test, because a same-process save/load only proves the
serialiser round-trips and not that the game can be closed and reopened:

```
phase=write    play a campaign, fight a battle to a conclusion, break off from a
               second fight, record every fact about the resulting world, save, exit
phase=verify   a brand-new process calls the same continue_campaign() the Continue
               button calls, and checks every recorded fact
```

It asserts, among other things, that the loaded world was **not** rebuilt over the
save, that the withdrawal and the progression rules it applied survived, and that
re-saving is stable. Result:

```
broke off from Road Bandits: WITHDREW, 0 xp, 0 gold, enemy still present: true
wounded s_0008: 28 -> 11 hp, must survive the restart
wrote: 5 soldiers (3 active, 2 dead), 269 gold, 3 enemy parties, save v1
--------- persistence write: PASS (6 checks, 0 failures) ---------
26 soldiers restored, 9 of them dead
--------- persistence verify: PASS (95 checks, 0 failures) ---------
```

The second process sees the withdrawal the first one made — 0 experience, 0 gold,
`battles_survived` untouched — and the bandits still on the map **with the specific
soldier `s_0008` still on the 11 hit points it was wounded to**, not restored to full.
No shared memory beyond the save file.

### 9.3 The test harness guards against false greens

This is worth stating plainly, because it happened twice.

**First:** GDScript has no exceptions. When `script.new()` was called on a suite that
had failed to compile, the runtime error aborted the runner *before* it could record a
failure, and the run printed `RESULT: PASS` with 212 green assertions while a
188-assertion suite had not run at all.

**Second, found by the Step 6.5 audit:** the same class of hole one level deeper. A
suite that compiles, starts running, records some assertions, and *then* hits a runtime
error was still reported as passing — because the assertions it managed to run all
passed. The runner now refuses to pass a suite that fails to load, fails to compile,
records zero assertions, or never reaches its completion marker, and fails the run if
fewer suites reported than expected. A `--suite=` filter matching nothing is also a
failure rather than a zero-suite green.

**A test harness that can report a silent false green is worse than no harness,
because it converts "I did not check" into "I checked and it is fine."**

### 9.4 Windowed verification

The whole loop runs through the actual UI, driven only by development flags:

```
godot --path "<project>" -- \
  --autostart-campaign=24680 --autotravel=greywatch --autostart-town=greywatch \
  --autorecruit=5 --autoleave --autoengage --autoattack --autostart-battle
```

```
scene -> world_map
scene -> settlement
scene -> world_map
scene -> battle
[Encounter] battle battle_0001 at 880,551: player (5) vs enemy (5), clear
[Resolver]  battle_0001: VICTORY - 4 of 5 survived, 5 of 5 enemies down (0 standing), 97 gold, 280 xp
[Resolver]  Road Bandits is destroyed and removed from the map
scene -> battle_results
```

with **zero script errors or warnings**. (The engine prints some shutdown noise under
`--quit-after`; that is teardown, not gameplay.)

### 9.5 The independent gate — GitHub Actions

Local tests prove the suites pass on one machine; they cannot catch a suite that
depends on a local import cache, a leftover save file or a working directory. So the
same two gates run on a clean runner on every push to `main` and every pull request
against it:

```
.github/workflows/godot-tests.yml
  install Godot 4.7.2-stable, then assert `godot --version` reports 4.7.2
  godot --headless --path . --import
  godot --headless --path . res://scenes/dev/tests.tscn           -> must report PASS
  godot --headless --path . res://scenes/dev/persistence_check.tscn -- --phase=write
  godot --headless --path . res://scenes/dev/persistence_check.tscn -- --phase=verify
```

The engine version is pinned by explicit release URL rather than "latest", because a
red run against an unpinned engine would not tell anyone whether the project or the
engine had changed. No verification step uses `continue-on-error`, and every step is
written so the engine's exit status survives the log capture: `set -o pipefail` around
the `tee`, plus an explicit grep for the runner's own `PASS` line, so a run that
somehow exited 0 without reporting success is still red. Logs upload as an artifact on
failure.

**Observed result** on the first run, on a clean Ubuntu runner
([run 34741699176](https://github.com/JAYST3AM/project-banner/actions/runs/34741699176)):

```
engine: 4.7.2.stable.official.ed1daf0bf
  suites: 13 of 13 reported   assertions: 1708   failures: 0
  RESULT: PASS
    wounded s_0008: 28 -> 11 hp, must survive the restart
--------- persistence write: PASS (6 checks, 0 failures) ---------
    26 soldiers restored, 9 of them dead
--------- persistence verify: PASS (95 checks, 0 failures) ---------
```

**Observed result after Step 7** ([run 34744677802](https://github.com/JAYST3AM/project-banner/actions/runs/34744677802),
commit `c4c2bd2`) — read from the runner's raw log rather than from the status badge:

```
engine: 4.7.2.stable.official.ed1daf0bf
  PASS  (69 assertions, 0 failures)     <- test_terrain
  PASS  (203 assertions, 0 failures)    <- test_formation
  PASS  (78 assertions, 0 failures)     <- test_formation_battle
  suites: 16 of 16 reported   assertions: 2058   failures: 0
  RESULT: PASS
--------- persistence write: PASS (6 checks, 0 failures) ---------
--------- persistence verify: PASS (95 checks, 0 failures) ---------
```

Every step in the job ran green — install, version assertion, import, the full suite,
and both persistence phases — with only the on-failure log upload skipped. The
three new suites appearing by assertion count in the raw log is the part that matters:
a green badge on its own would not have shown that the new coverage was actually
executed on the runner rather than merely present in the repository.

Every required step ran; the only skipped step was the failure-artifact upload, which
is correct on a passing run. The engine the runner used is the pinned one, not whatever
`latest` resolved to on the day.

**Observed result after Step 7.1** ([run 34746351217](https://github.com/JAYST3AM/project-banner/actions/runs/34746351217),
commit `ccf9cff`), again read from the runner's raw log:

```
engine: 4.7.2.stable.official.ed1daf0bf
  PASS  (72 assertions, 0 failures)     <- test_terrain
  PASS  (328 assertions, 0 failures)    <- test_formation
  PASS  (99 assertions, 0 failures)     <- test_formation_battle
  suites: 16 of 16 reported   assertions: 2207   failures: 0
  RESULT: PASS
--------- persistence write: PASS (6 checks, 0 failures) ---------
--------- persistence verify: PASS (95 checks, 0 failures) ---------
```

Same shape as the run above: every step green, only the on-failure upload skipped, and
the new assertion counts visible in the log rather than inferred from a badge.

**The gate was also proven to go red**, on a throwaway branch and a pull request that
was closed without merging, so `main` was never affected. Two separate failures were
induced deliberately:

| Induced failure | Result |
| --- | --- |
| A failing assertion in one suite | suite step **failed**, later steps skipped, job red, logs uploaded |
| A failing `--phase=verify` (suite and write phase both green) | verify step **failed**, job red, logs uploaded |

Both matter. The first proves a failing test cannot be swallowed; the second proves a
failure in a *later* step still reddens the job rather than being lost behind an
earlier green one. Neither run used `continue-on-error`, and in both cases the
failure-artifact upload step ran successfully, so logs exist exactly when they are
needed.

**CI does not fail on the runner self-test's deliberate runtime error.** That fixture
provokes a real engine error on purpose (see §9.3) and the engine still exits 0 because
the suite handles it. The workflow carries a comment saying so, so that nobody removes
the fixture in the belief that they are cleaning up noisy output.

### 9.6 Other verification

The development switches above exercise the real button handlers, so a flag-driven run
is not a simulation of the UI - it is the UI, driven by something other than a mouse.

The same pass also had to prove the **negative** cases, which is where the value is:

- `--suite=this_does_not_exist` → exit 1, with the filter and the available suites named.
- `--suite=battle_outcomes` → exit 0, 224 assertions, 1 of 1 suite.
- `--suite=enemy_persistence` → exit 0, 121 assertions, 1 of 1 suite.
- `--suite=legacy_menu` → exit 0, 30 assertions, 1 of 1 suite.
- A windowed run with no save present logs `main menu: continue offered` as unavailable.
- The two-process restart check was re-run from scratch after the withdrawal and enemy
  persistence changes.

### 9.7 The benchmark — what 100 to 5,000 soldiers actually costs

`scenes/dev/battle_benchmark.tscn` is a development-only harness. It builds one
deterministic battle per size, steps the simulation directly (no rendering) for as many
ticks as a wall-clock budget allows, and reports the cost. It also **re-runs the same
battle three more times** with terrain and formations switched off, so the cost of the
new systems is attributed by measurement rather than by assertion.

Headless, Godot 4.7.2-stable, one machine:

| units | ticks run | per tick | ticks/sec |
| --- | --- | --- | --- |
| 100 | 600 | 4.78 ms | 209 |
| 500 | 109 | 110.3 ms | 9 |
| 1,000 | 28 | 440.0 ms | 2 |
| 2,500 | 12 | 2,684.6 ms | 0.4 |
| 5,000 | 6 | 10,988.0 ms | 0.05 |

**Attribution:**

| units | units only | +terrain | +formations | both |
| --- | --- | --- | --- | --- |
| 100 | 3.271 ms | 3.269 ms | 4.583 ms | 4.783 ms |
| 500 | 108.145 ms | 108.776 ms | 108.690 ms | 110.337 ms |
| 1,000 | 432.896 ms | 427.976 ms | 430.173 ms | 439.993 ms |

Terrain is free. Formations cost nothing measurable above 500 soldiers. **The cost is two
loops that compare every soldier with every other soldier** — `_choose_target()` and
`_resolve_overlaps()` — and both predate this milestone. Fifty times the soldiers is
about 2,300 times the time per tick.

Three things stated plainly rather than left for a reader to infer:

- **This is not a claim about 20,000 soldiers.** It is a measurement of five sizes, and
  the shape of the number says the current architecture will not get there without the
  spatial work described in §12.
- **The large sizes measured the approach, not the melee.** Above 500 soldiers the
  budget ran out before the armies made contact, so those runs are movement and targeting
  rather than a fight. Both quadratic loops run every tick regardless of contact, so the
  per-tick figure is representative — but it is an approach.
- **The tick counts differ between sizes on purpose.** A fixed tick count would have made
  the top of the range take hours, so each run stops on a time budget and reports what it
  achieved. A size that managed six ticks says six.

The harness prints a checksum of each battle's *starting position*, so a performance
comparison across commits is comparing the same battle rather than merely the same number
of soldiers. The checksum is taken before the fighting starts, so it does not move when a
budget runs out a tick or two earlier.

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

### 10.4 The Step 6.5 external audit — seven defects

An external review of Steps 0–6 reported seven defects. All are fixed with regression
coverage. They are listed together because the pattern matters more than any one of
them: **six of the seven were silent.** Nothing crashed, nothing logged an error, and
the game looked like it was working. They were only visible by asking what the numbers
in the campaign *should* have been and comparing.

| # | What was wrong | Why it was silent | Now guarded by |
| --- | --- | --- | --- |
| 1 | Retreating from a battlefield still ran the survivor path: participation XP, survived-battle XP, `battles_survived`, survivor history. Enter, Retreat, repeat — a risk-free farming loop. | The screen said `WITHDREW`, which is what the player expects to see. The progression was invisible. | `test_battle_outcomes.gd` — including a deliberate six-cycle attempt to farm the loop |
| 2 | `step()` finished the battle on timeout and then processed the rest of the same step, so units could still move, strike, take damage and die after the end. | Only the *last* step of an undecided battle, so it looked like ordinary end-of-fight noise. | `test_battle_outcomes.gd` — HP and positions frozen, no hit/death events, later steps inert |
| 3 | Travel pace used the roster size, so a party that had lost most of its strength still marched at full-company speed. The HUD showed roster-vs-capacity while recruitment counted the living — `24 / 24` while replacements were still offered. | Slower travel is not "wrong" in any way the player can see; they just never arrive faster after a disaster. | `test_party_semantics.gd` — including "same active force, more graves, same pace" |
| 4 | `peek_metadata()` assumed `player_party` was already a dictionary, so the exact legacy save the v0 migration exists to handle errored in the main menu before Continue was pressed. | Nobody had a legacy save to test with. The migration was correct and unreachable. | `test_persistence.gd` — current, legacy, corrupt, missing and too-new saves |
| 5 | The Step 5 end-to-end test queued a **second** `battle_results` transition with no payload, replacing the real one. The screen fell back to "No battle result was passed to this screen". | The test passed. It confirmed the scene existed, which is all it actually checked. | `test_e2e_loop.gd` — real payload against the campaign chronicle and the rendered text |
| 6 | A `--suite=` filter matching nothing produced a zero-suite run that passed. | Zero failures reads as a clean run. | `test_runner_contract.gd`, plus a direct run of a bogus filter |
| 7 | A suite that aborted mid-run still reported `N assertions, 0 failures` and passed. | The assertions it managed to run genuinely did pass. | `test_runner_contract.gd` against deliberately malformed fixtures |

**Also found during the pass, not on the audit list:** the restart check looked up its
battle with `last_battle_summary()`, which stopped meaning "the battle we care about"
as soon as a second fight was on the record. The failures were loud, but the
assumption — that the entry you want is the last one — is false for any campaign that
has fought more than once.

**The one worth dwelling on is #7**, because the audit explicitly said not to assume
the answer. It was measured instead, with a throwaway probe that recorded three
assertions and then read past the end of an empty array:

```
SCRIPT ERROR: Out of bounds get index '3' (on base: 'Array')
PROBE: await run() RETURNED
PROBE: checks=3  failures=0  completed=false
```

So: control **does** return to the awaiting caller, the suite comes back looking
perfectly healthy, and a runner checking only the failure count calls it a pass. The
completion marker survived the abort because it is a statement the aborted function
never reaches. That is now the completion contract, and `test_runner_contract.gd`
keeps it honest.

Two lessons worth carrying forward:

1. **A test that only proves a scene loaded is not a test of what reached it.** #5 is
   the general shape of #7: both were tests that passed while verifying nothing, and
   both were worse than no test, because they converted "I did not check" into "I
   checked and it is fine."
2. **Ask what the number should be, not whether the number looks reasonable.** Bugs 1
   and 3 were both a wrong quantity used consistently, and the only way to see either
   was to compute the correct value independently and compare.

### 10.5 The Step 6.6 pass — persistence, one-sided

Step 6.6 closed the last gaps before declaring the foundation locked. The central one
is the same shape as the bugs above, and it is the clearest example in the project of
a rule applied to one half of a system and not the other.

| # | What was wrong | Why it was silent | Now guarded by |
| --- | --- | --- | --- |
| 1 | `BattleResult` described enemy **dead** but not enemy **survivors**, so an enemy damaged and left standing returned to the campaign at full health. The same band was a fresh band every time, so a hostile party could never be worn down and withdrawal was a free reset *for the enemy*. | Nothing looked wrong. The enemy was supposed to still be there — it was. Only its hit points quietly healed. | `test_enemy_persistence.gd` — the same soldier damaged, withdrawn from, saved, reloaded and fought again |
| 2 | Enemy **dead** kept none of the kills they had made before falling. `_fallen_entry` recorded them and `apply()` discarded them — the same bug as D-029, one layer further out. | A dead enemy is gone; nobody reads a corpse's stat block, so nobody notices it reads zero. | `test_enemy_persistence.gd` — an enemy kills one of ours, then dies |
| 3 | The **real main menu** was never tested against a legacy save. Step 6.5 fixed `peek_metadata()` and proved the Continue *path*, but not the menu scene the player actually meets. | The underlying calls were tested and passing. The untested part was the code the player touches first. | `test_legacy_menu.gd` — real scene, real status text, real Continue |
| 4 | No independent CI gate. | Local tests pass locally. That is what local tests do. | `.github/workflows/godot-tests.yml`, pinned to 4.7.2-stable |

**The generalisable lesson** — the one worth more than the four fixes — is that
"persistent soldiers" is a property of *the soldier model*, not of the player's half of
it. The project had a rule, wrote it down, enforced it for the party the player owns,
and never applied it to the party the player fights. Both bugs in the table are that
same omission, seen from two angles: a survivor's hit points, and a casualty's kills.

The related lesson is about **what the test was actually testing**. Step 6.5's gap 3 is
the same shape as its own gap 5: a test that exercises the layer underneath the thing
the player touches. `peek_metadata()` passing does not mean the menu works, in exactly
the way that `battle_results` existing does not mean the payload arrived.

### 10.6 The Step 7 pass — a battle that could not end

Step 7 was a new-systems milestone, not a hardening pass, and it still turned up two
defects. Both were found by **running the game**, and neither would have been visible
by reading the code that introduced them.

| # | Defect | Why it was invisible | Caught by |
| --- | --- | --- | --- |
| 1 | **A battle could stall permanently.** A fight resolved to nine players against one enemy and then ran for four more simulated minutes achieving nothing. The last enemy stood in the gap left by a fallen man: 2.6 units from the next soldier along, which is further than a sword reaches. Both formations were in `engage`, both had stopped, and neither would close — so nobody could reach anybody, and nothing was going to change. | Every individual piece was behaving correctly. The formations were steady, the cohesion was high, the men were exactly where they had been told to stand. The bug lived in the *interaction*: "hold your place" and "close with the enemy" were both true, and the second one had no way to express itself. | `test_formation_battle.gd` — a formed battle is required to reach a winner inside its step budget |
| 2 | **A formation closing on an enemy stopped six tenths of a unit short of it.** The arrival tolerance was written for a move order — walk to a waypoint and stop near it — and was being applied to "close with that body of men". | Stopping 0.6 units short of an enemy looks like stopping. It was found by printing the formation state during the stalled battle and seeing `moving` reported by a body that was not going anywhere. | The same suite, plus `test_formation.gd`'s "a body with no order is not moving" |

**Defect 1 is the interesting one**, and it is worth stating precisely why it happened,
because the same shape will recur. Step 7 gave formations a rule — soldiers hold their
places — which is exactly what makes a line a line. It also gave them a stance —
`engage`, close with the enemy — which is exactly what makes a battle happen. Neither is
wrong. Their combination is wrong in one specific case: **when the fight has stopped for
a reason neither rule can see.** The survivors are not in contact, so no soldier attacks;
no soldier is under orders to move, so none of them walks; and both bodies are holding
formation, correctly, while the battle quietly never ends.

The fix is narrow rather than a new system — a stopped, engaged body whose *side* has
nobody in contact lets its men press forward, and the moment anyone is in contact the
dressing wins again. But the lesson is broader, and it is the one to carry into Step 8:
**an invariant that is enforced everywhere individually can still be violated
collectively.** "Every soldier is in its correct place" was true throughout the stall.
The battle was still broken.

The second-order lesson is about measurement: this was caught because a test asserted
that a battle *reaches a conclusion*, rather than asserting things about the formations
in it. A suite full of correct per-system assertions would have passed for four hundred
simulated seconds while the game sat there doing nothing.

### 10.7 The Step 7.1 pass — a formation that could not tell the truth about itself

Step 7.1 was an external audit of Step 7, and the five defects it found have a single
shape in common: **a formation could report something untrue about itself.**

| # | Defect | Why it was invisible | Caught by |
| --- | --- | --- | --- |
| 1 | **A detached-from formation kept the geometry of its old self.** `assign_formation()` edited a donor's roster directly and then called `ensure_slots()`, which rebuilds only if something has already marked the geometry dirty — and nothing had. A dressed twelve-man line that lost four men went on reporting ten files, two ranks and the frontage of a body four men larger, *indefinitely*. | Nothing looked wrong. The line still existed, still had soldiers in it, still fought. It was simply standing in a shape it no longer was, and no operation in the game would correct it. | `test_formation.gd` — a twelve-man line, four men detached, the donor's geometry compared against a fresh eight-man line |
| 2 | **`set_type()` had the same defect one layer over.** It marked the geometry dirty and left `file_count`, `rank_count`, `frontage()` and `depth()` describing the shape the body was walking *out of*. | It corrected itself on the next simulation step, so nothing was ever permanently wrong — but every read between the order and the next tick was a lie, including the one the HUD prints. | The `--autoformations` drill's own log: a seven-man line reported as "6 files by 2 ranks", which is loose order's geometry |
| 3 | **The AI took orders against corpses.** It rejected candidates with `is_empty()`, but a wiped-out formation is never empty — casualties stay on the roll on purpose. An AI choosing by distance would pick the body it had just destroyed. | The AI appears to be working. It issues orders, its soldiers face *something*, and the something is usually in roughly the right direction. | `test_formation_battle.gd` — a wiped-out body nearer than a living one |
| 4 | **Contact was tracked per side rather than per formation.** Any player soldier in reach marked the whole side engaged, so a detached wing that had reached nobody held its dressing and stood still while the centre fought. | Step 7 only ever had one body per side, so the distinction never came up. It became reachable the moment detaching a group became a player command. | `test_formation_battle.gd` — a centre in contact and a wing that is not |
| 5 | **Debug bounds ignored facing.** Built from frontage and depth around the anchor, they drew a thin horizontal strip at forty-five degrees while the slots ran diagonally through it. | It is a debug overlay. The units are drawn from their real positions, so the battle behaves correctly and only the box is wrong. | `test_formation.gd` — bounds contain every slot at six facings |

**The generalisable lesson** is the one from 10.6 restated from the other direction. Step
7's bug was that individually-correct rules could be collectively wrong. Step 7.1's bugs
are that an object can be *individually* wrong about itself: the formation kept existing,
kept fighting, kept being drawn, and simply described a body that was not there.

Both come from the same source, which is that a derived quantity has to be *re-derived*
whenever its inputs change. Three of the five are exactly that — geometry derived from
membership, geometry derived from type, contact derived from positions — and the fix in
each case was to make the re-derivation part of the mutation rather than a step the
caller has to remember. The remaining two are the same thing with a stale *definition*
rather than a stale *value*: `is_empty()` standing in for `has_living_units()`, and
frontage-and-depth standing in for "where are the soldiers".

**One of the five was found by the fix for another.** Defect 2 surfaced in the drill log
while checking defect 1. That is worth recording, because it is the argument for the
windowed drill existing at all: the ownership fix made formations report themselves as
un-dressed, which made a Step 7 test that had been passing on an un-updated default start
failing, which led to reading the log, which showed the shape being misreported.

---

## 11. What is *not* implemented

The honest list of gaps.

**Step 6.5 and Step 6.6 closed none of these** — both were hardening passes over what
already existed, and both deliberately added no gameplay. **Step 7 closed the first two**
and left the rest untouched: battlefields are no longer flat, and formations exist. What
Step 7 did *not* do is change how any of it fights; the gaps below are the current list.

**Combat depth**

1. **Terrain affects movement and nothing else.** Elevation, cover and a slope query
   exist as data, but there is no combat modifier, no obstacles, no line of sight and
   no ammunition. Terrain is a movement fact, not yet a tactical one.
2. **Formations are shapes, not fighting styles.** LINE, COLUMN and LOOSE exist as real
   geometry with facing and cohesion, and both armies use them. But a formation's shape
   does not change how it fights: no shield wall, no phalanx, no bracing, no
   facing-dependent defence, no flank or rear bonus, and nothing consumes cohesion.
   There is also no retreating or refusing a flank — the only orders are engage, hold
   and move.
3. **No morale behaviour or fleeing.** A unit fights to its last hit point. Morale is
   tracked and displayed but does not affect anything. A broken enemy is killed where it
   stands rather than routed and run down.
4. **No cavalry and no anti-cavalry role** for the spear, which the brief anticipated.
5. **No projectiles.** Ranged hits apply immediately with a floating damage number;
   ammunition is unlimited, and there are no firing arcs or lines of fire.
6. **No wounds, fatigue, or weather effects.** Weather is a placeholder string in the
   context.
7. **The simulation is quadratic in soldiers.** `_choose_target()` and
   `_resolve_overlaps()` compare every soldier with every other soldier, which is why
   5,000 soldiers costs eleven seconds a tick. Measured and documented rather than
   fixed — see §9.1 and D-053.

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
| D-033 | A withdrawal is its own outcome, with its own progression rules | Anything less is a risk-free XP loop; the rules live in one place so they cannot drift from the label |
| D-034 | Roster membership and active force are separate quantities | Two numbers describe one party once anyone dies, and using the wrong one fails quietly |
| D-036 | A suite must reach its completion marker to pass | Verified, not assumed: an aborted suite returns looking healthy with `N assertions, 0 failures` |
| D-039 | Tests wait for transitions; they never cause them | A second transition replaces the first payload, so the test proves nothing while looking thorough |
| D-041 | Battle consequences are symmetric — enemy soldiers persist too | Persisting only the player's half makes "persistent soldiers" a property of one side, not of the world |
| D-042 | CI is an independent gate, pinned to the engine version | Local tests cannot catch a suite that depends on local state; "latest" CI reports on the engine, not the project |

Decisions D-006 to D-032 are recorded in full in `docs/DECISIONS.md`, along with
D-033 to D-042 from the Step 6.5 and 6.6 hardening passes.

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
6. **Withdrawal is now strict, but is it strict enough — or too strict?** It pays
   nothing but kills, and does not count as a battle survived. That closes the farming
   loop. It also means a player who makes a genuinely sensible tactical decision — pull
   out of a fight going badly, keep the army alive — gains nothing at all for it. Should
   there be *some* reward for a withdrawal that preserved the force, that is not
   farmable? The tension is real and unresolved.
7. **Does the party-capacity rule want a maximum, or a soft cost?** Only the living
   count against `max_party_size`, so losses free slots. The alternative is that a
   roster has a hard ceiling regardless, which makes deaths permanent in a second way.

These were written before the Step 6.5 audit, which addressed none of them directly.
Item 6 is new, and is a direct consequence of that pass: closing the farming exploit
also removed a reward that a careful player might reasonably have expected.

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
