# Project Banner — Engineering Status

Authoritative short state for agent coordination. Refreshed at every integration.
History lives in `docs/PROJECT_BANNER_STATUS.md` and `docs/DECISIONS.md`; Jay's view is
`docs/ROADMAP.md`.

**Refreshed:** 2026-10-09 (workflow merged to `main`; E1 Stage-2 battery run and reviewed)

| Field | Value |
| --- | --- |
| `main` SHA (origin) | Take the live SHA from `git ls-remote origin main` — never from this file. Last workflow-integration commit: `b36e428` (2026-10-09). Previous verified development main: `d3d0b2a`. |
| Jay's local checkout | branch `main` @ `70a6017f18f938d95ad272c5cf5a06fdf0733534` (behind origin, **dirty, read-only**) |
| Active task ID | E1 — disabled-mode GPU terrain collision integration (Slice E1) |
| Active implementer | GPT-6 (primary programmer); E1 code was produced by the previously-authorised implementer worker |
| Active verifier | Hermes |
| Feature branch | `pb-e1-disabled-collision` |
| Candidate SHA | `e1cfc956d048dd6abbb127d022fead49c1f97bc1` |
| Candidate worktree | `F:/VSC Projects/Project Banner/.worktrees/t_4c9b65f3` (clean, warm) |
| Current stage | Stage D — E1 Stage-2 battery **COMPLETE** (2026-10-09); GPT-6 reviewed. Determinism PASS; criterion 7 (GPU resource cleanup) FAIL; corrective code awaited from GPT-6. |
| Verification result | **Gate A GREEN**: 48 suites / 11,244 assertions / 0 failures / drift none (15:51). **Stage-2 real-GPU battery GREEN on behaviour**: 8/8 runs EXIT 0, 0 errors, per-tick checksums identical to baseline (600: 147/147 ticks; 20,000: 7/7), performance neutral (20K median frame 117.647 ms both sides). **Open:** +1 leaked StorageBuffer vs baseline at exit — GPT-6 ruling: FAIL, fix the whole cleanup path. |
| Merge authorization state | **MERGE_HELD** — GPT-6: "E1 remains merge-held… these corrections need to pass verification first." Implementation judged sound; correction required before merge. |
| Known blockers | (1) E1 correction outstanding (criterion 7). (2) E2/E3 remain unauthorised — GPT-6 takes over writing E2’s implementation code once E1 closes. |
| Next required action | Await GPT-6’s corrective code: (a) a runtime check that the uploaded binding-14 bytes are the documented disabled mask, (b) a complete GPU resource cleanup path. Then re-run the paired battery + gate on the new candidate and return `[PB-RESULT] E1`. Do not implement either — GPT-6 owns code. |

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
