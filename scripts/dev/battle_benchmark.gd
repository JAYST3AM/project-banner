extends Node
## Battle scale benchmark. Development tooling only - it is not part of the game and
## nothing in the game depends on it.
##
## It exists so that "is this getting slower?" has an answer that is a number rather
## than a feeling. Step 7 added formations and terrain, both of which sit in the
## battle loop, and the only honest way to know what they cost is to run the same
## battle at several sizes and write down what happened. Step 7.2 replaced the two
## quadratic loops that measurement found, so this is also the instrument that has to
## say whether that worked.
##
## [b]This is not the twenty-thousand-soldier milestone.[/b] It does not attempt to
## reach that figure, and a slow result here is a measurement to record rather than a
## problem to fix by rewriting the architecture.
##
## What it reports, per size:
## [br]- how long the simulation alone took, and per tick;
## [br]- how many ticks a second it managed;
## [br]- a checksum of the battle's starting position, so a comparison across commits is
##   comparing the same battle rather than merely the same number of soldiers;
## [br]- whether the armies actually reached each other, so an "approach" measurement is
##   never passed off as a fight;
## [br]- the busiest single cell, which is the number that says whether a uniform grid is
##   still doing its job at that size;
## [br]- and how much of the cost belongs to terrain and to formations, by running the
##   same battle with each switched off.
##
## Usage (headless):
## [codeblock]
## godot --headless --path . res://scenes/dev/battle_benchmark.tscn -- --units=100,500,1000
## godot --headless --path . res://scenes/dev/battle_benchmark.tscn -- --units=2500 --ticks=600
## godot --headless --path . res://scenes/dev/battle_benchmark.tscn -- --units=5000 --profile=1
## godot --headless --path . res://scenes/dev/battle_benchmark.tscn -- --grid-scale=1
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

## Step 7's measured cost per tick, at each size, from this same harness on this same
## machine with the same seed and the same budget. Recorded in the Step 7 report
## (docs/PROJECT_REPORT.md 9.7) before any of the spatial work existed. Hard-coded
## rather than re-measured because the code that produced them no longer exists - that
## is the point of the comparison.
const STEP_7_BASELINE := {
	100: 4.783,
	500: 110.337,
	1000: 439.993,
	2500: 2684.557,
	5000: 10988.004,
}

## Sizes for the constant-density grid probe. This one measures the spatial layer on its
## own, with the field scaled so that the crowd is no denser at fifty thousand than it is
## at one, which is the only way to see the shape of the curve rather than the shape of a
## saturated battlefield.
const GRID_SCALE_UNITS := [1000, 5000, 10000, 20000, 50000]
const GRID_SCALE_DENSITY := 0.833  # soldiers per square unit, the 5,000-on-100x60 case
const GRID_SCALE_QUERIES := 2000


