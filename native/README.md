# Project Banner - native accelerator

A GDExtension that accelerates **two** kernels, each of which was profiled, measured and given
its own comparison mode before it was allowed to exist: the spatial query inside automatic
soldier target search (Step 7.7, D-095), and the separation pass that keeps soldiers from
standing inside one another (Step 7.8, D-099). This directory's existence is not permission for
anything else to move native without its own profile.

## What is native and what is not

| | |
| --- | --- |
| Native | `NativeTargetQuery`: builds the cell index from a per-tick snapshot, walks it, filters by side and liveness, applies the exact squared-distance test, and breaks ties to the lower unit id |
| GDScript | everything else, including the whole decision around the query: the search ladder and its radii, the D-087 proof, retained opponents, hysteresis, cadence, explicit orders, formation focus, query margin, battle orchestration, movement, damage and persistence |
| Live state | the accelerator mirrors the two places a battle changes state inside a tick - a soldier's movement and a soldier's death - so its exact test reads true positions rather than the snapshot's |
| Reason | the cell index is a *snapshot* while soldiers move and die inside the same tick, so the boundary stops exactly where live state begins - and the mirror is what makes that safe, proven by the comparison mode rather than asserted |

The GDScript path is the reference implementation, the behavioural oracle, and the fallback.
It is never deleted and CI always exercises it.

## Toolchain

| | |
| --- | --- |
| Engine | Godot **4.7.2-stable** (pinned; the extension declares `compatibility_minimum = "4.7"`) |
| Dependency | godot-cpp, pinned to the revision in [`GODOT_CPP_REVISION`](GODOT_CPP_REVISION) |
| Windows | Visual Studio 2022 with the C++ workload (MSVC 14.4x), Python 3, SCons |
| Linux | any C++17 compiler, Python 3, SCons; `platform=linux` |
| Build API | `api_version=4.7` - godot-cpp refuses to guess, which is what ties a build to the engine |

The pinned godot-cpp revision is the one whose `gdextension/extension_api-4-7.json` matches
the engine's own dumped API (`godot --headless --dump-extension-api` reports
`4.7.2.stable`; the pinned dependency ships the 4.7 API). It is **not** floated: `build.sh`
checks out the exact commit, and nothing auto-updates it.

## Build

```bash
# Windows (Git Bash) or Linux - one command; fetches the pin if needed
bash native/build.sh

# Windows from cmd.exe / PowerShell - requires Git for Windows (see below)
native\build.cmd

# template_debug instead of the release build
TARGET=template_debug bash native/build.sh
```

`native\build.cmd` is a convenience wrapper, not a native Windows build system: it finds Visual
Studio's build environment and then runs `native/build.sh`, so **Git for Windows (Git Bash) must
be installed and on `PATH`** - a stock Command Prompt without Bash cannot build this. The wrapper
checks for `bash` first and stops with that instruction rather than a shell error.

Artifacts land in `addons/pb_native/bin/`, which is **git-ignored**, and SCons writes its object
files beside the sources in `native/src/`, which is ignored too: both are generated output,
produced by developers and by CI, never committed.

`native/deps/` (the dependency checkout) and `native/.sconsign.dblite` are ignored too.

## Fallback

If the library is missing, Godot logs that the extension could not be loaded and the game
runs on the locked GDScript path - `BattleSpatialGrid` only reaches for the native class
when `ClassDB.instantiate("NativeTargetQuery")` returns something. No battle is corrupted by
a missing accelerator, and no campaign fails to open.

## Verification modes

`BattleSpatialGrid.backend` selects the query implementation:

| Mode | Behaviour |
| --- | --- |
| `GDSCRIPT` | the locked reference - native code is not called at all |
| `NATIVE` | **shape A, measurement only.** The accelerator walks the cells and hands back candidate slots; the caller keeps the exact test. Exact by construction, measured at 1.04x, not the production path |
| `COMPARE` | shape A against the reference, per query, candidate sets compared |
| `NATIVE_FULL` | **shape B, the production accelerator.** The accelerator answers the whole query - cells, side, liveness, exact distance, tie-break - and returns one slot |
| `COMPARE_FULL` | shape B against the reference, per ladder rung, answers compared with full context |

**Shape B is what ships.** A battle selects it once, before the first tick, when the army is at
or above `BattleSimulator.TARGET_NATIVE_MIN_UNITS` (1,000 - where the measurement changes sign),
or when `PB_TARGET_BACKEND=native` asks for it explicitly. Shape A stays because its exactness is
structural: if the mirror is ever suspected, it is the shape to compare against.

The comparison modes are for correctness only and are never used to claim performance.

## NativeOverlapKernel - shape C, the separation pass

Step 7.7's lesson was that a native kernel which hands its intermediate results back to
GDScript is measuring the bridge rather than the work. The overlap kernel takes that seriously:
it does **everything** - its own cell index, its own same-cell and neighbour-cell enumeration,
the exact squared-distance test, the coincident branch, the push arithmetic, the accumulation
and the clamp - and returns one number per soldier per axis: the displacement to apply.

| | |
| --- | --- |
| Native | the whole pass, and the clamp |
| GDScript | packing the field once, applying the returned displacements to the units it owns, and everything else in the game |
| Ownership | none of the battle's. It holds transient arrays sized to the army and no `BattleObject` of any kind, so there is no mirror, no mutation point, and nothing that could enter a save |
| Enumeration | the reference's, case for case: occupied cells in first-occupancy order, slots in ascending order inside a cell, the same forward half-neighbourhood in the same offset order - kept so that the floating-point sums match and the two can be compared bit for bit |
| Accumulators | `float`, matching the `PackedFloat32Array` the GDScript pass accumulates into. That rounding is part of the shipped result and is reproduced rather than improved |
| Production rule | selected once, before the first tick, at `BattleSimulator.OVERLAP_NATIVE_MIN_UNITS`; `PB_OVERLAP_BACKEND=native` forces it, and the packed GDScript pass covers the case where the library is not built |

**What it is measured against.** The locked `BattleOverlapGrid` remains the oracle: 600 generated
states and the named boundary arrangements are compared position for position and counter for
counter, and a 300-tick battle is run under each pass and fingerprinted. The comparison mode
(`BattleOverlapNative.compare_enabled`) runs the reference over the same pre-overlap field on
its own proxy copies and reports the first disagreement with ids, bodies, cells and both
displacements - and the reference's result is the one applied, so a comparison can never change
a battle.
