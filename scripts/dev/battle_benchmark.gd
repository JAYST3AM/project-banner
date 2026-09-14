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
##
## Step 7.4 added four switches for sweeping the target schedule rather than editing the
## config between runs, and two for the evidence the milestone needed:
## [codeblock]
## --reacquire=4      ticks between a soldier's own awareness searches (1 = every tick)
## --retention=32     how far a remembered opponent may be before it is released
## --switch=1.25      how much closer a new candidate must be to take over
## --immediate=0      switch the urgency rule off, to measure what it costs
## --spikes=1         sample every tick and report average, p50, p95, p99 and worst
## --storm=1          kill an entire front rank on one tick and measure the tick it lands on
## [/codeblock]
##
## Step 7.5 added two more: the formation layer measured on its own, against the number of
## bodies rather than the number of soldiers, and a switch for skipping family B's unprofiled
## table when only the profile is being read.
## [codeblock]
## --focus-scale=1    where the formation layer stops being free, by body count
## --scaled-table=0   family B without the clock, off when only the profile is wanted
## [/codeblock]
##
## And two that predate all of the above and are easy to miss, both used by the methodology
## rather than by a milestone's own tables:
## [codeblock]
## --reliable=0       family A alone: no family B table, no repeatability pass
## --ticks=20         matched windows, for a before/after comparison across two builds
## [/codeblock]
## Step 7.8 added four switches for the separation pass, which is measured one implementation
## at a time on the same battles:
## [codeblock]
## --overlap-backend=gdscript|packed|native|compare   force one pass for every run
## --overlap-sweep=1   run the same battles once per pass and print the comparison
## --overlap-diag=1    accumulate the settled-cell proof's counters over a whole battle
## --overlap-split=1   decompose the phase's own cost by re-running it with its arithmetic
##                     removed, three passes over one frozen field per sample
## [/codeblock]
##
## A before/after comparison must not be made across `--budget` runs. The budget decides how
## long a run lasts by how fast the build is, so a cheaper build measures a later, heavier
## window of the same battle and can appear not to have improved. `--ticks=` is the fix: same
## tick count for both builds, no budget that can shorten the slower one.

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

## Step 7.3's measured cost per tick, same harness, same machine, same seed, same budget,
## recorded in docs/CURRENT_STATE.md when Step 7.3 shipped. Hard-coded for the same reason
## as the Step 7 figures: the behaviour that produced them has been replaced, and a
## comparison against a re-measurement would be a comparison against the new code
## pretending to be the old one.
const STEP_7_3_BASELINE := {
	100: 3.651,
	500: 33.939,
	1000: 57.537,
	2500: 172.164,
	5000: 425.177,
	10000: 781.491,
	20000: 1632.897,
}

## Benchmark B: a battlefield that grows with the army, so density stays where a real
## battle would put it instead of rising until the soldiers are standing in each other.
##
## The reference density is the 500-soldier case on the standard field - 500 soldiers on
## 100 x 60, which is 0.0833 per square unit, or about 12 square units of ground each.
## Every size in family B gets a field of that density and the standard 5:3 aspect, so
## the only thing changing between rows is how many soldiers there are.
const REALISTIC_DENSITY := 0.0833
const FIELD_ASPECT := 100.0 / 60.0
const DEFAULT_GROUP_SIZE := 200

## Sizes for the constant-density grid probe. This one measures the spatial layer on its
## own, with the field scaled so that the crowd is no denser at fifty thousand than it is
## at one, which is the only way to see the shape of the curve rather than the shape of a
## saturated battlefield.
const GRID_SCALE_UNITS := [1000, 5000, 10000, 20000, 50000]
const GRID_SCALE_DENSITY := 0.833  # soldiers per square unit, the 5,000-on-100x60 case
const GRID_SCALE_QUERIES := 2000

## Set by --overlap-cell, so the separation cell size can be swept without editing the
## config between runs. Zero means "use whatever the config says".
var _overlap_cell_override: float = 0.0

## Step 7.7. Which implementation answers the target search's spatial queries:
## 0 = the locked GDScript reference; 1 = the accelerator's broadphase only; 2 = both of
## those, compared; 3 = the accelerator answering the whole query (shape B); 4 = shape B
## against the reference, compared. A comparison run measures correctness only.
## A comparison run measures correctness only and never performance.
var _target_backend: int = 0

## Step 7.8. Why the settled-cell skip fires or does not fire, accumulated over a whole
## family-B battle rather than read off the last tick, and the three-pass decomposition of
## the overlap phase's own cost on frozen proxy units. Both are measurement only and neither
## changes what a battle does.
var _overlap_diag: bool = false
var _overlap_split: bool = false
## Step 7.8. Which separation pass a run uses: -1 keeps the production rule (the thresholds on
## BattleSimulator), anything else forces one pass so that it can be measured on the same
## battle as the others. The sweep prints the same battles once per pass.
var _overlap_backend: int = -1
var _overlap_sweep: bool = false
var _diag: Dictionary = {}
var _split_samples: Array[Dictionary] = []

## Step 7.4's swept values, each zero-or-negative meaning "use whatever the config says",
## so that a cadence, a retention radius or a hysteresis margin can be swept without
## editing data/config/game_config.json between runs. A sweep that required editing the
## config would not be a sweep - it would be five runs and four chances to forget one.
var _reacquire_override: int = 0
var _retention_override: float = 0.0
var _switch_override: float = 0.0
## -1 means "use the config"; 0 and 1 switch the urgency rule off and on.
var _immediate_override: int = -1
var _spikes: bool = false


func _ready() -> void:
	var options := _parse_args()
	var counts: Array = options["units"]
	var ticks: int = options["ticks"]
	var seed_value: int = options["seed"]
	var budget: float = options["budget"]
	var breakdown: bool = options["breakdown"]
	var breakdown_max: int = options["breakdown_max"]
	var cell_size := GameManager.config().get_float("battle.spatial_cell_size", 4.0)
	_overlap_cell_override = float(options["overlap_cell"])
	_reacquire_override = int(options["reacquire"])
	_retention_override = float(options["retention"])
	_switch_override = float(options["switch"])
	_immediate_override = int(options["immediate"])
	_spikes = bool(options["spikes"])
	_overlap_diag = bool(options["overlap_diag"])
	_overlap_split = bool(options["overlap_split"])
	_overlap_sweep = bool(options["overlap_sweep"])

	print("=== PROJECT BANNER - BATTLE SCALE BENCHMARK ===")
	print("cpu      %s (%d threads)" % [OS.get_processor_name(), OS.get_processor_count()])
	print("memory   %.1f GiB" % (float(OS.get_memory_info().get("physical", 0)) / 1073741824.0))
	print("os       %s" % OS.get_version())
	print("engine   %s" % str(Engine.get_version_info().get("string", "?")))
	print("tick     %.2fs   seed %d   budget %.0fs per variant, scaled by size" % [TICK, seed_value, budget])
	print("grid     cell %.2f units (battle.spatial_cell_size)" % cell_size)
	print("separation cell %.2f units%s" % [
		_overlap_cell_override if _overlap_cell_override > 0.0 else GameManager.config().get_float("battle.overlap_cell_size", 0.9),
		"  (--overlap-cell override)" if _overlap_cell_override > 0.0 else ""])
	print("targets  cadence %d ticks%s   retention %.1f units%s   switch margin x%.2f%s   urgent on contact loss %s%s" % [
		_reacquire_override if _reacquire_override > 0 else GameManager.config().get_int("battle.target_reacquisition_ticks", 4),
		"  (--reacquire override)" if _reacquire_override > 0 else "",
		_retention_override if _retention_override > 0.0 else GameManager.config().get_float("battle.target_retention_radius", 32.0),
		"  (--retention override)" if _retention_override > 0.0 else "",
		_switch_override if _switch_override > 0.0 else GameManager.config().get_float("battle.target_switch_advantage", 1.25),
		"  (--switch override)" if _switch_override > 0.0 else "",
		"yes" if _immediate_enabled() else "no",
		"  (--immediate override)" if _immediate_override >= 0 else ""])
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

	if bool(options["reliable"]) and bool(options["scaled_table"]):
		_print_scaled(options)

	if bool(options["profile"]):
		_print_scaled_profile(options)
	if _overlap_sweep:
		_print_overlap_sweep(options)

	if bool(options["storm"]):
		_print_storm(options)
	if bool(options["grid_scale"]):
		_print_grid_scale(cell_size)
	if bool(options["focus_scale"]):
		_print_focus_scale()

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
		"overlap_diag": false,
		"overlap_split": false,
		"overlap_sweep": false,
		"grid_scale": false,
		"reliable": true,
		"gap": 0.25,
		"group": DEFAULT_GROUP_SIZE,
		"battle_units": [1000, 2500, 5000, 10000, 20000],
		"overlap_cell": 0.0,
		"reacquire": 0,
		"retention": 0.0,
		"switch": 0.0,
		"immediate": -1,
		"spikes": false,
		"storm": false,
		"scaled_table": true,
		"focus_scale": false,
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
		elif arg.begins_with("--overlap-diag="):
			options["overlap_diag"] = arg.substr(15).to_int() != 0
		elif arg.begins_with("--overlap-split="):
			options["overlap_split"] = arg.substr(16).to_int() != 0
		elif arg.begins_with("--overlap-sweep="):
			options["overlap_sweep"] = arg.substr(16).to_int() != 0
		elif arg.begins_with("--overlap-backend="):
			match arg.substr(18).to_lower():
				"gdscript", "reference":
					_overlap_backend = BattleSimulator.OverlapBackend.GDSCRIPT
				"packed":
					_overlap_backend = BattleSimulator.OverlapBackend.PACKED
				"native":
					_overlap_backend = BattleSimulator.OverlapBackend.NATIVE
				"compare":
					_overlap_backend = BattleSimulator.OverlapBackend.COMPARE
				_:
					_overlap_backend = -1
		elif arg.begins_with("--grid-scale="):
			options["grid_scale"] = arg.substr(13).to_int() != 0
		elif arg.begins_with("--reliable="):
			options["reliable"] = arg.substr(11).to_int() != 0
		elif arg.begins_with("--target-backend="):
			match arg.substr(17):
				"native":
					_target_backend = 1
				"compare":
					_target_backend = 2
				"full":
					_target_backend = 3
				"compare-full":
					_target_backend = 4
				_:
					_target_backend = 0
		elif arg.begins_with("--battle-units="):
			var wanted: Array[int] = []
			for piece in arg.substr(15).split(",", false):
				var value := int(piece.strip_edges())
				if value > 0:
					wanted.append(value)
			if not wanted.is_empty():
				options["battle_units"] = wanted
		elif arg.begins_with("--gap="):
			options["gap"] = clampf(float(arg.substr(6)), 0.0, 0.95)
		elif arg.begins_with("--group="):
			options["group"] = maxi(10, int(arg.substr(8)))
		elif arg.begins_with("--overlap-cell="):
			options["overlap_cell"] = maxf(0.0, float(arg.substr(15)))
		elif arg.begins_with("--reacquire="):
			options["reacquire"] = maxi(0, int(arg.substr(12)))
		elif arg.begins_with("--retention="):
			options["retention"] = maxf(0.0, float(arg.substr(12)))
		elif arg.begins_with("--switch="):
			options["switch"] = maxf(0.0, float(arg.substr(9)))
		elif arg.begins_with("--immediate="):
			options["immediate"] = arg.substr(12).to_int()
		elif arg.begins_with("--spikes="):
			options["spikes"] = arg.substr(9).to_int() != 0
		elif arg.begins_with("--storm="):
			options["storm"] = arg.substr(8).to_int() != 0
		elif arg.begins_with("--focus-scale="):
			options["focus_scale"] = arg.substr(14).to_int() != 0
		elif arg.begins_with("--scaled-table="):
			# Family B without the clock is a second full sweep of the same battles. It is
			# on by default because the two tables together are the evidence; it is off when
			# only the profile is being read, to halve a long run.
			options["scaled_table"] = arg.substr(15).to_int() != 0
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
	simulator.target_backend = _target_backend
	if _overlap_cell_override > 0.0:
		simulator.overlap_cell_size = _overlap_cell_override
		simulator.overlap_grid.configure(simulator.field_size, _overlap_cell_override)
	if _overlap_backend >= 0:
		simulator.overlap_backend = _overlap_backend
	_apply_target_overrides(simulator)
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
		simulator.sample_phases = _spikes
	if _overlap_diag:
		_diag = _empty_diag(maxi(1, ticks / 20))
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
		if _overlap_diag:
			_accumulate_diag(simulator)
		done += 1
	var total_us := Time.get_ticks_usec() - started

	if _target_backend != 0:
		# What the backend did, printed with the run it belongs to, so a native number can
		# never be quoted without the mode and the counters that produced it.
		var backend: Dictionary = simulator.backend_report()
		print("    backend %d: queries %d, mismatches %d, native candidates %d, native %d us" % [
			backend.get("backend", -1), backend.get("native_calls", 0), backend.get("native_mismatches", 0),
			backend.get("native_candidates", 0), backend.get("native_usec", 0)])

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
		out["overlap_report"] = simulator.overlap_report()
		out["overlap_backend"] = simulator.overlap_backend_active
		out["overlap_backend_report"] = simulator.overlap_backend_report()
		out["target_report"] = simulator.target_report()
		if _target_backend != 0:
			out["backend_report"] = simulator.backend_report()
		if _spikes:
			var stats := {}
			# "focus" and "grid" are sampled by the tick mark already; naming them here is what
			# puts the two phases this milestone is judged on into the tail table.
			for key in ["total", "focus", "grid", "target", "overlap", "soldiers", "overlap_sync", "overlap_native", "overlap_apply"]:
				stats[key] = simulator.phase_stats(key)
			out["spike_stats"] = stats
			# The worst tick, with what it was doing. Counters only; the pass has already run.
			out["overlap_worst"] = simulator.overlap_worst()
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