func _ready() -> void:
	var options := _parse_args()
	var counts: Array = options["units"]
	var ticks: int = options["ticks"]
	var seed_value: int = options["seed"]
	var budget: float = options["budget"]
	var breakdown: bool = options["breakdown"]
	var breakdown_max: int = options["breakdown_max"]
	var cell_size := GameManager.config().get_float("battle.spatial_cell_size", 4.0)

	print("=== PROJECT BANNER - BATTLE SCALE BENCHMARK ===")
	print("cpu      %s (%d threads)" % [OS.get_processor_name(), OS.get_processor_count()])
	print("memory   %.1f GiB" % (float(OS.get_memory_info().get("physical", 0)) / 1073741824.0))
	print("os       %s" % OS.get_version())
	print("engine   %s" % str(Engine.get_version_info().get("string", "?")))
	print("tick     %.2fs   seed %d   budget %.0fs per variant, scaled by size" % [TICK, seed_value, budget])
	print("grid     cell %.2f units (battle.spatial_cell_size)" % cell_size)
	print("")
	print("%7s | %7s | %10s | %10s | %9s | %8s | %7s | %7s | %6s | %s" % [
		"units", "ticks", "sim total", "per tick", "ticks/sec", "setup", "alive", "busiest", "contact", "setup checksum"])
	print("-".repeat(108))

	var reports: Array[Dictionary] = []
	for count in counts:
		reports.append(_benchmark(int(count), ticks, seed_value, budget, breakdown and int(count) <= breakdown_max))

	if breakdown:
		print("")
		print("=== WHAT THE NEW SYSTEMS COST (same battle, per tick) ===")
		print("%7s | %13s | %13s | %13s | %13s" % [
			"units", "units only", "+terrain", "+formations", "both"])
		print("-".repeat(78))
		for report in reports:
			if not bool(report["attributed"]):
				print("%7d | %47s" % [int(report["units"]), "not run at this size (one tick is seconds)"])
				continue
			print("%7d | %12s | %12s | %12s | %12s" % [
				int(report["units"]),
				_ms(float(report["per_tick_plain"])),
				_ms(float(report["per_tick_terrain"])),
				_ms(float(report["per_tick_formation"])),
				_ms(float(report["per_tick"])),
			])

	_print_comparison(reports)

	if bool(options["profile"]):
		_print_profile(counts, ticks, seed_value, budget)

	if bool(options["grid_scale"]):
		_print_grid_scale(cell_size)

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
		"profile": false,
		"grid_scale": false,
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
		elif arg.begins_with("--profile="):
			options["profile"] = arg.substr(10).to_int() != 0
		elif arg.begins_with("--grid-scale="):
			options["grid_scale"] = arg.substr(13).to_int() != 0
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
	print("%7d | %7d | %7.1f ms | %7.3f ms | %9.0f | %6.1f ms | %7d | %7d | %6s | %s" % [
		count, int(main["ticks"]),
		float(main["total_ms"]), float(main["per_tick_ms"]), float(main["ticks_per_second"]),
		float(main["setup_ms"]), int(main["alive"]), int(main["busiest"]),
		"yes" if bool(main["contact"]) else "no", str(main["checksum"])])
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
		"busiest": int(main["busiest"]),
		"contact": bool(main["contact"]),
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
	budget: float,
	profile: bool = false
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

	# The index as the first tick will build it, so the density figure describes the
	# deployment rather than whatever the fighting has left standing afterwards.
	simulator.call("_rebuild_spatial", TICK)
	var busiest := simulator.grid.busiest_cell() if simulator.grid != null else 0

	var checksum := _setup_checksum(simulator)
	var ai := BattleAI.create(config)
	var setup_ms := float(Time.get_ticks_usec() - setup_start) / 1000.0

	if profile:
		simulator.reset_profile()
		simulator.profile_enabled = true

	simulator.start()
	var started := Time.get_ticks_usec()
	var budget_us := int(budget * 1000000.0)
	var done := 0
	var hits := 0
	var deaths := 0
	while done < ticks:
		if simulator.is_finished():
			break
		if Time.get_ticks_usec() - started >= budget_us:
			break
		ai.update(simulator, TICK)
		for event in simulator.step(TICK):
			var kind := str(event.get("type", ""))
			if kind == "hit":
				hits += 1
			elif kind == "death":
				deaths += 1
		done += 1
	var total_us := Time.get_ticks_usec() - started

	var alive := 0
	for unit in simulator.units:
		if unit.is_alive():
			alive += 1

	var per_tick_ms := 0.0
	if done > 0:
		per_tick_ms = (float(total_us) / 1000.0) / float(done)
	var out := {
		"ticks": done,
		"total_ms": float(total_us) / 1000.0,
		"per_tick_ms": per_tick_ms,
		"ticks_per_second": 0.0 if total_us <= 0 else float(done) / (float(total_us) / 1000000.0),
		"setup_ms": setup_ms,
		"alive": alive,
		"busiest": busiest,
		"contact": hits > 0,
		"hits": hits,
		"deaths": deaths,
		"checksum": checksum,
		"exhausted": done >= ticks,
	}
	if profile:
		out["profile"] = simulator.profile.duplicate()
	return out


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


