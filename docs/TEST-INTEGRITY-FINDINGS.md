# Test-integrity findings (registered for remediation before the Playable Alpha gate)

Registered 2026-10-09. These are defects in the verification apparatus itself, not in game code. They
are recorded here because GPT-6's Slice A review directed that they be explicitly registered for
remediation before the Playable Alpha gate: **a required fixture must either be present and tested, or
produce a failed/incomplete result — never a misleading PASS.**

## TI-1 — a missing fixture produces PASS instead of an incomplete result

**Evidence.** With an un-imported texture atlas (`res://.godot/imported/unit_atlas.png-*.ctex` absent),
`test_unit_sprites` reported `PASS (47 assertions, 0 failures)` where the baseline is
`PASS (460 assertions, 0 failures)`. The suite's own log says *"the atlas is not present: the field
draws its discs, and that path is unchanged"* — it deliberately branches on fixture presence and
passes either way.

**Why it matters.** 413 assertions were skipped and the run was green. Any release gate built on
"0 failures" would have accepted it.

**Interim mitigation (in place).** `tools/verify_branch.py` now fails on assertion drift, so this
cannot pass the gate from outside. That is a guard, not a fix.

**Required remediation.** Suites whose coverage depends on a fixture must assert the fixture's presence
and fail (or report an explicitly incomplete result) when it is missing. A suite must not be able to
silently shed assertions and still report PASS.

## TI-2 — the documented 90-second per-suite deadline is not in force

**Evidence.** `test_battle_hardening` reports an internal duration of 206,855 ms (207.3 s wall, 0.4 s
wrapper overhead) and `test_formation_engagement` 145,539 ms (145.9 s wall). Both exceed the
documented per-suite deadline of 90 seconds by a wide margin and neither is reported as a watchdog
failure.

**Why it matters.** Either the deadline does not exist as documented (documentation defect) or it is
not applied (guard defect). Both readings mean a genuinely hung suite would take far longer to detect
than the docs claim.

**Required remediation.** Establish which it is, make the code and the documentation agree, and state
the real bound per suite in the runbook.

## TI-3 — wall time and suite time are conflated in reporting

**Evidence.** `test_formation` reports 628 ms of internal suite time but takes 155.4 s wall, identically
on two different commits — 155 s of engine/setup work outside the measured section.

**Why it matters.** Wall-clock claims about suite cost are wrong by two orders of magnitude for such
suites, and "the suite takes N seconds" has no single answer.

**Required remediation.** Reports must state which figure is quoted (`ms` = internal suite duration,
`wall_s` = wrapper elapsed including engine boot and setup). `verify_branch.py` records both.
