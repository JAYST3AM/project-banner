# Project Banner - native accelerator

A GDExtension that accelerates **one** kernel: the spatial query inside automatic soldier
target search. Nothing else lives here, and this directory's existence is not permission for
anything else to move native without its own profile (see D-095).

## What is native and what is not

| | |
| --- | --- |
| Native | `NativeTargetQuery` - builds a cell index from a per-tick snapshot and walks it to hand back candidate slot numbers |
| GDScript | everything else, including the decision the query feeds: the exact distance test, the liveness recheck, the tie-break, hysteresis, cadence, formation focus, orders |
| Reason | the grid is a *snapshot* while soldiers move and die inside the same tick; the exact answer must be computed against live positions, so the native boundary stops exactly where live state begins |

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

# Windows from cmd.exe / PowerShell
native\build.cmd

# template_debug instead of the release build
TARGET=template_debug bash native/build.sh
```

Artifacts land in `addons/pb_native/bin/`, which is **git-ignored**: the library is a
generated artifact, produced by developers and by CI, never committed.

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
| `NATIVE` | the native kernel answers the queries |
| `COMPARE` | both answer every query; disagreements are counted and reported with full context |

`COMPARE` is for correctness only and is never used to claim performance.
