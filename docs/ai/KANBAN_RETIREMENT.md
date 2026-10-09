# Kanban Retirement — Project Banner

**Authorised by Jay, 2026-10-09.** The Kanban task-board workflow is permanently discontinued.
The GPT-6-led process and the shared roadmap (`docs/ROADMAP.md`, `docs/ai/PROJECT_STATUS.md`,
`docs/ai/WORKFLOW.md`) replace it. No replacement task board is to be built.

## 1. What the Kanban system actually was

The board was **not** code in the game repository — a search of
`F:/VSC Projects/Project Banner` for "kanban" returns **zero** files. It was Hermes agent
machinery, in three parts:

| Part | Location |
| --- | --- |
| The board and its task database | `%LOCALAPPDATA%/hermes/kanban/boards/banner/` (`kanban.db`, `board.json`, per-task logs, per-task workspaces) |
| The dispatcher | Hermes' built-in Kanban worker dispatcher (spawns a worker agent per claimed task) |
| Driving automation | three Hermes cron jobs, below |

### Cron jobs that drove it (now paused)

| Job ID | Name | Schedule | Was doing |
| --- | --- | --- | --- |
| `e8550ea023d9` | `banner-room-muse-updates` | every 15m | polled the board diff, posted narrative update notifications to Discord |
| `e8ea6da26061` | `banner-room-queue-keeper` | every 10m | released/assigned held work, kept workers ≤ 3, chained follow-ups from task bodies |
| `654951d89bda` | `banner-roadmap-driver` | every 15m | the actual work loop — read the roadmap state, drove one job at a time with GPT-6 |

These three polled the board on a timer, which is exactly the "wasteful AI polling / redundant
verification loop / duplicate reporting" the new workflow removes: every tick burned an agent
turn whether or not anything had changed. They are **paused** (enabled=false, state=paused,
2026-10-09 16:27), not deleted, so the decision is reversible and auditable.

## 2. Board inventory — unfinished work at retirement

29 tasks. 10 done/archived, 12 live (ready/triage), the rest archived. The live ones are carried
into `docs/ROADMAP.md` (section "Carried over from the retired task board") so no requirement is
lost:

| Task | Title | Status at retirement |
| --- | --- | --- |
| `t_4c9b65f3` | E1 — disabled-mode GPU terrain collision integration | triage (merge held; see PROJECT_STATUS) |
| `t_2fbfce13` | PB-202 — Command bar contract tests | ready |
| `t_2b33efac` | PB-203 — Unit dock lifecycle | ready |
| `t_d1d2e1b3` | PB-204 — Minimap interaction verification | ready |
| `t_ad5fd6d0` | PB-205 — Rejected movement orders preserve state | ready |
| `t_9872d84e` | PB-206 — Deployment legality | ready |
| `t_263af5ae` | PB-207 — Real GPU terrain collision verification | ready |
| `t_f2164cc9` | PB-208 — Live-battle strategic zoom parity | ready |
| `t_8418a78e` | PB-209 — Campaign aftermath and persistence | ready |
| `t_cbf18e6c` | PB-210 — Battlefield HUD resolution audit | ready |
| `t_18610dfd` | PB-211 — Reproducible performance benchmark | ready |
| `t_75061e4c` | PR-E — remaining `gpu_crowd.gd` integration hunks (sprite atlas archetypes) | ready |

## 3. Preserved (nothing deleted)

- **Board data:** left in place at `%LOCALAPPDATA%/hermes/kanban/boards/banner/`, marked
  `"archived": true` in `board.json` so the dispatcher no longer picks it up. The task database,
  per-task logs and workspaces are intact audit evidence (they contain the E1 publish forensics
  and the slice certification trail).
- **Task branches and worktrees:** untouched. Every `pb-*` worktree, every branch named on the
  board, and Jay's dirty checkout are all as they were. No remote branch deleted, no history
  rewritten.
- **E1 work:** explicitly preserved — candidate `e1cfc95` in
  `.worktrees/t_4c9b65f3`, published to `origin/pb-e1-disabled-collision`. Its verification
  continues under the new workflow.
- **Evidence trail:** `F:/VSC Projects/project-banner-mcp/docs/tasks/` (roadmap-state.md, gate
  reports, GPT-6 messages, E1 publish forensics) is the historical record and is not touched.

## 4. What stops Kanban from running again

- All three cron jobs paused — they cannot fire.
- Board marked archived — no dispatch.
- No Kanban worker or dispatcher process was running at retirement (verified: no `kanban`
  process; the only Project Banner process alive is the MCP bridge `pb_server.py` on 8791, which
  is a chat channel to GPT-6, not Kanban, and is **not** part of Kanban).
- The monitor scripts (`banner_board_state.sh`, `banner_pending_work.sh`,
  `banner_roadmap_state.sh`) are inert — they only ever ran inside those paused jobs.

## 5. Remaining Kanban references (found and dispositioned)

| Location | Reference | Disposition |
| --- | --- | --- |
| game repo | none | clean — nothing to remove |
| `project-banner-mcp/docs/gpt6-collaboration.md` | describes the board workflow | **leave** — historical record; superseded by `docs/ai/WORKFLOW.md` |
| `project-banner-mcp/docs/tasks/roadmap-state.md` (+ `.bak-*`) | the loop's memory, references the board | **leave** — evidence |
| `project-banner-mcp/tools/queue_batch.py`, `queue_batch2.py` | batch-queued board tasks | **orphaned** — no longer called by anything once jobs are paused; recommend removal with approval |
| `project-banner-mcp/docs/showcase/2026-10-09.html` | narrative mention | **leave** — showcase artifact |
| Hermes itself | the built-in `kanban` tool / CLI | **decision required** — see below |

## 6. Decision required

The Kanban *feature* (the `hermes kanban` CLI and the board UI) is part of the Hermes agent
application, not Project Banner's code. Two options:

- **A (done, reversible):** disabled for Project Banner — jobs paused, board archived. Hermes'
  Kanban capability remains installed but unused. Nothing else on the machine is affected.
- **B (needs approval):** remove the Kanban feature from the Hermes install and delete the board
  database. This edits a shared component of the agent tooling and destroys the audit data
  preserved above, so it was **not** done unilaterally.

Recommendation: stay on **A** until the E1 record and the slice history are no longer needed;
revisit deletion once the roadmap has fully absorbed the board's content.