## Step 7 against Step 7.2, at the sizes both measured. This is the table the Step 7.2
## milestone exists to produce, and it is kept because the history is the point: a
## milestone that quietly stops reporting the milestones before it is a milestone nobody
## can audit. Step 7.4's own table follows it.
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
	print("  The Step 7.2 column is this run's own figure for the same battle, so the table")
	print("  above is history rather than a claim about this milestone.")

	_print_recent_comparison(reports)

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
	for report in reports:
		if float(report["per_tick"]) <= frame_budget:
			holds = maxi(holds, int(report["units"]))
	if holds > 0:
		print("  Largest measured size with a simulation tick under one 60 FPS frame: %d soldiers." % holds)
	else:
		print("  No measured size has a simulation tick under one 60 FPS frame yet.")


## Step 7.3 against Step 7.4: the table this milestone exists to produce. Same seed, same
## fixed-area layout, same rules, same budget - only the target schedule differs.
func _print_recent_comparison(reports: Array[Dictionary]) -> void:
	var comparable: Array[Dictionary] = []
	for report in reports:
		if STEP_7_3_BASELINE.has(int(report["units"])):
			comparable.append(report)
	if comparable.is_empty():
		return
	print("")
	print("=== STEP 7.3 vs STEP 7.4 (fixed-area torture test, same seed and budget) ===")
	print("%7s | %16s | %16s | %10s | %12s | %s" % [
		"units", "Step 7.3 ms/tick", "Step 7.4 ms/tick", "speedup", "7.4 ticks/s", "contact"])
	print("-".repeat(80))
	for report in comparable:
		var before := float(STEP_7_3_BASELINE[int(report["units"])])
		var after := float(report["per_tick"])
		print("%7d | %14.3f | %14.3f | %9.2fx | %12.1f | %s" % [
			int(report["units"]), before, after, before / maxf(0.000001, after),
			float(report["ticks_per_second"]), "yes" if bool(report["contact"]) else "no"])
	print("-".repeat(80))
	print("  Step 7.3 figures are the recorded measurements from docs/CURRENT_STATE.md when")
	print("  Step 7.3 shipped, taken on this machine with this harness. Step 7.4 changed how")
	print("  often a soldier looks for an enemy and nothing else about it.")


## Where the time actually goes now. Enabled with --profile=1, and reported at phase
## granularity because that is the level at which a next step can be chosen.
func _print_profile(counts: Array, ticks: int, seed_value: int, budget: float) -> void:
	print("")
	print("=== PHASE PROFILE (ms per tick, same battles, clock on) ===")
	print("%7s | %10s | %9s | %11s | %10s | %12s | %9s | %10s | %s" % [
		"units", "grid", "focus", "formations", "soldiers", "of which target", "overlap", "accounted", "total"])
	print("-".repeat(114))
	var overlaps: Array[Dictionary] = []
	var targets: Array[Dictionary] = []
	var spikes: Array[Dictionary] = []
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
		var report: Dictionary = run.get("overlap_report", {})
		report["units"] = count
		report["ticks"] = int(run["ticks"])
		report["pass_ms"] = float(phases.get("overlap", 0.0))
		overlaps.append(report)
		var target_report: Dictionary = run.get("target_report", {})
		target_report["units"] = count
		target_report["ticks"] = int(run["ticks"])
		target_report["phase_ms_per_tick"] = target
		targets.append(target_report)
		var stats: Dictionary = run.get("spike_stats", {})
		if not stats.is_empty():
			spikes.append({"units": count, "stats": stats, "worst": run.get("overlap_worst", {})})
	print("-".repeat(114))
	print("  'accounted' is the sum of the phases and should sit just under 'total'; the gap")
	print("  is the parts of a tick nothing has been instrumented for. 'soldiers' is the")
	print("  per-soldier update loop and 'of which target' is the share of")
	print("  it spent choosing targets. The clock costs two reads per soldier, so a profiled")
	print("  figure is slightly higher than the unprofiled one in the table above - use the")
	print("  table above for comparisons and this one for attribution.")

	if overlaps.is_empty():
		return
	print("")
	print("=== THE SEPARATION PASS: where its time goes (Step 7.8) ===")
	print("  Per pass, and all from the same field: 'build' is clearing, the roster walk, alive")
	print("  filtering, cell calculation and insertion; 'same-cell' is the intra-cell pair loop;")
	print("  'neighbour' is the neighbour-cell loop including the settled-cell proof; 'apply' is")
	print("  the clamp and the write-back. 'total' is the whole pass as the pass itself timed it,")
	print("  so the four parts can be checked against the whole rather than being the whole.")
	print("  The exact pair work lives inside the two traversal columns - see the split table")
	print("  printed with the family-B profile, which measures it by subtraction.")
	print("")
	print("%7s | %9s | %11s | %11s | %9s | %9s | %8s | %8s | %7s | %s" % [
		"units", "build us", "same-cell us", "neighbour us", "apply us", "total us",
		"pop p50", "pop p99", "coincid", "moved/tk"])
	print("-".repeat(126))
	for report in overlaps:
		# Only directly measured figures are printed: the remainder of the phase is not
		# derived here, because the clocks in this table are per pass and the phase value is
		# per tick, and subtracting one from the other produced a number that was neither.
		print("%7d | %9.0f | %11.0f | %11.0f | %9.0f | %9.0f | %8.0f | %8.0f | %7.0f | %8.1f" % [
			int(report["units"]),
			float(report.get("usec_build", 0)), float(report.get("usec_same_cell", 0)),
			float(report.get("usec_neighbour", 0)), float(report.get("usec_apply", 0)),
			float(report.get("usec_total", 0)),
			float(report.get("cell_population_p50", 0)), float(report.get("cell_population_p99", 0)),
			float(report.get("coincident", 0)), float(report.get("moved_units", 0))])
	print("")
	print("=== THE SEPARATION PASS: what it did, not only what it cost ===")
	print("  Per tick. 'pairs' is how many soldier pairs the broadphase produced and measured;")
	print("  'touching' is how many of them were actually inside the separation distance.")
	print("")
	print("%7s | %8s | %9s | %9s | %8s | %9s | %9s | %9s | %s" % [
		"units", "cells", "pop/cell", "cell prs", "skipped", "pairs", "touching", "clamped", "diam/ms"])
	print("-".repeat(102))
	for report in overlaps:
		var ticks_done := maxf(1.0, float(report.get("ticks", 1)))
		print("%7d | %8.0f | %9.1f | %9.0f | %8.0f | %9.0f | %9.1f | %9.0f | %s" % [
			int(report["units"]),
			float(report.get("occupied_cells", 0)),
			float(report.get("cell_population_avg", 0.0)),
			float(report.get("cell_pairs", 0)) / ticks_done,
			float(report.get("cell_pairs_skipped", 0)) / ticks_done,
			float(report.get("pairs", 0)) / ticks_done,
			float(report.get("touching", 0)) / ticks_done,
			float(report.get("clamped", 0)) / ticks_done,
			"%.3f ms" % (float(report.get("pass_ms", 0.0)) / ticks_done)])
	print("-".repeat(102))
	for report in overlaps:
		var ticks_done := maxf(1.0, float(report.get("ticks", 1)))
		var pairs := maxf(1.0, float(report.get("pairs", 0)))
		print("  %d units: reach %d cells of %.2f units; %.1f pairs measured per touching pair;" % [
			int(report["units"]),
			int(report.get("reach_cells", 0)),
			float(report.get("cell_size", 0.0)),
			pairs / maxf(1.0, float(report.get("touching", 0)))])
		print("            %d of %d soldiers stood on their assigned place; %d cells were a" % [
			int(report.get("settled_units", 0)),
			int(report.get("indexed_units", 0)),
			int(report.get("interior_cells", 0))])
		print("            settled body's interior, %.0f of them skipped outright." % [
			float(report.get("cell_pairs_skipped", 0)) / ticks_done])
	print("")
	print("  'skipped' counts cell pairs a formation's own spacing already proves cannot be")
	print("  touching: two soldiers standing within the settle distance of their assigned")
	print("  places are a slot apart, and a slot is wider than a body. That is the one place")
	print("  the pass declines to do work, and it declines on a proof rather than a guess.")
	_print_target_table(targets)
	_print_spike_table(spikes)


## ---------- Benchmark B: battlefield scaled with the army -------------------

## The field a given army gets at the reference density, keeping the standard aspect.
func _battlefield_for(count: int) -> Vector2:
	var area := float(count) / REALISTIC_DENSITY
	var height := sqrt(area / FIELD_ASPECT)
	return Vector2(height * FIELD_ASPECT, height)