## Step 7 against Step 7.2, at the sizes both measured. This is the table the milestone
## exists to produce, and it is printed from the same run that produced the numbers above
## rather than assembled by hand afterwards.
func _print_comparison(reports: Array[Dictionary]) -> void:
	var comparable: Array[Dictionary] = []
	for report in reports:
		if STEP_7_BASELINE.has(int(report["units"])):
			comparable.append(report)
	if comparable.is_empty():
		return
	print("")
	print("=== STEP 7 vs STEP 7.2 (same sizes, same seed, same layout, same budget) ===")
	print("%7s | %16s | %16s | %10s | %14s" % [
		"units", "Step 7 ms/tick", "Step 7.2 ms/tick", "speedup", "Step 7.2 ticks/s"])
	print("-".repeat(76))
	for report in comparable:
		var before := float(STEP_7_BASELINE[int(report["units"])])
		var after := float(report["per_tick"])
		var speedup := before / maxf(0.000001, after)
		print("%7d | %14.3f | %14.3f | %9.1fx | %14.0f" % [
			int(report["units"]), before, after, speedup, float(report["ticks_per_second"])])
	print("-".repeat(76))
	print("  Step 7 figures are the recorded measurements from docs/PROJECT_REPORT.md 9.7,")
	print("  taken on this machine with this harness before the spatial work existed.")

	# 16.67 ms is 60 FPS. The simulation does not have to run at render frequency, and
	# Step 7.2 does not decide that it should - so this is a reference point, not a
	# target, and it is stated as the simulation tick cost only.
	var frame_budget := 1000.0 / 60.0
	print("")
	print("  For reference, 60 FPS is %.2f ms per frame. That budget covers rendering too," % frame_budget)
	print("  and the simulation need not update every frame; this harness measures the tick")
	print("  and nothing else. The largest size measured under that figure here is reported")
	print("  below rather than claimed.")
	var holds := 0
	for report in comparable:
		if float(report["per_tick"]) <= frame_budget:
			holds = maxi(holds, int(report["units"]))
	if holds > 0:
		print("  Largest measured size with a simulation tick under one 60 FPS frame: %d soldiers." % holds)
	else:
		print("  No measured size has a simulation tick under one 60 FPS frame yet.")


## Where the time actually goes now. Enabled with --profile=1, and reported at phase
## granularity because that is the level at which a next step can be chosen.
func _print_profile(counts: Array, ticks: int, seed_value: int, budget: float) -> void:
	print("")
	print("=== PHASE PROFILE (ms per tick, same battles, clock on) ===")
	print("%7s | %10s | %9s | %11s | %10s | %12s | %9s | %10s | %s" % [
		"units", "grid", "focus", "formations", "soldiers", "of which target", "overlap", "accounted", "total"])
	print("-".repeat(114))
	for count_value in counts:
		var count := int(count_value)
		var effective := minf(MAX_BUDGET, budget * maxf(1.0, float(count) / 1000.0))
		var run := _run_battle(count, ticks, seed_value, true, true, effective, true)
		var done := maxf(1.0, float(run["ticks"]))
		var phases: Dictionary = run.get("profile", {})
		var grid := float(phases.get("grid", 0.0)) / done
		var focus := float(phases.get("focus", 0.0)) / done
		var formations := float(phases.get("formation", 0.0)) / done
		var soldiers := float(phases.get("soldiers", 0.0)) / done
		var target := float(phases.get("target", 0.0)) / done
		var overlap := float(phases.get("overlap", 0.0)) / done
		var accounted := grid + focus + formations + soldiers + overlap
		print("%7d | %7.3f ms | %6.3f ms | %8.3f ms | %7.3f ms | %9.3f ms | %6.3f ms | %7.3f ms | %7.3f ms" % [
			count, grid, focus, formations, soldiers, target, overlap, accounted, float(run["per_tick_ms"])])
	print("-".repeat(114))
	print("  'accounted' is the sum of the phases and should sit just under 'total'; the gap")
	print("  is the parts of a tick nothing has been instrumented for. 'soldiers' is the")
	print("  per-soldier update loop and 'of which target' is the share of")
	print("  it spent choosing targets. The clock costs two reads per soldier, so a profiled")
	print("  figure is slightly higher than the unprofiled one in the table above - use the")
	print("  table above for comparisons and this one for attribution.")


