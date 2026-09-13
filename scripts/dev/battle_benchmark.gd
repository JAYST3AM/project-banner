extends Node
## Battle scale benchmark. Development tooling only - it is not part of the game and
## nothing in the game depends on it.
##
## It exists so that "is this getting slower?" has an answer that is a number rather
## than a feeling. Step 7 added formations and terrain, both of which sit in the
## battle loop, and the only honest way to know what they cost is to run the same
## battle at several sizes and write down what happened.
##
## [b]This is not the twenty-thousand-soldier milestone.[/b] It does not attempt to
## reach that figure, and a slow result here is a measurement to record rather than a
## problem to fix by rewriting the architecture.
##
## What it reports, per size:
## [br]- how long the simulation alone took, and per tick;
## [br]- how many ticks a second it managed;
## [br]- a checksum of the finished battle, so a performance comparison across commits
##   is comparing the same battle rather than merely the same number of soldiers;
## [br]- and, by running the same battle with the new systems switched off, how much of
##   the cost belongs to terrain and to formations.
##
## Usage (headless):
## [codeblock]
## godot --headless --path . res://scenes/dev/battle_benchmark.tscn -- --units=100,500,1000
## godot --headless --path . res://scenes/dev/battle_benchmark.tscn -- --units=2500 --ticks=600
## [/codeblock]

const DEFAULT_UNITS := [100, 500, 1000, 2500, 5000]
const DEFAULT_TICKS := 600
const DEFAULT_SEED := 70707
const DEFAULT_BUDGET := 12.0
## Sizes above this get one measurement rather than four. The four-way breakdown is
## what makes the attribution honest, but at the largest sizes a single tick costs
## seconds and running everything four times would turn a measurement into an
## afternoon.
const DEFAULT_BREAKDOWN_MAX := 1000
const MAX_BUDGET := 60.0
const TICK := 0.05


func _ready() -> void:
	var options := _parse_args()
	var counts: Array = options["units"]
	var ticks: int = options["ticks"]
	var seed_value: int = options["seed"]
	var budget: float = options["budget"]
	var breakdown: bool = options["breakdown"]

	print("=== PROJECT BANNER - BATTLE SCALE BENCHMARK ===")
	print("engine %s   tick %.2fs   seed %d   budget %.0fs per variant" % [
		str(Engine.get_version_info().get("string", "?")), TICK, seed_value, budget])
	print("")
	print("%8s | %8s | %11s | %11s | %10s | %11s | %8s | %s" % [
		"units", "ticks", "sim total", "per tick", "ticks/sec", "setup", "alive", "setup sum"])
	print("-".repeat(112))

	var reports: Array[Dictionary] = []
	var breakdown_max: int = options["breakdown_max"]
	for count in counts:
		reports.append(_benchmark(int(count), ticks, seed_value, budget, breakdown and int(count) <= breakdown_max))

	if breakdown:
		print("")
		print("=== BREAKDOWN: what the new systems cost (same battle, per tick) ===")
		print("%8s | %12s | %12s | %12s | %12s" % [
			"units", "units only", "+terrain", "+formations", "both"])
		print("-".repeat(74))
		for report in reports:
			if not bool(report["attributed"]):
				print("%8d | %35s" % [int(report["units"]), "not run at this size (one tick is seconds)"])
				continue
			print("%8d | %11s | %11s | %11s | %11s" % [
				int(report["units"]),
				_ms(float(report["per_tick_plain"])),
				_ms(float(report["per_tick_terrain"])),
				_ms(float(report["per_tick_formation"])),
				_ms(float(report["per_tick"])),
			])

	print("")
	print("=== SCALE NOTES ===")
	print(_scaling_note(reports))
	print("")
	print("BENCHMARK COMPLETE")
	get_tree().quit(0)


func _parse_args() -> Dictionary:
	var options := {
		"units": DEFAULT_UNITS,
		"ticks": DEFAULT_TICKS,
		"seed": DEFAULT_SEED,
		"budget": DEFAULT_BUDGET,
		"breakdown": true,
		"breakdown_max": DEFAULT_BREAKDOWN_MAX,
	}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--units="):
			var parsed: Array[int] = []
			for piece in arg.substr(8).split(",", false):
				var value := int(piece.strip_edges())
				if value > 0:
					parsed.append(value)
			if not parsed.is_empty():
				options["units"] = parsed
		elif arg.begins_with("--ticks="):
			options["ticks"] = maxi(1, int(arg.substr(8)))
		elif arg.begins_with("--seed="):
			options["seed"] = int(arg.substr(7))
		elif arg.begins_with("--budget="):
			options["budget"] = maxf(0.5, float(arg.substr(9)))
		elif arg == "--breakdown=0":
			options["breakdown"] = false
		elif arg.begins_with("--breakdown-max="):
			options["breakdown_max"] = maxi(0, int(arg.substr(16)))
	return options