## Two coherent armies that march into each other on a field sized for them.
##
## This is the benchmark that answers the question the fixed-area one cannot: what a real
## battle of this size costs. The fixed-area harness crams every army into the same
## hundred-by-sixty field, which is a deliberate torture test and is useful precisely
## because it is cruel - but past a few hundred soldiers it stops describing a battle and
## starts describing a crowd. Here the ground grows with the army, the armies deploy as
## several formed bodies a side, stand on the places their formations give them, and
## advance until they meet.
func _run_battle_scaled(
	count: int,
	ticks: int,
	seed_value: int,
	budget: float,
	gap_fraction: float,
	group_size: int,
	profile: bool = false
) -> Dictionary:
	var config := GameManager.config()
	var field := _battlefield_for(count)
	var setup_start := Time.get_ticks_usec()

	var context := BattleContext.new()
	context.battle_id = "scale_%d" % count
	context.battle_seed = seed_value
	context.terrain_seed = seed_value

	var simulator := BattleSimulator.new(config, seed_value)
	simulator.target_backend = _target_backend
	# The field is a property of the battle rather than of the game, so it is set on the
	# simulator and its two indexes rather than edited into the config. Nothing else reads
	# the field size.
	simulator.field_size = field
	simulator.grid.configure(field, simulator.cell_size)
	simulator.overlap_grid.configure(field, simulator.overlap_cell_size)
	if _overlap_backend >= 0:
		simulator.overlap_backend = _overlap_backend
	_apply_target_overrides(simulator)

	var units := _build_ranks_scaled(count, field, gap_fraction)
	simulator.add_units(units)
	simulator.set_terrain_from_context(context, config)
	_assign_armies(simulator, field, group_size)

	var checksum := _setup_checksum(simulator)
	var ai := BattleAI.create(config)
	var setup_ms := float(Time.get_ticks_usec() - setup_start) / 1000.0

	if profile:
		simulator.reset_profile()
		simulator.profile_enabled = true
		simulator.sample_phases = _spikes

	if _overlap_diag:
		_diag = _empty_diag(maxi(1, ticks / 20))
	if _overlap_split:
		_split_samples.clear()
	# Enabling the counters is what makes the report readable at all; the accumulation below
	# reads the same dictionary the phase table does, once a tick.
	if _overlap_diag or _overlap_split:
		simulator.profile_enabled = true

	simulator.start()
	var started := Time.get_ticks_usec()
	var budget_us := int(budget * 1000000.0)
	var done := 0
	var combat_ticks := 0
	var deaths := 0
	var first_contact := -1
	var split_every := maxi(1, ticks / 6)
	while done < ticks:
		if simulator.is_finished():
			break
		if Time.get_ticks_usec() - started >= budget_us:
			break
		ai.update(simulator, TICK)
		if _overlap_split and done > 0 and done % split_every == 0:
			_split_samples.append(_overlap_split_probe(simulator, done))
		var events := simulator.step(TICK)
		if _overlap_diag:
			_accumulate_diag(simulator)
		var fought := false
		for event in events:
			var kind := str(event.get("type", ""))
			if kind == "hit" or kind == "miss":
				fought = true
			elif kind == "death":
				deaths += 1
		if fought:
			combat_ticks += 1
			if first_contact < 0:
				first_contact = done
		done += 1
	var total_us := Time.get_ticks_usec() - started

	if _target_backend != 0:
		# What the backend did, printed with the run it belongs to, so a native number can
		# never be quoted without the mode and the counters that produced it.
		var backend: Dictionary = simulator.backend_report()
		print("    backend %d: queries %d, mismatches %d, native candidates %d, native %d us" % [
			backend.get("backend", -1), backend.get("native_calls", 0), backend.get("native_mismatches", 0),
			backend.get("native_candidates", 0), backend.get("native_usec", 0)])

	var alive := 0
	for unit in simulator.units:
		if unit.is_alive():
			alive += 1

	var per_tick_ms := 0.0 if done == 0 else (float(total_us) / 1000.0) / float(done)
	var out := {
		"units": count,
		"field": field,
		"density": float(count) / (field.x * field.y),
		"ticks": done,
		"total_ms": float(total_us) / 1000.0,
		"per_tick_ms": per_tick_ms,
		"ticks_per_second": 0.0 if total_us <= 0 else float(done) / (float(total_us) / 1000000.0),
		"setup_ms": setup_ms,
		"alive": alive,
		"deaths": deaths,
		"combat_ticks": combat_ticks,
		"first_contact": first_contact,
		"armies": simulator.formations.size(),
		"checksum": checksum,
		"simulator": simulator,
	}
	if _overlap_diag:
		out["overlap_diag"] = _diag.duplicate(true)
	if _overlap_split:
		out["overlap_split"] = _split_samples.duplicate(true)
	if profile:
		out["profile"] = simulator.profile.duplicate()
		out["target_report"] = simulator.target_report()
		out["overlap_backend"] = simulator.overlap_backend_active
		out["overlap_backend_report"] = simulator.overlap_backend_report()
		if _target_backend != 0:
			out["backend_report"] = simulator.backend_report()
		out["focus_report"] = simulator.focus_report()
		if _spikes:
			var stats := {}
			# "focus" and "grid" are sampled by the tick mark already; naming them here is what
			# puts the two phases this milestone is judged on into the tail table.
			for key in ["total", "focus", "grid", "target", "overlap", "soldiers", "overlap_sync", "overlap_native", "overlap_apply"]:
				stats[key] = simulator.phase_stats(key)
			out["spike_stats"] = stats
			# The worst tick, with what it was doing. Counters only; the pass has already run.
			out["overlap_worst"] = simulator.overlap_worst()
	return out


## Each side's soldiers split into several line bodies rather than one enormous one, which
## is what an army looks like and what makes a formed body a sensible size. Every soldier
## is then stood on the place its body gave it, so the armies start dressed - which is the
## state a battle actually begins in, and the state the separation pass is meant to be
## cheap in.
func _assign_armies(simulator: BattleSimulator, field: Vector2, group_size: int) -> void:
	var catalog := FormationCatalog.load_from()
	var config := GameManager.config()
	for side in [BattleContext.SIDE_PLAYER, BattleContext.SIDE_ENEMY]:
		var facing := 0.0 if side == BattleContext.SIDE_PLAYER else PI
		var mine: Array[BattleUnit] = []
		for unit in simulator.units:
			if unit.side == side:
				mine.append(unit)
		# Front to back, so a body is a slice of the line rather than a random sample.
		mine.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool:
			if absf(a.position.x - b.position.x) > 0.001:
				return a.position.x < b.position.x if side == BattleContext.SIDE_PLAYER else a.position.x > b.position.x
			return a.position.y < b.position.y)
		var index := 0
		var ordinal := 0
		while index < mine.size():
			var slice: Array[BattleUnit] = []
			var ids: Array[int] = []
			var centroid := Vector2.ZERO
			for i in mini(group_size, mine.size() - index):
				slice.append(mine[index + i])
				ids.append(mine[index + i].id)
				centroid += mine[index + i].position
			centroid /= float(slice.size())
			var body := BattleFormation.create("%s_body_%d" % [side, ordinal], side, centroid, facing, "line", catalog, config)
			simulator.add_formation(body)
			simulator.assign_formation(body, ids)
			ordinal += 1
			index += group_size

	for body in simulator.formations:
		var opposing := field.x * 0.5
		body.order_face_toward(Vector2(opposing, body.anchor.y))
		body.set_facing(body.desired_facing)
		body.order_engage()
		body.ensure_slots()
		for i in body.unit_ids.size():
			var unit := simulator.find_unit(body.unit_ids[i])
			if unit != null and i < body.slots.size():
				unit.position = body.slots[i]
				unit.position = Vector2(
					clampf(unit.position.x, 0.5, field.x - 0.5),
					clampf(unit.position.y, 0.5, field.y - 0.5))


## Two blocks facing each other on a field sized for them. The blocks sit on the flanks of
## the middle, separated by [param gap_fraction] of the field's width - so at 0.25 the
## front ranks start a quarter of a battlefield apart and walk into each other.
func _build_ranks_scaled(count: int, field: Vector2, gap_fraction: float) -> Array[BattleUnit]:
	var per_side := maxi(1, count / 2)
	var files := maxi(1, mini(int(field.y * 0.6), int(ceil(sqrt(float(per_side) * 1.6)))))
	var ranks := maxi(1, int(ceil(float(per_side) / float(files))))
	var lateral_step := (field.y * 0.8) / float(files)
	var depth_step := (field.x * 0.2) / float(ranks)
	var front := field.x * (0.5 - gap_fraction * 0.5)

	var units: Array[BattleUnit] = []
	var next_id := 0
	for side_value in [BattleContext.SIDE_PLAYER, BattleContext.SIDE_ENEMY]:
		var side := str(side_value)
		var left := side == BattleContext.SIDE_PLAYER
		for i in per_side:
			var file := i % files
			var rank := i / files
			var unit := BattleUnit.new()
			unit.id = next_id
			next_id += 1
			unit.side = side
			unit.soldier_id = "s_scale_%d" % unit.id
			unit.display_name = "Scale %d" % unit.id
			unit.max_hp = 40
			unit.hp = 40
			unit.attack = 5
			unit.defence = 2
			unit.move_speed = 5.0
			unit.attack_range = 1.8
			unit.attack_cooldown = 1.2
			unit.ranged = (rank % 5) == 4
			unit.position = Vector2(
				front - float(rank) * depth_step if left else front + float(rank) * depth_step,
				field.y * 0.1 + float(file) * lateral_step)
			units.append(unit)
	return units


