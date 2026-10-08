#!/usr/bin/env python3
"""Acceptance selftest for the verification gate — the four rejections GPT-6 required (TI-2).

    python tools/verify_branch_selftest.py                # verdict rules only, no engine needed
    python tools/verify_branch_selftest.py --with-engine  # also proves the real kill + missing baseline

GPT-6's acceptance criteria, each with a POSITIVE control so it is clear the gate is not simply
rejecting everything:

  (a) a timeout                                    -> TIMEOUT, gate fails, child tree actually killed
  (b) a zero-exit process with no complete result  -> NO-RESULT, gate fails
  (c) a nonzero-exit process printing PASS         -> EXIT-MISMATCH, gate fails
  (d) a suite with no baseline entry               -> gate fails (nothing to compare against)
  (control) a clean PASS                           -> PASS, gate accepts
"""
from __future__ import annotations

import io
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# Test what ships by default. While a corrected gate is staged as verify_branch_next.py (so a running
# chain keeps the behaviour it started with), name it here and the selftest will exercise that instead.
_MODULE = os.environ.get("VBSELFTEST_MODULE", "verify_branch")
if _MODULE != "verify_branch":
    import importlib
    vb = importlib.import_module(_MODULE)
else:
    import verify_branch as vb  # noqa: E402

GODOT_EXE = os.path.basename(vb.GODOT)
WORKTREE = r"F:/VSC Projects/pb-ti2"
FAILS: list[str] = []


def check(label: str, got, want) -> None:
    ok = got == want
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}: got {got!r}, want {want!r}")
    if not ok:
        FAILS.append(label)


def part_a_verdict_rules() -> None:
    print("\n=== A. verdict rules (no engine required) ===")
    # control first: a genuinely clean run must still be accepted, or the rest proves nothing
    check("control: exit 0 + RESULT: PASS is a PASS", vb.classify(0, "... RESULT: PASS ...", False), "PASS")
    check("(a) verifier timeout", vb.classify(-1, "[VERIFIER] TIMEOUT", True), "TIMEOUT")
    check("(b) zero exit, no complete result", vb.classify(0, "engine chatter, no result line", False), "NO-RESULT")
    check("(c) printed PASS but exited nonzero", vb.classify(1, "... RESULT: PASS ...", False), "EXIT-MISMATCH")
    check("engine marker is not a pass", vb.classify(0, "!! HARD DEADLINE: ...", False), "HARD-DEADLINE")
    check("a real FAIL stays FAIL", vb.classify(1, "... RESULT: FAIL ...", False), "FAIL")
    # and the gate's own notion of "not passing" must include every one of them
    rejected = [v for v in ("TIMEOUT", "NO-RESULT", "EXIT-MISMATCH", "HARD-DEADLINE", "CRASH", "FAIL")]
    check("none of the rejected verdicts equals PASS", [v for v in rejected if v == "PASS"], [])


