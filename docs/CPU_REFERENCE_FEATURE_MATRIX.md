# CPU reference feature matrix

**What this is.** The roadmap's Phase 0 deliverable: every feature the **reference** build has,
what the **GPU prototype** currently does with it, and how each one is proved. A feature is only
`PARITY` when the GPU version behaves the same *from the player's perspective*, and only
`VERIFIED` when a measurement in this repository says so. Similar code is not parity.

**The reference build.** Branch `main`, commit `fd597d2`, tag **`cpu-reference-2026-09-17`**.
The CPU simulation is the reference implementation; nothing in the GPU work replaces it until it
has passed a paired test against it.

**Environment recorded for the reference (Phase 1).** Read from `DeviceReport.report()` on this
machine, 2026-09-17:

```
device:        NVIDIA GeForce RTX 3080 Ti  (NVIDIA)
device class:  discrete GPU
driver:        forward_plus / vulkan  api 1.4.351  server Windows
rendering:     method forward_plus  vsync off  fps cap 0  debug true
display:       window 1280x720  screen 2560x1440
host:          12th Gen Intel(R) Core(TM) i9-12900K  (24 threads)  ram 32535 MiB
os:            10.0.22631
toolchain:     Godot 4.7.2-stable, native accelerator built from native/ (godot-cpp)
```

No software rasteriser is in play: the renderer is Vulkan on the discrete 3080 Ti. The earlier
suspicion that builds may have been running on a CPU rasteriser is **not** what the diagnostics
show on this machine.

**Statuses.** `NOT PORTED` · `PARTIAL` · `PARITY` · `VERIFIED` · `REGRESSION`.

---

## 1. Soldiers (persistent people)

| Feature | Reference | GPU prototype | Status | Proof |
| --- | --- | --- | --- | --- |
| Unique soldier ids, names, age, class | Yes (`CampaignState.soldiers`) | No — anonymous array indices | **NOT PORTED** | `test_recruitment`, `test_persistence` |
| Level, XP, kills, battles survived | Yes | No | **NOT PORTED** | `test_combat`, `test_battle_outcomes` |
| Traits, morale, loyalty (tracked) | Yes | No | **NOT PORTED** | `test_recruitment` |
| Personal history log | Yes | No | **NOT PORTED** | `test_party_semantics` |
| Alive/dead state survives a battle | Yes | In-session only | **PARTIAL** | `test_enemy_persistence` |
| Recruitment in settlements | Yes | n/a (no campaign) | **NOT PORTED** | `test_recruitment` |

**The gap in one line:** the GPU prototype has soldiers without identities. Codex's item 5 —
mapping GPU state to real `BattleUnit`/soldier identities and returning results through
`BattleContext` → `BattleResolver.apply()` — is the bridge that turns any of this into a game
feature.

## 2. Formation system

| Feature | Reference | GPU prototype | Status | Proof |
| --- | --- | --- | --- | --- |
| Formation as a body with geometry | Yes (`BattleFormation`) | Yes — 3 bodies a side, 40 files × 25 ranks | **PARTIAL** | lattice deployment, `gpu crowd: 3 bodies a side…` log line |
| Slots and slot ownership | Yes | Yes — every soldier has file/rank, walks to his place | **PARTIAL** | dressing visible in `battle_6000_1.png` |
| Dressing / reformation | Yes | Dresses on the way in; does **not** re-form after casualties | **PARTIAL** | — |
| Facing and turning | Yes (`order_face_toward`, turn rate) | Yes: bodies face their **selected target** and turn at 1.2 rad/s, and the whole lattice swings with the heading — slots, dressing and the advance all follow it | **PARITY (measured)** | facing error **0°** on every steady-state line; **-45°** turn measured after a scripted target wipe |
| Orders (hold / advance / engage) | Yes (`order_hold`, `order_move_to`, `order_engage`) | Yes: HOLD, ADVANCE-to-a-point (arrives within 1.5 units then holds), ENGAGE | **PARITY (measured)** | HOLD: ordered body stayed at x=196 while neighbours advanced to 284. ADVANCE: ordered 60 units, arrived at 194 of a 196 target on tick 395 |
| Body-level target selection | Yes (`_engage_target_for`) | Yes: nearest **living** enemy body, retained while within 1.4× of the nearest so a line cannot flap between two equidistant enemies | **PARITY (measured)** | per-body target printed every report (P0→E0, P1→E1, P2→E2) |
| Target reassignment when destroyed | Yes | Yes: a destroyed target is dropped the tick it dies and a new one selected immediately | **PARITY (measured)** | scripted wipe of E1 at tick 500 → `P1: target E1 destroyed -> E0` on the same tick, then a -45° turn onto the new target; repeated at 600 soldiers (E2 → E1) |
| Formation cohesion | Yes (measured) | Yes: mean distance from each man's **place in the line**, built from the same geometry the shader uses, measured every tick | **PARITY (measured)** | dressed and holding: 0.59–0.60 units; during a 45° re-face: 14.55 → 7.75 as the men re-dress; in the melee crush: rises as the collision displaces men (19.1 measured) — the number behaves like the thing it claims to measure |
| Casualties leave gaps | Yes | Yes — the fallen keep their place, the living stay on theirs | **PARITY (visual)** | contact-line shots, rank gaps visible |
| Casualties change frontage | Yes | No — ranks do not close up | **NOT PORTED** | — |
| Collision between bodies | Yes (`_resolve_overlaps`) | Hard: anchors held at the living front lines, separation settled over three rounds | **PARTIAL — measured** | see below |

