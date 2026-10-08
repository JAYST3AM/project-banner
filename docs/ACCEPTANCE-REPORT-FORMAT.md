# Acceptance Report Format and Branch Rules

Defined under M00 (see D-174). Every completed task on Project Banner reports in this shape, and
every branch follows these rules. Their purpose is that a claim can be checked by someone who was
not there.

## The report line

```
[PB-RESULT] ID | BASE SHA | HEAD SHA | FILES | TEST COMMAND | PASS/FAIL | EVIDENCE | LIMITATIONS
```

| Field | What goes in it |
| --- | --- |
| `ID` | The task identifier this work answers (for example `M05-formation-orders`) |
| `BASE SHA` | The commit the branch was cut from — not "main", the actual SHA |
| `HEAD SHA` | The commit being offered for review |
| `FILES` | Files touched, with insertions/deletions or a `--stat` line |
| `TEST COMMAND` | The exact command a reviewer should run, copy-pasteable, including engine path |
| `PASS/FAIL` | The raw result line, e.g. `(119 assertions, 0 failures, 514 ms)` — never "looks good" |
| `EVIDENCE` | Absolute paths to raw logs, captures or output files produced by that command |
| `LIMITATIONS` | What was **not** tested, what was assumed, what is known to be fragile |

A report missing `LIMITATIONS` is incomplete. If nothing is known to be untested, say "not tested
outside the harness (headless only)" or similar — an empty limitation field means nobody thought
about it.

## Rules for evidence

- Raw output or it did not happen. A verdict derived from a summary is not a verdict.
- Failures are reported verbatim, including the failing assertion text.
- Screenshots and captures are evidence only when their filename says what they show and they are
  produced by a command recorded in the report.
- Numbers that matter (assertions, durations, frame times, pixels) are stated with units and the
  machine they were measured on.

## Branch rules

1. **Cut from a stated base.** Every branch records its base SHA. Work that depends on unreviewed
   code says so explicitly.
2. **Push before review.** A branch that exists only on a local disk cannot be reviewed. Push, then
   report the SHA.
3. **Never merge without independent verification.** The author is not the verifier. Verification is
   a separate pass, by a different party, with its own raw output.
4. **One writer per file per branch.** Concurrent edits to the same file on branches intended for
   immediate integration are a conflict generator; coordinate before starting.
5. **No work on Jay's working tree.** It is protected (D-173). Work happens in worktrees and lands
   through commits.
6. **No force-pushes to a branch under review.** If history must change, cut a new branch and say
   why.
7. **Deletions and refactors state their blast radius.** What else calls this, what test covers it,
   what breaks if it is wrong.

## What "done" means for a task

A task is done when: the acceptance check named in its milestone passes, the raw output proving it
is attached, the limitation list is written, the branch is pushed, and an independent verification
has reproduced the result. Anything less is in progress.

## Completion criteria for the Playable Alpha

Declare **PROJECT BANNER — PLAYABLE ALPHA** only when the production GPU battle path is tested and
accepted, the complete campaign loop works in an exported build, combat/orders/terrain/LOD are
reliable, results and saves survive a restart, there is a reason to play another encounter,
essential visuals and audio are coherent, performance meets the agreed target, no critical
progression or data-loss defects remain, licensing requirements are met, an external tester has
completed the loop, and Jay approves the result.

No screenshot, milestone report, test count or commit can substitute for those conditions.
