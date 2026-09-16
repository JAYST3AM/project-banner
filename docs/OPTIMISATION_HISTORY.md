# Project Banner — the optimisation history, technique by technique

**What this is.** One place for every performance technique used on this project since the Step 7
series began: what it replaced, what it measured, what it cost, and what it had to keep working.
The raw evidence is elsewhere and this document deliberately does not replace it — the per-milestone
tables are in `CURRENT_STATE.md`, the reasoning is in `DECISIONS.md` (D-059 to D-106), the harness
is `scenes/dev/battle_benchmark.tscn`, and the renderer work is in
`RENDER_PATH_SPIKE_2026-09-16.md`.

**How to read the numbers.** Every figure below was produced by the project's own benchmark on this
machine, and the trustworthy comparisons are the *within-table* ones: same seed, same tick count,
same windows, measured back to back. The machine is noisy at the few-per-cent level, and milestones
were measured with different budgets and window lengths, so a number from one milestone's table
should not be divided by a number from another's. Where a cross-era figure is given it is labelled
indicative.

---

## 1. The arc

Family A (fixed-area torture field) at the standard budget, ms per simulated tick:

| soldiers | Step 7 | 7.2 | 7.3 | 7.4 | 7.5 | 20K-era benchmarks | today (layer on) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 4.783 | 4.160 | 3.651 | 1.987 | 2.025 | — | 9.4 (whole tick) |
| 500 | 110.337 | 36.165 | 33.939 | 12.760 | 12.808 | — | — |
| 1,000 | 439.993 | 65.299 | 57.537 | 30.746 | 29.659 | 20.460 → 15.926 (7.8 native) | 22.8 |
| 2,500 | 2,684.557 | 254.277 | 172.164 | 91.848 | 89.383 | 63.818 → 47.922 | 47.0 |
| 5,000 | 10,988.004 | 703.456 | 425.177 | 235.303 | 231.812 | 149.249 → 106.529 | 89.8 |
| 10,000 | not measured | 2,872.690 | 781.491 | 541.734 | 518.008 | — | 170.0 |
| 20,000 | not measured | 12,016.796 | 1,632.897 | 1,141.059 | 1,092.018 | 1,028.9 → 527.5 (7.7), 650.5 → 454.7 (7.8) | 331.7 |

Indicative cumulatively: **10,988 ms/tick at five thousand soldiers in Step 7 against 89.8 today**,
and 20,000 soldiers went from *unmeasurable* to ~0.33 s/tick. The individual columns are honest
per-milestone measurements; the ratio across columns is not a controlled experiment.

---

## 2. The techniques

### 2.1 Replace all-pairs scans with a uniform spatial grid (Step 7.2, D-059…D-071)

**What it replaced.** Every hot query — the separation pass, target search, formation awareness —
walked every soldier and tested it, i.e. O(N²) per tick.

**What it bought.** 3.1x at 500 soldiers rising to 15.6x at 5,000; it is also what made 20,000
soldiers measurable at all (12,016 ms/tick rather than a number nobody could wait for).

**The parts that mattered as much as the grid.** A query radius is a *promise*, not a hint, and the
answer is filtered by it (D-065). Walking occupied cells beats walking the cells of a box when
fewer (D-066). Bucket tails are persistent storage, so a rebuild allocates nothing (D-070).
Liveness is checked when a query is answered, not only when the index was built (D-063) — the
defect this fixed answered questions about corpses.

### 2.2 Stop re-deciding, and stagger the deciding (Step 7.3, D-079…D-087)

**What it replaced.** A soldier that lost sight of its opponent re-searched on the next tick, and
every soldier decided independently at the same moment, so the cost arrived in a wave.

**What it bought.** An automatic target is now a *persistent engagement* with a retention radius and
a switch margin (a quarter — D-081), and awareness runs on a four-tick cadence staggered by soldier
id. At 20,000 soldiers that alone was **7.36x** (12,016.8 → 1,632.9 ms/tick), and 87% of soldier-ticks
stopped looking at anything.

**Swept, not reasoned.** The retention radius was swept (8/16/24/32) and the only value with *zero*
releases per tick was the search ceiling itself (D-082) — a bound narrower than the thing it bounds
is a loop, not a rule.