func _print_scaled(options: Dictionary) -> void:
	var counts: Array = options["battle_units"]
	var ticks: int = options["ticks"]
	var seed_value: int = options["seed"]
	var budget: float = options["budget"]
	var gap: float = options["gap"]
	var group: int = options["group"]

	print("")
	print("=== BENCHMARK B: battlefield scaled with the army ===")
	print("  Density held at %.4f soldiers per square unit - the 500-on-100x60 case - with" % REALISTIC_DENSITY)
	print("  the standard %.2f aspect. Armies are formed bodies of %d that start standing on" % [FIELD_ASPECT, group])
	print("  their slots, so the numbers below are a dressed battle rather than a crowd.")
	print("  Front ranks start %.0f%% of a battlefield apart and walk into each other." % (gap * 100.0))
	print("")
	print("%7s | %13s | %8s | %10s | %10s | %9s | %8s | %9s | %8s | %s" % [
		"units", "field", "density", "ms/tick", "ticks/sec", "ticks", "contact", "combat", "deaths", "armies"])
	print("-".repeat(112))
	var first_ms := 0.0
	var last_ms := 0.0
	var reports: Array[Dictionary] = []
	for count_value in counts:
		var count := int(count_value)
		var effective := minf(MAX_BUDGET, budget * maxf(1.0, float(count) / 1000.0))
		var run := _run_battle_scaled(count, ticks, seed_value, effective, gap, group)
		reports.append(run)
		var per_tick := float(run["per_tick_ms"])
		if first_ms == 0.0:
			first_ms = per_tick
		last_ms = per_tick
		print("%7d | %6.0fx%-6.0f | %8.4f | %7.3f ms | %10.0f | %9d | %8s | %8d | %8d | %d" % [
			count, Vector2(run["field"]).x, Vector2(run["field"]).y, float(run["density"]),
			per_tick, float(run["ticks_per_second"]), int(run["ticks"]),
			"yes" if int(run["combat_ticks"]) > 0 else "no",
			int(run["combat_ticks"]), int(run["deaths"]), int(run["armies"])])
	print("-".repeat(112))
	if reports.size() >= 2 and first_ms > 0.0:
		var unit_ratio := float(int(reports[reports.size() - 1]["units"])) / maxf(1.0, float(int(reports[0]["units"])))
		print("  %d -> %d soldiers is %.1fx the army and %.1fx the time per tick, at constant" % [
			int(reports[0]["units"]), int(reports[reports.size() - 1]["units"]), unit_ratio,
			last_ms / maxf(0.0001, first_ms)])
		print("  density. A curve that tracks the army is the shape a real battlefield has; one")
		print("  that climbs steeply is density, not size, and family A is where that shows.")
	for run in reports:
		if int(run["combat_ticks"]) == 0:
			print("  NOTE: %d soldiers never reached contact inside the budget. The figure is an"
				% int(run["units"]))
			print("  approach measurement and is not offered as the cost of a fight.")
		elif int(run["combat_ticks"]) < int(run["ticks"]) / 4:
			print("  NOTE: %d soldiers reached contact but spent only %d of %d ticks fighting." % [
				int(run["units"]), int(run["combat_ticks"]), int(run["ticks"])])


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


## ---------- Step 7.4: what target handling did, and what it cost -------------

## Whether the urgency rule is on, as the config or an override has it.
func _immediate_enabled() -> bool:
	if _immediate_override >= 0:
		return _immediate_override != 0
	return GameManager.config().get_bool("battle.target_immediate_on_contact_loss", true)


## Apply the swept values to a freshly built battle simulator. Called before the roster is
## added, because that is where the awareness phases are handed out.
func _apply_target_overrides(simulator: BattleSimulator) -> void:
	if _reacquire_override > 0:
		simulator.target_reacquisition_ticks = _reacquire_override
	if _retention_override > 0.0:
		simulator.target_retention_radius = _retention_override
	if _switch_override > 0.0:
		simulator.target_switch_advantage = _switch_override
	if _immediate_override >= 0:
		simulator.target_immediate_on_contact_loss = _immediate_override != 0


## What target handling did, per size: the figures that say why the tick got cheaper.
##
## Counters rather than a clock. "Target selection is now 60 ms" says the milestone
## worked; "twenty thousand soldiers looked 1,400 times a tick instead of 20,000, and
## nineteen out of twenty were dealing with an enemy they already had" says how, and a
## number that cannot say how is a number nobody can check.
func _print_target_table(targets: Array[Dictionary]) -> void:
	if targets.is_empty():
		return
	print("")
	print("=== TARGET ACQUISITION: what it did, per tick ===")
	print("%7s | %10s | %11s | %11s | %11s | %10s | %10s | %9s" % [
		"units", "looks", "kept/in reach", "kept/holding", "focus", "avoided", "avoided%", "switches"])
	print("-".repeat(100))
	for report in targets:
		var ticks := maxf(1.0, float(report.get("ticks", 1)))
		print("%7d | %10.1f | %11.1f | %11.1f | %11.1f | %10.1f | %9.1f%% | %9.1f" % [
			int(report["units"]),
			float(report["searches"]) / ticks,
			float(report["retained_in_reach"]) / ticks,
			float(report["retained_held"]) / ticks,
			float(report["focus_fallbacks"]) / ticks,
			float(report["searches_avoided"]) / ticks,
			float(report["searches_avoided_pct"]),
			float(report["switches"]) / ticks])
	print("-".repeat(100))
	print("  'focus' is the cheap answer: soldiers pointed at the fighting without looking. Of")
	print("  those, the looks skipped on a proof that they would have found nobody:")
	for report in targets:
		var ticks := maxf(1.0, float(report.get("ticks", 1)))
		print("      %6d soldiers: %.1f per tick, %.1f%% of the cheap path" % [
			int(report["units"]), float(report.get("focus_proven", 0)) / ticks,
			float(report.get("focus_proven_pct", 0.0))])
	print("-".repeat(100))
	print("%7s | %10s | %11s | %11s | %11s | %10s | %10s | %9s" % [
		"units", "looks/sld", "dead", "too far", "urgent", "scheduled", "cand/look", "cand max"])
	print("-".repeat(100))
	for report in targets:
		var soldier_seconds := maxf(0.0001, float(report["soldier_ticks"]) * TICK)
		print("%7d | %10.2f | %11.1f | %11.1f | %11.1f | %10.1f | %10.1f | %9d" % [
			int(report["units"]),
			float(report["searches"]) / soldier_seconds,
			float(report["invalid_dead"]) / maxf(1.0, float(report.get("ticks", 1))),
			float(report["invalid_far"]) / maxf(1.0, float(report.get("ticks", 1))),
			float(report["immediate_reacquires"]) / maxf(1.0, float(report.get("ticks", 1))),
			float(report["scheduled_reacquires"]) / maxf(1.0, float(report.get("ticks", 1))),
			float(report["candidates_per_search"]),
			int(report["candidates_max"])])
	print("-".repeat(100))
	for report in targets:
		print("  %d soldiers: %.2f looks per soldier per simulated second (the old rule was" % [
			int(report["units"]), float(report["searches_per_soldier_second"])])
		print("              %d per second), %.1f%% of soldier-ticks did not look at all, and" % [
			int(round(1.0 / TICK)), float(report["searches_avoided_pct"])])
		print("              %.2f of them spent the tick fighting, holding or chasing the enemy" % [
			float(report["retained_uses"]) / maxf(1.0, float(report["soldier_ticks"]))])
		print("              they already had.")
	var with_latency: Array[Dictionary] = []
	for report in targets:
		if int(report.get("latency_samples", 0)) > 0:
			with_latency.append(report)
	if not with_latency.is_empty():
		print("")
		print("  Acquisition latency, for soldiers that lost an opponent and had to find" )
		print("  another: measured in simulation ticks from the loss to the replacement. The")
		print("  average is bounded by the cadence; the worst is not, and is a soldier with")
		print("  nobody left to find rather than a schedule arriving late.")
		print("  %7s | %11s | %11s | %11s | %11s | %s" % [
			"units", "avg ticks", "worst ticks", "samples", "over cadence", "within cadence"])
		for report in with_latency:
			var samples := maxi(1, int(report["latency_samples"]))
			var over := int(report["latency_over_cadence"])
			print("  %7d | %11.1f | %11d | %11d | %11d | %.1f%%" % [
				int(report["units"]), float(report["latency_avg_ticks"]),
				int(report["latency_worst_ticks"]), samples, over,
				100.0 * float(samples - over) / float(samples)])
	_print_search_shape_table(targets)


## Step 7.6. What one automatic search actually costs: how many grid queries a look makes,
## how much ground those queries walk, how much of that ground one search walks twice, how
## many candidates it measures, and how the cost splits between the first rung and the
## widening. Development counters, printed only when the run was profiled.
func _print_search_shape_table(targets: Array[Dictionary]) -> void:
	var shaped: Array[Dictionary] = []
	for report in targets:
		if not Dictionary(report.get("search_shape", {})).is_empty():
			shaped.append(report)
	if shaped.is_empty():
		return
	print("")
	print("=== SEARCH SHAPE: what one automatic look costs (Step 7.6) ===")
	print("%7s | %7s | %10s | %9s | %9s | %8s | %10s | %8s | %7s | %7s | %7s" % [
		"units", "queries", "cells/look", "unique", "repeated", "rep %", "cand/look", "escal %", "hit1 %", "deep %", "empty %"])
	print("-".repeat(104))
	for report in shaped:
		var shape: Dictionary = report["search_shape"]
		var cells: Dictionary = shape["cells"]
		var cand: Dictionary = shape["candidates"]
		var searches := maxf(1.0, float(report["searches"]))
		var found_first := float(report["successful_searches"]) - float(shape["deep_hits"])
		print("%7d | %7.2f | %10.1f | %9.1f | %9.1f | %7.1f%% | %10.2f | %7.1f%% | %6.1f%% | %6.1f%% | %6.1f%%" % [
			int(report["units"]),
			float(shape["grid_queries_per_search"]),
			float(cells["avg"]),
			float(shape["cells_unique_avg"]),
			float(shape["cells_repeated_avg"]),
			float(shape["cells_repeated_pct"]),
			float(cand["avg"]),
			100.0 * float(shape["searches_escalated"]) / searches,
			100.0 * maxf(0.0, found_first) / searches,
			100.0 * float(shape["deep_hits"]) / searches,
			100.0 * float(report["empty_searches"]) / searches])
		if int(shape["searches_mixed_walk"]) > 0:
			print("        (%d of %d looks walked the occupied list rather than their box -" % [
				int(shape["searches_mixed_walk"]), int(report["searches"])])
			print("         a packed field, where that is the cheaper walk. Their cells are")
			print("         counted in 'cells/look' and excluded from 'unique'/'repeated'.)")
	print("-".repeat(104))
	print("  'queries' is grid queries per look: one per rung of the escalation ladder, so")
	print("  'hit1' is the looks answered by the first radius, 'deep' the looks answered only")
	print("  after widening, and 'empty' the looks that found nobody at any radius. The three")
	print("  partition the looks, and it is the empty one that a widening search cannot end")
	print("  early: proving there is nobody out there costs the whole box, whichever way it")
	print("  is traversed.")
	print("  1.00 means the first radius found somebody and 2.00 means every look widened.")
	print("  'unique' is the ground the widest rung covers; 'repeated' is ground one look")
	print("  walked twice because the second rung is a superset of the first.")
	print("")
	print("%7s | %9s | %9s | %9s | %9s | %9s | %9s | %9s" % [
		"units", "cells p50", "cells p95", "cells p99", "cells max", "cand p95", "cand p99", "dist p50"])
	print("-".repeat(104))
	for report in shaped:
		var shape: Dictionary = report["search_shape"]
		var cells: Dictionary = shape["cells"]
		var cand: Dictionary = shape["candidates"]
		var reached: Dictionary = shape["reached"]
		print("%7d | %9.0f | %9.0f | %9.0f | %9.0f | %9.0f | %9.0f | %9.2f" % [
			int(report["units"]), float(cells["p50"]), float(cells["p95"]), float(cells["p99"]),
			float(cells["max"]), float(cand["p95"]), float(cand["p99"]), float(reached["p50"])])
	print("-".repeat(104))
	print("  'dist' is the distance to the opponent a look returned, in world units. The")
	print("  radius it was found inside is the rung count; the distance says how much of the")
	print("  ladder was needed rather than merely how far it was allowed to reach.")
	print("")
	print("%7s | %11s | %11s | %11s | %11s | %11s" % [
		"units", "grid us/tick", "1st rung us", "deep us", "phase ms/tick", "grid share"])
	print("-".repeat(104))
	for report in shaped:
		var shape: Dictionary = report["search_shape"]
		var ticks := maxf(1.0, float(report.get("ticks", 1)))
		var phase: float = float(report.get("phase_ms_per_tick", 0.0))
		var per_tick_us := float(shape["total_usec_grid"]) / ticks
		var share := 100.0 * (per_tick_us / 1000.0) / maxf(0.0001, phase) if phase > 0.0 else 0.0
		print("%7d | %11.1f | %11.1f | %11.1f | %11.2f | %10.1f%%" % [
			int(report["units"]), per_tick_us, float(shape["avg_usec_first_rung"]),
			float(shape["avg_usec_deep_rungs"]), phase, share])
	print("-".repeat(104))
	print("  'grid us/tick' is time inside the grid query for one tick, summed over rungs and")
	print("  looks; '1st rung' and 'deep' are per look. The share is of the measured target")
	print("  phase, which says whether the search itself or the work around it is the cost.")
	# Where the phase actually goes. The grid query is the part Step 7.6 changes; the rest is
	# the target loop's own bookkeeping, and the size of the rest is what says whether a
	# faster query can move the phase at all.
	print("")
	print("%7s | %10s | %10s | %10s | %10s | %10s | %11s" % [
		"units", "retained", "proof", "grid", "improve", "focus", "phase ms/tick"])
	print("-".repeat(96))
	for report in shaped:
		var shape: Dictionary = report["search_shape"]
		var ticks_s := maxf(1.0, float(report.get("ticks", 1)))
		var grid_us := float(shape.get("total_usec_grid", 0)) / ticks_s
		var retained_us := float(shape.get("usec_retained", 0)) / ticks_s
		var proof_us := float(shape.get("usec_proof", 0)) / ticks_s
		var improve_us := float(shape.get("usec_improve", 0)) / ticks_s
		var focus_us := float(shape.get("usec_focus", 0)) / ticks_s
		print("%7d | %9.1fus | %9.1fus | %9.1fus | %9.1fus | %9.1fus | %10.2fms" % [
			int(report["units"]), retained_us, proof_us, grid_us, improve_us, focus_us,
			float(report.get("phase_ms_per_tick", 0.0))])
		var accounted := (retained_us + proof_us + grid_us + improve_us + focus_us) / 1000.0
		var phase := float(report.get("phase_ms_per_tick", 0.0))
		print("          of %.2f ms: %.1f%% timed, %.2f ms in the target loop around them" % [
			phase, 100.0 * accounted / maxf(0.0001, phase), maxf(0.0, phase - accounted)])
	print("-".repeat(96))
	print("  'retained' is deciding whether a remembered opponent is still worth keeping,")
	print("  'proof' is deciding whether a look is worth making, 'improve' is the hysteresis")
	print("  and the store, and 'focus' is answering with the formation when the look is over")
	print("  or was never due. Only 'grid' is a query of the spatial index.")
	for report in shaped:
		var shape: Dictionary = report["search_shape"]
		if bool(shape.get("samples_capped", false)):
			print("  NOTE: %d soldiers - the per-search samples hit their cap, so the" % int(report["units"]))
			print("        percentiles above describe the first %d searches only." % int(shape["samples"]))


