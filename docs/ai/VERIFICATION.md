# Project Banner — Verification Workflow

How a change is tested, and which of it is scripted. Companion to `docs/ai/WORKFLOW.md`.

The single reusable command is the gate, not a set of manual checks:

```
F:/VSC Projects/project-banner-mcp/.venv/Scripts/python.exe \
  F:/VSC Projects/project-banner-mcp/tools/verify_branch.py \
  --worktree <tree> --out <report.md> --suite-list <list> --baseline <baseline> --json <out.json>
```

It runs the suites, parses the results, compares assertion counts against the frozen baseline,
refuses to report a pass where a suite shed assertions, and refuses a dirty worktree unless
`--allow-dirty`. Run `tools/verify_branch_selftest.py` after changing the gate.

## Evidence matched to risk

Verification is **risk-based**: match the evidence to what actually changed. Do not run a suite for
a comment, and do not certify a shader from a CPU-only check.

| What changed | Required evidence |
| --- | --- |
| Documentation, comments, records | A documentation check: the file renders, its links and paths resolve, and its statements match the repository. **No suite run required.** |
| Ordinary gameplay or logic change | The targeted unit suites first, then the wider regression when the task's risk or acceptance criteria call for it. |
| An integration or milestone merge | The full regression through the gate, compared against the frozen baseline. |
| Rendering, GPU, physics or battle simulation | All of the above **plus** actual runtime verification - real GPU / windowed execution, performance metrics, and deterministic checks where relevant. A CPU-only check never proves a GPU feature. |

A change is not done until the evidence its risk class requires has passed. A green suite that
tests less is a failure — compare assertion counts against the baseline and name every difference.

When the risk class is genuinely unclear, ask GPT-6 to name it before choosing the evidence; do not
default either way.

## Rules that have already cost time (keep them)

- **Never report timed-out, crashed, skipped or incomplete runs as passing.** Missing required
  fixture = FAIL, not PASS. Could-not-load = BROKEN.
- **One Godot process at a time.** Check the process count before every timed run and re-check
  before each run of a battery; abort and report incomplete rather than contaminating a
  measurement.
- **Paired runs, not old logs.** A before/after claim compares builds measured in the same
  session, same inputs, same tick count.
- **Efficiency:** do not rerun an unchanged suite to reproduce a result already recorded against
  the same code, environment, baseline and requirements. A merge gate that specifically requires
  a fresh run gets one.
- Test-integrity guards (TI-1/TI-2) and their semantics live in
  `project-banner-mcp/docs/TEST-INTEGRITY-FINDINGS.md`.

## Deterministic operations → scripts

These are mechanical and should never be done by model reasoning. Most already exist; the
remainder are the recommendation from this setup.

| Operation | Where it lives | Status |
| --- | --- | --- |
| Suite execution + result parsing | `tools/verify_branch.py` | exists |
| Assertion-count comparison and drift detection | `tools/verify_branch.py` | exists |
| Gate self-test | `tools/verify_branch_selftest.py` | exists |
| Exact candidate / base SHA identification | `git rev-parse`, `git ls-remote` in the run scripts | exists |
| Remote SHA + blob read-back after push | `git ls-remote` / `git cat-file` in the run scripts | exists |
| Patch preflight + apply | `git apply --check` then `git apply` | exists (per task) |
| Paired windowed benchmark battery | `tools/e1_stage2_run.sh` | exists (E1) |
| Determinism / checksum comparison | `tools/e1_stage2_analyze.py` | exists (E1) |
| Godot process count check | `scripts/banner_godot_running.sh` | exists, rename pending (see below) |

**Recommended consolidation (proposal, not yet built):**

1. A single `tools/pb_verify.sh <worktree> <task-id>` that does, in order: clean-tree check →
   base SHA → gate run → baseline diff → report file → exit code. Replaces the several per-task
   `run_*.sh` wrappers that each re-implement the same sequence.
2. Fold the process-count check into that script rather than a separate monitor script.
3. Retire the Kanban monitor scripts (`banner_board_state.sh`, `banner_pending_work.sh`,
   `banner_roadmap_state.sh`) once the board is gone; keep `banner_godot_running.sh` under a
   clearer name (`pb_godot_running.sh`).

Nothing above changes a production file. Build on GPT-6's or Jay's say-so.