### 2.3 Count before changing, and count the right thing (D-079, D-088, D-096)

**The technique.** Instrument what a subsystem *did* — how many looks, how many candidates each
handed over, which rung of the ladder they reached — before deciding how to make it cheaper.

**Why it is on this list.** "The target phase costs 387 ms" does not say whether to make the search
smaller or to stop it happening. Counting found that at 5,000 soldiers **86.3 ms of the target phase
was soldiers escalating to the widest, emptiest rung**, which is what justified a bounded ladder
(Step 7.4, D-061/D-067) and the "prove nobody is findable" skip (D-087). Target acquisition became
**3.5x cheaper** (500: 8.84 → 2.43 ms; 2,500: 79.8 → 22.8; 5,000: 286.7 → 81.3), and the same
technique later chose the formation layer's design without a line of code being read first.

### 2.4 A hierarchy of answers, and awareness as a declared capability (D-085, D-086)

**What it replaced.** "Search for the nearest enemy" as the single answer to every soldier's
question.

**What it is now.** Order → retained opponent → the formation's focus → a search, in that order, so
the expensive answer is the last resort rather than the default. Awareness is a capability a unit
*declares* (D-086) rather than a property inferred from the weapon it happens to carry, which is
what let the ranged/melee split stay correct while the cost came down.

### 2.5 Summarise once at the level that owns the data (Step 7.5, D-089…D-091)

**What it replaced.** 100 bodies asking 100 questions per tick, each answered by walking the whole
army — **2.2 million soldier-visits a tick**.

**What it bought.** One summary pass per tick (centre, count, bounds per body), then bodies compared
against bodies with the distance to a body's box as a *lower bound*, opened nearest-box-first and
stopped when the closest remaining bound beats the best candidate — exact, not approximate. Plus:
the army-wide walk is skipped entirely for soldiers that have a body (22 ms of 55 in that phase),
accumulation happens into locals with one write per soldier, counters live in one array addressed by
body index rather than a dictionary, and numbers live on the body while references live in the battle.

**What it cost.** Nothing measurable — the tick was flat (0.97–0.99x). It bought structure, and
every later milestone has cashed it in: the same layer is what makes the 20K target phase 81.8 ms
today rather than 100 ms of pure searching.

### 2.6 Keep the load-bearing `if`, and prove it is load-bearing (Step 7.6, D-068, D-096)

The cell mask — which sides are present in a cell — looks like an implementation detail and is not.
Removing it costs **602.7 → 2,776.3 ms/tick** in the target phase at 20,000 soldiers (4.6x) and
1,138.6 → 3,349.0 ms on the torture family: it buys ~2.16 s/tick of query for 4.9 ms/tick of
rebuild. It was nearly deleted as a revert's leftover, and was saved by checking whether it
predated the milestone (`git log -S`) instead of assuming.

### 2.7 Move the kernel native, behind one measured condition (Step 7.7, D-095)

**What it replaced.** The GDScript candidate scan inside the target search: ~170 candidate slots
handed over per look, scanned one by one.

**What it bought.** The search's spatial kernel now returns **one slot per search** instead of
candidate lists: target phase **591.5 → 99.5 ms/tick (5.94x)** and the whole tick 1,004.9 →
**525.5 ms (1.91x)** at 20,000 soldiers, with 83,669 queries and 29.9 million candidates answered
with **0 disagreements** against the GDScript reference. The spikes got *tighter*, not jagged
(worst tick 1,157.8 → 598.8 ms).

**The condition.** It is chosen once per battle from the army's size at `TARGET_NATIVE_MIN_UNITS`
(1,000) — the size where the measurement changes sign, because below it the snapshot and the mirror
across the boundary cost 4–5% more than the search they replace.

### 2.8 Packed arrays in GDScript with identical arithmetic (Step 7.8, D-098)

**What it replaced.** Object-heavy GDScript in the separation pass — `Vector2` components
get-modify-set per soldier through `RefCounted` objects.

**What it bought.** Positions in `PackedFloat64Array` (the same double a `Vector2` component is),
accumulators in `PackedFloat32Array`, written back per pair, enumeration order preserved so the
floating-point sums match: **2.3–3.7x on the pass, bit for bit identical** — which is what made the
equivalence test possible rather than a tolerance.

