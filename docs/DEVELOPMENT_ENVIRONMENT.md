# Development Environment

Living document. Update it whenever the toolchain changes.

## Machine

| Item | Value |
| --- | --- |
| Operating system | Windows 11 Home (10.0.22631, build 22631) |
| Architecture | x86_64 (AMD64) |
| CPU | Intel Core i9-12900K (24 threads) |
| GPU | NVIDIA RTX 3080 Ti |
| Shell used by Hermes | bash (Git for Windows / MSYS2) |
| Free space on `F:` at setup | ~504 GB |

## Toolchain

| Tool | Version | Location |
| --- | --- | --- |
| Godot | **4.7.2-stable** (official build `ed1daf0bf`) | `C:\Users\jayde\Tools\Godot\Godot_v4.7.2-stable_win64.exe` |
| Godot (console build) | 4.7.2-stable | `C:\Users\jayde\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe` |
| Git | 2.52.0.windows.1 | `C:\Program Files\Git` |
| Repository working copy | — | `F:\VSC Projects\Project Banner` |
| Remote | `JAYST3AM/project-banner` | `https://github.com/JAYST3AM/project-banner.git` |

### Why 4.7.2-stable

Requested: latest *stable* Godot 4.x, no betas / nightlies / release candidates.
`4.7.2-stable` is the newest stable release on the official channel (published 2026-08-18).
The **standard** build is used, not .NET, because the project is GDScript-only.

### PATH shims

`C:\Users\jayde\bin` is already on the user `PATH`, so two tiny launcher shims were added
there instead of polluting the global environment:

| Command | Points at | Use |
| --- | --- | --- |
| `godot` | GUI executable | running the game normally |
| `godotc` | console executable | any run where stdout/stderr must be captured |

The `_console.exe` variant is the one to use from the terminal: the plain `.exe` detaches
from the console on Windows, so its `print()` output is not captured. Both report the
same engine build.

Verified:

```bash
$ godot --version
4.7.2.stable.official.ed1daf0bf
$ godotc --version
4.7.2.stable.official.ed1daf0bf
```

## Primary scripting language

GDScript (typed, Godot 4 syntax). No C#. Project Banner remains primarily GDScript: one
narrowly scoped C++ GDExtension exists for the proven target-query hot loop introduced in
Step 7.7 (`native/`, D-095). Native code is not the default architecture, and expanding it
requires separate profiling and approval.

## Command reference

```bash
PROJ="F:/VSC Projects/Project Banner"

# --- Run the real game (windowed) ---
godot --path "$PROJ"

# --- Run the game with stdout captured ---
godotc --path "$PROJ"

# --- Import assets / resolve the project without opening the editor window ---
godotc --headless --path "$PROJ" --import

# --- Boot the project, run a few frames, quit (smoke test, no window) ---
godotc --headless --path "$PROJ" --quit-after 120

# --- Run the headless test suites (see tests/) ---
godotc --headless --path "$PROJ" res://scenes/dev/tests.tscn

# --- Run one suite only ---
godotc --headless --path "$PROJ" res://scenes/dev/tests.tscn -- --suite=combat

# --- Prove a campaign survives closing and reopening the game ---
#     Must be two separate processes; that is the point. See docs/GAME_ARCHITECTURE.md.
godotc --headless --path "$PROJ" res://scenes/dev/persistence_check.tscn -- --phase=write
godotc --headless --path "$PROJ" res://scenes/dev/persistence_check.tscn -- --phase=verify

# --- Drive the real game without a mouse (see scripts/core/dev_flags.gd) ---
#     Recruit in town, leave, meet the smallest bandit band, attack, fight it out.
godotc --path "$PROJ" -- --autostart-campaign=2026 --autostart-town=greywatch \
        --autorecruit=5 --autoleave --autoengage --autoattack --autostart-battle --battlespeed=8

# --- Check a single script parses ---
godotc --headless --path "$PROJ" --check-only --script res://scripts/core/main.gd

# --- Measure what a battle costs, by size (dev tooling; not part of the game) ---
#     Reports ms per tick, ticks/sec, and a setup checksum for cross-commit comparison.
#     Re-runs each size with terrain and formations off, to attribute the cost.
godotc --headless --path "$PROJ" res://scenes/dev/battle_benchmark.tscn -- --units=100,500,1000
#     The full sweep. Large sizes stop on a time budget, so they report the tick count
#     they actually managed rather than running for hours. Takes several minutes.
godotc --headless --path "$PROJ" res://scenes/dev/battle_benchmark.tscn -- --units=100,500,1000,2500,5000,10000,20000
#     Where the time goes, by phase. Costs two clock reads per soldier, so it is a
#     separate measurement and is labelled as one.
godotc --headless --path "$PROJ" res://scenes/dev/battle_benchmark.tscn -- --units=500,2500 --profile=1
#     The spatial layer alone, at constant density, so the curve is the algorithm's
#     rather than the battlefield's.
godotc --headless --path "$PROJ" res://scenes/dev/battle_benchmark.tscn -- --units=100 --ticks=1 --grid-scale=1
#     The second family: a battlefield that grows with the army, at constant density, with
#     armies that start dressed and advance into contact. Says whether contact was reached.
godotc --headless --path "$PROJ" res://scenes/dev/battle_benchmark.tscn -- --battle-units=1000,2500,5000 --units=100
#     Sweep the separation cell size without editing the config.
godotc --headless --path "$PROJ" res://scenes/dev/battle_benchmark.tscn -- --units=5000 --battle-units=100 --overlap-cell=0.9
#     Family C: the formation layer alone, against the number of bodies rather than the number
#     of soldiers. Says where comparing bodies against bodies stops being acceptable.
godotc --headless --path "$PROJ" res://scenes/dev/battle_benchmark.tscn -- --units=100 --focus-scale=1 --reliable=0
#     Family B's phase profile without re-running its unprofiled table, for a long run.
godotc --headless --path "$PROJ" res://scenes/dev/battle_benchmark.tscn -- --units=100 --battle-units=5000 --profile=1 --scaled-table=0
#     What one search costs, rather than what one tick costs: one grid query, at a chosen
#     density and spacing, so a change to the traversal can be measured in seconds. Leave it
#     alone unless you are changing the search - and read D-094 first, which is the record of
#     what happened the last time somebody did.
godotc --headless --path "$PROJ" res://scenes/dev/search_bench.tscn -- --units=20000 --queries=20000 --gap=0.25
```

