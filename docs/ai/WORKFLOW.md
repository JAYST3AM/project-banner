# Project Banner — Operating Agreement

Standing rules for how Project Banner is developed. This file replaces the retired Kanban
task-board workflow. It is the authoritative statement of who does what.

Two companion records:

| File | For | Contains |
| --- | --- | --- |
| `docs/ROADMAP.md` | Jay | milestones, what is done, what is next, in plain language |
| `docs/ai/PROJECT_STATUS.md` | the agents | the current task, candidate, stage and merge state, kept short |
| `docs/ai/VERIFICATION.md` | the verifier | how a change is tested, and which checks are scripted |

---

## 1. Roles

**Jay — project owner and final authority.** Decides what Project Banner becomes, major gameplay
and visual decisions, feature priority, and any significant change of scope.

**GPT-6 — primary programmer and technical director.** Writes the code: new GDScript, shaders,
tests, fixes, patches, architecture and system integration. Divides large features into slices,
sets acceptance criteria before implementation, directs the order of work, reviews test results,
corrects failed implementations, approves milestone completion, and authorises Git operations.

**Hermes — integration and verification agent.** Reads GPT-6's code, applies supplied patches
accurately, reviews for errors/compatibility/regressions, runs compilation and tests, runs real
runtime checks where the feature needs them, protects repository integrity, verifies pushes,
and maintains the roadmap and status records.

**Hermes must not independently implement new gameplay features, redesign systems, or delegate
coding to another AI** unless GPT-6 or Jay explicitly authorises it. Hermes is a reviewer, not a
passive copier: defective code is challenged with evidence, not silently patched to pass.

## 2. The development cycle

**Stage A — GPT-6 prepares.** Inspects the code, names affected systems and permitted files,
defines expected behaviour, writes the implementation *and* its tests, delivers an exact patch or
commit, and states the verification requirements. GPT-6 delivers code, not instructions to code.

**Stage B — Hermes integrates.** Confirm repo and base commit; use an isolated feature branch or
worktree; check the patch is complete and uncorrupted; dry-run it (`git apply --check`); apply it
without changing its behaviour; review the diff for out-of-scope changes.

**Stage C — Hermes verifies.** Targeted tests first, then compile/parse and the wider regression
where the risk requires it; real runtime (windowed/GPU) checks for rendering, physics or battle
work; compare against the frozen baseline; write a short verification report.

**Stage D — GPT-6 reviews.** Examines the evidence, writes corrections if needed, requests more
tests if the evidence is incomplete, and explicitly accepts or rejects. Only GPT-6 or Jay can
authorise a merge.

**Stage E — Hermes publishes.** Commits and pushes the authorised branch, verifies the remote
commit and blobs by read-back, performs any authorised merge, and confirms the final state.

**Stage F — Roadmap completion.** GPT-6 confirms the milestone is complete; only then does Hermes
tick it off. A passing test is not a completed milestone.

## 3. Git and worktree safety

1. Never overwrite Jay's uncommitted changes. `F:/VSC Projects/Project Banner` is **read-only**:
   no stash, reset, checkout, commit or push into it.
2. Never reset, clean or replace a dirty worktree without explicit authorisation.
3. Work in dedicated feature branches and isolated worktrees.
4. Record the base commit before applying anything.
5. Restrict each task to its authorised file set; reject unexplained changes outside it.
6. Do not combine unrelated workstreams in one commit.
7. Never force-push without specific approval.
8. Never merge to `main` without authorisation naming the specific candidate commit.
9. Verify the branch and commit after every authorised push.

An earlier general approval, or a green test run, is **not** merge permission. Before merging,
confirm the authorisation is current and the branch has not moved since it was given. If the
authorisation is unclear, leave `main` untouched and ask.

## 4. Code ownership

GPT-6 owns implementation changes. Hermes must not silently modify GPT-6's code to make tests
pass. On finding a defect, Hermes reports: the failing file and location, the specific problem,
the test result or evidence, a suggested correction if useful — then returns it to GPT-6.

