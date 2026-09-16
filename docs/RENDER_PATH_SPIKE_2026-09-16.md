# Project Banner — render path spike (Step 7.9), 2026-09-16

**What this document is.** The record of one day's work on Project Banner: what was asked, what was
measured, what it proves, what it does not, and what is still open. It is written to be audited by
another model or a person without re-running anything, and to be checked against the repository's own
documents rather than taken on trust.

**Repository state when this was written.** Working copy `F:\VSC Projects\Project Banner`,
`main` @ `b6b04e2` ("docs: record the CI run for the formation-driven engagement spike"), clean tree,
CI green on that commit (run 35015514367). The work described here is **uncommitted** — no commit, no
push, no changes to `CURRENT_STATE.md` / `ROADMAP.md` / `DECISIONS.md` yet.

**Host.** i9-12900K, RTX 3080 Ti, Windows 11, Godot 4.7.2-stable, Vulkan/Forward+. The project's own
docs warn that numbers on this host move by tens of percent with CPU state; every paired figure below
was taken back to back in one session for that reason.

---

## 1. The question

Jay's goal: **20,000 soldiers on screen at 60 fps.** Two separate constraints hide inside that
sentence and they had never been separated:

1. can the **renderer** draw 20,000 soldiers at 60 fps?
2. can the **simulation** run 20,000 soldiers fast enough to feed it?

The project's own `docs/CURRENT_STATE.md` states in its "Known limitations" (item 24) that *rendering
is not in any of these measurements* and that drawing twenty thousand soldiers is "a separate problem
the large-battle milestone will also have to pay for". That was an assumption, not a measurement —
and it was the first thing that needed a number.

The simulation side was already thoroughly measured: family B (field scaled with the army), 20,000
soldiers, instrumented, final build:

| phase | ms/tick | share |
| --- | ---: | ---: |
| per-soldier update loop | 231.7 | 53% |
| &nbsp;&nbsp;of which automatic target selection | 104.5 | 24% |
| formation focus | 47.7 | 11% |
| spatial grid (rebuild + mirror) | 44.5 | 10% |
| formations | 41.8 | 10% |
| separation pass (already native, "shape C") | 40.4 | 9% |
| **total** | **437.1** | 100% |

The battle runs on a fixed-step clock at `battle.tick_rate = 20` Hz (D-103), so a tick has **50 ms**.
437 ms is **8.7x short** of that.

---

## 2. Method

New development-only harness: `scenes/dev/render_bench.tscn` + `scripts/dev/render_bench.gd`.

Invariants, chosen so the number means what it says:

- windowed (there is nothing to measure headlessly), **vsync disabled**, `Engine.max_fps = 0`, so the
  frame time belongs to the renderer and not to the monitor;
- the battle is the **production** one, built by the production constructors
  (`ShowcaseBattle.build`), and its setup checksum is printed (`600:f8a81f4d` at 600 soldiers, which
  matches the checksum recorded for the showcase — the thing measured is the thing played);
- the simulation is **stepped a fixed number of ticks and then frozen** for the whole measurement, so
  the frame cost is render cost and nothing else; the tick cost is printed separately and never mixed
  into a render number;
- the ticks are stepped **after a settling window** of rendered frames;
- each mode is sampled after a warm-up, and reports avg / p50 / p95 / worst / implied fps;
- ground-only mode is measured as the baseline, so "the army costs X" never means "the army plus the
  field it stands on".

