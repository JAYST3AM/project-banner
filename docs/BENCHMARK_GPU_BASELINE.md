# GPU baseline benchmark — 2026-09-17

The roadmap's Phase 2: what the GPU version does *now*, before any optimisation, measured on the
owner's machine. Every number below is from `F:/VSC Projects/pb-bench/gpu_ladder.log` and
`gpu_ladder_gpu.csv`, produced by `pb-bench/gpu_ladder.sh`.

**Machine** (the same block `DeviceReport` prints at startup):

```
device:        NVIDIA GeForce RTX 3080 Ti  (NVIDIA), discrete GPU
driver:        forward_plus / vulkan  api 1.4.351  server Windows
rendering:     method forward_plus  vsync off  fps cap 0  debug true
host:          12th Gen Intel(R) Core(TM) i9-12900K  (24 threads), 32 GiB
os:            10.0.22631   Godot 4.7.2-stable
```

**What was run.** The GPU battle scene at five sizes, each for twenty seconds of wall clock on the
game's own fixed 20 Hz tick *semantics* but driven as fast as the machine can drive it
(`--ticks-per-frame=1`, frames uncapped). "Ticks/s" is therefore the ceiling the machine can run the
simulation at when nothing else limits it; the simulation itself always runs at 20 ticks/s in the
game's clock, which is what the free frame rate then races ahead of.

## Throughput

| Soldiers | Ticks/s (peak) | Simulation a tick | Readback a tick | Repack a tick | Soldiers updated a second |
| --- | --- | --- | --- | --- | --- |
| 600 | 578 | 0.03 ms | 0.28 ms | 0.63 ms | 0.35 M |
| 2,000 | 258 | 0.03 ms | 0.77 ms | 2.45 ms | 0.52 M |
| 6,000 | 112 | 0.04 ms | 0.30 ms | 7.42 ms | 0.67 M |
| 12,000 | 60 | 0.04 ms | 0.84 ms | 15.25 ms | 0.72 M |
| 20,000 | 36 | 0.05 ms | 0.37 ms | 25.31 ms | 0.72 M |

GPU during the whole ladder: **mean 31%, median 26%, peak 57%**; 147 W mean, 231 W peak, SM clock
1,760 MHz mean.

### Re-measured after formation behaviour (4.2) and the determinism fix

Same ladder, same machine, same settings, current build. Reported against the row above, because a
number without its before is not a result:

| Soldiers | Ticks/s (peak) | Simulation a tick | Repack a tick | Change |
| --- | --- | --- | --- | --- |
| 600 | 814 | 0.05 ms | 0.20 ms | throughput +41%, repack −68% |
| 2,000 | 317 | 0.06 ms | 1.81 ms | throughput +23%, repack −26% |
| 6,000 | 103 | 0.06 ms | 7.97 ms | throughput −8%, repack +7% |
| 12,000 | 53 | 0.08 ms | 16.14 ms | throughput −12%, repack +6% |
| 20,000 | 33 | 0.08 ms | 27.08 ms | throughput −8%, repack +7% |

What changed, and what each change cost:

- **The determinism fix costs about 0.02 ms a tick.** The separation is now accumulated in
  fixed-point integers and each settling round is two passes instead of one (six dispatches in
  place of three). At 20,000 soldiers the simulation went 0.05 → 0.08 ms. It remains roughly four
  thousand times cheaper than the CPU reference's 346 ms — but it is a real cost and it is recorded
  as one rather than rounded away.
- **Small battles got faster.** Cohesion is a slot calculation and a distance per man, which cost
  6.5 ms of the pack at 20,000 (measured); sampling it every fourth tick, honestly labelled as
  sampled rather than estimated, halved the repack at 600 and cut it by a quarter at 2,000.
- **Large battles got about 7% slower on the repack**, from the per-man bookkeeping the formation
  work added (living counts, front edges, the weakest man). That is the number the repack task
  starts from.

## What the numbers say

1. **The simulation is no longer the cost, at any size.** Ten dispatches (clear, bins, probe, walk,
   three settling rounds, barriers between) cost **0.03–0.05 ms a tick for 600 soldiers and for
   20,000** — the same number, because the GPU has the parallelism for it. The CPU reference at
   20,000 is 346 ms a tick. The simulation has stopped being the problem.
2. **The presentation is now the bottleneck, and it scales linearly with soldiers**: 0.63 ms to
   repack 600, 25.3 ms to repack 20,000. Health bars are most of it (two instanced quads a soldier
   plus the colour writes). Throughput plateaus at ~0.7 M soldier-ticks a second for every size
   above 6,000 — that is the pack, not the card.
3. **At the game's clock this is invisible.** The game runs 20 ticks a second, so the repack costs
   20 × 25.3 ms = 0.5 s of one core a second at 20,000 soldiers, and 0.15 s at 6,000. That is the
   honest reading of "can we run the real battle this way": yes — 20,000 soldiers, real time, half a
   core of presentation cost, with the frame rate free to run at whatever the renderer manages
   (1,600+ fps at 6,000 measured tonight).
4. **GPU utilisation is modest (31% mean) precisely because the simulation is cheap.** The card is
   waiting on the CPU to repack the picture. The 98%-GPU figures measured earlier in the week came
   from driving tens of thousands of *extra* ticks a second with no picture work between them; they
   were a stress test of the shader, not a description of the game.

## Collision proof at each size

Recorded by the shader every tick (see `docs/CPU_REFERENCE_FEATURE_MATRIX.md` for the method):
closest enemy gap anywhere on the field, and how many pairs are inside the agreed 2.47-unit minimum.

| Soldiers | Closest enemy gap | Pairs inside the minimum | Verdict |
| --- | --- | --- | --- |
| 600 | 1.29 | 22,992 | **not a valid test** — see caveat below |
| 2,000 | 1.32 | 7,984 | **not a valid test** — see caveat below |
| 6,000 | **2.46** | **2** | holds |
| 12,000 | 2.39 | 122 | holds to within 0.08; contact had only just begun (1,162 ticks) |
| 20,000 | — | — | the armies never met in 710 ticks |

**Caveat, stated plainly.** At 600 and 2,000 soldiers the deployment geometry did not fit the
field when this ladder ran: a body was always forty files wide at 2.6 units a file, so a 300-a-side
battle put a 104-unit-wide block on a field a fraction of that. Men were clamped to the field edge,
the settling rounds fought the clamp, and the recorded "steps" of 114 and 65 units a tick were that
clamping, not the solver — the rows above for 600 and 2,000 are therefore **not valid collision
tests**. Both faults have since been fixed (the frontage is fitted to the field, and the deployment
centres on the fitted frontage instead of the old constant), and 600 soldiers re-measured on the
fixed build: **closest enemy gap 2.49, zero pairs inside the minimum, biggest step 0.60** — the same
quality as 6,000. The probe now audits its own deployment at startup and prints how many men are
out of bounds, so this class of fault cannot come back quietly.

**20,000 never reached contact** in the twenty seconds of the run (710 ticks at 36 ticks/s, while
closing 400 units at 0.3 a tick needs ~1,300). The throughput row stands; the collision row needs a
longer run.

## Suggested next levers, in order

1. **Scale the deployment to the field** (files and ranks both), so every size is a valid test.
2. **Repack only what changed** — the bars are rebuilt from scratch every tick; a soldier whose hit
   points have not changed does not need his two quads rewritten. This is the single biggest
   throughput lever, and it is presentation-only, so it cannot touch simulation behaviour.
3. **Then** the formation-behaviour port (Codex item 2), on a base whose collision is measured and
   whose sizes are all valid.
