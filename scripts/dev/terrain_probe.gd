extends Node
## A probe, not a test: generate battlefields, print what came out, and get out of the way.
##
## It exists to answer questions the suite cannot answer as cheaply - what the type mix is, how long
## generation takes at four field sizes, whether every channel landed inside its own range. Delete it
## when the question stops being interesting; the suite is what keeps the answers true.
##
##   godotc --headless --path "<project>" res://scenes/dev/terrain_probe.tscn
##   godotc --headless --path "<project>" res://scenes/dev/terrain_probe.tscn -- --biome=swamp

const SEED := 70701

var _biome: String = ""
var _sizes: Array[Vector2] = []
var _printed_summary := false


func _ready() -> void:
	_parse_flags()
	var config := GameManager.config()
	if config == null:
		push_error("terrain probe: no config")
		get_tree().quit(1)
		return

	for size in _sizes:
		_run(size, config)

	print("")
	print("TERRAIN PROBE COMPLETE")
	get_tree().quit(0)


func _parse_flags() -> void:
	_biome = ""
	_sizes = [Vector2(100.0, 60.0), Vector2(316.0, 190.0)]
	for raw in OS.get_cmdline_user_args():
		var argument := str(raw)
		if argument.begins_with("--biome="):
			_biome = argument.trim_prefix("--biome=")
		elif argument.begins_with("--field="):
			var parts := argument.trim_prefix("--field=").split("x")
			if parts.size() == 2:
				_sizes = [Vector2(float(parts[0]), float(parts[1]))]


func _run(size: Vector2, config: GameConfig) -> void:
	var started := Time.get_ticks_usec()
	var field := BattlefieldTerrain.generate(SEED, size, config, null, null, _biome)
	var generation_ms := float(Time.get_ticks_usec() - started) / 1000.0
	print("")
	print("=== field %s, biome %s ===" % [str(size), field.biome_id])
	print("  %s" % field.summary())
	print("  generation: %.1f ms (%d cells, %.3f ms per hundred cells)" % [
		generation_ms, field.cell_count(), generation_ms / maxf(0.01, float(field.cell_count()) / 100.0)])
	print("  signature: %s" % field.signature())
	print("  soils: %s" % str(field.counts_by_soil()))
	print("  variants: %s" % str(field.counts_by_variant()))

	# Ranges. Every one of these should hold for every seed and every biome, and a probe is the
	# cheapest place to look at all of them at once.
	var violations := {}
	var traversable := 0
	var water := 0
	var cover_sum := 0.0
	var vegetation_sum := 0.0
	var variant_sums := 0
	for index in field.cell_count():
		var height := field.height_of_cell(index)
		if absf(height) > 500.0 or is_nan(height):
			_count(violations, "height out of range")
		var move := field.move_multiplier_of_cell(index)
		if move <= 0.0 or move > 1.0:
			_count(violations, "move out of range")
		var slope := field.slope_of_cell(index)
		if slope < 0.0 or slope > 20.0 or is_nan(slope):
			_count(violations, "slope out of range")
		var cover := field.cover_of_cell(index)
		if cover < 0.0 or cover > 1.0:
			_count(violations, "cover out of range")
		var veg := field.vegetation_of_cell(index)
		if veg < 0.0 or veg > 1.0:
			_count(violations, "vegetation out of range")
		var wet := field.wetness_of_cell(index)
		if wet < 0.0 or wet > 1.0:
			_count(violations, "wetness out of range")
		var variant_total := 0.0
		for slot in 4:
			variant_total += field.variant_weight_of_cell(index, slot)
		if absf(variant_total - 1.0) > 0.02:
			_count(violations, "variant weights do not sum to one")
		for slot in 4:
			var coverage := field.overlay_weight_of_cell(index, slot)
			if coverage < 0.0 or coverage > 1.0:
				_count(violations, "overlay out of range")
		if field.is_cell_traversable(index):
			traversable += 1
		if field.type_id_of_cell(index) == "water":
			water += 1
		cover_sum += cover
		vegetation_sum += veg
		variant_sums += field.variant_of_cell(index)

	var cells := float(field.cell_count())
	print("  traversable: %.1f%%, water: %.1f%%, mean cover %.3f, mean vegetation %.3f" % [
		100.0 * float(traversable) / cells, 100.0 * float(water) / cells,
		cover_sum / cells, vegetation_sum / cells])
	if violations.is_empty():
		print("  channel ranges: all inside their own bounds")
	else:
		print("  channel ranges: VIOLATIONS %s" % str(violations))

	# Determinism, at the only level that matters: a second field from the same seed, cell for cell.
	var again := BattlefieldTerrain.generate(SEED, size, config, null, null, _biome)
	print("  determinism: %s" % ("identical" if again.signature() == field.signature() else "DIFFERENT"))
	var other := BattlefieldTerrain.generate(SEED + 1, size, config, null, null, _biome)
	print("  a different seed differs: %s" % ("yes" if other.signature() != field.signature() else "NO"))

	# The maps, printed rather than described: one line per row, one character per cell.
	if not _printed_summary:
		_printed_summary = true
		print("")
		print("  type map (o open, r rough, w woods, h high, m mud, ~ water, ^ cliff):")
		for row in field.rows:
			var line := "    "
			for col in field.cols:
				line += _glyph(field.type_id_of_cell(row * field.cols + col))
			print(line)
		print("  traversability map ('.' passable, '#' not):")
		for row in field.rows:
			var line := "    "
			for col in field.cols:
				line += "." if field.is_cell_traversable(row * field.cols + col) else "#"
			print(line)
		print("  variant map (which of the four looks dominates each cell):")
		for row in field.rows:
			var line := "    "
			for col in field.cols:
				line += str(field.variant_of_cell(row * field.cols + col))
			print(line)


func _glyph(type_id: String) -> String:
	match type_id:
		"open":
			return "o"
		"rough":
			return "r"
		"woods":
			return "w"
		"high_ground":
			return "h"
		"mud":
			return "m"
		"water":
			return "~"
		"cliff":
			return "^"
	return "?"


func _count(counts: Dictionary, key: String) -> void:
	counts[key] = int(counts.get(key, 0)) + 1
