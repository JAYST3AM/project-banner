extends Node
## The terrain system's own benchmark: generation, memory and every query a battle makes, at four
## battlefield sizes.
##
## The showcase answers "does a three-hundred-a-side battle still run at speed on the new ground" by
## fighting one. This answers the other half of the question - what the ground itself costs, and how
## that cost grows - because a benchmark that only ever reports one size cannot tell a system that
## scales from one that happens to be fast today.
##
## Everything here is measured, nothing is estimated. Timings are the best of three runs of each
## measurement, because the first pass through a million array reads is not the same thing as the
## second, and the honest number for a hot path is the one it settles at rather than the one it starts
## at. The query costs are reported per call in nanoseconds, which is the unit a per-soldier path has
## to be argued in: at sixty ticks a second, a thousand soldiers each paying a hundred nanoseconds is
## six milliseconds a second.
##
## Usage:
## [codeblock]
## godotc --headless --path "<project>" res://scenes/dev/terrain_bench.tscn
## godotc --headless --path "<project>" res://scenes/dev/terrain_bench.tscn -- --biome=swamp --quick
## [/codeblock]
## Switches: [code]--biome=[/code], [code]--seed=[/code], [code]--quick[/code] (two sizes instead of
## four), [code]--out=PATH[/code] (write the report to a file as well as printing it).

const SEED := 70701
## Field sizes in world units, with the cell count each works out to at the production cell size.
## The first is a skirmish, the second is a battle, the third is the showcase's own ground, and the
## fourth is a field nobody has fought on yet - it is here to show the shape of the curve.
const SIZES := [
	Vector2(100.0, 60.0),
	Vector2(200.0, 120.0),
	Vector2(500.0, 300.0),
	Vector2(1000.0, 600.0),
]

const HEIGHT_CALLS := 1000000
const MOVE_CALLS := 1000000
const TRAVERSABLE_CALLS := 1000000
const OBSTACLE_CALLS := 1000000
const COVER_CALLS := 500000
const ELEVATION_CALLS := 200000
const BATCH_POINTS := 1000
const BATCH_CALLS := 500
const SIGHT_LINES := 20000
const SUMMARY_CALLS := 20000
const SAMPLES := 2000

var _biome := "plains"
var _quick := false
var _out_path := ""
var _report: PackedStringArray = []


func _ready() -> void:
	_parse_args()
	var config := GameManager.config()
	if not config.is_valid():
		push_error("terrain bench: the game config did not load")
		quit(1)
		return
	_line("terrain benchmark - biome %s, seed %d, generation version %d" % [
		_biome, SEED, config.get_int("terrain.generation_version", 1)])
	_line("Godot %s, %s %s" % [Engine.get_version_info()["string"],
		OS.get_name(), Engine.get_architecture_name()])
	_line("")
	_line("generation (best of 3)")
	_line("%-14s %9s %9s %9s %9s %10s %10s" % [
		"field", "cells", "generate", "props", "visual maps", "memory MB", "per cell"])
	_line("-".repeat(76))
	var sizes: Array = SIZES if not _quick else [SIZES[0], SIZES[2]]
	var fields: Array = []
	for size in sizes:
		fields.append(_measure_field(size, config))

	_line("")
	_line("queries (nanoseconds per call, best of 3, on the %s field)" % _describe(sizes[-1]))
	_line("%-24s %12s %12s" % ["query", "ns/call", "calls/s"])
	_line("-".repeat(50))
	var largest: BattlefieldTerrain = fields[-1]
	var points := _sample_points(largest, SAMPLES)
	_measure_query(largest, points, "height_at", HEIGHT_CALLS, func(point: Vector2) -> float:
		return largest.height_at(point))
	_measure_query(largest, points, "slope_at", HEIGHT_CALLS, func(point: Vector2) -> float:
		return largest.slope_at(point))
	_measure_query(largest, points, "move_multiplier_at", MOVE_CALLS, func(point: Vector2) -> float:
		return largest.move_multiplier_at(point))
	_measure_query(largest, points, "movement_cost_at", MOVE_CALLS, func(point: Vector2) -> float:
		return largest.movement_cost_at(point))
	_measure_query(largest, points, "is_traversable", TRAVERSABLE_CALLS, func(point: Vector2) -> float:
		return 1.0 if largest.is_traversable(point) else 0.0)
	_measure_query(largest, points, "obstacle_bits_at", OBSTACLE_CALLS, func(point: Vector2) -> float:
		return float(largest.obstacle_bits_at(point)))
	_measure_query(largest, points, "cover_at", COVER_CALLS, func(point: Vector2) -> float:
		return largest.cover_at(point))
	_measure_query(largest, points, "elevation_advantage_at", ELEVATION_CALLS, func(point: Vector2) -> float:
		return largest.elevation_advantage_at(point))
	_measure_batch(largest, points)
	_measure_sight_lines(largest, points)
	_measure_summaries(largest)

	_line("")
	_line("field detail (largest)")
	for entry in largest.channel_census():
		var record := entry as Dictionary
		_line("  %-18s %10d values" % [str(record["name"]), int(record["values"])])
	_line("  %-18s %10d props on %d field%s" % ["props", largest.props.count(),
		largest.biome_id, "" if largest.props == null else ""])
	_line("  %-18s %10.1f MB" % ["channels", float(largest.memory_bytes()) / 1048576.0])

	if _out_path != "":
		var file := FileAccess.open(_out_path, FileAccess.WRITE)
		if file != null:
			file.store_string("\n".join(_report) + "\n")
			file.close()
			print("terrain bench report written: %s" % _out_path)
	quit(0)