Line-ending normalisation and other mechanical adjustments are allowed only when required for
compatibility and when they do not change behaviour; record them in the report.

## 5. Reliable code delivery

Prefer unified Git patches, exact file artifacts or commits over prose code. For every delivery:
record the expected base SHA and the permitted paths; check integrity (SHA-256 where supplied);
`git apply --check` before applying; confirm the diff matches the intended scope; check the
resulting files for truncation. If a patch will not apply cleanly, stop and report — never
reconstruct missing code by guessing, and do not reuse a transfer channel that has already
produced corruption without an added integrity check. A successful `push` is not proof of
correct publication; verify the remote commit and blobs.

## 6. Task sizing

GPT-6 splits substantial features into slices. Each slice names its goal, base commit, authorised
files, expected behaviour, patch/artifact, required tests, acceptance criteria, dependencies and
merge restrictions. Verify one slice at a time unless GPT-6 permits parallel work on independent
files. Do not widen scope because a nearby feature looks convenient.

## 7. Communication protocol

Short and structured. Acknowledge a delivery and proceed; do not ask for information already in
the task or the status file. Keep full logs in files; send excerpts only when diagnosing a
failure.

Completion report shape:

```
[PB-VERIFY]
- Task:            <id and short name>
- Candidate:       <branch and SHA>
- Patch integrity: PASS/FAIL
- Compile:         PASS/FAIL/NOT REQUIRED
- Tests:           <passed/failed counts>
- Runtime/GPU:     <result or NOT REQUIRED>
- Protected trees: PASS/FAIL
- Push:            <SHA, branch, or NOT AUTHORIZED>
- Roadmap:         <changed/unchanged>
- Blockers:        <none or concise>
- Next:            <required action>
```

Failure report shape:

```
[PB-FAIL]
- Task:
- Exact failing check:
- Relevant error:
- Evidence/log location:
- Suspected cause:
- Required action from GPT-6:
```

Send a progress message only when something meaningful changes or a decision is needed.

## 8. Token efficiency

There is no fixed token budget and no mandatory model downgrade; the aim is the most useful
engineering per token. Read selectively (the function, diff or log tail you need, not the whole
file). Batch repository checks. Do local arithmetic with local commands. Parse test logs in code
rather than reading successful output. Do not re-analyse a settled question or rerun an unchanged
suite to reproduce a known result. Never skip a required test or hide uncertainty to save tokens.

## 9. Automation, and what not to automate

Use deterministic scripts for mechanical work: git status, base/candidate identification, branch
and worktree checks, file-allowlist validation, patch checksum and preflight, test execution,
result parsing, assertion-count comparison, drift detection, remote SHA/blob verification, report
generation. See `docs/ai/VERIFICATION.md`.

Do not: continuously poll another agent for instructions; start work merely because a queue is
empty; repeatedly reconstruct project history; run background AI workflows that duplicate an
active task; launch several verification agents for work one can do; retry an unchanged failing
operation. Prefer event-driven execution — a new instruction or a submitted patch starts a
verification task. One writer per file at a time; never two agents on the same files.

Do not disable or delete an existing service (cron job, script, scheduler) without authorisation.
The Kanban jobs that used to run here are retired; see `docs/ai/KANBAN_RETIREMENT.md`.

## 10. Records

- `docs/ROADMAP.md` — Jay's view; `[x]` = verified and accepted, `[ ]` = not yet accepted. Never
  tick a box because code exists on a branch. Distinguish technical foundations from visible
  gameplay: never imply a system is playable when it has only passed isolated tests.
- `docs/ai/PROJECT_STATUS.md` — compact engineering state, refreshed at every integration.
- `docs/ai/WORKFLOW.md` — this file.
- Existing history stays where it is: `docs/DECISIONS.md`, `docs/OPTIMISATION_HISTORY.md`,
  `docs/CURRENT_STATE.md`, `docs/PROJECT_BANNER_STATUS.md`.
- `F:/VSC Projects/project-banner-mcp/docs/tasks/` — the verification evidence and GPT-6 message
  archive produced by the (now retired) driving loop. Read-only historical record.
