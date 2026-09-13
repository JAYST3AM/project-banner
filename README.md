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

Early vertical slice. See [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) for what is
actually playable right now, and [`docs/ROADMAP.md`](docs/ROADMAP.md) for what comes next.

## Documentation

| File | Purpose |
| --- | --- |
| [`docs/DEVELOPMENT_ENVIRONMENT.md`](docs/DEVELOPMENT_ENVIRONMENT.md) | Toolchain, executable paths, run/test commands |
| [`docs/GAME_ARCHITECTURE.md`](docs/GAME_ARCHITECTURE.md) | Core systems, state ownership, scene hierarchy |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Milestone plan and progress |
| [`docs/CURRENT_STATE.md`](docs/CURRENT_STATE.md) | What is playable / tested today |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Significant technical and design decisions |

## Quick start

```bash
# Play the game
godot --path "F:/VSC Projects/Project Banner"

# Headless validation (loads every scene, runs the test suites)
godot --headless --path "F:/VSC Projects/Project Banner" res://scenes/dev/tests.tscn
```

See `docs/DEVELOPMENT_ENVIRONMENT.md` for the full command reference.

## Repository layout

```
assets/     audio, fonts, sprites, placeholders
data/       data-driven definitions (units, items, settlements, encounters, config)
scenes/     core, world, settlements, battle, ui, dev
scripts/    core, world, battle, units, ui
docs/       architecture, roadmap, current state, decisions, environment
tests/      headless test suites
```