**The collision proof (measured, this machine, 2026-09-17).** A probe inside the compute shader
records, on every simulation tick: the closest enemy gap anywhere on the field, how many pairs are
inside the agreed minimum (2.6 units, five per cent tolerance = 2.47), the furthest single step
anyone took, and how many men the grid could not hold. Same scene, as each fault was found and
fixed:

| State of the solver | Closest enemy gap | Pairs inside the minimum | Biggest step |
| --- | --- | --- | --- |
| One capped correction a tick (as it was) | **1.49** | 275,614 and rising | 0.60 |
| + three relaxation rounds after the walk | 1.59 | 123,528 | 0.60 |
| + anchors held at their own living front line | 2.22 | 4,640 | 0.60 |
| + an enemy's half of the correction not shared | 2.45 | 6 | 0.60 |
| + the deployment actually fitting the field | **2.48–2.49** | **0 (600), 6 (6,000)** | 0.60 |

The collision held from this point on, but the *battle* still froze at 228 dead, with the two lines
standing and staring at each other. Two more faults, both in the rule that drives the bodies'
anchors rather than in the solver:

- **The anchors were being driven by the leading man's x alone.** Two bodies' leading men can sit in
  different bands down the field, so comparing their x read as "2.3 apart, no room" while the
  nearest real enemy pair stood 3.52 away — past the 3.4 reach. Nobody could fight and nobody could
  close. The rule now uses the *measured* nearest-enemy distance **per body**, taken by the shader
  every tick.
- **The press stopped the instant "somebody is in reach"**, which left the two lines sitting at
  3.2–3.4 — a knife-edge where only the occasional pair could strike, and the battle crawled at 16
  blows a tick. Bodies now lean in until the men are at their own separation (`ENGAGE` = 2.73),
  which the separation solver can hold whatever the anchors ask, so pressing that close cannot crush
  the line: it only decides whether the lines are actually fighting.

Every one of those steps is in the shader and the probe, and each was found by the measurement
rather than by looking at the picture. The last two faults are worth stating as rules:

- **A body advances only while its living men have room ahead of them.** The anchors are what every
  man's place in the line hangs off; marching an anchor into the enemy walks the body's rear ranks
  forward for ever and squeezes the front ranks into each other, however well the separation itself
  is solved. The same rule is what unseats a corpse-gap stalemate, because a fallen front rank moves
  the enemy's *living* edge backwards.
- **An enemy never displaces me; I move myself clear of him** — the whole overlap, every round.
  Sharing an enemy pair's correction half-and-half let a man's own rear rank push him into the
  enemy: the two pushes cancelled, and the front sat 0.38 units inside the agreed gap while the
  solver reported a clean pass. Friendly pairs still share, because both men are trying to leave.

Two further faults, both in the *probe* rather than the solver, were found the same way and are
worth remembering because each one made the measurement lie:

- The counter block had grown to eight words while the clear pass still covered four, so the
  violation and step counters were never reset — every "this tick" figure was a running total.
- The deployment still centred a body's files on the *old* forty-file constant after the frontage
  was fitted to the field, so a third of a 600-soldier army deployed up to 33 units outside the
  field and was dragged back in on the first tick. The probe now audits its own deployment and
  prints how many men are out of bounds.

**Still open (and why this is `PARTIAL`, not `PARITY`):** at 6,000 the worst measured gap is 2.45
against a 2.47 minimum — six pair-samples out of roughly 48,000, at first contact, 0.02 short. The
grid's fixed capacity (64 a cell) is still a hard cap in principle, and the run is not yet
deterministic: atomic binning orders vary between runs, so this is a measured claim at a fixed seed
and tick rate, not a reproducible one.

## 3. Battle system