## The frame-spike analysis: average, worst and tail for the phases that matter. A system
## that averages well and spikes every sixth tick is the failure mode a staggered cadence
## is most likely to introduce, so the average alone is not evidence.
func _print_spike_table(rows: Array[Dictionary]) -> void:
	if rows.is_empty():
		return
	print("")
	print("=== SPIKES: per-tick distribution of the phases (milliseconds) ===")
	print("%7s | %8s | %22s | %22s | %s" % ["units", "phase", "avg / p50", "p95 / p99", "worst"])
	print("-".repeat(96))
	for row in rows:
		var stats: Dictionary = row["stats"]
		for key in ["total", "focus", "grid", "target", "overlap", "soldiers", "overlap_sync", "overlap_native", "overlap_apply"]:
			if not stats.has(key) or stats[key].is_empty():
				continue
			var phase: Dictionary = stats[key]
			print("%7d | %8s | %10.3f / %10.3f | %10.3f / %10.3f | %9.3f" % [
				int(row["units"]), key,
				float(phase["avg"]), float(phase["p50"]),
				float(phase["p95"]), float(phase["p99"]), float(phase["max"])])
	print("-".repeat(96))
	for row in rows:
		var worst: Dictionary = row.get("worst", {})
		if worst.is_empty():
			continue
		print("  %d units' worst overlap tick (%.0f us): %d candidate pairs, %d touching, %d clamped, %d coincident, max cell population %d" % [
			int(row["units"]), float(worst.get("usec", 0)),
			int(worst.get("pairs", 0)), int(worst.get("touching", 0)),
			int(worst.get("clamped", 0)), int(worst.get("coincident", 0)),
			int(worst.get("cell_population_max", 0))])
	print("  Nearest-rank percentiles over every tick of the run, from the phase clock. A")
	print("  spread between the average and the tail is the price of staggering: it is the")
	print("  worst tick, not the average one, that a frame notices.")


## Family B, profiled. The same battles as the table above, run a second time with the
## clock on, because the 20K realistic-density case is now a primary engineering metric
## and a metric nobody breaks down is a metric nobody can act on.
func _print_scaled_profile(options: Dictionary) -> void:
	# Family B is the family --reliable=0 switches off, profiling and all: a run that
	# cannot afford the battles cannot afford their breakdown either.
	if not bool(options["reliable"]):
		return
	var counts: Array = options["battle_units"]
	var ticks: int = options["ticks"]
	var seed_value: int = options["seed"]
	var budget: float = options["budget"]
	var gap: float = options["gap"]
	var group: int = options["group"]

	print("")
	print("=== FAMILY B PHASE PROFILE (scaled battlefield, clock on) ===")
	print("%7s | %10s | %9s | %11s | %10s | %12s | %9s | %10s | %s" % [
		"units", "grid", "focus", "formations", "soldiers", "of which target", "overlap", "accounted", "total"])
	print("-".repeat(114))
	var targets: Array[Dictionary] = []
	var focuses: Array[Dictionary] = []
	var spikes: Array[Dictionary] = []
	var diags: Array[Dictionary] = []
	var splits: Array[Dictionary] = []
	for count_value in counts:
		var count := int(count_value)
		var effective := minf(MAX_BUDGET, budget * maxf(1.0, float(count) / 1000.0))
		_split_samples.clear()
		var run := _run_battle_scaled(count, ticks, seed_value, effective, gap, group, true)
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
		var report: Dictionary = run.get("target_report", {})
		report["units"] = count
		report["ticks"] = int(run["ticks"])
		# The measured target phase, so the search-shape table can say what share of it the
		# grid query itself is rather than leaving the reader to guess.
		report["phase_ms_per_tick"] = target
		targets.append(report)
		var focus_stats: Dictionary = run.get("focus_report", {})
		if not focus_stats.is_empty():
			focus_stats["units"] = count
			focuses.append(focus_stats)
		var stats: Dictionary = run.get("spike_stats", {})
		if not stats.is_empty():
			spikes.append({"units": count, "stats": stats, "worst": run.get("overlap_worst", {})})
		if _overlap_diag:
			var diag: Dictionary = run.get("overlap_diag", {})
			if not diag.is_empty():
				diag["units"] = count
				# Which pass was measured. The rejection counters the diagnosis is read from
				# live in the locked reference, so a run that measured the packed or native
				# pass reports zeros for every reason - which looks exactly like a proof that
				# never fires. Naming the pass in the table is what stops that being read as
				# a finding.
				diag["pass"] = BattleSimulator.overlap_backend_label(int(run.get("overlap_backend", 0)))
				diags.append(diag)
		if _overlap_split:
			var split_rows: Array = run.get("overlap_split", [])
			for row in split_rows:
				splits.append(row as Dictionary)
	print("-".repeat(114))
	print("  Combat ticks for each size are reported in the table above; a size that never")
	print("  reached contact is an approach measurement and its profile says so.")
	_print_focus_table(focuses)
	_print_target_table(targets)
	_print_spike_table(spikes)
	if _overlap_diag:
		_print_overlap_diagnosis(diags)
	if _overlap_split:
		_print_overlap_split(splits)


## What the formation-focus path did, per size. The column that matters is 'soldier scans':
## whole-army walks made by the focus logic on behalf of one soldier, which is a formation's
## work being repeated N times and the O(N^2) failure this milestone exists to remove.
func _print_focus_table(focuses: Array[Dictionary]) -> void:
	if focuses.is_empty():
		return
	print("")
	print("=== FORMATION FOCUS: what the path actually did ===")
	print("%7s | %9s | %11s | %12s | %12s | %13s | %9s | %8s | %s" % [
		"units", "bodies", "evals/tick", "scans/tick", "soldier scans", "units/tick",
		"hits/tick", "repairs", "changes/tick"])
	print("-".repeat(118))
	for report in focuses:
		print("%7d | %9d | %11.1f | %12.1f | %12.1f | %13.0f | %9.1f | %8d | %.2f" % [
			int(report["units"]), int(report["formations"]),
			float(report["evaluations_per_tick"]), float(report["scans_per_tick"]),
			float(report["soldier_scans_per_tick"]), float(report["units_per_tick"]),
			float(report["formation_hits"]) / maxf(1.0, float(report["ticks"])),
			int(report["formation_repairs"]), float(report["changes_per_tick"])])
	print("-".repeat(118))
	print("  'evals/tick' is one focus evaluation per body per tick, which is the intent. 'scans/tick'")
	print("  is whole-army walks; 'soldier scans' is the share of them made on behalf of one soldier.")
	print("  'hits/tick' is soldiers answered straight out of their body's cached focus. 'changes/tick'")
	print("  is focus churn - how often a body's answer is a different soldier than last tick.")
	for report in focuses:
		print("  %d units: worst tick %d scans / %.0f units walked, against %.1f / %.0f on average" % [
			int(report["units"]), int(report["scans_worst_tick"]), float(report["units_worst_tick"]),
			float(report["scans_per_tick"]), float(report["units_per_tick"])])


## ---------- family C: the formation layer on its own ----------------------

## A synthetic formation-layer benchmark, independent of soldier combat.
##
## Bodies a side, soldiers to a body, two lines facing each other, and the only thing
## measured is the focus layer: the summary pass, the candidate collection, the selection,
## and - over the same state, in the same tick - the reference implementation, so that the
## two can be compared on identical work rather than across two runs.
##
## It exists to answer the question the battle benchmarks cannot. They measure the army the
## game actually fields, where the number of bodies is set by how the armies deployed; this
## measures the layer against the number of bodies alone, so that "where does comparing
## bodies against bodies stop being acceptable" has a curve rather than an opinion. The
## interesting figure is not the largest one that still runs: it is the count at which the
## layer stops being a rounding error, which is far beyond anything a battle fields.
const SCALE_BODIES := [10, 25, 50, 100, 200, 500, 1000]
const SCALE_PER_BODY := 20
const SCALE_TICKS := 20

