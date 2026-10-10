# GPU Combat Slice 3 — Automatic Target Acquisition & Hysteresis

**Milestone:** E6 / GPU Combat S3 (candidate; unverified).
**Base:** `7c0642e45bc1032e5f18b856285f96f7fc1b2ef6` (E1–E3, S1 and S2 already merged).
**Branch:** `gpt6/gpu-combat-acquisition-s3`.
**State:** Corrective candidate awaiting renewed Hermes certification. Earlier tip `4da2c0aa` compiled and passed the S1/S2/S3 real-GPU windowed gate but failed four copies of one unsupported headless casualty assertion. It was not certified and must not be merged. The correction below has not yet been run by Hermes.

## Changed files — S3-only, GitHub blob SHA-1 and UTF-8 sizes

- `scripts/battle/battle_combat_acquisition_gate.gd` — Independent pure CPU oracle, fixed-seed battle snapshots, 17 adversarial cases, eight reasons, strict hysteresis and mismatch diagnostics. Blob `0032b9d83bc7eab49e0f2be69387ee000d5c9392`; 9643 bytes; verified LF and final newline.
- `scripts/battle/battle_gpu_acquisition_probe.gd` — Windowed Vulkan-only independent GPU candidate computation; four input/output buffers, checked readback and owned resource cleanup. Blob `4a6e0a9bd50d54ad336b144262457b3c8e04e5f8`; 5423 bytes; verified LF and final newline.
- `scripts/dev/gpu_combat_equivalence.gd` — Extends existing S1/S2 windowed gate with 17 adversarial comparisons and four seeded live-battle traces; fails closed on the first error. Blob `84a48910be02c1f07ce924e420d9928b0779bab8`; 7076 bytes; verified LF and final newline.
- `shaders/dev/gpu_combat_acquisition.glsl` — Independent local-nearest enemy GPU scan, ID-based deterministic tie-breaking and strictly better challenger threshold. Blob `d6a53a079f26f2df7739dedb08cb0ceaffed3ed3`; 3015 bytes; verified LF and final newline.
- `tests/test_combat.gd` — Four new named headless suites exercising the independent oracle, reason and tie coverage, real seeded CPU-shadow traces and negative failure diagnostics. Blob `e843f9f914c8de499d6f5e6ce8ee8a7c0ca678ac`; 36085 bytes; verified LF and final newline.
- `docs/GPT_NOTES.md` — Updates the top-level milestone index so E3 historical notes are not mistaken for the current Slice 3 head; its final blob and bytes appear in the delivery readback.
- `docs/tasks/e6-s3/GPT_DELIVERY.md` — This standalone, independently titled source/acceptance note. Its final blob and bytes appear in the delivery readback.

## What is independently equivalent — and what is not

Slice 3 is **opt-in, off by default** and is invoked **only** by `scenes/dev/gpu_combat_equivalence.tscn`. It reads a complete pre-tick roster into a Vulkan compute shader. The GPU independently computes **the nearest currently eligible living enemy inside the soldier's maximum local search radius**, breaking exactly equal squared distances by the **lowest soldier ID**, and optionally compares that candidate with the **living, hostile incumbent within the soldier's retention radius**. A replacement is eligible only when `candidate_distance_squared * target_switch_advantage_squared < incumbent_distance_squared` (strict inequality). No candidate, acquisition, incumbent already nearest, hysteresis hold, switch, valid incumbent beyond local search, dead owner and explicit-order precedence are separate reason codes 1/2/3/4/5/6/0/7. Output is a four-int tuple `(chosen_id, reason, nearest_id, retained_id)` per soldier.

The **CPU oracle** in `BattleCombatAcquisitionGate` independently scans `BattleUnit` objects; it does **not** call the production `_nearest_local_enemy`, `_retained_target`, `_clear_improvement`, or `_search_for_target` methods and does not use GPU results. Its 17 fixtures exercise all eight reasons, the lower-ID tie under reversed input order and coincident coordinates, exact 1.25 threshold where retained must win, a 1.24 threshold where challenger wins, a tie to an incumbent with higher ID, individual awareness override, ignored allies and dead enemies.

The GPU gate compares **all soldiers and all four output components** on every fixture and pre-tick live snapshot, returning **first soldier ID, subfield and tick** on divergence. Four seeded live fights then replay independent CPU `BattleSimulator` instances and compare identities, targets, hits, health, casualties, events, winners and timestamps tick by tick using the S1 trace. The CPU simulations remain identical and authoritative; GPU decisions are **never adopted**.

### S3 seeded scenario: legitimate no-casualty stalemate (verification correction)

