#!/usr/bin/env python3
"""Run a branch's full suite list headlessly and report raw results, with an optional baseline diff.

    python tools/verify_branch.py --worktree "F:/VSC Projects/pb-m02-formation" \
        --out "F:/VSC Projects/pb-m02-formation/docs/reports/m02-formation-verification.md" \
        --baseline "F:/VSC Projects/project-banner-mcp/docs/tasks/baseline-suites-warm.md"

One engine process per suite, as the baseline did: `--require-native` so a missing native module
fails loudly instead of silently degrading. Raw output per suite is kept in <worktree>/logs/verify/.

TI-2 (GPT-6 review, 2026-10-09): THIS PROCESS IS THE AUTHORITATIVE WATCHDOG.

- It owns the per-suite bound (--timeout, default 900 s). Godot's own in-process marker only catches a
  suite that stalls WHILE YIELDING; a synchronous suite blocks its main thread and can never trip it, so
  the bound that actually holds for one has to live outside the engine, on the child process.
- On expiry the child PROCESS TREE is killed and the suite is failed here, independently of whether the
  engine flushed any output - a forced termination loses buffered output, so no marker printed by the
  engine may be the only safeguard.
- A suite is PASS only when the engine exits 0 AND its own result line says PASS. The reverse cases are
  real: a kill can exit 0 (Windows TerminateProcess), and a run can print PASS and still die.
- A suite with no baseline entry is a gate failure, not a curiosity: with nothing to compare against,
  a shed assertion looks like a pass. Add it to the baseline deliberately.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time

GODOT = r"C:/Users/jayde/Tools/Godot/Godot_v4.7.2-stable_win64_console.exe"
RESULT_RE = re.compile(r"\((\d+)\s+assertions,\s+(\d+)\s+failures,\s+(\d+)\s*ms\)")
VERDICT_RE = re.compile(r"RESULT:\s*(PASS|FAIL)")
# The per-suite bound the verifier enforces on the child process. 900 s = ~4.3x the slowest measured
# suite (test_battle_hardening ~207 s), deliberately loose because the harness can add ~155 s of wrapper
# time around a suite that itself takes under a second (TI-3).
DEFAULT_TIMEOUT = 900


def suites_from_report(path: str) -> list[str]:
    """Suite names from a markdown table of a previous run (`| `name` | ...`)."""
    names = []
    for line in open(path, encoding="utf-8"):
        m = re.match(r"\|\s*`([a-z0-9_]+)`\s*\|", line.strip())
        if m:
            names.append(m.group(1))
    return names


def baseline_numbers(path: str) -> dict[str, int]:
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"\|\s*`([a-z0-9_]+)`\s*\|\s*(PASS|FAIL)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|", line.strip())
        if m:
            out[m.group(1)] = int(m.group(3))
    return out


def kill_tree(pid: int) -> None:
    """Kill the process AND its children: the Godot console shim spawns the real engine, so killing the
    parent alone leaves an engine burning CPU - which then inflates every later timing on this machine."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True)
    else:  # pragma: no cover - this project runs on Windows
        import signal
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except ProcessLookupError:
            pass


def classify(code: int, out: str, timed_out: bool) -> str:
    """The verdict, in order of what actually HAPPENED rather than what the engine last printed.

    Pure, so the gate's rejection rules can be demonstrated without an engine run (see
    tools/verify_branch_selftest.py) - the four cases GPT-6 required proof for are all here.
    """
    if timed_out:
        return "TIMEOUT"                      # the verifier's own bound fired
    if "HARD DEADLINE" in out:
        return "HARD-DEADLINE"                # the engine's supplementary marker
    v = VERDICT_RE.search(out)
    if v and v.group(1) == "PASS" and code != 0:
        return "EXIT-MISMATCH"                # printed PASS, died non-zero: not a pass
    if v:
        return v.group(1)
    return "CRASH" if code != 0 else "NO-RESULT"   # no result line: never a pass