`--check-only` does **not** load autoloads, so "Identifier not found: GameData" or
`DebugLogger` from that command is a false positive, not a real error.

Notes:

* `--path` must use forward slashes or escaped backslashes; the shims pass arguments
  straight through to the Windows executable, so use `F:/...` style paths.
* Exit code `0` = clean. Any GDScript parse error or failed runtime assertion returns
  non-zero, which is what the milestone workflow gates on.
* `--quit-after N` counts *frames*, not seconds.

## Known environment limitations

1. **Console output needs the console build.** `Godot_v4.7.2-stable_win64.exe` is a GUI
   subsystem binary; run it directly from bash and you get no stdout. Use `godotc`, or add
   `--headless` for validation runs. This is the single most common source of "the script
   produced no output" confusion.
2. **Export templates are not installed.** Steps 0-6 only *run* the project; nothing is
   exported to a platform binary yet. Install the `4.7.2-stable` export templates
   (~700 MB) before the first desktop export.
3. **No Android SDK / JDK configured for Godot.** Irrelevant until mobile export, which is
   not in scope for the first checkpoint. JDK 21 is present if it is ever needed.
4. **Editor UID churn.** Godot writes `uid://` values into `.tscn`/`.import` files on first
   import. `.godot/` is git-ignored, so a fresh clone re-imports and may rewrite UIDs; this
   is expected and harmless, but it means "save in the editor" can touch many files at once.
5. **Godot's first run per project re-imports assets.** A brand-new clone takes a few
   seconds longer on its first headless run.

## Repository authentication

Git identity (`Jay <jaydenln.work@gmail.com>`) already existed globally and was left
untouched. Pushing uses the `GITHUB_PERSONAL_ACCESS_TOKEN` from the Hermes secrets vault
(`%LOCALAPPDATA%\hermes\vault\vault.sh get GITHUB_PERSONAL_ACCESS_TOKEN`), supplied to git
via a per-command `http.extraheader`. The token is never written into `.git/config`.

```bash
TOKEN=$(bash "$LOCALAPPDATA/hermes/vault/vault.sh" get GITHUB_PERSONAL_ACCESS_TOKEN)
git -c http.extraheader="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)" push origin main
```

Use the `basic`/`x-access-token` form. A plain `bearer <token>` extraheader is **rejected**
(`remote: invalid credentials`) for `gho_`-prefixed OAuth tokens; and do not put the token
in the remote URL, because git then writes it into `.git/config` and into the branch's
upstream tracking ref. Verify with `grep -ri "gho_" .git/config` returning nothing.

Token scope confirmed: `repo`, `workflow`, `gist` (account `JAYST3AM`).

## Native accelerator (Step 7.7, D-095)

| | |
| --- | --- |
| Engine | Godot 4.7.2-stable; the extension declares `compatibility_minimum = "4.7"` |
| Dependency | godot-cpp, pinned to the revision in `native/GODOT_CPP_REVISION` (never floated; `build.sh` checks out the exact commit) |
| Toolchain (Windows) | Visual Studio 2022 with the C++ workload (MSVC 14.4x), Python 3, SCons (`python -m pip install scons`) |
| Toolchain (Linux/CI) | any C++17 compiler, Python 3, SCons |
| Build | `bash native/build.sh` (fetches the pin into the git-ignored `native/deps/`), or `native/build.cmd` from a command prompt; `TARGET=template_debug` builds a debug library |
| Output | `addons/pb_native/bin/` - git-ignored: a generated artifact, built by developers and by CI, never committed |
| Build mode used for benchmarks | `template_release`. The editor and headless binaries are debug builds, and the `.gdextension` points both feature sets at the optimized library on purpose, so every run in this project loads the same one; see `native/README.md` |
| Fallback | if the library is not built, `ClassDB.instantiate("NativeTargetQuery")` returns null, the grid never reaches for it, and the game runs the locked GDScript path. A missing accelerator never corrupts a battle |
| Selecting the backend | the benchmark takes `--target-backend=gdscript\|native\|compare\|full\|compare-full`; a real run selects the accelerator with `PB_TARGET_BACKEND=native` |
| Verification | `tests/test_native_query.gd` compares both backends; CI builds the extension and runs the suites with `--require-native`, so a missing library fails there instead of being skipped |
