# Project Banner — native soldier-batch spike (2026-09-16)

**What this document is.** The record of one day's work on the per-soldier loop: what was asked
(Struct-of-Arrays, SIMD, a job system, and multirate cohorts, targeting the 211.7 ms loop), what was
built and measured, what the measurements prove, what they *disprove*, and what the plan now is. It
is written to be audited without re-running anything.

**Repository state.** Branch `main`, HEAD `a05a34b` at the start of this work. This spike's files are
committed (see §7); the *render-path* spike's eleven files are a separate, uncommitted workstream and
were not touched.

**Host.** i9-12900K (24 cores), RTX 3080 Ti, Windows 11, Godot 4.7.2-stable. Matched windows
throughout; every paired figure was taken back to back in one session.

---

## 1. The question, decomposed

"Refactor the 20,000-soldier simulation with GDExtension, SIMD, a job system and multirate cohort
sub-stepping" is four different bets, and they have different pay-offs. This spike set out to price
them rather than assume them:

1. **SoA + native kernel** for the per-soldier work — is the arithmetic actually the cost?
2. **SIMD** — does the layout buy vectorisation, and does it matter next to memory traffic?
3. **A job system** — how much is there to parallelise, and what does determinism cost?
4. **Multirate cohorts** — the only one of the four that *removes work* rather than making it
   cheaper, and therefore the only one that should be designed before it is built.

---

## 2. What was built

| file | what it is |
| --- | --- |
| `native/src/native_soldier_batch.h/.cpp` | `NativeSoldierBatch`: the awareness slice of the per-soldier loop over a struct-of-arrays layout, with a persistent worker pool, fixed block partitioning and per-block counters merged in block order |
| `native/src/register_types.cpp` | registers the class alongside the two Step 7.7/7.8 kernels |
| `scenes/dev/soldier_batch_bench.tscn` + `scripts/dev/soldier_batch_bench.gd` | the live-battle harness: builds the arrays, runs the kernel at one worker and at the machine's default, runs a GDScript mirror of the same decision over the identical arrays, and calls **the sim's own functions** on a sample so the kernel's decisions are compared against their authority, not against another copy of my arithmetic |
| `tests/test_soldier_batch.gd` | the CI-affordable half: pool determinism, the pass's decisions, the small-batch path, and the refusal of mismatched arrays (24 assertions, 0 failures) |

Nothing in the game calls it yet: the class is additive, loads with the shared library, and changes
no existing behaviour.

---

## 3. Measurements

`res://scenes/dev/soldier_batch_bench.tscn`, live battles, seed 780780, decisions and counters only
(no searches: this pass decides, it does not look):

| soldiers | workers | blocks | arrays (build) | kernel | kernel, 1 worker | GDScript mirror | kernel vs mirror | rule check | array check |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,200 (600/side), 4 ticks | 23 | 2 | 1,293.8 µs | 77.8 µs | **23.8 µs** | 210.8 µs | 8.9x | 0 of 240 sampled | 0 of 4,800 |
| 40,000 (20,000/side), 12 ticks | 23 | 32 | **45,463.8 µs** | 151.8 µs | 168.0 µs | 6,663.0 µs | **43.9x** | **0 of 24,000** | **0 of 480,000** |

- **The kernel's own cost is 3.8 ns a soldier** (151.8 µs for 40,000) against 167 ns for the same
  decision in GDScript: **44x**, with **zero disagreements** against the sim's own
  `_retained_target` and `_formation_driven_search_allowed` on 24,000 sampled soldiers, and zero
  against the element-by-element mirror on 480,000 decisions.
- **The pool is deterministic by construction and by measurement**: a reduction over the same batches
  is bit-identical at one worker and at twenty-three. The first version of it was *not* — the block
  count depended on the pool, so the same numbers were summed in different groupings (see §5).
- **The pool only pays for work worth parallelising.** At 1,200 soldiers one worker beat twenty-three
  (23.8 µs against 77.8 µs: a dispatch costs ~50 µs); at 40,000 the pass is still small enough that
  the two are within 10% of each other. Threads are for *heavy* per-soldier work, not for this
  arithmetic.
- **The cadence shows up in the counters, which is a good sign**: of 40,000 soldiers, 10,000 per tick
  were due and 30,000 were not — exactly the four-tick awareness cadence, from a kernel that has no
  idea what a cadence is.

---

## 4. What this proves, and what it disproves

**Proved.** The awareness decision is genuinely SoA-shaped and the kernel is faithfully identical to
the rules it mirrors. On a 40,000-soldier field, 480,000 decisions were compared and none differed.
The layout, the pool, the partitioning and the counters are all correct and CI is guarding them.

**Disproved, and this is the important half.** *As wired, a native pass on this slice would make the
tick slower, not faster*: building the input arrays from the simulation's objects costs **45.5 ms at
40,000 soldiers** — three hundred times the kernel's own 0.15 ms — so the boundary, not the
arithmetic, is the bill. This is Step 7.7's lesson arriving again with a number attached: a native
accelerator is paid for by what crosses it, and an object-based simulation has to *serialise itself*
to cross.