def run_suite(worktree: str, suite: str, logdir: str, timeout: int = DEFAULT_TIMEOUT) -> dict:
    cmd = [GODOT, "--headless", "--path", worktree, "res://scenes/dev/tests.tscn",
           "--", f"--suite={suite}", "--require-native"]
    t0 = time.time()
    timed_out = False
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            creationflags=(subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0))
    try:
        out, _ = proc.communicate(timeout=timeout)
        code = proc.returncode
    except subprocess.TimeoutExpired:
        kill_tree(proc.pid)
        try:
            out, _ = proc.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            out = ""
        code = -1
        timed_out = True
        out = (out or "") + (f"\n[VERIFIER] TIMEOUT: no result after {timeout}s - the process tree was "
                             f"killed. This is a FAILED suite; nothing about a killed run is a pass.\n")
    elapsed = time.time() - t0
    with open(os.path.join(logdir, f"{suite}.log"), "w", encoding="utf-8") as fh:
        fh.write(out)

    m = RESULT_RE.search(out)
    assertions = int(m.group(1)) if m else -1
    failures = int(m.group(2)) if m else -1
    ms = int(m.group(3)) if m else -1
    verdict = classify(code, out, timed_out)
    return {"suite": suite, "verdict": verdict, "assertions": assertions, "failures": failures,
            "ms": ms, "exit": code, "wall_s": round(elapsed, 1), "timed_out": timed_out}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--suite-list", default="", help="markdown report to read suite names from")
    ap.add_argument("--baseline", default="", help="markdown report to compare assertion counts against")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                    help=f"per-suite wall bound in seconds, enforced on the child process "
                         f"(default {DEFAULT_TIMEOUT})")
    ap.add_argument("--json", default="", help="also write raw results as JSON here")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="certify a worktree that differs from HEAD (normally refused - see below)")
    args = ap.parse_args()

    # A regression run certifies a COMMIT, so the tree must be that commit. This is not hypothetical: a
    # leftover experiment in a worktree (HARD_DEADLINE_S = 5 left uncommitted in tests/test_runner.gd)
    # killed every suite slower than five seconds and the run read as a real regression in 8 suites.
    # Untracked files (Godot's .uid companions) are normal and are not counted.
    porcelain = subprocess.run(["git", "-C", args.worktree, "status", "--porcelain"],
                               capture_output=True, text=True).stdout
    modified = [ln for ln in porcelain.splitlines() if ln.strip() and not ln.startswith("??")]
    if modified and not args.allow_dirty:
        print("REFUSING TO CERTIFY: the worktree differs from the commit it would be reporting on.")
        for ln in modified:
            print(f"   {ln}")
        print("Commit or discard those changes first. A regression run describes one commit; anything "
              "else is a run of an unknown tree. (--allow-dirty overrides, and says so in the report.)")
        return 1
    if modified:
        print(f"WARNING: certifying a dirty tree by request - {len(modified)} modified file(s) not in HEAD\n")

    suites = suites_from_report(args.suite_list) if args.suite_list else []
    if not suites:
        print("no suite list given/found")
        return 2
    base = baseline_numbers(args.baseline) if args.baseline else {}
    logdir = os.path.join(args.worktree, "logs", "verify")
    os.makedirs(logdir, exist_ok=True)

    head = subprocess.run(["git", "-C", args.worktree, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    print(f"verifying {len(suites)} suites at {head[:12]} "
          f"(per-suite bound {args.timeout}s, enforced here)\n", flush=True)

    rows = []
    for i, s in enumerate(suites, 1):
        r = run_suite(args.worktree, s, logdir, args.timeout)
        rows.append(r)
        delta = ""
        b = base.get(s)
        if b is not None and r["assertions"] >= 0:
            d = r["assertions"] - b
            delta = f"  ({'+' if d >= 0 else ''}{d} vs baseline)"
        print(f"  {i:2d}/{len(suites)} {s:38s} {r['verdict']:13s} "
              f"{r['assertions']:>6} assertions  {r['failures']} failures  {r['ms']:>6} ms{delta}", flush=True)

    total_a = sum(r["assertions"] for r in rows if r["assertions"] > 0)
    total_f = sum(max(r["failures"], 0) for r in rows)
    bad = [r for r in rows if r["verdict"] != "PASS"]
    # Assertion-count DRIFT is a failure, not a curiosity: a suite that passes while asserting less
    # than the baseline is a gate that has stopped gating (seen: test_unit_sprites PASS with 47
    # assertions instead of 460 because the atlas was not imported).
    drift = []
    for r in rows:
        b = base.get(r["suite"])
        if b is not None and r["assertions"] >= 0 and r["assertions"] != b:
            drift.append((r["suite"], b, r["assertions"], r["assertions"] - b))
    # A suite with no baseline entry cannot be gated at all: nothing says how many checks it should make,
    # so a shed assertion passes silently. Deliberate additions to the baseline, not silent ones.
    missing = [r["suite"] for r in rows if r["suite"] not in base]

    print(f"\nTOTAL {len(rows)} suites, {total_a} assertions, {total_f} failures, "
          f"not-passing: {[r['suite'] for r in bad] or 'none'}", flush=True)
    if drift:
        print(f"ASSERTION DRIFT vs BASELINE: {len(drift)} suite(s) — the gate is NOT satisfied:", flush=True)
        for s, b, c, d in drift:
            print(f"   {s}: {b} -> {c} ({d:+d})", flush=True)
    else:
        print("ASSERTION DRIFT vs BASELINE: none", flush=True)
    if missing:
        print(f"NO BASELINE ENTRY: {len(missing)} suite(s) cannot be gated — the gate is NOT satisfied:", flush=True)
        for s in missing:
            print(f"   {s}", flush=True)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(f"# Verification run — {os.path.basename(args.worktree)}\n\n")
        fh.write(f"**Commit:** `{head}`\n**Engine:** Godot 4.7.2-stable, headless, `--require-native`, "
                 f"one process per suite\n**Suites:** {len(rows)}\n"
                 f"**Per-suite bound:** {args.timeout} s, enforced by this verifier on the child "
                 f"process (not by the engine)\n\n")
        fh.write(f"## Verdict\n\n{'**ALL SUITES PASS.**' if not bad else '**FAILURES: ' + ', '.join(r['suite'] for r in bad) + '**'} "
                 f"{total_a} assertions, {total_f} failures across {len(rows)} suites.\n\n")
        if drift:
            fh.write(f"**ASSERTION DRIFT vs BASELINE — gate NOT satisfied.** {len(drift)} suite(s) "
                     f"assert a different number of checks than the baseline:\n\n")
            fh.write("| Suite | Baseline | This run | Delta |\n|---|---|---|---|\n")
            for s, b, c, d in drift:
                fh.write(f"| `{s}` | {b} | {c} | {d:+d} |\n")
            fh.write("\nA pass with fewer assertions is a suite that stopped testing something. Fix the "
                     "environment (imported textures, this tree's class cache, native module staged) or "
                     "explain the change in the suite itself before treating this run as a gate.\n\n")
        else:
            fh.write("**Assertion drift vs baseline: none** — every inherited suite asserts exactly "
                     "what it asserted before.\n\n")
        if missing:
            fh.write(f"**NO BASELINE ENTRY — gate NOT satisfied.** {len(missing)} suite(s) have nothing "
                     f"to compare against, so a shed assertion would pass silently: "
                     f"{', '.join('`' + s + '`' for s in missing)}. Add them to the baseline deliberately "
                     f"once their counts are accepted.\n\n")
        fh.write("| Suite | Result | Assertions | Failures | ms | vs baseline |\n|---|---|---|---|---|---|\n")
        for r in rows:
            b = base.get(r["suite"])
            d = f"{r['assertions'] - b:+d}" if (b is not None and r["assertions"] >= 0) else ("new" if b is None else "-")
            fh.write(f"| `{r['suite']}` | {r['verdict']} | {r['assertions']} | {r['failures']} | "
                     f"{r['ms']} | {d} |\n")
        fh.write(f"\nRaw per-suite output: `logs/verify/*.log`\n")
    print(f"wrote {args.out}")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"head": head, "rows": rows, "missing_baseline": missing}, fh, indent=1)
        print(f"wrote {args.json}")
    return 0 if (not bad and not drift and not missing) else 1


if __name__ == "__main__":
    raise SystemExit(main())