| Feature | Reference | GPU prototype | Status | Proof |
| --- | --- | --- | --- | --- |
| Deterministic terrain from a seed | Yes | Yes — the production generator, same seed | **PARITY (visual only, see 4)** | `test_terrain` |
| Deployment / teams | Yes | Yes | **PARITY** | setup log line |
| Fixed-step clock | Yes, 20 Hz | Yes, 20 Hz (frames free-running) | **PARITY** | fps 1,600+ with `ticks 20.0/s` |
| Target acquisition (retention, hysteresis, cadence) | Yes | No — strikes every enemy neighbour in reach each tick | **NOT PORTED** | `test_target_acquisition` |
| Damage model (attack, defence, cooldown, variance) | Yes | Flat 0.25 hp/attacker/tick | **NOT PORTED** | `test_combat` |
| Retaliation | Yes | Incidental (everyone strikes) | **NOT PORTED** | `test_target_acquisition` |
| Battle completion / victory | Yes (victory, defeat, draw, withdrawal) | Partial: a verdict when a side hits zero | **PARTIAL** | `test_battle_outcomes` |
| Large-battle stalemate regression | Fixed in 7.8B | Reproduced, then fixed the same way (press forward) | **PARTIAL** | casualties grind to 5,645/6,000 vs. freezing at ~200 |
| Timeout / frozen field | Yes | No | **NOT PORTED** | `test_battle_outcomes` |

## 4. Terrain

| Feature | Reference | GPU prototype | Status | Proof |
| --- | --- | --- | --- | --- |
| Deterministic generation | Yes | Yes | **PARITY** | same generator, seed 780780 |
| Rendered as the game renders it | Yes | Yes — one baked texture, elevation shading | **PARITY** | `battle_6000_1.png` |
| Slows movement | Yes (`move_multiplier_at`) | **No — the ground is a picture to the prototype** | **NOT PORTED** | — |

## 5. Presentation

| Feature | Reference | GPU prototype | Status | Proof |
| --- | --- | --- | --- | --- |
| Instanced soldier rendering | Yes (`SoldierField`) | Yes — same MultiMesh idiom | **PARITY** | 1,600+ fps at 6,000 soldiers |
| Health bars | Yes | Yes | **PARITY** | zoomed screenshot crop |
| Fallen shown where they fell | Yes | Yes (greyed) | **PARITY** | contact-line shots |
| Selection rings, order lines | Yes | No (no player input) | **NOT PORTED** | `test_battle_view` |
| Damage/miss/death events | Yes | Deaths only, no events | **PARTIAL** | `test_battle_view` |
| Formation debug overlay | Yes (boxes, slots, facing) | Boxes removed at the owner's request; no slots/facing | **NOT PORTED** | — |
| Block view at scale | Yes (D-117) | No | **NOT PORTED** | `test_battle_view` |

## 6. Campaign, save, results

| Feature | Reference | GPU prototype | Status | Proof |
| --- | --- | --- | --- | --- |
| Casualties, XP, kills, loot written back | Yes | No | **NOT PORTED** | `test_e2e_loop` |
| Results screen naming the fallen | Yes | No | **NOT PORTED** | `test_battle_outcomes` |
| Save / close / reopen / continue | Yes | n/a | **NOT PORTED** | `persistence_check` two-process |
| Save versioning + migration | Yes | n/a | **NOT PORTED** | `test_persistence` |

## 7. Performance and architecture

| Feature | Reference | GPU prototype | Status | Proof |
| --- | --- | --- | --- | --- |
| Spatial index for local queries | Yes (native + GDScript grid) | Yes — GPU grid, 32 slots a cell | **PARTIAL** (overflow drops agents) | `overflow` counter |
| Native C++ hot loops | Yes (3 kernels) | n/a — compute shaders | **PARITY (by other means)** | `native/` builds, CI |
| Simulation/presentation separation | Yes (fixed 20 Hz) | Yes, since tonight: fixed clock, free frames | **PARITY** | `fps 1,600+ / ticks 20.0` |
| Deterministic results | Yes — same seed, same battle | **No** — atomic binning orders vary per run | **NOT PORTED** | the reference's own determinism suites |
| Device/renderer diagnostics | Added tonight (`DeviceReport`) | same | **PARITY** | this document's environment block |
| Test suite | 27 suites / 8,955 assertions | none of its own | **NOT PORTED** | `tests/` |

---

## The missing/partial list, in the order the roadmap asks for it

1. **Collision that can be proved** (Codex item 1) — exact minimum enemy separation every tick, no
   grid omission, a per-tick worst-pair record. *Nothing else about formations is credible until
   this exists.*
2. **Production-equivalent formation behaviour** (item 2) — orders, turning, dressing, cohesion,
   body target selection, frontage that changes with casualties.
3. **Targeting and the real damage model** (item 3) — targets, retention, cooldown, defence, misses.
4. **Terrain in the simulation** (item 4) — movement multipliers, slowest-member body pace.
5. **The battle contract** (item 5) — identities, events, `BattleContext`, `BattleResolver.apply()`.
6. **Readability** (item 6) — facing, events, order feedback — after the systems exist.
7. **Determinism** — the reference's "same seed, same battle" rule, which the GPU path currently
   cannot claim.

## Regressions

None in the reference: `main` at the tagged commit is untouched by the GPU work, and the GPU scene
is additive (three files). The GPU prototype has one known *internal* regression risk recorded
above — the capped separation and the fixed-capacity grid, both listed as dead ends by the audit.
