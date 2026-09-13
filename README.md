# Project Banner

An original medieval sandbox strategy / RPG: a persistent simulated world, tactical
battles, and individual soldiers who live, fight, gain experience, and die permanently.

Project Banner takes inspiration from the *structure* of games in the sandbox-bannerlord
genre (world map travel, settlement recruitment, overworld encounters, tactical battles).
All assets, names, factions, lore, UI and code in this repository are original.

> **Working codename.** The final game name will be chosen later; the repository,
> the campaign seed and the documentation all use "Project Banner" until then.

---

## Status

**The first vertical slice is complete and verified.** You can start a campaign,
travel, recruit individual named soldiers, take them into a tactical battle, watch
some of them die, earn experience and gold, and find all of it intact after closing
and reopening the game.

See [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) for exactly what is playable
and how it is verified, and [`docs/ROADMAP.md`](docs/ROADMAP.md) for what comes next.

## Reviewing this codebase?

Start with [`docs/PROJECT_REPORT.md`](docs/PROJECT_REPORT.md) — it is written as a
self-contained orientation and covers the architecture, the content data, the combat
maths, the verification strategy and an honest list of gaps.

The five invariants that hold the design together, and that a review should check
against:

1. A soldier's identity lives in `CampaignState.soldiers` and nowhere else.
   `Party` stores **ids**, not objects; battle units hold a `soldier_id`.
2. `BattleContext` is the only channel between campaign and battle — the battle
   scene never reads global state or a catalog.
3. A battle is described (`BattleResolver.build_result`) before it is applied
   (`apply`). `apply()` is the only place a battle changes the campaign.
4. Time conversion exists only in `CampaignClock`.
5. All balance numbers live in `data/*.json`, never inline in code.

Where the risk actually lives, and where the interesting reading is:

| File | Why |
| --- | --- |
| `scripts/battle/battle_simulator.gd` | the whole fight, as pure data — combat maths, targeting, death |
| `scripts/battle/battle_resolver.gd` | the only function that lets a battle change the campaign |
| `scripts/core/campaign_state.gd` | the persistence root; ownership rules live here |
| `scripts/units/recruitment_service.gd` | the one transaction that adds a soldier to the party |
| `tests/test_combat.gd` | includes the balance assertion that caught a silently broken melee system |
| `tests/test_battle_outcomes.gd` | the four battle outcomes, and a deliberate attempt to farm the retreat loop |
| `tests/test_runner_contract.gd` | the runner testing itself against deliberately broken suites |

Two distinctions are easy to get wrong, and both fail quietly:

- **`Party.size()` is the historical roster; `active_member_count()` is the force.**
  The dead are kept on purpose, so the two diverge the moment anyone dies. Travel
  pace, party capacity, encounter strength and every strength display use the force.
- **A withdrawal is not a battle.** It records `battles_fought`, pays XP for kills
  actually made and nothing else, and does not touch `battles_survived`. Otherwise
  enter-fight-press-Retreat is a risk-free progression loop.

And one rule worth stating plainly, because it was applied to only half the world for
a while: **enemy soldiers are persistent people too.** A band that survives a fight
comes back with the hit points it has left, not a fresh set. Battle consequences are
symmetric — see `docs/GAME_ARCHITECTURE.md`.

Verification is the point of this repository. If you change something, the claim to
check is not "it compiles" but that
`tests/` still reports `1708 assertions, 0 failures, 13 of 13 suites` and that the
two-process restart check still passes. Both run automatically in CI on every push and
pull request, pinned to Godot 4.7.2-stable.

## Documentation

| File | Purpose |
| --- | --- |
| [`docs/PROJECT_REPORT.md`](docs/PROJECT_REPORT.md) | One-document overview: status, architecture, data, verification, gaps |
| [`docs/DEVELOPMENT_ENVIRONMENT.md`](docs/DEVELOPMENT_ENVIRONMENT.md) | Toolchain, executable paths, run/test commands |
| [`docs/GAME_ARCHITECTURE.md`](docs/GAME_ARCHITECTURE.md) | Core systems, state ownership, scene hierarchy |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Milestone plan and progress |
| [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) | What is playable / tested today |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Significant technical and design decisions |

## Quick start

```bash
git clone https://github.com/JAYST3AM/project-banner.git
cd project-banner
PROJ="$(pwd)"

# Play the game (Godot 4.7.2-stable; `godotc` is the console build)
godot --path "$PROJ"

# Headless validation: run every test suite
godotc --headless --path "$PROJ" res://scenes/dev/tests.tscn

# Prove a campaign survives closing the game (two processes, on purpose)
godotc --headless --path "$PROJ" res://scenes/dev/persistence_check.tscn -- --phase=write
godotc --headless --path "$PROJ" res://scenes/dev/persistence_check.tscn -- --phase=verify
```

On Windows the plain `godot` executable detaches from the console and prints nothing;
use `godotc` whenever you want to read output.

See `docs/DEVELOPMENT_ENVIRONMENT.md` for the full command reference, including the
development switches that let the real game be driven without a mouse.

## Repository layout

```
assets/     audio, fonts, sprites, placeholders
data/       data-driven definitions (units, items, settlements, encounters, config)
scenes/     core, world, settlements, battle, ui, dev
scripts/    core, world, battle, units, ui
docs/       report, architecture, roadmap, current state, decisions, environment
tests/      headless test suites, plus the two-process restart check
.github/    CI: the headless suites and both persistence phases, on a clean runner
```
