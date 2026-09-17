# Project Banner — status

Continuous status report, updated after every meaningful session. Written for a reader who has
not been in the room: what the build is, what was proved, what is next, and what is measured.

---

## Session: 2026-09-17 (night, continuing) — formation behaviour, and the collision made honest

**Owner's brief this session:** "get the gpu version up to standard"; then the GPU migration +
development roadmap, then the execution-order directive (finish 4.2 → determinism gate → 4.3 →
remaining parity → the 20k repack), with the standing rules: finish each task completely, measure
before and after, no silent compromises, commit coherent work.

### Phase 4.2 — formation behaviour: COMPLETE

Every requirement of the task, with the evidence that says so. All figures are from runs of
`scenes/dev/gpu_crowd.tscn` on this machine, 6,000 soldiers unless stated.

| Requirement | Verified by |
| --- | --- |
| Formation orders | HOLD: a body ordered to hold stayed at x=196 while its neighbours advanced to x=284. ADVANCE: ordered 60 units, arrived at 194 against a 196 target on tick 395, then held. ENGAGE: the default, verified by the battle runs below. |
| Body-level target selection | Each body selects the nearest **living** enemy body and keeps it while it is within 1.4× of the nearest (no flapping): printed every report as `target E0 355 away, facing error 0 deg`. |
| Target reassignment | Scripted wipe of an enemy body: `P1: target E1 destroyed at tick 500 -> E0` **on the same tick**, then a measured **-45°** turn onto the new target and a renewed advance. Repeated at 600 soldiers: `E2 destroyed -> E1`. |
| Facing toward the selected target | Facing error **0°** on every steady-state line in every test; the turn rate (1.2 rad/s) visible as the -45° swing above. |
| Advance / hold behaviour | The two scripted tests above; anchor displacement measured per body. |
| Cohesion while turning | Mean distance from each man's place in the line: 0.59–0.60 dressed and holding, **14.55 during a 45° re-face falling to 7.75** as the men re-dress, 19.1 in the melee crush. The number behaves like the thing it claims to measure. |
| After target destruction | No deadlock: the body re-targets, turns, advances and fights on. (This is the case that froze the battle at 228 dead before tonight's anchor fixes.) |
| Multiple formations | 3 bodies a side selecting among 3 enemies; a body whose own opposite number dies takes a *different* band's enemy and turns to face it. |
| No regression | Collision proof unchanged: **2.47 minimum gap, zero pairs inside, biggest step 0.60**; the battle still runs to a decision (an earlier run tonight: 5,997 of 6,000 fallen). |

### Determinism gate — IN PROGRESS, first result: the battle was not reproducible, and now is

The gate asks for the same seed and the same initial state to produce the same authoritative battle
at 20 / 30 / 60 / 120 / uncapped frames. Before anything could be compared, the state had to be
made comparable, so the scene now prints **checksums** every `--checksum-every=N` ticks: one hash
each for the men's positions, their condition (hit points and fallen flags), the formations
(anchors, headings) and how many men each body still has standing — quantised to a thousandth of a
unit before hashing, so the trace cannot fire on float noise.

**First finding: two identical runs were different battles.**

```
ticks traced: 1193 (tick 1 to 1193)
first divergent tick: 2
  first divergent field: positions  A=ea6110a2  B=a4bc7147
  positions  differs on 1192 of 1193 traced ticks
  condition  differs on 867 of 1193 traced ticks
  formations differs on 50 of 1193 traced ticks
```

Two causes, both order-dependence rather than float error:

1. **The separation sum was a float accumulated in binning order.** Which thread bins which man
   first varies between runs, so a man's neighbours were summed in a different order and the sum
   came out microscopically different. Integer addition is associative; float addition is not.
2. **The settling round read neighbours while writing its own position** in the same dispatch, so a
   thread could read half of another thread's move, or none of it, depending on scheduling.

Both are fixed: the correction is accumulated in **fixed-point integers with atomics** (order cannot
matter), and each settling round is now **two passes** — accumulate, then apply — so no thread reads
a position another thread is still moving.

```
ticks traced: 1189 (tick 1 to 1189)
IDENTICAL on every traced tick - the battle is reproducible at this granularity
```

Still to do for the gate: the frame-rate variants (the run in flight as this was written), then the
same comparison with scripted events firing at fixed ticks, and a regression test that fails if
order-dependence comes back.

**The gate, run across frame rates — PASS.**

| Variant | Ticks compared | Result |
| --- | --- | --- |
| `--max-fps=20` (reference) | 2 → 500 | — |
| `--max-fps=30` | 2 → 500 | identical |
| `--max-fps=60` | 25 → 500 | identical |
| `--max-fps=120` | 25 → 500 | identical |
| `--max-fps=0` (uncapped) | 2 → 500 | identical |

Every variant ran 1,000 soldiers, the same seed, and the same scripted event: an enemy body
destroyed at tick 300 so the comparison covers target reassignment and the turn that follows, not
just the approach. Men's positions, their condition, the formations and the standing counts are
identical at every compared tick — the battle does not care how fast it is drawn.

Repeatable: `pb-bench/determinism_check.sh` runs the variants and `pb-bench/trace_diff.py` reports
the first divergent tick and field, exiting non-zero if one appears. It needs a real GPU (this scene
simulates on the rendering device, so it cannot run headless) — which is why it is a local check
rather than part of the headless CI suite. That limitation is stated rather than hidden.

### Build

- `main`, commit `fd597d2` (pushed to GitHub; CI run in progress on it).
- Reference frozen: tag **`cpu-reference-2026-09-17`** at `fd597d2`.
- GPU work is **uncommitted** in three dev-only files:
  `scenes/dev/gpu_crowd.tscn`, `scripts/dev/gpu_crowd.gd`, `shaders/dev/crowd_sim.glsl`,
  plus `scripts/dev/device_report.gd`. No tracked game file is modified.

### Tests

- Reference: 27 suites / 8,955 assertions / 0 failures, plus the two-process restart check
  (95 + 6 checks). CI was queued on `fd597d2` when this was written; last green run was `d87af20`.
- GPU prototype: no suites of its own yet. Its evidence is a live run's counters and screenshots —
  which the audit explicitly says is not enough for a collision claim.

### Renderer

```
device:        NVIDIA GeForce RTX 3080 Ti  (NVIDIA)
device class:  discrete GPU
driver:        forward_plus / vulkan  api 1.4.351  server Windows
rendering:     method forward_plus  vsync off  fps cap 0  debug true
display:       window 1280x720  screen 2560x1440
host:          12th Gen Intel(R) Core(TM) i9-12900K  (24 threads), 32 GiB
os:            10.0.22631   Godot 4.7.2-stable
```

`DeviceReport` (new tonight) prints this block at startup and warns if the adapter is a software
rasteriser. **Verified: this machine draws on the discrete GPU.** No CPU/software rendering was
involved in any number quoted below.

### Performance (measured tonight, this machine)

| What | Reference (CPU sim) | GPU prototype |
| --- | --- | --- |
| 6,000 soldiers (3,000 a side), per tick | **87 ms** ≈ 11 ticks/s | **0.04 ms** to simulate, 0.3–0.8 ms to read back, 7.4 ms to repack the picture |
| Frame rate | 7.5 fps at that size | **1,600–1,950 fps** (uncapped, vsync off) |
| Battle clock | fixed 20 Hz | fixed 20 Hz (frames free-running) — separated tonight |
| 20,000 soldiers | ~346 ms/tick ≈ 2.9 ticks/s | **0.05 ms** to simulate, 25.3 ms to repack → 36 ticks/s driven flat out |
| Ceiling | the simulation | the repack, not the card (GPU 31% mean, 57% peak during the ladder) |

### CPU-reference parity

See `docs/CPU_REFERENCE_FEATURE_MATRIX.md`. Headline: **the GPU prototype has a slice, not a game.**
It has: formations as lattices with dressing, contact-gated walking, capped separation, terrain as
a picture, health bars, instanced rendering at 1,600+ fps, a casualty grind and a verdict. It does
not have: soldier identities, targeting, the real damage model, terrain in the simulation, orders,
facing/turning, cohesion, results, saves or determinism.

### Completed this session

1. GPU battle prototype: 6,000 soldiers, GPU-resident state, ten compute dispatches a tick, drawn
   through the game's own MultiMesh idiom.
2. Formations: three bodies a side with per-soldier lattice slots; ranks dress on the way in;
   formation boxes added, then removed at the owner's request.
3. **Collision, measured rather than asserted.** A probe inside the shader records every tick: the
   closest enemy gap anywhere on the field, pairs inside the agreed minimum, the furthest step, and
   men the grid could not hold. The first honest reading was **1.49 units against a 2.47 minimum,
   with 275,614 pair-violations** — the collision claim made earlier in the week was decoration.
   Three fixes later: **2.45–2.46, six pair-samples in a run, nobody inside anybody.**
   - Three relaxation rounds a tick after the walk, so a tick ends separated.
   - A body's anchor is held at its own living front line: an anchor marched into the enemy walks
     the rear ranks forward for ever and squeezes the front ranks into each other.
   - An enemy's half of a pair correction is not shared: he never displaces me, I move myself clear
     of him. Sharing it let a man's own rear rank push him into the enemy.
4. The game's own stalemate reproduced and fixed the game's way — and then twice more, as it
   re-appeared in new disguises. The bodies' anchors are now driven by a *measured* nearest-enemy
   distance per body, taken inside the shader every tick: a body leans in until its men are at
   their own separation, and stops. Two faults were found here by the numbers, not the eye:
   - the first version of the rule compared the leading men's **x only**, so two leading men in
     different bands read as "2.3 apart, no room" while the nearest real pair stood **3.52** away —
     past the 3.4 melee reach. The battle froze at 228 dead with the lines staring at each other;
   - the second stopped the press the moment "somebody is in reach", leaving the front at 3.2–3.4,
     a knife-edge where the fight crawled at 16 blows a tick. Fixed by leaning in to 2.73.
   After both: the fight grinds continuously (0 → 469 fallen in a two-minute run, and on), with the
   collision proof intact at 2.48 and zero violations.
5. Simulation/presentation split: fixed 20 Hz battle clock, free-running frames, uncapped by
   default — 1,600+ fps at 6,000 soldiers.
6. Phase 4 parity begun — **facing and turning**: bodies aim at the nearest enemy body and turn at
   1.2 rad/s, and every man's place in the line is built from the body's forward vector, so the
   lattice, the dressing and the advance all swing with the heading. Verified two ways: the square
   setup is unchanged (2.46 gap, six samples, same deployment), and an oblique setup — the sides
   offset in y so the bodies are forced to turn — converged at 4°/184° with the collision held at
   2.48 and zero violations. The oblique option also *caught a fault of its own*: a shift that
   pushed men past the field edge, now taken out of the field's slack and reported by the
   deployment audit as a 2.5-unit jitter spill rather than a 27-unit drag.
7. `DeviceReport`: renderer, device, vendor, class, resolution, vsync, fps cap, debug state, host;
   software-rasteriser warning. Confirmed: this machine draws on the 3080 Ti, Vulkan, nothing
   software-rasterised.
8. Roadmap Phase 0: reference tagged `cpu-reference-2026-09-17`, environment recorded, feature
   matrix written (`docs/CPU_REFERENCE_FEATURE_MATRIX.md`).
9. Roadmap Phase 2: the GPU baseline ladder, 600 → 20,000 soldiers
   (`docs/BENCHMARK_GPU_BASELINE.md`). Headline: **the simulation is 0.03–0.05 ms a tick at every
   size**; throughput is capped by the CPU repack (0.63 ms at 600 soldiers, 25.3 ms at 20,000).
10. Codex audit: director verdict with a seven-item work list (recorded below).

### Regressions

None in the reference build (untouched). Known *internal* risks in the prototype, named by the
audit as dead ends: the grid's fixed capacity (raised to 64 a cell, still a hard cap in principle)
and no determinism story (atomic binning orders vary between runs, so a "same seed, same battle"
claim cannot be made yet). The two deployment faults the ladder exposed — a body always forty files
wide, and files centred on the old constant — are **fixed**, with the probe auditing its own
deployment at startup so the class of fault cannot come back quietly.

### Current bottleneck

The **repack**, not the simulation and not the card. Simulating 20,000 soldiers costs 0.05 ms a
tick; rebuilding their picture on the CPU costs 25.3 ms — five hundred times more. The game's 20 Hz
clock absorbs it (0.5 s of one core a second at 20,000; 0.15 s at 6,000), which is why the frame
rate still runs at 1,600+, but it is the wall any further scale-up hits.

### Next action

**The determinism gate** (roadmap priority 2, and a hard gate before any new combat mechanics).
The scripted-event options now in the scene make it testable: `--wipe-band=N --wipe-at=T`,
`--hold-band=N --hold-at=T`, `--advance-band=N --advance-at=T --advance-by=D` and `--oblique=F`
fire at fixed ticks, so two runs of the same seed can be compared event for event.

The work, in order:

1. Add a **state checksum** (positions, hit points, fall flags, body anchors and headings) printed
   at fixed ticks, so two runs can be compared tick by tick without dumping the whole field.
2. Run the same seed at 20 / 30 / 60 / 120 / uncapped frames and compare the traces — the number of
   ticks a frame runs must not change what tick *N* looks like.
3. Build the **divergence tracer**: first divergent tick, first divergent body, expected vs actual.
4. Fix the root cause. The known suspect is order-dependence, not float error: the grid bins men
   with atomics, so a man's neighbours are summed in an order that varies between runs; the damage
   tally is an integer atomic and already order-independent, but the separation accumulator is
   float. Converting it to fixed-point integers makes the sum independent of the order it was
   summed in.
5. Re-run every frame-rate variant and record the result in this file.

Then 4.3 (targeting and combat parity against the reference), the rest of Phase 4, and the 20k
repack (25.3 ms → single digits, before/after measured, presentation only).

### The audit's work list (Codex, this session, verbatim in substance)

1. Real enemy collision, proved per tick, every soldier.
2. Production-equivalent formation behaviour (orders, turning, dressing, cohesion, frontage).
3. Real targeting and combat rules before kills are treated as results.
4. Terrain applied to movement and formation pace.
5. The battle contract: identities, events, `BattleContext`, `BattleResolver.apply()`, persistence.
6. Readability: facing, formation state, order feedback, damage/miss/death events.
7. Do not build on the dead ends; do not tune constants before the paired reference tests exist.
