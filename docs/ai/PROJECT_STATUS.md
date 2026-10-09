# Project Banner — Engineering Status

Authoritative short state for agent coordination. Refreshed at every integration.
History lives in `docs/PROJECT_BANNER_STATUS.md` and `docs/DECISIONS.md`; Jay's view is
`docs/ROADMAP.md`.

**Refreshed:** 2026-10-09 (workflow setup + Kanban retirement, merged to `main`)

| Field | Value |
| --- | --- |
| `main` SHA (origin) | `a3dcfdfc6b40dc02e1b72a5829739e290e09555d` — carries the workflow records; the previous verified development main was `d3d0b2a` |
| Jay's local checkout | branch `main` @ `70a6017f18f938d95ad272c5cf5a06fdf0733534` (behind origin, **dirty, read-only**) |
| Active task ID | E1 — disabled-mode GPU terrain collision integration (Slice E1) |
| Active implementer | GPT-6 (primary programmer); E1 code was produced by the previously-authorised implementer worker |
| Active verifier | Hermes |
| Feature branch | `pb-e1-disabled-collision` |
| Candidate SHA | `e1cfc956d048dd6abbb127d022fead49c1f97bc1` |
| Candidate worktree | `F:/VSC Projects/Project Banner/.worktrees/t_4c9b65f3` (clean, warm) |
| Current stage | Stage C — verification, partially complete (Stage-2 benchmark battery outstanding) |
| Verification result | **Gate A GREEN**: 48 suites / 11,244 assertions / 0 failures / drift none (15:51, 2026-10-09). Real-GPU Stage-2 paired benchmark + determinism battery **NOT RUN**. |
| Merge authorization state | **MERGE_HELD** — GPT-6 directive: "merge on hold"; publish was repaired to `e1cfc95` on origin, certification authorised to continue at that exact SHA. No merge authorisation issued. |
| Known blockers | (1) Stage-2 battery needs an exclusive machine — must be run with `godot` process count 0, one run at a time. (2) E1's accepted-but-unmerged state blocks E2/E3 authorisation. |
| Next required action | Run the 8-run Stage-2 battery (recipe: `project-banner-mcp/docs/tasks/e1-stage2/`, runner `tools/e1_stage2_run.sh`), analyse with `tools/e1_stage2_analyze.py`, send `[PB-RESULT] E1` to GPT-6, await accept/reject. |

## Authorization ledger

| Candidate | Decision | State | Recorded |
| --- | --- | --- | --- |
| Slice D terrain collision mask (`d3d0b2a`) | GPT-6 ACCEPTED + DIRECTED MERGE | `MERGED_VERIFIED` (origin/main) | 2026-10-09 11:41 |
| E1 `e1cfc956` (disabled-mode GPU integration) | GPT-6 `[PB-DIRECTIVE] Start E1`; merge on hold | `MERGE_HELD` | 2026-10-09 |
| E2 (enabled collision + parity) | Planned, **NOT AUTHORIZED** | — | 2026-10-09 |
| E3 (campaign activation / live battle terrain) | Planned, **NOT AUTHORIZED** | — | 2026-10-09 |

Newer explicit decisions override older instructions in this file.

## Standing facts

- Game repo: `F:/VSC Projects/Project Banner` → `https://github.com/JAYST3AM/project-banner`.
- GPT-6 channel: MCP bridge `project-banner-mcp` (`pb_server.py`, port 8791); sender
  `tools/gpt6_send3.py`. GPT-6 can read the game repo, not the bridge alone.
- Verification gate: `project-banner-mcp/tools/verify_branch.py` (also published in the game repo
  on branch `tools/verification-gate`). Fails on assertion drift, not just failures.
- Worktree warm-up recipe and suite runner: `project-banner-mcp/docs/tasks/how-to-run-suites.md`.
- Kanban: **retired** (Option A — Banner automation disabled, feature installed, evidence preserved). See `docs/ai/KANBAN_RETIREMENT.md`.
- The GPT-6-led workflow is **established**: `docs/ai/WORKFLOW.md`, `PROJECT_STATUS.md`, `VERIFICATION.md` and `KANBAN_RETIREMENT.md` are on `main`.