func _print_focus_scale() -> void:
	print("")
	print("=== FAMILY C: the formation layer against the number of bodies ===")
	print("  Two lines of bodies, %d soldiers each, held still. Every figure is milliseconds" % SCALE_PER_BODY)
	print("  per tick, averaged over %d identical passes, with the reference implementation run" % SCALE_TICKS)
	print("  over the same state so the comparison is like for like.")
	print("")
	print("%8s | %9s | %11s | %12s | %13s | %12s | %9s | %9s | %10s | %s" % [
		"bodies", "soldiers", "summaries", "selection", "layer total", "reference",
		"speedup", "boxes/sel", "members/sel", "agree"])
	print("-".repeat(126))
	for bodies in SCALE_BODIES:
		var row := _focus_scale_row(bodies)
		if row.is_empty():
			continue
		var reference := "%9.3f ms" % float(row["reference_ms"]) if bool(row["measured"]) else "        -"
		print("%8d | %9d | %10.3f ms | %9.3f ms | %10.3f ms | %s | %8.1fx | %9.2f | %10.1f | %s" % [
			int(row["bodies"]), int(row["soldiers"]), float(row["summary_ms"]),
			float(row["select_ms"]), float(row["layer_ms"]), reference,
			float(row["speedup"]), float(row["measured_per_selection"]),
			float(row["members_per_selection"]),
			("yes" if bool(row["agree"]) else "NO") if bool(row["measured"]) else "not measured"])
	print("-".repeat(120))
	print("  'selection' is the work of choosing a focus for every body, summaries excluded;")
	print("  'reference' is one pass over the whole army per body, which is what Step 7.4 did and")
	print("  what the bounds are proved against. 'boxes/sel' is how many bodies' boxes were")
	print("  measured per selection, 'members/sel' how many soldiers were walked inside them, and")
	print("  'agree' says every selection matched the reference on every body of every pass.")


## One row of family C: build the battle, then time the three things - summaries, the
## bounded selection, and the reference the selection is proved against.
##
## The armies are built the way the battle benchmark builds them: every soldier is created
## first, then handed to the simulator, then assigned to a body. Nothing here is a special
## case for the measurement, which is what makes the row comparable with a real battle.
func _focus_scale_row(bodies: int) -> Dictionary:
	var config := GameManager.config()
	var catalog := FormationCatalog.load_from()
	var field := Vector2(float(bodies) * 12.0 + 60.0, 220.0)
	var units: Array[BattleUnit] = []
	var plan: Array = []
	var next_id := 0
	for side_value in [BattleContext.SIDE_PLAYER, BattleContext.SIDE_ENEMY]:
		var side := str(side_value)
		var left := side == BattleContext.SIDE_PLAYER
		for body_index in bodies:
			var anchor := Vector2(
				field.x * 0.25 if left else field.x * 0.75,
				20.0 + float(body_index) * (field.y - 40.0) / float(maxi(1, bodies - 1)))
			var ids: Array[int] = []
			for i in SCALE_PER_BODY:
				var unit := BattleUnit.new()
				unit.id = next_id
				next_id += 1
				unit.side = side
				unit.soldier_id = "s_focus_scale_%d" % unit.id
				unit.display_name = "Scale %d" % unit.id
				unit.max_hp = 40
				unit.hp = 40
				unit.attack = 5
				unit.defence = 2
				unit.move_speed = 5.0
				unit.attack_range = 1.8
				unit.attack_cooldown = 1.2
				unit.position = anchor + Vector2(float(i % 5) * 1.4, float(i / 5) * 1.4)
				units.append(unit)
				ids.append(unit.id)
			plan.append({"id": "%s_%d" % [side, body_index], "side": side, "anchor": anchor, "facing": 0.0 if left else PI, "ids": ids})

	var simulator := BattleSimulator.new(config, DEFAULT_SEED)
	simulator.target_backend = _target_backend
	simulator.field_size = field
	simulator.grid.configure(field, simulator.cell_size)
	simulator.overlap_grid.configure(field, simulator.overlap_cell_size)
	simulator.add_units(units)
	for entry in plan:
		var body := BattleFormation.create(str(entry["id"]), str(entry["side"]),
			Vector2(entry["anchor"]), float(entry["facing"]), "line", catalog, config)
		simulator.add_formation(body)
		simulator.assign_formation(body, entry["ids"])
	simulator.start()

	# Warm up, so the buffers that are going to be built are built before anything is timed,
	# and switch the counters on for the measured passes only.
	simulator.call("_refresh_focus")
	simulator.profile_enabled = true
	simulator.reset_profile()

	# The reference is O(bodies x army) by construction, which is the whole point of the
	# family: at a thousand bodies a side it is eighty million soldier-visits a pass, and
	# measuring it would take longer than measuring everything else put together. It is
	# measured where it is affordable and reported as not measured where it is not - the
	# layer's own figures carry on. Two hundred a side is the last size worth paying for
	# (about 1.1 seconds a pass), and it is the row that says what "not affordable" means.
	var measure_reference := bodies <= 200
	var passes := SCALE_TICKS if bodies <= 200 else 4
	var summary_ms := 0.0
	var select_ms := 0.0
	var reference_ms := 0.0
	var comparisons := 0
	var disagreements := 0
	for pass_index in passes:
		var start := Time.get_ticks_usec()
		simulator.call("_refresh_summaries")
		summary_ms += float(Time.get_ticks_usec() - start) / 1000.0

		start = Time.get_ticks_usec()
		simulator.call("_refresh_focus")
		select_ms += float(Time.get_ticks_usec() - start) / 1000.0

		if measure_reference:
			start = Time.get_ticks_usec()
			for body in simulator.formations:
				simulator.call("_nearest_enemy_to_point", body.side, body.anchor)
			reference_ms += float(Time.get_ticks_usec() - start) / 1000.0
			for body in simulator.formations:
				var mine: BattleUnit = simulator.call("_focus_unit_of", body)
				var expected: BattleUnit = simulator.call("_nearest_enemy_to_point", body.side, body.anchor)
				comparisons += 1
				if mine != expected:
					disagreements += 1
	var ticks := float(passes)
	var layer := select_ms / ticks
	var reference := reference_ms / ticks
	var selections := float(maxi(1, simulator.formations.size())) * ticks
	var report: Dictionary = simulator.focus_report()
	return {
		"bodies": bodies * 2,
		"soldiers": units.size(),
		"summary_ms": summary_ms / ticks,
		"select_ms": layer - (summary_ms / ticks),
		"layer_ms": layer,
		"reference_ms": reference,
		"speedup": reference / maxf(0.0001, layer),
		"opened_per_selection": float(report.get("buckets_opened", 0)) / selections,
		"measured_per_selection": float(report.get("buckets_measured", 0)) / selections,
		"members_per_selection": float(report.get("members_walked", 0)) / selections,
		"agree": disagreements == 0 if measure_reference else true,
		"measured": measure_reference,
		"comparisons": comparisons,
	}

## The worst case a staggered schedule has to survive: a great many soldiers losing the
## opponent they were fighting, all on the same tick.
##
## The shape is deliberate. Two lines of three ranks are dressed and already in contact,
## and the armies are held exactly where they are - speed zero - so that the only thing
## that changes between the measured ticks is the storm. The average tick is measured over
## a window of ordinary fighting first, with the same clock, so the storm tick is compared
## against the battle it interrupted rather than against a guess.
##
## The question is not whether the storm tick costs more. It must: work that did not
## happen before now happens at once. The question is whether it is a step or a cliff, and
## whether the tick after it goes back to the schedule.
const STORM_FILES := 200
const STORM_SETTLE_TICKS := 40
const STORM_WINDOW_TICKS := 30
const STORM_SIZES := [600, 1200, 2400]

func _print_storm(_options: Dictionary) -> void:
	print("")
	print("=== THE DEATH STORM: an entire front rank lost on one tick ===")
	print("  %d files of three ranks a side, dressed and in contact, held still so that the" % STORM_FILES)
	print("  storm is the only thing that changes. Everything below is the phase clock's own")
	print("  per-tick total, so the storm tick is measured with the same instrument as the")
	print("  %d ticks of ordinary fighting it interrupts." % STORM_WINDOW_TICKS)
	print("")
	print("%8s | %11s | %11s | %9s | %7s | %8s | %10s | %10s | %10s | %s" % [
		"soldiers", "front rank", "avg tick", "storm", "spike", "next tick", "looks/tick",
		"storm looks", "immediate", "waiting"])
	print("-".repeat(122))
	for count in STORM_SIZES:
		var row := _storm_measure(count)
		if row.is_empty():
			continue
		print("%8d | %11d | %8.3f ms | %6.3f ms | %8.2fx | %7.3f ms | %10.1f | %10d | %10d | %10.1f" % [
			int(row["soldiers"]), int(row["front"]), float(row["avg_ms"]), float(row["storm_ms"]),
			float(row["storm_ms"]) / maxf(0.0001, float(row["avg_ms"])), float(row["next_ms"]),
			float(row["window_searches"]) / float(STORM_WINDOW_TICKS), int(row["storm_searches"]),
			int(row["immediate"]), float(row["waiting"])])
	print("-".repeat(122))
	print("  'immediate' is how many soldiers lost an opponent they could have struck and had")
	print("  another one in the same tick; 'waiting' is how many lost one that was never in")
	print("  reach and were left to their own turn. 'looks/tick' is the same battle's ordinary")
	print("  rate, and the storm column is what one tick of it cost when a line died at once.")


## One run of the storm, reduced to the numbers the table prints.
func _storm_measure(count: int) -> Dictionary:
	var config := GameManager.config()
	var ranks := 3
	var files := maxi(1, count / 2 / ranks)
	var width := float(files) * 1.4 + 20.0
	var field := Vector2(width, 30.0 + float(files) * 1.4)
	var simulator := BattleSimulator.new(config, DEFAULT_SEED)
	simulator.target_backend = _target_backend
	simulator.field_size = field
	simulator.grid.configure(field, simulator.cell_size)
	simulator.overlap_grid.configure(field, simulator.overlap_cell_size)
	if _overlap_backend >= 0:
		simulator.overlap_backend = _overlap_backend
	_apply_target_overrides(simulator)

	var units: Array[BattleUnit] = []
	var front: Array[BattleUnit] = []
	var next_id := 0
	for rank_index in ranks:
		for file in files:
			var y := 10.0 + float(file) * 1.4
			var front_x := 10.0 + float(files) * 1.4 * 0.5
			var player := _storm_unit(next_id, BattleContext.SIDE_PLAYER,
				Vector2(front_x - float(ranks - 1 - rank_index) * 1.4 - 1.7, y))
			next_id += 1
			units.append(player)
			var enemy := _storm_unit(next_id, BattleContext.SIDE_ENEMY,
				Vector2(front_x + float(rank_index) * 1.4, y))
			next_id += 1
			units.append(enemy)
			if rank_index == 0:
				front.append(enemy)
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()
	simulator.reset_profile()
	simulator.profile_enabled = true

	for i in STORM_SETTLE_TICKS:
		simulator.step(TICK)

	# A window of ordinary fighting, tick by tick, through the same clock everything else
	# uses. The phase clock is cumulative, so a tick's cost is the difference.
	var window_ms := 0.0
	var window_searches := 0
	for i in STORM_WINDOW_TICKS:
		var mark := float(simulator.profile.get("total", 0.0))
		var searches_before := simulator.tgt_searches
		simulator.step(TICK)
		window_ms += float(simulator.profile.get("total", 0.0)) - mark
		window_searches += simulator.tgt_searches - searches_before
	var avg_ms := window_ms / float(STORM_WINDOW_TICKS)

	# The storm: every soldier in the enemy front rank dies on the same tick.
	var mark := float(simulator.profile.get("total", 0.0))
	var searches_before := simulator.tgt_searches
	var immediates_before := simulator.tgt_immediate_reacquires
	var scheduled_before := simulator.tgt_scheduled_reacquires
	for victim in front:
		victim.hp = 0
		victim.alive = false
	simulator.step(TICK)
	var storm_ms := float(simulator.profile.get("total", 0.0)) - mark
	var storm_searches := simulator.tgt_searches - searches_before
	var immediate := simulator.tgt_immediate_reacquires - immediates_before
	var waiting := simulator.tgt_scheduled_reacquires - scheduled_before

	# And the tick after it, which is the one that says whether the schedule reasserted
	# itself or whether the storm broke it.
	mark = float(simulator.profile.get("total", 0.0))
	simulator.step(TICK)
	var next_ms := float(simulator.profile.get("total", 0.0)) - mark

	return {
		"soldiers": units.size(),
		"front": front.size(),
		"avg_ms": avg_ms,
		"storm_ms": storm_ms,
		"next_ms": next_ms,
		"window_searches": window_searches,
		"storm_searches": storm_searches,
		"immediate": immediate,
		"waiting": float(waiting),
	}