## ---------- measurement --------------------------------------------------

func _measure_field(size: Vector2, config: GameConfig) -> BattlefieldTerrain:
	var best_generate := INF
	var best_props := INF
	var best_maps := INF
	var field: BattlefieldTerrain = null
	for run in 3:
		var start := Time.get_ticks_usec()
		field = BattlefieldTerrain.generate(SEED, size, config, null, null, _biome)
		best_generate = minf(best_generate, float(Time.get_ticks_usec() - start) / 1000.0)
		start = Time.get_ticks_usec()
		field.build_props(config, null)
		best_props = minf(best_props, float(Time.get_ticks_usec() - start) / 1000.0)
		var ppu := field.visual_pixels_per_unit(config)
		start = Time.get_ticks_usec()
		field.build_ground_map(ppu)
		field.build_overlay_map(ppu)
		field.build_type_map(ppu)
		best_maps = minf(best_maps, float(Time.get_ticks_usec() - start) / 1000.0)
	var cells := field.cell_count()
	_line("%-14s %9d %8.2fms %8.2fms %8.2fms %9.2f %9.3fms" % [
		"%dx%d" % [int(size.x), int(size.y)], cells, best_generate, best_props, best_maps,
		float(field.memory_bytes()) / 1048576.0, best_generate / maxf(1.0, float(cells))])
	return field


## The cost of one query, at a call count high enough that a single call is a large number of
## nanoseconds rather than a rounding error. Returns the best of three.
func _measure_query(field: BattlefieldTerrain, points: PackedVector2Array, label: String,
		calls: int, query: Callable) -> void:
	var check := 0.0
	var best := INF
	for run in 3:
		var start := Time.get_ticks_usec()
		var index := 0
		for i in calls:
			check += float(query.call(points[index]))
			index += 1
			if index >= points.size():
				index = 0
		var usec := float(Time.get_ticks_usec() - start)
		best = minf(best, usec * 1000.0 / float(calls))
	# The accumulation is kept and printed so no compiler is free to notice that nothing depends on
	# the answer: a query measured and thrown away is a query that may not have been run at all.
	_line("%-24s %12.1f %12.0f   (sum %.1f)" % [label, best, 1e9 / maxf(1.0, best), check])


func _measure_batch(field: BattlefieldTerrain, points: PackedVector2Array) -> void:
	var check := 0.0
	var best := INF
	for run in 3:
		var start := Time.get_ticks_usec()
		for i in BATCH_CALLS:
			var values := field.sample_batch(points, BattlefieldTerrain.Channel.MOVE)
			check += values[0]
		var usec := float(Time.get_ticks_usec() - start)
		best = minf(best, usec * 1000.0 / float(BATCH_CALLS * points.size()))
	_line("%-24s %12.1f %12.0f   (sum %.1f)" % ["sample_batch (1k points)", best, 1e9 / maxf(1.0, best), check])


func _measure_sight_lines(field: BattlefieldTerrain, points: PackedVector2Array) -> void:
	var check := 0.0
	var best := INF
	var index := 0
	for run in 3:
		var start := Time.get_ticks_usec()
		for i in SIGHT_LINES:
			var from := points[index % points.size()]
			var to := points[(index + 7) % points.size()]
			if field.blocks_line_of_sight(from, to):
				check += 1.0
			index += 3
		var usec := float(Time.get_ticks_usec() - start)
		best = minf(best, usec * 1000.0 / float(SIGHT_LINES))
	_line("%-24s %12.1f %12.0f   (blocked %d)" % ["blocks_line_of_sight", best, 1e9 / maxf(1.0, best), int(check)])


func _measure_summaries(field: BattlefieldTerrain) -> void:
	var check := 0.0
	var best := INF
	var index := 0
	for run in 3:
		var start := Time.get_ticks_usec()
		for i in SUMMARY_CALLS:
			var rect := Rect2(Vector2(float(index % 40) * 3.0, float(index % 27) * 3.0), Vector2(14.0, 8.0))
			var summary := TerrainSummary.grade(field, rect)
			check += summary.mean_movement
			index += 1
		var usec := float(Time.get_ticks_usec() - start)
		best = minf(best, usec * 1000.0 / float(SUMMARY_CALLS))
	_line("%-24s %12.1f %12.0f   (sum %.1f)" % ["TerrainSummary.grade", best, 1e9 / maxf(1.0, best), check])


## ---------- helpers ------------------------------------------------------

func _sample_points(field: BattlefieldTerrain, count: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	var random := RandomNumberGenerator.new()
	random.seed = 31337
	points.resize(count)
	for i in count:
		points[i] = Vector2(random.randf_range(0.0, field.size.x), random.randf_range(0.0, field.size.y))
	return points


func _describe(size: Vector2) -> String:
	return "%dx%d" % [int(size.x), int(size.y)]


func _line(text: String) -> void:
	print(text)
	_report.append(text)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--biome="):
			_biome = arg.substr(8)
		elif arg == "--quick":
			_quick = true
		elif arg.begins_with("--out="):
			_out_path = arg.substr(6)
