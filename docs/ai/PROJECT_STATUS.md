# Project Banner — Engineering Status

Authoritative short state for agent coordination. Refreshed at every integration.
History lives in `docs/PROJECT_BANNER_STATUS.md` and `docs/DECISIONS.md`; Jay's view is
`docs/ROADMAP.md`.

**Refreshed:** 2026-10-09 (E1 verified and merged to `main`)

| Field | Value |
| --- | --- |
| `main` SHA (origin) | Take the live SHA from `git ls-remote origin main` — never from this file. Last workflow-integration commit: `b36e428` (2026-10-09). Previous verified development main: `d3d0b2a`. |
| Jay's local checkout | branch `main` @ `70a6017f18f938d95ad272c5cf5a06fdf0733534` (behind origin, **dirty, read-only**) |
| Active task ID | None in flight. **E1 closed**; next is **E2** (not started). |
| Active implementer | GPT-6 (primary programmer) — it writes E2’s code next. |
| Active verifier | Hermes |
| Feature branch | E1 merged: `pb-e1-disabled-collision` (`e1cfc956`) plus correction branch `pb-e1-disabled-collision-fix` (`3613709c332837500bae52018b4382e47ecc5f9e`). |
| Candidate SHA | E1 merged as **`ddbc6bb280d9425c5b9e3e3bbf09f63c4fffff1a`** (merge of `0a8a568` + `3613709c332837500bae52018b4382e47ecc5f9e`). |
| Candidate worktree | `F:/VSC Projects/Project Banner/.worktrees/t_4c9b65f3` (clean, warm) |
| Current stage | E1 **complete** (Stage F: records updated). Nothing in flight; E2 awaits GPT-6. |
| Verification result | **E1 GREEN, both gates**: Gate A (candidate) and Gate B (merge rehearsal) each 48 suites / 11,244 assertions / 0 failures / drift none. Binding-14 GPU read-back PASS, failure path proven to exit 1; zero GPU leak warnings vs the baseline’s 17 RIDs; determinism identical to baseline; no performance regression. |
| Merge authorization state | `MERGED_VERIFIED` for E1 (`ddbc6bb280d9425c5b9e3e3bbf09f63c4fffff1a`), authorised by GPT-6 on the exact rehearsal commit after Gate B. |
| Known blockers | None. E2/E3 remain unauthorised until GPT-6 issues their directives. |
| Next required action | Await GPT-6’s E2 implementation, then integrate and verify it the same way (isolated worktree, gate, paired battery, [PB-RESULT]). |

## Authorization ledger

| Candidate | Decision | State | Recorded |
| --- | --- | --- | --- |
| Slice D terrain collision mask (`d3d0b2a`) | GPT-6 ACCEPTED + DIRECTED MERGE | `MERGED_VERIFIED` (origin/main) | 2026-10-09 11:41 |
| E1 `e1cfc956` + correction `3613709c332837500bae52018b4382e47ecc5f9e` | GPT-6 accepted; rehearsal `ddbc6bb280d9425c5b9e3e3bbf09f63c4fffff1a` authorised and pushed | `MERGED_VERIFIED` (`main`) | 2026-10-09 |
| E2 (enabled collision + parity) | Next up; GPT-6 writes it, authorisation follows E1 | `PENDING` | 2026-10-09 |
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
