# The battle moves to the compute path

The owner's directive, 2026-09-18: *move everything to the GPU version, then stop calling it the
GPU version - it is the base game from that point - and archive the CPU version.*

This is the plan for that, with the conditions it runs under.

## What "everything" is

The battle system that ships today is 10,784 lines of GDScript in `scripts/battle/`, guarded by
27 suites and 8,955 assertions in `tests/`. It is the game's battle, and it is the thing that has
to move:

| Piece | Lines | What moves |
|---|---|---|
| `battle_simulator.gd` | 3,756 | the rules: movement, contact, combat, orders, targeting, outcomes |
| `battle.gd` | 985 | the command UI |
| `battle_formation.gd` | 825 | formation shapes, slots, dressing |
| overlap + spatial grids | 1,800 | collision resolution - becomes the shader's own cell pass |
| `battle_view.gd`, `soldier_field.gd` | 992 | drawing - becomes the instanced field |
| `battle_resolver.gd` | 419 | how a battle ends and what it hands back |
| terrain, journal, result, unit, setup, ai, clock | 1,357 | the ground, the record, the outcome, the data |

## The conditions

**1. The CPU version is archived, not deleted, and it stays runnable.** It becomes the oracle: the
port is checked *against* it, behaviour by behaviour. Nothing in this plan is allowed to change
what the reference does - the reference is the specification, and a port that disagrees with its
own specification is a bug in the port.

**2. Nothing is promoted until the parity list below is green.** A half-ported battle scene is a
broken game. The game keeps running the CPU path until the new one passes end to end, and then
there is one switch, not a slow drift.

## The parity list (the specification)

Derived from the reference and its suites - each line is something the new path must reproduce
before promotion. The matrix in `docs/CPU_REFERENCE_FEATURE_MATRIX.md` is the long form.

**Combat (the next work)**
- [ ] Hit chance: 75% base, per strike, misses do nothing
- [ ] Damage: attacker's attack, varied ±15%
- [ ] Defence: 5% per point, capped at 70%
- [ ] Cooldowns between blows; a man strikes when his weapon is ready and an enemy is in reach
- [ ] Retaliation: whoever struck you is a valid target for 20 ticks
- [ ] Ranged units exist, deploy behind the melee, and strike past the front rank
- [ ] Fallen men stay fallen and stay on the field

**Targeting**
- [x] Acquire, keep, release - cadence, retention radius 32, switch only for a 25% advantage
- [x] Reacquire immediately when a target dies or leaves contact
- [x] An explicit order outranks the automatic choice - *for units; per-soldier orders are the open question the owner raised*
- [ ] Search radius widening from 8 to 60 when nothing is near

**Formations and movement**
- [x] Units as boxes that turn, advance, hold, and press into the gap
- [x] Cohesion measured, not assumed
- [x] Shapes from the game's own catalogue: line, column, loose
- [ ] Shape changes that survive contact - a re-form in the middle of a fight is the hard case
- [ ] Terrain modifiers: roads, mud, woods changing the march rate

**Battle outcomes**
- [ ] End conditions: annihilation, withdrawal, timeout
- [ ] The result the campaign consumes: dead, survivors, kills, experience, loot
- [ ] Withdrawal, and the retreat order that causes it
- [ ] The journal - what happened, in words, for the record

**Interface**
- [x] Selection, box selection, orders, groups, stances, shapes - built this week
- [ ] The reference's own command UI, restyled to the game's look
- [ ] The results screen
- [ ] Deployment from the campaign's own battle setup rather than `--agents=N`

## The order of work

1. **The combat model on the compute path** - the biggest single gap, and the one that decides
   whether battles resolve the way the reference's do. Needs a deterministic per-man random
   number: the reference seeds one stream per battle, the shader can hash (tick, man) instead.
2. **The campaign drives it** - `battle_setup.gd`'s armies become the buffers, and the result
   comes back as a `BattleResult` the campaign already knows how to eat.
3. **The command UI in the game's style**, including withdrawal and the results screen.
4. **The promotion** - the scene becomes `scenes/battle/battle.tscn`, every "gpu" name in the
   game's own files goes (`gpu_crowd.gd` → `scripts/battle/battle_field.gd`), and the world map's
   encounter flow points at it.
5. **The archive** - `scripts/battle/` moves to `archive/battle_cpu/` with a README saying what it
   is and why it is still runnable; the suites keep running against it; the new path gets its own
   suites asserting the same behaviours.

## Gates that already exist and carry over

- **Determinism**: identical runs produce identical state, at any frame rate. The check script is
  in the repo and passes today.
- **Collision proof**: no two enemies closer than the separation minimum, measured every tick in
  the shader, and the number reported rather than asserted.
- **The suite**: the reference's 27 suites stay green throughout - they are what "the game still
  works" means while the second implementation is built beside it.