## The spatial layer measured on its own, at constant density.
##
## The battle benchmark cannot answer this: it puts every army on one fixed field, so at
## twenty thousand soldiers the field is many times too small and the measurement says
## more about saturation than about the algorithm. Here the field grows with the army so
## that the crowd is exactly as dense at fifty thousand as at one thousand, which is the
## only configuration in which the shadow of the old quadratic behaviour would be visible
## if it were still there.
func _print_grid_scale(cell_size: float) -> void:
	print("")
	print("=== GRID SCALING AT CONSTANT DENSITY (the spatial layer alone) ===")
	print("%8s | %10s | %12s | %10s | %12s | %11s | %9s" % [
		"units", "field", "rebuild", "cells", "query avg", "query p99", "found avg"])
	print("-".repeat(94))
	var rng := RandomNumberGenerator.new()
	rng.seed = DEFAULT_SEED
	for count_value in GRID_SCALE_UNITS:
		var count := int(count_value)
		var side := sqrt(float(count) / GRID_SCALE_DENSITY)
		var field := Vector2(side, side)
		var grid := BattleSpatialGrid.new()
		grid.configure(field, cell_size)
		var units: Array[BattleUnit] = []
		for index in count:
			var unit := BattleUnit.new()
			unit.id = index
			unit.side = BattleContext.SIDE_PLAYER if index % 2 == 0 else BattleContext.SIDE_ENEMY
			unit.hp = 1
			unit.max_hp = 1
			unit.position = Vector2(rng.randf_range(0.0, field.x), rng.randf_range(0.0, field.y))
			units.append(unit)

		var rebuild_started := Time.get_ticks_usec()
		var rebuilds := 8
		for pass_index in rebuilds:
			grid.rebuild(units)
		var rebuild_ms := float(Time.get_ticks_usec() - rebuild_started) / 1000.0 / float(rebuilds)

		var scratch: Array[BattleUnit] = []
		var timings := PackedFloat64Array()
		var total_found := 0
		for query_index in GRID_SCALE_QUERIES:
			var probe := Vector2(rng.randf_range(0.0, field.x), rng.randf_range(0.0, field.y))
			var started := Time.get_ticks_usec()
			grid.collect_within(probe, 4.0, BattleContext.SIDE_ENEMY, scratch)
			timings.append(float(Time.get_ticks_usec() - started) / 1000.0)
			total_found += scratch.size()
		var sorted := timings.duplicate()
		sorted.sort()
		var total := 0.0
		for value in timings:
			total += value
		var average := total / maxf(1.0, float(timings.size()))
		var p99 := 0.0
		if sorted.size() > 0:
			p99 = sorted[mini(sorted.size() - 1, int(float(sorted.size()) * 0.99))]
		print("%8d | %10s | %9.3f ms | %10d | %9.4f ms | %8.4f ms | %9.1f" % [
			count, "%.0fx%.0f" % [field.x, field.y], rebuild_ms, grid.cols * grid.rows,
			average, p99, float(total_found) / maxf(1.0, float(timings.size()))])
	print("-".repeat(94))
	print("  Radius fixed at 4 units of a %.2f-unit cell, so every query covers the same" % cell_size)
	print("  ground regardless of how large the field is. A rebuild that stays proportional to")
	print("  the army, and a query that stays flat, is the whole of what Step 7.2 claims.")


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
	lines.append("  Step 7's two quadratic loops are gone: target selection searches the soldiers")
	lines.append("  near a soldier rather than the whole army, and overlap resolution compares")
	lines.append("  only the pairs standing close enough to touch. What is left is proportional")
	lines.append("  to the army and to how crowded each soldier's own neighbourhood is.")
	lines.append("")
	lines.append("  Two things that are still true and are not claims to the contrary:")
	lines.append("  the fixed battlefield means density rises with the army, so a crowded cell")
	lines.append("  costs more per query; and the 'busiest' column is where to see that. Run")
	lines.append("  --grid-scale=1 for the same layer measured at constant density.")
	lines.append("")
	lines.append("  Measured on this machine, headless, with the simulation stepped directly -")
	lines.append("  it excludes rendering, which the large-battle milestone will also have to pay.")
	return "\n".join(lines)


func _ms(value: float) -> String:
	return "%.3f ms" % value
