#!/usr/bin/env python3
"""Run a branch's full suite list headlessly and report raw results, with an optional baseline diff.

    python tools/verify_branch.py --worktree "F:/VSC Projects/pb-m02-formation" \
        --out "F:/VSC Projects/pb-m02-formation/docs/reports/m02-formation-verification.md" \
        --baseline "F:/VSC Projects/project-banner-mcp/docs/tasks/baseline-suites.md"

One engine process per suite, as the baseline did: `--require-native` so a missing native module
fails loudly instead of silently degrading. Raw output per suite is kept in <worktree>/logs/verify/.
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


def run_suite(worktree: str, suite: str, logdir: str, timeout: int = 300) -> dict:
    cmd = [GODOT, "--headless", "--path", worktree, "res://scenes/dev/tests.tscn",
           "--", f"--suite={suite}", "--require-native"]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "") + (p.stderr or "")
        code = p.returncode
    except subprocess.TimeoutExpired:
        out, code = f"TIMEOUT after {timeout}s", -1
    elapsed = time.time() - t0
    with open(os.path.join(logdir, f"{suite}.log"), "w", encoding="utf-8") as fh:
        fh.write(out)

    m = RESULT_RE.search(out)
    v = VERDICT_RE.search(out)
    assertions = int(m.group(1)) if m else -1
    failures = int(m.group(2)) if m else -1
    ms = int(m.group(3)) if m else -1
    verdict = (v.group(1) if v else ("CRASH" if code != 0 else "NO-RESULT"))
    return {"suite": suite, "verdict": verdict, "assertions": assertions, "failures": failures,
            "ms": ms, "exit": code, "wall_s": round(elapsed, 1)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--suite-list", default="", help="markdown report to read suite names from")
    ap.add_argument("--baseline", default="", help="markdown report to compare assertion counts against")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--json", default="", help="also write raw results as JSON here")
    args = ap.parse_args()

    suites = suites_from_report(args.suite_list) if args.suite_list else []
    if not suites:
        print("no suite list given/found")
        return 2
    base = baseline_numbers(args.baseline) if args.baseline else {}
    logdir = os.path.join(args.worktree, "logs", "verify")
    os.makedirs(logdir, exist_ok=True)

    head = subprocess.run(["git", "-C", args.worktree, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    print(f"verifying {len(suites)} suites at {head[:12]}\n", flush=True)

    rows = []
    for i, s in enumerate(suites, 1):
        r = run_suite(args.worktree, s, logdir, args.timeout)
        rows.append(r)
        delta = ""
        b = base.get(s)
        if b is not None and r["assertions"] >= 0:
            d = r["assertions"] - b
            delta = f"  ({'+' if d >= 0 else ''}{d} vs baseline)"
        print(f"  {i:2d}/{len(suites)} {s:38s} {r['verdict']:8s} "
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
    print(f"\nTOTAL {len(rows)} suites, {total_a} assertions, {total_f} failures, "
          f"not-passing: {[r['suite'] for r in bad] or 'none'}", flush=True)
    if drift:
        print(f"ASSERTION DRIFT vs BASELINE: {len(drift)} suite(s) — the gate is NOT satisfied:", flush=True)
        for s, b, c, d in drift:
            print(f"   {s}: {b} -> {c} ({d:+d})", flush=True)
    else:
        print("ASSERTION DRIFT vs BASELINE: none", flush=True)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(f"# Verification run — {os.path.basename(args.worktree)}\n\n")
        fh.write(f"**Commit:** `{head}`\n**Engine:** Godot 4.7.2-stable, headless, `--require-native`, "
                 f"one process per suite\n**Suites:** {len(rows)}\n\n")
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
            json.dump({"head": head, "rows": rows}, fh, indent=1)
        print(f"wrote {args.json}")
    return 0 if (not bad and not drift) else 1


if __name__ == "__main__":
    raise SystemExit(main())