## A soldier for the storm fixture: a real reach, real hit points, and no movement at all,
## so that the two lines stay exactly where they were put.
func _storm_unit(id: int, side: String, position: Vector2) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_storm_%d" % id
	unit.display_name = "Storm %d" % id
	unit.max_hp = 40
	unit.hp = 40
	unit.attack = 5
	unit.defence = 2
	unit.move_speed = 0.0
	unit.attack_range = 1.8
	unit.attack_cooldown = 1.2
	unit.position = position
	return unit


func _ms(value: float) -> String:
	return "%.3f ms" % value



## ---------- Step 7.8: the separation pass, one battle per implementation ----------

## The same battles, run once per separation pass, so the comparison is between
## implementations rather than between runs.
##
## Matched tick windows, no budget: a cheaper pass fits more ticks into the same wall-clock
## budget and would then be compared at a later, heavier moment of the same fight - which is
## a way of measuring the battle and calling it the pass. `--ticks=` is the whole
## configuration, and both families are swept with it.
##
## The reference is the baseline of the table rather than a column in it: every row's speedup
## is against the same battle run with BattleOverlapGrid, which is the pass that has shipped
## since Step 7.3. "total" is the whole tick as the harness clocks it, which is what a player
## would feel; "overlap" is the pass's own phase.
func _print_overlap_sweep(options: Dictionary) -> void:
	var ticks: int = options["ticks"]
	var seed_value: int = options["seed"]
	var budget: float = minf(MAX_BUDGET, float(options["budget"]))
	var gap: float = options["gap"]
	var group: int = options["group"]
	var passes: Array[int] = [BattleSimulator.OverlapBackend.GDSCRIPT, BattleSimulator.OverlapBackend.PACKED]
	if BattleOverlapNative.available():
		passes.append(BattleSimulator.OverlapBackend.NATIVE)

	print("")
	print("=== STEP 7.8: THE SEPARATION PASS, ONE BATTLE PER IMPLEMENTATION ===")
	print("  matched tick windows (%d ticks), no budget shortening either run, seed %d" % [ticks, seed_value])
	print("")

	for family in ["A", "B"]:
		var counts: Array = options["units"] if family == "A" else options["battle_units"]
		print("--- FAMILY %s (%s) ---" % [family,
			"fixed 100x60 torture field" if family == "A" else "field scaled with the army"])
		print("%7s | %10s | %11s | %11s | %9s | %8s | %9s | %7s | %7s | %7s | %s" % [
			"units", "pass", "overlap ms", "total ms", "speedup", "cell prs", "pairs", "touch",
			"pop max", "contact", "note"])
		print("-".repeat(130))
		for count_value in counts:
			var count := int(count_value)
			var baseline_overlap := 0.0
			var baseline_total := 0.0
			for pass_id in passes:
				_overlap_backend = pass_id
				# The counters beside the timings are accumulated over every tick of the run
				# rather than read off the last one: a battle's last tick is one moment of
				# one battle, and "2.2 pairs measured per touching pair at 20,000 soldiers"
				# was a claim about a whole fight being read off a single sample of it.
				_overlap_diag = true
				var run := _run_sweep_battle(family, count, ticks, seed_value, budget, gap, group)
				var done := maxf(1.0, float(run["ticks"]))
				var phases: Dictionary = run.get("profile", {})
				var overlap := float(phases.get("overlap", 0.0)) / done
				var total := float(run["per_tick_ms"])
				var overlap_report: Dictionary = _diag
				_overlap_diag = false
				var speedup := 0.0
				var note := "%d ticks" % int(run["ticks"])
				if pass_id == BattleSimulator.OverlapBackend.GDSCRIPT:
					baseline_overlap = overlap
					baseline_total = total
					note = "reference, %d ticks" % int(run["ticks"])
				else:
					if overlap > 0.0:
						speedup = baseline_overlap / overlap
					note = "vs reference, %d ticks" % int(run["ticks"])
					if total > 0.0 and baseline_total > 0.0:
						note += ", total x%.2f" % (baseline_total / total)
				var boundary: Dictionary = run.get("overlap_backend_report", {})
				if pass_id == BattleSimulator.OverlapBackend.NATIVE and not boundary.is_empty():
					note += ", sync %d us + native %d us + apply %d us" % [
						int(boundary.get("sync_us", 0)) / maxi(1, int(run["ticks"])),
						int(boundary.get("native_us", 0)) / maxi(1, int(run["ticks"])),
						int(boundary.get("apply_us", 0)) / maxi(1, int(run["ticks"]))]
					if int(boundary.get("mismatches", 0)) > 0:
						note += ", MISMATCHES %d" % int(boundary["mismatches"])
				# Family A reports "contact" and family B reports the tick contact was first
				# made; both mean the same thing here, and a row that never reached contact is
				# an approach measurement and says so.
				var engaged := bool(run.get("contact", int(run.get("first_contact", -1)) >= 0))
				print("%7d | %10s | %10.3f ms | %8.3f ms | %8s | %8.0f | %9.1f | %7.1f | %7d | %7s | %s" % [
					count, BattleSimulator.overlap_backend_label(pass_id), overlap, total,
					"%.2fx" % speedup if speedup > 0.0 else "-",
					float(overlap_report.get("cell_pairs", 0)) / done,
					float(overlap_report.get("pairs", 0)) / done,
					float(overlap_report.get("touching", 0)) / done,
					int(overlap_report.get("cell_population_max", 0)),
					"yes" if engaged else "no",
					note])
			print("-".repeat(130))
		print("  'overlap ms' is the phase clock; 'total ms' is the whole tick; 'pop max' is the")
		print("  busiest single cell the pass walked. 'speedup' compares" )
		print("  passes on the same battle, and the tick counts above are the same for every row")
		print("  of a size, because nothing here runs on a budget.")
		print("")
	_overlap_backend = -1


## One battle for the sweep, in the family the caller asked for.
func _run_sweep_battle(family: String, count: int, ticks: int, seed_value: int, budget: float,
		gap: float, group: int) -> Dictionary:
	# A sweep is a set of matched windows, so the budget is deliberately generous rather than
	# tuned: it exists to stop a pathological run, not to decide how long a row lasts. Each
	# row prints the tick count it actually completed, so a shortened row is visible rather
	# than silent.
	var effective := maxf(120.0, budget * 20.0)
	if family == "A":
		return _run_battle(count, ticks, seed_value, true, true, effective, true)
	return _run_battle_scaled(count, ticks, seed_value, effective, gap, group, true)

## ---------- Step 7.8: the separation pass, explained -----------------------

## One tick of the separation pass's own counters, accumulated over a whole battle.
##
## The Step 7.8 pass read these counters off the *last* tick and concluded the settled-cell
## skip never fires. The last tick of a battle is a field full of fighting soldiers, which is
## the one state in which nobody can be settled, so that conclusion was about the sample
## rather than about the mechanism. Accumulating the same counters over every tick, plus a
## series of samples through the battle, is what turns it into an answer: how often the skip
## fires, when it fires, and - when it does not - which of the five tests rejected the pair.
func _empty_diag(sample_every: int) -> Dictionary:
	return {
		"ticks": 0,
		"sample_every": maxi(1, sample_every),
		"cell_pairs": 0, "skipped": 0, "pairs": 0, "touching": 0,
		"settled": 0, "living": 0, "interior": 0, "mixed": 0,
		"coincident": 0, "clamped": 0,
		"skip_not_settled_a": 0, "skip_not_settled_b": 0, "skip_no_body": 0,
		"skip_other_body": 0, "skip_spacing": 0, "skip_proved": 0,
		"settled_max": 0, "skipped_max": 0, "ticks_with_skip": 0, "cell_population_max": 0,
		"series": [],
		"bodies": {},
	}


func _accumulate_diag(simulator: BattleSimulator) -> void:
	var report := simulator.overlap_report()
	if report.is_empty():
		return
	_diag["ticks"] = int(_diag["ticks"]) + 1
	_diag["cell_pairs"] = int(_diag["cell_pairs"]) + int(report.get("cell_pairs", 0))
	_diag["skipped"] = int(_diag["skipped"]) + int(report.get("cell_pairs_skipped", 0))
	_diag["pairs"] = int(_diag["pairs"]) + int(report.get("pairs", 0))
	_diag["touching"] = int(_diag["touching"]) + int(report.get("touching", 0))
	_diag["settled"] = int(_diag["settled"]) + int(report.get("settled_units", 0))
	_diag["living"] = int(_diag["living"]) + int(report.get("indexed_units", 0))
	_diag["interior"] = int(_diag["interior"]) + int(report.get("interior_cells", 0))
	_diag["mixed"] = int(_diag["mixed"]) + int(report.get("mixed_cells", 0))
	_diag["coincident"] = int(_diag["coincident"]) + int(report.get("coincident", 0))
	_diag["clamped"] = int(_diag["clamped"]) + int(report.get("clamped", 0))
	for key in ["skip_not_settled_a", "skip_not_settled_b", "skip_no_body",
			"skip_other_body", "skip_spacing", "skip_proved"]:
		_diag[key] = int(_diag[key]) + int(report.get(key, 0))
	var settled := int(report.get("settled_units", 0))
	var skipped := int(report.get("cell_pairs_skipped", 0))
	_diag["settled_max"] = maxi(int(_diag["settled_max"]), settled)
	_diag["cell_population_max"] = maxi(int(_diag.get("cell_population_max", 0)),
		int(report.get("cell_population_max", 0)))
	_diag["skipped_max"] = maxi(int(_diag["skipped_max"]), skipped)
	if skipped > 0:
		_diag["ticks_with_skip"] = int(_diag["ticks_with_skip"]) + 1

	var sample_every := int(_diag["sample_every"])
	if int(_diag["ticks"]) == 1 or int(_diag["ticks"]) % sample_every == 0:
		var series: Array = _diag["series"]
		series.append({
			"tick": simulator.tick_index,
			"living": int(report.get("indexed_units", 0)),
			"settled": settled,
			"cell_pairs": int(report.get("cell_pairs", 0)),
			"skipped": skipped,
			"pairs": int(report.get("pairs", 0)),
			"touching": int(report.get("touching", 0)),
			"not_settled": int(report.get("skip_not_settled_a", 0)) + int(report.get("skip_not_settled_b", 0)),
			"spacing": int(report.get("skip_spacing", 0)),
			"proved": int(report.get("skip_proved", 0)),
		})
		_diag["series"] = series

	for raw in report.get("bodies", []) as Array:
		var body := raw as Dictionary
		var index := int(body.get("index", 0))
		var bodies: Dictionary = _diag["bodies"]
		var accumulated: Dictionary = bodies.get(index, {
			"index": index, "living": 0, "settled": 0,
			"distance_average": 0.0, "distance_p50": 0.0, "distance_p95": 0.0,
		})
		accumulated["living"] = int(accumulated["living"]) + int(body.get("living", 0))
		accumulated["settled"] = int(accumulated["settled"]) + int(body.get("settled", 0))
		accumulated["distance_average"] = float(body.get("distance_average", 0.0))
		accumulated["distance_p50"] = float(body.get("distance_p50", 0.0))
		accumulated["distance_p95"] = float(body.get("distance_p95", 0.0))
		bodies[index] = accumulated
		_diag["bodies"] = bodies