### 2.9 Native, shaped as one answer per soldier (Step 7.8, D-099)

**What it replaced.** The packed pass's remaining per-pair work.

**What it bought.** The whole separation pass runs native and returns **one displacement per soldier
per axis**; GDScript implements only the write-back. At 20,000 soldiers the overlap phase goes
237.99 → 103.28 (packed) → **42.69 ms/tick (5.58x)** and the whole tick 650.5 → **454.7 ms (1.43x)**;
at 1,000 soldiers 3.59x/1.28x. Shape matters more than the language: the candidate-list shape is
1.04x for the same boundary cost, and was rejected.

### 2.10 Lean the fix before shipping it (Step 7.8B, D-101…D-104)

**What it replaced.** Nothing — this one *fixed a bug*, and the bug fix cost 8% (32 ms/tick at
20,000) in its first cut, because the surviving-front station rule probed a dictionary and did
`Vector2` arithmetic per slot.

**What it bought.** The same behaviour at **+2.6 ms/tick (+0.7%) family A and +0.19% family B**, by a
lean surviving-frontage walk (no dictionary probe, no `Vector2` arithmetic) and by reading the live
members from the summary the tick had already built rather than rebuilding them per slot. The rule:
**a correctness fix still has to pay its own way**, and "it is needed for correctness" is not a
licence to add 8% to the tick.

### 2.11 Gate the caller, not the search (Step 7.8, the formation-driven engagement, D-105)

**What it replaced.** Every living soldier asking the battlefield a strategic question — *which
individual enemy should I attack* — while its formation already knew the strategic answer.

