# verify_branch.py — the acceptance gate for a branch

Runs a branch's suite list headlessly, one engine process per suite, and reports raw results with an
assertion-count comparison against a recorded baseline.

    python tools/verify_branch.py \
        --worktree <worktree> --out <report.md> --suite-list <suite-list.md> \
        --baseline <baseline-results.md> --json <results.json>

## Why it fails on drift, not only on failures

A suite that PASSes while asserting fewer checks than the baseline is a gate that has stopped gating.
This was not hypothetical: with an un-imported texture atlas, `test_unit_sprites` reported **PASS with
47 assertions where the baseline has 460** - 413 assertions silently skipped, no failure recorded.
`verify_branch.py` therefore computes per-suite assertion drift and returns non-zero if ANY inherited
suite asserts a different number of checks. Every report states either the drift table or
"Assertion drift vs baseline: none".

Evidence, both directions (reproduced 2026-10-09, one-suite runs, exit codes measured without a pipe):

| Case | Result |
| --- | --- |
| Baseline records `test_persistence` = 121, actual run = 150 | exit **1**, `ASSERTION DRIFT vs BASELINE: 1 suite(s) — the gate is NOT satisfied` |
| Baseline records `test_persistence` = 150, actual run = 150 | exit **0**, `ASSERTION DRIFT vs BASELINE: none` |

Policy agreed with GPT-6: an intentional change to an inherited suite's assertion count must be
explicitly reviewed and approved. The drift gate is never relaxed to absorb an unexplained difference.

## The three environment traps that change results silently

A run is only comparable when all three are in place. Each was reproduced on 2026-10-08/09.

| Missing | Symptom |
| --- | --- |
| imported textures (`.godot/imported`) | `test_unit_sprites` PASSes with 47 assertions instead of 460 — it takes its "atlas absent" path |
| this tree's class cache | classes the branch adds read as `Identifier "X" not declared in the current scope`; the affected suites report `BROKEN (0 assertions, 1 failures)` in milliseconds |
| the native module (`addons/pb_native/bin/`) | under `--require-native`: `test_native_query`, `test_soldier_batch` and both overlap suites fail |

Recipe:

    robocopy '<MAIN TREE>\.godot\imported' '<WORKTREE>\.godot\imported' /E /NFL /NDL /NJH /NJS /NP
    mkdir -p <WORKTREE>/addons/pb_native/bin && cp '<MAIN TREE>/addons/pb_native/bin/'* <WORKTREE>/addons/pb_native/bin/
    <godot> --headless --path <WORKTREE> --import          # caches then describe THIS tree

Never copy `global_script_class_cache.cfg`, `uid_cache.bin`, `scene_groups_cache.cfg` or
`extension_list.cfg` from another tree; if a whole `.godot` was copied, delete those and re-import.

## Timing: what the numbers mean

`--json` records both the runner's internal suite duration (`ms`) and the wrapper's elapsed time
(`wall_s`). They are not interchangeable:

- `test_battle_hardening` 206,855 ms internal / 207.3 s wall — the suite genuinely runs ~207 s, so the
  documented 90-second per-suite deadline is not in force for it.
- `test_formation` 628 ms internal / 155.4 s wall — 155 s of engine and setup work the runner does not
  count as suite time.

Quote the internal figure for suite cost and the wall figure for wall-clock planning, and say which.