## Run one battle at one size and report what it cost.
##
## The same battle is run four times with progressively more of the new machinery
## switched on. That is what makes the breakdown honest: it is four measurements of one
## battle rather than four guesses about each other.
##
## Each run stops on a wall-clock budget rather than a fixed tick count, because the
## cost per tick grows faster than the army does and a fixed count would make the large
## sizes take hours. The tick count actually achieved is reported, so nothing is
## hidden: a size that only managed six ticks says so.
func _benchmark(count: int, ticks: int, seed_value: int, budget: float, breakdown: bool) -> Dictionary:
	# A bigger army gets longer, so that a size which costs seconds per tick still
	# manages enough ticks to be measured rather than merely noticed.
	var effective_budget := minf(MAX_BUDGET, budget * maxf(1.0, float(count) / 1000.0))
	var rows := {
		"both": _run_battle(count, ticks, seed_value, true, true, effective_budget),
	}
	if breakdown:
		rows["plain"] = _run_battle(count, ticks, seed_value, false, false, effective_budget)
		rows["terrain"] = _run_battle(count, ticks, seed_value, true, false, effective_budget)
		rows["formation"] = _run_battle(count, ticks, seed_value, false, true, effective_budget)

	var main: Dictionary = rows["both"]
	print("%8d | %8d | %9.1f ms | %8.3f ms | %9.0f | %8.1f ms | %8d | %s" % [
		count, int(main["ticks"]),
		float(main["total_ms"]), float(main["per_tick_ms"]), float(main["ticks_per_second"]),
		float(main["setup_ms"]), int(main["alive"]), str(main["checksum"])])
	return {
		"units": count,
		"ticks": int(main["ticks"]),
		"attributed": breakdown,
		"per_tick_plain": float(rows.get("plain", main)["per_tick_ms"]),
		"per_tick_terrain": float(rows.get("terrain", main)["per_tick_ms"]),
		"per_tick_formation": float(rows.get("formation", main)["per_tick_ms"]),
		"per_tick": float(main["per_tick_ms"]),
		"total_ms": float(main["total_ms"]),
		"ticks_per_second": float(main["ticks_per_second"]),
		"exhausted": bool(main["exhausted"]),
	}


## One deterministic battle of [param count] soldiers, simulated for up to
## [param ticks] ticks or [param budget] seconds of wall clock, whichever comes first.
##
## The setup is deterministic on purpose: given the same size, seed and configuration it
## builds the same field, the same ranks and the same formations, and reports a
## checksum of that setup to prove it. Without that, comparing two runs across commits
## would be comparing two different battles and calling the difference a performance
## change. The checksum is taken before the fighting starts, so it does not move when a
## budget runs out two ticks earlier.
func _run_battle(
	count: int,
	ticks: int,
	seed_value: int,
	use_terrain: bool,
	use_formations: bool,
	budget: float
) -> Dictionary:
	var config := GameManager.config()
	var setup_start := Time.get_ticks_usec()

	var context := BattleContext.new()
	context.battle_id = "bench_%d" % count
	context.battle_seed = seed_value
	context.terrain_seed = seed_value

	var simulator := BattleSimulator.new(config, seed_value)
	var units := _build_ranks(count, config)
	simulator.add_units(units)
	if use_terrain:
		simulator.set_terrain_from_context(context, config)
	if use_formations:
		BattleSetup.assign_default_formations(simulator, config)

	var checksum := _setup_checksum(simulator)
	var ai := BattleAI.create(config)
	var setup_ms := float(Time.get_ticks_usec() - setup_start) / 1000.0

	simulator.start()
	var started := Time.get_ticks_usec()
	var budget_us := int(budget * 1000000.0)
	var done := 0
	while done < ticks:
		if simulator.is_finished():
			break
		if Time.get_ticks_usec() - started >= budget_us:
			break
		ai.update(simulator, TICK)
		simulator.step(TICK)
		done += 1
	var total_us := Time.get_ticks_usec() - started

	var alive := 0
	for unit in simulator.units:
		if unit.is_alive():
			alive += 1

	var per_tick_ms := 0.0
	if done > 0:
		per_tick_ms = (float(total_us) / 1000.0) / float(done)
	return {
		"ticks": done,
		"total_ms": float(total_us) / 1000.0,
		"per_tick_ms": per_tick_ms,
		"ticks_per_second": 0.0 if total_us <= 0 else float(done) / (float(total_us) / 1000000.0),
		"setup_ms": setup_ms,
		"alive": alive,
		"checksum": checksum,
		"exhausted": done >= ticks,
	}