The S3 seeded battle is **not** the S1/S2 explicit-order combat fixture. `BattleCombatAcquisitionGate.live(seed)` builds from the S2 retention scenario, **removes explicit attack orders**, configures a cached opponent and absent cache on alternate soldiers, and inherits a deferred `next_search_tick = 400`. The rigid formation slots in these four small fights prevent soldiers from reaching melee contact. Hermes's first independent windowed run measured **121 ticks, no winner, zero casualties** for all four seeds (101, 2026, 4096, 73001); this is a legitimate timeout/stalemate for the scenario, **not** a failed equivalence decision. Each real-GPU run nonetheless evaluated per-tick target candidates, producing 968 live acquisitions and 968 switches across the four seeds. This is not evidence of successful lethal combat.

The original headless regression incorrectly demanded `casualties >= 1` on those same runs, so one assertion failed four times despite matching CPU-to-CPU traces and an accepted real-GPU result. **Option (b) correction:** remove the minimum-casualty assertion, retain the already-executing per-tick comparison of identity, target state, health, casualties, combat events and final outcome, and retain the proof that steps executed and the headless test claimed zero GPU decisions. The production scenario, GPU algorithm, strict hysteresis, existing S1/S2 gates and windowed acceptance checks remain unchanged. A future scenario that specifically tests *lethal* automatic acquisition belongs in a separate fixture with controlled movement/engagement rather than an invented casualty threshold on this one.

Previous gate numbers: import PASS; all three real-GPU gates PASS; frozen 48-suite run had 16,229 assertions and four failures, exclusively the repeated minimum-casualty assertion in `test_combat` (454 checks). Removing only that assertion from each of the four seed iterations **predicts**, but does not prove, 450 assertions in `test_combat` and 16,225 in the 48-suite regression. Hermes must rerun and confirm the actual numbers before certification.

**Important limitation:** This is a **bounded, pure local target-candidate plus hysteresis kernel**. It is **not** production automatic targeting equivalence at arbitrary instants. The production solver can defer search based on cadence, formation focus, contact and retaliation; the GPU snapshot does **not** emulate those gating decisions, the escalation ladder with nonstandard escalation factors, or mid-tick death ordering. Its search uses the maximum permitted radius rather than executing the production ladder's successive rungs, which is equivalent for valid geometric nearest-neighbor queries when the ladder increases to that maximum. Hysteresis eligibility has no side effects. These limitations must not be reported as solved.

**Never GPU-owned in this slice:** battle mutation, target state writes, true selected target adoption, soldier movement, attack cooldown, hit RNG, damage, casualties, winner, battle result, campaign resolution, or persistent world state. `BattleSimulator` and `BattleResolver` have **zero changes**. S1 and S2 GPU probes and shaders remain untouched; the original S1 and S2 runner sections are preserved.

## Certification required — evidence or no gate

1. Godot 4.7.2 import/compile on the **fetched** worktree, return code 0, no GDScript or SPIR-V errors.
2. Targeted `test_combat` with all four new named sections executing: **GPU acquisition S3: all eight reason codes and adversarial inputs**, **deterministic ties and strict hysteresis**, **four live seeded battles preserve every CPU result**, **first divergent soldier decision and tick**. Report assertions/failures and the exact delta versus current main.
3. Exclusive-machine Vulkan run of `res://scenes/dev/gpu_combat_equivalence.tscn`, exit code 0, with **S1, S2 and GPU COMBAT ACQUISITION PASS** lines, four seeded S3 verdicts, 17/17 static fixtures checked on real GPU, all 8 reason codes, nonzero GPU decisions, live acquisitions and switches; no RID leak or shader errors. A GPU unavailable or short readback path must fail, not fall back.
4. Frozen **48/48** suites with **all summary lines present**, zero failures, exact per-suite assertion delta reconciled to **16,113** on S2 main. The native GDExtension binary is provisioned by Hermes as before; never modify code to hide its gitignore exclusion. Existing E3 smoke may be rerun unchanged.
5. Exactly seven changed files, each read back from GitHub by blob SHA-1, UTF-8 byte size and LF/final-newline status. If a post-publication correction is required, move the candidate head and **repeat the complete readback**, then report only the settled final head.

No local Godot/Vulkan executable, private native GDExtension or exclusive runtime was available to GPT-6. **No compilation, target-suite, GPU pass, performance claim or 48-suite success is asserted for S3 until Hermes supplies raw evidence.**

## Follow-on work explicitly deferred

GPU search cadence, formation focus, retaliation priority, explicit target order application, mutation of cached targets, native spatial query equivalence under every broadphase shape, mid-tick changes, deterministically equivalent CPU/GPU damage and victory, campaign writeback, and measured throughput at large battle sizes. Separate certified slices are required; do not silently adopt this O(n²) probe into gameplay.