**What that means for the target phase.** The sim's target phase at 20,000 soldiers is 81.8 ms/tick.
Of that, ~21 ms is the ~533 searches a tick (Step 7.7's kernel, already native) and ~60 ms is the
per-soldier decision path around them — roughly **3 µs a soldier** to fetch a remembered opponent,
check three fields and compare two distances. The same decision costs **167 ns** of arithmetic in
GDScript when the data is already in arrays, and **3.8 ns** in the kernel. The difference between
3 µs and 167 ns is not arithmetic; it is *reaching into RefCounted objects ten million times a
second*. That is the real prize, and it is only reachable if the state lives in arrays that the
native side already owns — not if it is copied across a boundary every tick.

---

## 5. Two bugs the harness caught (recorded because they are the point)

1. **The pool's block count depended on the pool.** `blocks = min(workers + 1, ...)` made a batch sum
   into two partials when running alone and twenty-four partials on this machine — the same numbers
   added in different groupings, disagreeing in the eighth decimal place. A reduction merged in block
   order is only bit-identical at any worker count if the *blocks* are the same blocks, so the block
   count is now a function of the batch alone (`MIN_BLOCK` 1024, `MAX_BLOCKS` 32) and the probe
   asserts it.
2. **The kernel conflated the retention radius with the soldier's reach** (32 against 2.4). Caught
   while writing the harness, before it produced a single wrong number: the sim keeps two distances
   apart — one says whether an opponent is still worth remembering, the other whether it can be
   struck now — and a kernel that merges them silently changes who fights whom.

---

## 6. The plan, in the order the measurements force

**Tranche 1 — the loop's state moves into arrays (the only order that works).** Positions, liveness,
sides, reach, remembered opponents and cadence step are owned by a struct-of-arrays block that the
simulation keeps resident and mirrors to the game's objects (for the view and for events) rather than
rebuilding from them. This is the piece that removes the 45.5 ms boundary and the ~60 ms of object
traversal together; done as a kernel-per-tick it is a *loss*, which is what today measured. The
render spike's instanced field is already the same idea on the drawing side, and the two should be
designed together: one SoA block, one mirror, two consumers.

**Tranche 2 — the movement and dressing pass moves native, with the deterministic reduction.** This
is where the job system earns its keep: per-soldier steering is heavier than a distance test, and it
contains the one genuine cross-soldier reduction in the loop (a body's cohesion). The pool runs
element-wise passes deterministically today; a reduction needs fixed blocks, per-block partials and a
merge in block order, and the probe for that is already in place.

**Tranche 3 — multirate cohort sub-stepping, and only after its rates are measured.** The cohorts
already exist conceptually (a body is a roll of ids; a cohort is a sub-roll) and this milestone's
counters say how much of an army is in each state: at 20,000 realistic, 2.7% of soldiers are in the
fight at any moment (Step 7.8C) and 5–8% of soldier-ticks are settled in their places (Step 7.8's
own count). Those two numbers are the ceiling on what rates can buy: a cohort out of contact and
settled does not need its contact, cohesion and separation work recomputed every tick, and a
quarter-rate pass over three-quarters of an army is a bigger saving than any kernel that makes the
full-rate pass cheaper. It changes behaviour, so it needs its own brief and its own equivalence
evidence — a lowered rate must be provably invisible in a battle's outcome.

**Not in this plan, deliberately:** an ECS (the project's rule), threads inside gameplay code the
project has not measured, and any C++ rewrite of subsystems outside the loop.

---

## 7. What is committed

`native/src/native_soldier_batch.{h,cpp}`, `native/src/register_types.cpp`,
`scenes/dev/soldier_batch_bench.tscn`, `scripts/dev/soldier_batch_bench.gd`,
`tests/test_soldier_batch.gd`, `tests/test_runner.gd`, and this document. The built library is a
git-ignored artefact (`addons/pb_native/bin/`, built by `bash native/build.sh`, and by CI on a clean
runner).

## 8. Verdicts

- **A native SoA awareness kernel: YES.** 44x on the decisions, 0 disagreements out of 480,000, and a
  deterministic pool. It is not wired into the game because wiring it alone would be a loss.
- **Wiring kernels into the current object-based simulation: NO.** Measured: the boundary costs 300x
  the kernel. The representation has to move first.
- **Threading: not yet.** The passes worth threading are the heavy ones (movement, dressing,
  cohesion); this arithmetic is too small for a dispatch to pay for itself, and that is a
  measurement, not a preference.
- **Multirate cohorts: the largest remaining lever, and not started.** It is the only technique of the
  four that reduces work rather than re-homing it.

`NATIVE SOLDIER-BATCH SPIKE: kernel YES, integration NO (as wired), representation-first.`