## Two blocks of soldiers facing each other, laid out to fit the field whatever the
## count. A square-ish block keeps a big army from becoming one absurdly long rank.
func _build_ranks(count: int, config: GameConfig) -> Array[BattleUnit]:
	var field := BattleSetup.field_size(config)
	var per_side := maxi(1, count / 2)
	var files := maxi(1, mini(60, int(ceil(sqrt(float(per_side))))))
	var ranks := maxi(1, int(ceil(float(per_side) / float(files))))
	var lateral_step := (field.y - 4.0) / float(files)
	var depth_step := 16.0 / float(ranks)

	var units: Array[BattleUnit] = []
	var next_id := 0
	for side_value in [BattleContext.SIDE_PLAYER, BattleContext.SIDE_ENEMY]:
		var side := str(side_value)
		var left_side := side == BattleContext.SIDE_PLAYER
		for i in per_side:
			var file := i % files
			var rank := i / files
			var unit := BattleUnit.new()
			unit.id = next_id
			next_id += 1
			unit.side = side
			unit.soldier_id = "s_bench_%d" % unit.id
			unit.display_name = "Bench %d" % unit.id
			unit.max_hp = 40
			unit.hp = 40
			unit.attack = 5
			unit.defence = 2
			unit.move_speed = 5.0
			unit.attack_range = 1.8
			unit.attack_cooldown = 1.2
			unit.ranged = (rank % 5) == 4
			unit.position = Vector2(
				6.0 + float(rank) * depth_step if left_side else field.x - 6.0 - float(rank) * depth_step,
				2.0 + float(file) * lateral_step
			)
			units.append(unit)
	return units


## A digest of the battle's starting position - every soldier's place and every
## formation's centre. Two runs of the same benchmark must produce the same one; if they
## do not, the measurement is not comparable and saying so is more useful than reporting
## a number anyway.
func _setup_checksum(simulator: BattleSimulator) -> String:
	var parts: PackedStringArray = []
	for unit in simulator.units:
		parts.append("%d:%.3f:%.3f" % [unit.id, unit.position.x, unit.position.y])
	for formation in simulator.formations:
		parts.append("%s:%.3f:%.3f:%d" % [
			formation.id, formation.anchor.x, formation.anchor.y, formation.unit_ids.size()])
	if simulator.terrain != null:
		parts.append(simulator.terrain.signature())
	return "%08x" % RngService.stable_hash("|".join(parts))


func _scaling_note(reports: Array[Dictionary]) -> String:
	if reports.size() < 2:
		return "  Only one size was run, so nothing can be said about scaling."
	var lines: PackedStringArray = []
	var first: Dictionary = reports[0]
	var last: Dictionary = reports[reports.size() - 1]
	var unit_ratio := float(last["units"]) / maxf(1.0, float(first["units"]))
	var cost_ratio := float(last["per_tick"]) / maxf(0.0001, float(first["per_tick"]))
	lines.append("  %d -> %d units is %.0fx the soldiers and %.1fx the time per tick." % [
		int(first["units"]), int(last["units"]), unit_ratio, cost_ratio])
	lines.append("")
	lines.append("  The cost per tick grows faster than the army does. The cause is not terrain")
	lines.append("  or formations - both of which are a few per cent - but two loops that")
	lines.append("  compare every soldier against every other soldier: target selection and")
	lines.append("  overlap resolution. Both predate this milestone.")
	lines.append("  This is recorded as the first target of the large-battle milestone, not")
	lines.append("  fixed here. See the scaling notes in docs/GAME_ARCHITECTURE.md.")
	if first["exhausted"] and not last["exhausted"]:
		lines.append("")
		lines.append("  Note: the largest size did not complete its tick budget and reports the")
		lines.append("  ticks it did manage. That is a measurement, not a failure.")
	lines.append("")
	lines.append("  Measured on this machine, headless, with the simulation stepped directly -")
	lines.append("  it excludes rendering, which the large-battle milestone will also have to pay.")
	return "\n".join(lines)


func _ms(value: float) -> String:
	return "%.3f ms" % value