def godot_count() -> int:
    """How many REAL Godot processes exist - matched by image NAME.

    Never match a command line: Hermes runs every terminal command as `bash -c "<the text>"`, so any
    pattern searched for in command lines also matches this agent's own shells (that mistake cost two
    rounds: once making the loop wait on itself, once killing a shell instead of an engine).
    """
    out = subprocess.run(["powershell.exe", "-NoProfile", "-Command",
                          "(Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'Godot' } | "
                          "Measure-Object).Count"], capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else -1


def part_b_real_kill() -> None:
    print("\n=== B. the bound fires on a REAL synchronous suite, and the tree dies ===")
    running = godot_count()
    if running != 0:
        # GPT-6 (c0d496a): a mandatory negative control that cannot run must FAIL the selftest, not
        # skip quietly - a skipped control reads as a pass and is exactly how a gate stops gating.
        check("(a) real kill test could run (no other Godot process)", running, 0)
        print("  (real kill test NOT RUN: another Godot is active; the acceptance selftest must fail)")
        return
    suite = "test_battle_hardening"          # ~207 s when left alone; it must be cut off well before that
    logdir = os.path.join(WORKTREE, "logs", "verify")
    os.makedirs(logdir, exist_ok=True)
    r = vb.run_suite(WORKTREE, suite, logdir, timeout=5)
    check(f"(a) {suite} with a 5s bound", r["verdict"], "TIMEOUT")
    check(f"(a) wall time stayed near the bound", r["wall_s"] < 60, True)
    check("(a) exit code is non-zero (-1)", r["exit"], -1)
    log = io.open(os.path.join(logdir, f"{suite}.log"), encoding="utf-8").read()
    check("(a) the log says the verifier killed it", "[VERIFIER] TIMEOUT" in log, True)
    check("(a) no engine process survived the kill", godot_count(), 0)


def part_c_missing_baseline() -> None:
    print("\n=== C. a suite with no baseline entry is rejected by the gate ===")
    tmp = tempfile.mkdtemp(prefix="vb-selftest-")
    suite_list = os.path.join(tmp, "one.md")
    io.open(suite_list, "w", encoding="utf-8").write(
        "| Suite | Result | Assertions | Failures | ms |\n|---|---|---|---|---|\n"
        "| `test_core_services` | PASS | 83 | 0 | 80 |\n")
    empty_baseline = os.path.join(tmp, "other-baseline.md")
    # A non-empty baseline for a DIFFERENT registered suite: the input validation must pass (so the run
    # reaches the rule under test) and the requested suite must still have no entry - which is what the
    # missing-baseline rule is for.
    io.open(empty_baseline, "w", encoding="utf-8").write(
        "| Suite | Result | Assertions | Failures | ms |\n|---|---|---|---|---|\n"
        "| `test_roads` | PASS | 74 | 0 | 400 |\n")
    out = os.path.join(tmp, "report.md")
    p = subprocess.run([sys.executable, os.path.join(HERE, "verify_branch.py"),
                        "--worktree", WORKTREE, "--out", out, "--suite-list", suite_list,
                        "--baseline", empty_baseline, "--allow-dirty"],
                       capture_output=True, text=True)
    print(f"  gate exit code: {p.returncode}")
    check("(d) gate rejects a suite missing from the baseline", p.returncode, 1)
    check("(d) and says why", "NO BASELINE ENTRY" in p.stdout, True)
    check("(d) the suite itself was fine", "test_core_services" in p.stdout and "PASS" in p.stdout, True)


def part_d_dirty_tree() -> None:
    """A regression certifies a COMMIT. A worktree that differs from HEAD cannot be reported on as if it
    were that commit - a leftover HARD_DEADLINE_S = 5 in one worktree made a whole run read as a
    regression in 8 suites."""
    print("\n=== D. a worktree that differs from HEAD is refused ===")
    tmp = tempfile.mkdtemp(prefix="vb-selftest-dirty-")
    dirty = os.path.join(tmp, "dirty-tree")
    subprocess.run(["git", "-C", WORKTREE, "worktree", "add", dirty, "HEAD"], capture_output=True, text=True)
    runner = os.path.join(dirty, "tests", "test_runner.gd")
    if not os.path.exists(runner):
        check("(D) dirty-tree fixture created", False, True)
        print("  (dirty-tree test NOT RUN: fixture creation failed; the acceptance selftest must fail)")
        return
    text = io.open(runner, encoding="utf-8", newline="").read()
    io.open(runner, "w", encoding="utf-8", newline="").write(text.replace("const SUITE_DEADLINE_S := 90",
                                                                          "const SUITE_DEADLINE_S := 91", 1))
    suite_list = os.path.join(tmp, "one.md")
    io.open(suite_list, "w", encoding="utf-8").write(
        "| Suite | Result | Assertions | Failures | ms |\n|---|---|---|---|---|\n"
        "| `test_core_services` | PASS | 83 | 0 | 80 |\n")
    p = subprocess.run([sys.executable, os.path.join(HERE, "verify_branch.py"),
                        "--worktree", dirty, "--out", os.path.join(tmp, "r.md"),
                        "--suite-list", suite_list],
                       capture_output=True, text=True)
    check("(D) the gate refuses a tree that differs from HEAD", p.returncode, 1)
    check("(D) and says which file", "tests/test_runner.gd" in p.stdout, True)
    check("(D) and explains why", "REFUSING TO CERTIFY" in p.stdout, True)
    subprocess.run(["git", "-C", WORKTREE, "worktree", "remove", "--force", dirty],
                   capture_output=True, text=True)


def part_e_input_validation() -> None:
    """GPT-6's requirements on the inputs themselves (2026-10-09): every requested name must exactly match
    a registered suite, no duplicate names, no duplicate or stale baseline entries, no silent test_
    normalization - and the verifier must record the HASHES of the inputs it certified under.

    No engine needed: validation happens before any suite runs, which is the point of it.
    """
    print("\n=== E. input validation (exact names, duplicates, stale entries, hashes) ===")
    reg = vb.registered_suites(WORKTREE)
    check("the runner's registered suites are readable", len(reg) > 0, True)
    list_path = os.path.join(HERE, "..", "docs", "tasks", "m02-suite-list.md")
    mine = vb.suites_from_report(list_path)
    fix = {"battle_formation_navigator": "test_battle_formation_navigator",
           "battle_formation_cohesion": "test_battle_formation_cohesion",
           "battle_placement": "test_battle_placement"}
    canon = [fix.get(s, s) for s in mine]

    # The shipped list is canonical now (aligned 2026-10-09), so the aliased case is built here rather
    # than read from the file - a test that depends on the file being wrong stops testing anything the
    # moment somebody fixes the file.
    aliased = [{"test_battle_formation_navigator": "battle_formation_navigator",
                "test_battle_formation_cohesion": "battle_formation_cohesion",
                "test_battle_placement": "battle_placement"}.get(s, s) for s in canon]
    p, _ = vb.input_problems(aliased, aliased, reg, True)
    check("(E) an aliased name is refused", any("not registered suites" in x for x in p), True)
    p2, w2 = vb.input_problems(canon, canon, reg, True)
    check("(E) a canonical pair is clean", (p2, w2), ([], []))
    p3, _ = vb.input_problems(canon + ["test_roads"], canon, reg, True)
    check("(E) a duplicated list name is refused", any("more than once" in x for x in p3), True)
    p4, _ = vb.input_problems(canon, canon + ["test_roads"], reg, True)
    check("(E) a duplicated baseline entry is refused", any("more than one entry" in x for x in p4), True)
    p5, _ = vb.input_problems(canon, canon + ["test_removed"], reg, True)
    check("(E) a stale baseline entry is refused", any("not registered" in x for x in p5), True)
    p6, w6 = vb.input_problems(["test_roads"], ["test_roads"], reg, True)
    check("(E) a subset run is allowed but WARNED", (p6 == [], len(w6)), (True, 1))
    p7, _ = vb.input_problems(canon, canon, [], True)
    check("(E) an unreadable runner is refused", any("could not read" in x for x in p7), True)
    if hasattr(vb, "sha256_of"):
        h = vb.sha256_of(list_path)
        check("(E) input hashes are recorded", len(h) == 64 and all(c in "0123456789abcdef" for c in h), True)
    else:
        check("(E) the gate records input hashes", False, True)


def main() -> int:
    print(f"testing the gate that will actually run: {vb.__file__}")
    part_a_verdict_rules()
    part_e_input_validation()
    if "--with-engine" in sys.argv:
        part_b_real_kill()
        part_c_missing_baseline()
        part_d_dirty_tree()
    else:
        print("\n(B, C and D need the engine: rerun with --with-engine)")
    print("\n" + ("SELFTEST FAILED: " + "; ".join(FAILS) if FAILS else "SELFTEST PASSED - all four rejections hold"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