## The overlap phase's own cost, split by measurement rather than by apportioning.
##
## Three passes over one frozen field: the real pass, the same pass with the push arithmetic
## left out, and the same pass with the distance test left out as well. A dry pass never moves
## anybody, so all three read identical positions - which is the only thing that makes
## subtracting one from another mean anything. The units are proxies: same positions, sides,
## bodies and slot indices, so the pass cannot tell the difference and the real battle is not
## touched by being measured. Development-only, sampled a handful of times per run.
func _overlap_split_probe(simulator: BattleSimulator, tick: int) -> Dictionary:
	var proxies: Array[BattleUnit] = []
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		var proxy := BattleUnit.new()
		proxy.id = unit.id
		proxy.side = unit.side
		proxy.hp = 1
		proxy.max_hp = 1
		proxy.position = unit.position
		proxy.formation_ref = unit.formation_ref
		proxy.slot_index = unit.slot_index
		proxies.append(proxy)

	var minimum := simulator.separation_radius * BattleSimulator.SEPARATION_FACTOR
	var settle := simulator.separation_settle_epsilon
	var grid := BattleOverlapGrid.new()
	grid.configure(simulator.field_size, simulator.overlap_cell_size)
	grid.max_push = simulator.max_separation_push
	grid.stats_enabled = true
	# One throwaway pass so the first measurement does not pay for the arrays being grown to
	# the size of the army. It moves nothing.
	grid.dry_level = 2
	grid.resolve(proxies, minimum, settle)

	var samples := {}
	for level in [0, 1, 2]:
		grid.dry_level = level
		grid.resolve(proxies, minimum, settle)
		var report := grid.report()
		var name := "full" if level == 0 else ("distance_only" if level == 1 else "enumerate_only")
		samples[name] = {
			"total_us": int(report.get("usec_total", 0)),
			"build_us": int(report.get("usec_build", 0)),
			"same_cell_us": int(report.get("usec_same_cell", 0)),
			"neighbour_us": int(report.get("usec_neighbour", 0)),
			"apply_us": int(report.get("usec_apply", 0)),
			"pairs": int(report.get("pairs", 0)),
			"touching": int(report.get("touching", 0)),
		}
	return {"tick": tick, "living": proxies.size(), "samples": samples}


func _print_overlap_diagnosis(diags: Array[Dictionary]) -> void:
	if diags.is_empty():
		return
	print("")
	print("=== WHY THE SETTLED-CELL SKIP DOES OR DOES NOT FIRE (Step 7.8) ===")
	print("  Every tick of the battle, not the last one. 'settled/tick' is how many soldiers")
	print("  stood on the place their body gave them, averaged over the run; 'skip %' is the")
	print("  share of neighbour-cell pairs the proof let the pass skip.")
	print("")
	print("%7s | %10s | %9s | %12s | %10s | %9s | %9s | %8s | %s" % [
		"units", "pass", "ticks", "settled/tick", "settled %", "cell prs", "skipped", "skip %", "ticks with a skip"])
	print("-".repeat(110))
	for diag in diags:
		var ticks := maxf(1.0, float(diag["ticks"]))
		var living := maxf(1.0, float(diag["living"]))
		var cell_pairs := maxf(1.0, float(diag["cell_pairs"]))
		print("%7d | %10s | %9.0f | %12.2f | %9.2f%% | %9.1f | %9.1f | %7.2f%% | %.1f" % [
			int(diag["units"]), str(diag.get("pass", "?")), ticks,
			float(diag["settled"]) / ticks, 100.0 * float(diag["settled"]) / living,
			float(diag["cell_pairs"]) / ticks, float(diag["skipped"]) / ticks,
			100.0 * float(diag["skipped"]) / cell_pairs, float(diag["ticks_with_skip"])])
	print("-".repeat(110))
	print("  The proof's own tests, as a share of the cell pairs that reached it. The first test")
	print("  that fails is the one counted, so these add up to the cell pairs considered, and")
	print("  'proved' is the only one of the six that ends in a skip.")
	print("")
	print("%7s | %10s | %11s | %11s | %9s | %11s | %9s | %s" % [
		"units", "pass", "not settled", "settle off", "no body", "other body", "spacing", "proved"])
	print("-".repeat(104))
	for diag in diags:
		var reached := maxf(1.0, float(int(diag["skip_not_settled_a"]) + int(diag["skip_not_settled_b"])
			+ int(diag["skip_no_body"]) + int(diag["skip_other_body"])
			+ int(diag["skip_spacing"]) + int(diag["skip_proved"])))
		print("%7d | %10s | %10.1f%% | %10.1f%% | %8.1f%% | %10.1f%% | %8.1f%% | %.1f%%" % [
			int(diag["units"]), str(diag.get("pass", "?")),
			100.0 * float(diag["skip_not_settled_a"]) / reached,
			100.0 * float(diag["skip_not_settled_b"]) / reached,
			100.0 * float(diag["skip_no_body"]) / reached,
			100.0 * float(diag["skip_other_body"]) / reached,
			100.0 * float(diag["skip_spacing"]) / reached,
			100.0 * float(diag["skip_proved"]) / reached])
	print("-".repeat(104))
	print("  'not settled' means one of the two cells held a soldier who was not standing within")
	print("  the settle epsilon of his place. 'settle off' means the same but for the other cell.")
	print("  'spacing' means both cells were settled and of one body, but that body's own slot")
	print("  spacing is not wide enough to prove the pair apart.")
	print("")
	for diag in diags:
		print("  %d units: through the battle (one sample every %dth tick):" % [
			int(diag["units"]), int(diag["sample_every"])])
		print("  %8s | %8s | %9s | %8s | %11s | %8s | %8s | %9s | %s" % [
			"tick", "living", "settled", "cell prs", "not settled", "spacing", "skipped", "proved", "pairs"])
		print("  " + "-".repeat(92))
		for raw in diag["series"] as Array:
			var row := raw as Dictionary
			print("  %8d | %8d | %9d | %8d | %11d | %8d | %8d | %9d | %d" % [
				int(row["tick"]), int(row["living"]), int(row["settled"]), int(row["cell_pairs"]),
				int(row["not_settled"]), int(row["spacing"]), int(row["skipped"]), int(row["proved"]),
				int(row["pairs"])])
		print("")
	print("  Per body, over the whole run: how often its soldiers were standing where it put")
	print("  them, and how far off they were at the last tick (half-unit buckets).")
	print("  %6s | %11s | %10s | %s" % [
		"body", "living/tick", "settled %", "distance avg / p50 / p95 at the last tick"])
	print("  " + "-".repeat(86))
	for diag in diags:
		var bodies: Dictionary = diag["bodies"]
		var keys: Array = bodies.keys()
		keys.sort()
		var ticks := maxf(1.0, float(diag["ticks"]))
		for index in keys:
			var body: Dictionary = bodies[index]
			var body_living := maxf(1.0, float(body["living"]))
			print("  %6d | %11.1f | %9.1f%% | %.2f / %.2f / %.2f" % [
				int(index), float(body["living"]) / ticks,
				100.0 * float(body["settled"]) / body_living,
				float(body["distance_average"]), float(body["distance_p50"]), float(body["distance_p95"])])


func _print_overlap_split(splits: Array[Dictionary]) -> void:
	if splits.is_empty():
		return
	print("")
	print("=== THE SEPARATION PASS: what its own time is spent on (Step 7.8) ===")
	print("  Three passes over one frozen field per sample: the real pass, the same pass with the")
	print("  push arithmetic removed, and the same with the distance test removed as well. A dry")
	print("  pass never moves anybody, so the three read identical positions and the differences")
	print("  between them are the removed work, measured rather than apportioned.")
	print("")
	print("%7s | %9s | %11s | %11s | %11s | %11s | %10s | %s" % [
		"units", "tick", "build us", "same-cell us", "neighbour us", "apply us", "total us", "pairs/touching"])
	print("-".repeat(112))
	for row in splits:
		var samples: Dictionary = row["samples"]
		var full: Dictionary = samples["full"]
		print("%7d | %9d | %11.0f | %11.0f | %11.0f | %11.0f | %10.0f | %d / %d" % [
			int(row["living"]), int(row["tick"]),
			float(full["build_us"]), float(full["same_cell_us"]), float(full["neighbour_us"]),
			float(full["apply_us"]), float(full["total_us"]),
			int(full["pairs"]), int(full["touching"])])
	print("-".repeat(112))
	print("%7s | %10s | %10s | %10s | %10s | %10s | %s" % [
		"units", "full us", "no push us", "no push/d", "apply", "pair math", "push math"])
	print("-".repeat(112))
	for row in splits:
		var samples: Dictionary = row["samples"]
		var full: Dictionary = samples["full"]
		var no_push: Dictionary = samples["distance_only"]
		var bare: Dictionary = samples["enumerate_only"]
		var pair_math := float(no_push["total_us"]) - float(bare["total_us"])
		var push_math := float(full["total_us"]) - float(no_push["total_us"]) - float(full["apply_us"])
		print("%7d | %10.0f | %10.0f | %10.0f | %10.0f | %10.0f | %.0f" % [
			int(row["living"]), float(full["total_us"]), float(no_push["total_us"]),
			float(bare["total_us"]), float(full["apply_us"]), pair_math, push_math])
	print("-".repeat(112))
	print("  One sample per sixth of the run. 'pair math' is the squared-distance test for every")
	print("  enumerated pair; 'push math' is the square root, the scale and the accumulated")
	print("  writes for the pairs that turned out to be touching. Both are differences of clocks")
	print("  read on the same field, and a difference of clocks carries the noise of both.")