**What it bought.** A soldier may look for an opponent of his own only when the fight could be his
(inside his body's contact band, having just been struck, under an explicit order, or owing no body).
At realistic 20,000 soldiers: looks **2,561.9 → 532.9 per tick (−79.2%)**, individual-mode soldiers
13.0% → 2.7%, the total tick **439.6 → 408.3 ms (−7.1%)** and the target phase 105.7 → **81.8 ms
(−22.6%)**. With the armies apart or merely marching the count is exactly **zero**. The new body
pass that decides all this costs **1.3 ms/tick** at 20K and 0.02 ms at 600.

**Why it was safe.** It touches *who is asked*, not what is asked: retention, the cadence, the
ladder, the retention radius, the switch margin, the native kernel and the separation pass are all
untouched, and the old architecture is one switch away (`PB_ENGAGEMENT=off`), which makes every
figure a paired run in one build instead of a comparison against an old log.

### 2.12 Reuse a decision that has already been made

Two small examples with the same shape: the engagement layer caches each body's chosen enemy and
`_engage_target_for` reads it instead of rescanning for the nearest enemy body every tick; and the
routing of "who looks" is answered from geometry the tick already computed (positions, bounds,
living counts) rather than by asking the spatial grid. Neither is dramatic; both remove whole scans
from a hot path for free.

### 2.13 The renderer (in flight, uncommitted — see the render spike document)

| technique | replaced | measured |
| --- | --- | --- |
| instanced `MultiMesh` instead of immediate `draw_*` calls | ~17 ms of per-soldier canvas work at 600 soldiers | frozen 600: 18.83 → 2.76 ms/frame; frozen 20K: 132.73 → 19.66 ms/frame |
| a published buffer, repacked on the simulation's cadence | rewriting every instance transform each frame | 20K frozen: **2.56 ms/frame (390 fps)**, 0.06 ms to hand over, 16.93 ms per repack every ~15 frames = **1.13 ms/frame amortised** |
| packed buffer writes (`PackedFloat32Array` → `MultiMesh.buffer`) | two API calls per instance | ~0.85 µs per soldier to repack |
| detail LOD by zoom | per-soldier health bars and pips at every zoom | dropped below `battle.health_bar_min_zoom` = 2.5 |
| view culling | *nothing yet* | not implemented: zooming in currently saves no drawing |

---

## 3. The disciplines that made the wins verifiable

1. **Count what a subsystem did before trying to make it cheaper** (D-079, D-088, D-096).
2. **Keep the old implementation as the test's reference** and demand equivalence — 0 disagreements
   across 29.9 million candidates (7.7), bit-for-bit equality (7.8's packed pass). Never claim
   equality you have not measured.
3. **Enumeration order is contract, not detail** where relaxation is sequential (D-074) — and where
   it is *not* required, prefer an ordering that does not exist at all (a Jacobi pass, proven by
   reversing the roster) over one carefully reproduced.
4. **Sweep constants; do not reason them out** (cell size 7.2/7.8, retention radius 7.4, and the
   native threshold 7.7). The winning value should also have a reason, which is worth more than a
   lucky number.
5. **Sample every tick, not the average** (D-084): a system that averages well and spikes every
   sixth tick is not finished, and only the distribution shows it.
6. **Two benchmark families** (D-077): a torture field that packs an army into one small field and a
   second where the field grows with the army at realistic density, because one battlefield cannot
   answer both "does it break" and "does it scale".
7. **Hard-code past baselines** in the harness so a re-measurement cannot masquerade as the old code.
8. **Measure in one build with a switch** wherever possible: `--overlap-sweep` (7.8), the target
   backend flag (7.7), `PB_ENGAGEMENT=off` (7.8C).
9. **Profiling is development-only and allocation-free, behind a boolean** (D-064, D-070, D-091),
   and a hot path that allocates nothing says so with a counted number.
10. **Wall-clock budget runs are not comparable across builds**: a faster build fits more ticks into
    the budget and can look slower per tick. Match the window, and say which table is which.
11. **Verify a revert before trusting it**: check whether what it removed predated the milestone
    (`git log -S`, `git show <old-tip>:<file>`) before deleting it — the `_cell_mask` was one
    careless revert away from a 4.6x regression.
12. **A correctness fix still has to pay its own way** (7.8B: 8% → 0.7% before shipping).

---

## 4. Tried and rejected

Documented because the rejections are why the accepted ones are believable:

| tried | measured | outcome |
| --- | --- | --- |
| a block-level mask on top of the per-cell side mask (7.6) | no gain | reverted; it was the *revert* of this that nearly took the cell mask with it |
| the settled-cell skip in separation (7.8, D-097) | never fired in a real fight (soldiers are settled ~5–8% of ticks) | deleted, with the count recorded |
| every cheaper target search (7.6, D-094) | all slower than the existing one | the search was left alone |
| native candidate lists (7.7 shape A) | 1.04x for ~170 slots per look | rejected in favour of one-slot answers (1.91x) |
| batching accumulators into locals before writing (7.8) | more precise, therefore no longer comparable | per-pair writes kept for bit-for-bit equality |
| loosening separation / increasing reach / teleporting armies to end the 300 v 300 stalemate | forbidden by the brief, and would have hidden the real defect (a station rule chasing an unreachable anchor) | the state was fixed instead (7.8B) |

---

## 5. Where the cost is now, and what is left

Realistic 20,000 soldiers (family B, 240-tick engaged window, layer on, ms per tick):

| phase | ms/tick |
| --- | ---: |
| grid rebuild | 43.4 |
| formation focus | 48.6 |
| engagement (new, 7.8C) | 1.3 |
| formations (movement, dressing, cohesion, station) | 33.6 |
| **per-soldier update loop** | **211.7** |
| of which target selection | 81.8 |
| overlap/separation | 39.7 |
| **total** | **408.3** |

The renderer is no longer the wall at this scale: the instanced published-buffer path draws 20,000
soldiers in **2.56 ms/frame**. The simulation is: ~2.5 ticks a second at 20,000 soldiers realistic,
and inside that number the per-soldier loop is half the tick, of which the bulk is now the
*retention* path every living soldier still takes (a dictionary probe and two distance checks per
tick, ~20,000 a tick) plus movement, dressing, cohesion and separation.

Not started, and the honest candidates for the next performance milestone: the per-soldier loop
itself (its structure, not its search), the Cohort layer (sub-rolls with their own summaries, which
would let partial-contact LOD and multirate simulation exist at all), multirate simulation, and
threading. None of them is blocked by anything above, and none of them is a small change.