Modes: `terrain` (no soldiers), `immediate` (the path the game uses today — one canvas command per
soldier per overlay), `field: setters` (instanced, written with the documented API), `field: buffer`
(instanced, rebuilt into one `PackedFloat32Array` every frame), `field: published buffer` (instanced,
rebuilt on the simulation's cadence and handed over with one assignment per frame).

The instanced path is `scripts/battle/soldier_field.gd` (`SoldierField`): three instance batches —
bodies (generated disc texture: outline rim, white core so the per-instance colour is the team
colour), health bars (background + fill per soldier), facing pips (rotated thin quad) — so three draw
calls for the whole army.

**The instance-buffer layout is probed, not assumed.** `MultiMesh.buffer` is a flat float array whose
slice layout is not documented in a form worth trusting. The field writes one instance through the
documented setters with values that cannot be confused with each other, reads the buffer back, and
finds where each field landed. Measured on Godot 4.7.2: **stride 12 floats per instance; basis
diagonals at 0 and 5; origin x at 3 and origin y at 7 (not adjacent); colour RGBA at 8-11.** Had the
layout been assumed as "colour follows the origin", the army would have been drawn at coordinates
made out of colour values. If the probe fails, the field falls back to the setters path, and the
battle scene falls back to the canvas path rather than drawing nonsense.

---

## 3. Measurements

### 3.1 600 soldiers (300 v 300), sim frozen, window 1600x900, whole field in view (zoom 5.63)

| mode | avg ms/frame | p50 | p95 | worst | fps |
| --- | ---: | ---: | ---: | ---: | ---: |
| terrain only | 1.92 | 1.85 | 1.94 | 3.05 | 520 |
| **immediate (today's path)** | **18.83** | 19.05 | 19.05 | 19.45 | **53.1** |
| field: setters (bodies only, first run) | 2.45 | 2.51 | 2.53 | 2.53 | 408 |
| field: buffer (bodies only, first run) | 2.76 | 2.78 | 2.78 | 2.78 | 363 |

Per-soldier instance write at this size: 0.61 ms for 600 soldiers.

**Finding: the showcase size the project watches and the accepted regression is built on does not hold
60 fps today.** 18.8 ms/frame at 600 soldiers, and ~17 ms of it is per-soldier canvas drawing.

### 3.2 20,000 soldiers (10,000 v 10,000), sim frozen, same window, whole field in view

| mode | avg ms/frame | p50 | p95 | worst | fps | per-frame instance write |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| terrain only | 2.13 | 2.08 | 2.33 | 2.39 | 469 | – |
| **immediate (today's path)** | **132.73** | 133.33 | 143.30 | 144.11 | **7.5** | – |
| field: setters | 23.86 | 23.81 | 24.15 | 24.15 | 41.9 | 21.37 ms |
| field: buffer, rebuilt per frame | 19.66 | 19.53 | 19.76 | 22.28 | 50.9 | 17.06 ms |
| **field: published buffer** | **2.56** | 2.45 | 2.78 | 2.78 | **390** | **0.06 ms** (+ repack) |

The published-buffer path rebuilds the buffers on the simulation's cadence (measured here: every 15
frames) at **16.93 ms per rebuild**, i.e. **1.13 ms/frame amortised** across 20,000 soldiers — and the
frame itself pays 0.06 ms to hand the buffers over. Repack cost is ~0.85 µs per soldier.

Simulation ticks measured in the same windowed run, for completeness (deployment window, live window,
**not** comparable to the headless family-B figures): 365.1 ms and 914.6 ms.

### 3.3 The real showdown: 300 v 300 showcase, paired, one build, sim running

`battle_showcase.tscn`, `--per-side=300 --ticks-per-frame=1`, 45 s each, `PB_RENDER_BACKEND=canvas`
switches the same binary back to the old path. Simulation cost is identical in both (~10.4-10.7
ms/tick).

| run | stage: approach | first contact | melee | tick 500 | tick 1000 | tick 1500 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| canvas (today) | 22.6 fps | 25.9 | 24.1 | 23.0 | 26.0 | – |
| instanced (new) | 34.7 fps | 41.9 | 37.9 | 35.0 | 41.0 | 42.0 |

Both runs include the showcase's own formation debug overlay (slots, bounds, anchors, engagement
bands — canvas work for every slot of every body), which a player never sees and which is why even the
instanced path sits at ~40 fps rather than at the ~400 fps the frozen bench shows for the same army.

---

## 4. Three defects found by running it, not by reading it

1. **The instance-buffer layout is not what a reasonable person would assume.** See §2 — stride 12,
   origin at 3/7, colour at 8. The probe exists because the assumption was wrong the first time.
2. **`ERROR: Cannot set a buffer on a Multimesh that is a different size from the Multimesh's existing
   buffer.`** The multimesh's `instance_count` must equal the buffer's length *before* the assignment.
   In the frozen benchmark the count never changed, so it never appeared; in a live battle the count
   falls as soldiers die and the engine rejected every assignment — thousands of errors a second,
   silently drawing nothing. Fixed by setting the count first (`SoldierField._assign`).
3. **A windowed run's first frames are the engine's, not the scene's.** The first measurement reported
   the first simulation tick as **10,015 ms**; after the window settles it is **10.1 ms**. Pipelines
   compile and the terrain is uploaded the first time it is drawn. The harness now steps ticks and
   samples only after a settling window of rendered frames.

---

## 5. What this means for "20,000 soldiers at 60 fps"

**Rendering: solved, and it was never the wall.** 20,000 soldiers cost **2.56 ms a frame plus 1.13 ms
amortised repack = ~3.7 ms** of a 16.7 ms budget, against 132.73 ms for the canvas path — a 52x
improvement — with the simulation frozen so the comparison is like-for-like. The GPU side is not close
to being the constraint: ground + 20,000 instanced soldiers is ~4.7 ms/frame.

**Simulation: the whole remaining gap.** 437 ms/tick against a 50 ms budget at 20 Hz. What the profile
says matters more than the total:

- The **quadratic** work in the battle tick was removed in Steps 7.2–7.6 (target selection, separation,
  formation focus). Every remaining phase is a linear pass over soldiers or bodies. There is no
  algorithmic silver bullet left in that profile; the cost is *per-soldier constant work in GDScript*.
- GDScript-to-native translation on this codebase is measured, not guessed: the separation pass's
  native kernel ("shape C") gave **5.58x** at 20,000 (238.0 → 42.7 ms) and the native target query
  ("shape B") gave **5.94x** on the query (591.5 → 99.5 ms/tick) and 1.91x on the whole tick.
- Project the same ratio honestly across the remaining phases (soldiers 231.7, focus 47.7, grid 44.5,
  formations 41.8 at ~4-5x, overlap already native at 40.4): **≈120-140 ms/tick, i.e. ~7-8 Hz, not
  20 Hz.**
- **A 20 Hz simulation at 20,000 soldiers is therefore not one more optimisation — it is the whole
  battle tick in C++ with a structure-of-arrays data layout**, or a lower simulation rate for very
  large battles (60 rendered frames over fewer simulated ticks, with interpolation).
- The render side's own remaining GDScript cost (the 16.9 ms repack per 20,000 soldiers) is the same
  kind of cost and belongs in the same native pass, not in a per-frame loop.

**One design call belongs to Jay** (and it is the only thing blocking the next decision): does 20,000
soldiers mean *60 rendered frames per second over a 20 Hz simulation*, or *60 rendered frames over a
lower simulation rate at that size*? The first is a native-core project. The second is reachable with
a bounded native port.

---

## 6. Claims the measurements do NOT support

- ~~"Rendering is the wall at 20,000 soldiers."~~ Measured: 132.7 ms today, 2.56 ms instanced.
- ~~"The simulation needs a better algorithm."~~ The algorithmic work was done in 7.2–7.6; what is
  left is per-soldier constant cost and language overhead.
- ~~"20,000 at 60 fps is a rendering problem."~~ It is a simulation problem.
- ~~"The 300 v 300 showcase runs at 60 fps."~~ It runs at 23-26 fps today.
- ~~"A 5x native port gets to 20 Hz at 20,000."~~ It gets to roughly 7-8 Hz. The rest is a full native
  tick.
- No fps figure in this document is a prediction. Every one is a measured frame on this host.

---

## 7. Files touched (uncommitted)

| file | what it is |
| --- | --- |
| `scripts/battle/soldier_field.gd` | **new.** The instanced army: three batches, the layout probe, `pack`/`apply` (primary path) and `update_from` (per-frame rebuild, for comparison). |
| `scripts/dev/render_bench.gd`, `scenes/dev/render_bench.tscn` | **new.** The windowed render benchmark described in §2. |
| `scripts/battle/battle_view.gd` | added `show_units`; the view skips the per-soldier loop when a field draws the army. |
| `scripts/battle/battle.gd` | attaches the field as the primary renderer, packs on the tick, drops bars/pips below a zoom threshold, falls back to canvas if the layout cannot be probed, honours `PB_RENDER_BACKEND`. |
| `scripts/dev/battle_showcase.gd` | uses the same renderer the game uses; `PB_RENDER_BACKEND=canvas` gives the paired comparison. |

Benchmark logs: `F:/VSC Projects/pb-bench/render/` (bench reports), `F:/VSC Projects/pb-bench/showcase/`
(`instanced_run.log`, `canvas_run.log`).

---

## 8. Not done, and open

- No commit, no push, no doc updates in `CURRENT_STATE.md` / `ROADMAP.md` / `GAME_ARCHITECTURE.md` /
  `DECISIONS.md` (the house rule is that a milestone lands with its docs; this is still a spike).
- **No test suite yet for the field.** The house standard for a render/behaviour change of this kind is
  an equivalence suite (the field's buffer against unit positions and colours over generated states,
  plus "the count drawn equals the count standing"). That is the next thing to write, before any claim
  of parity.
- **No visual verification by screenshot.** The field's bars and pips are verified by measurement (no
  engine errors, instance counts, cost) but not yet looked at. A screenshot pass at 600 soldiers,
  instanced against canvas, is the honest way to confirm the two draw the same picture.
- **No interpolation.** Positions exist per tick; nothing lerps between ticks. Needed for smooth motion
  at 60 rendered fps over a lower simulation rate, and it belongs in the native fill.
- Not drawn by the field: the ranged ring (needs a fourth batch and a second texture). Selection rings
  and order lines deliberately stay on the canvas path — their cost is proportional to what a player
  selected, not to the size of the army.
- **No CI performance gate.** The numbers above are host-specific; a gate would need wide margins or a
  ratio-to-reference measurement.
- The native soldier loop ("shape D") is scoped but not started, and is the main effort either way.
