extends Node
## A search-shaped micro-benchmark, for Step 7.6 only.
##
## The battle benchmark answers "what does the tick cost"; this answers "what does one query
## cost", on a fixed field at a known density, so a change to the search can be measured in
## seconds rather than in a two-minute battle. Step 7.6 needed it because its first attempts at
## a cheaper search were *slower* than the ladder they replaced while doing fewer cell reads
## and fewer candidate tests - a result that says the cost is in the loop structure, which no
## amount of reasoning about cell counts was going to reveal.
##
## What remains here are the two measurements that outlived the milestone: the locked ladder,
## and the same two boxes with the best kept as the walk goes instead of a candidate list being
## built. The variants that lost - a ring walk, two row walks and a block-indexed walk - were
## removed with the implementations they measured, since D-094 records their numbers and the
## conclusion is that none of them is worth its code.
##
## Run: godotc --headless --path . res://scenes/dev/search_bench.tscn -- --units=20000 --queries=20000
##
## It is development tooling. Nothing in the game loads it.

const FIELD := Vector2(633.0, 380.0)
const CELL := 4.0
const MARGIN := 1.5

var units_target: int = 20000
var queries: int = 20000
var radius: float = 32.0
var gap: float = 0.25

## Tallies from the bench's own walk, written by [_inline_box] and read by the caller that made
## it: the grid's counters describe the shipped search, not this one.
var _last_cells: int = 0
var _last_candidates: int = 0


func _ready() -> void:
	_parse()
	var config := GameManager.config()
	var rng := RandomNumberGenerator.new()
	rng.seed = 76001
	# Two blocks of ranks facing each other down the middle of the field, packed the way a
	# body is packed - because the first version of this bench scattered its units evenly and
	# then reported the new search as 1.5x slower when in a real battle it was 5x slower. A
	# cell in a battle holds half a dozen soldiers; a cell in a uniform scatter holds one.
	var units: Array[BattleUnit] = []
	var per_side := units_target / 2
	var files := maxi(1, mini(int(FIELD.y * 0.6), int(ceil(sqrt(float(per_side) * 1.6)))))
	var ranks := maxi(1, int(ceil(float(per_side) / float(files))))
	var lateral_step := (FIELD.y * 0.8) / float(files)
	var depth_step := (FIELD.x * 0.2) / float(ranks)
	# The two fronts are separated, as they are in the real benchmark's scaled battle: a
	# quarter of the field apart at the start. Placing them adjacent instead hides the case
	# this bench exists to measure - a look that finds nobody, which is a third of looks in a
	# real battle and none at all in a permanent melee.
	var front_centre := FIELD.x * (0.5 - gap * 0.5)
	var front_enemy := FIELD.x * (0.5 + gap * 0.5)
	var next_id := 0
	for side_index in 2:
		var side := BattleContext.SIDE_PLAYER if side_index == 0 else BattleContext.SIDE_ENEMY
		var left := side_index == 0
		for i in per_side:
			var rank := i / files
			var file := i % files
			var unit := BattleUnit.new()
			unit.id = next_id
			next_id += 1
			unit.side = side
			unit.soldier_id = "s_bench_%d" % unit.id
			unit.display_name = "Bench %d" % unit.id
			unit.max_hp = 100
			unit.hp = 100
			unit.attack = 1
			unit.defence = 0
			unit.move_speed = 5.0
			unit.attack_range = 2.0
			unit.attack_cooldown = 1.0
			var x := front_centre - float(rank) * depth_step if left else front_enemy + float(rank) * depth_step
			unit.position = Vector2(x, FIELD.y * 0.1 + float(file) * lateral_step)
			units.append(unit)

	var grid := BattleSpatialGrid.new()
	grid.configure(FIELD, CELL)
	grid.rebuild(units)
	grid.query_margin = MARGIN
	grid.dev_profile = true

	# Query points are soldiers' own positions, cycled, because that is where a target look
	# happens and it is not the same question as a query from a random pixel: it is a point
	# in the middle of a crowded cell rather than a point in the middle of nowhere.
	var points := PackedVector2Array()
	points.resize(queries)
	for i in queries:
		points[i] = units[i % units.size()].position

	print("")
	print("=== SEARCH MICRO-BENCH ===")
	print("  %d units on %.0fx%.0f (%.4f a unit per square unit), cell %.1f, margin %.2f" % [
		units_target, FIELD.x, FIELD.y, float(units_target) / (FIELD.x * FIELD.y), CELL, MARGIN])
	print("  %d queries at radius %.0f, the same points for every variant" % [queries, radius])
	print("")

	_bench_box_ladder(grid, points, units)
	_bench_box_inline(grid, points, units)

	# The one thing that must not differ: the answer.
	_agree(grid, points, units, config)
	get_tree().quit(0)


func _parse() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--units="):
			units_target = maxi(100, int(arg.substr(8)))
		elif arg.begins_with("--queries="):
			queries = maxi(100, int(arg.substr(10)))
		elif arg.begins_with("--gap="):
			gap = clampf(float(arg.substr(6)), 0.0, 0.95)
		elif arg.begins_with("--radius="):
			radius = maxf(1.0, float(arg.substr(9)))


## What Step 7.5 did: a radius-8 box query, and if it found nobody, a radius-32 one, each
## materialising every enemy in the box so the caller could pick the nearest.
func _bench_box_ladder(grid: BattleSpatialGrid, points: PackedVector2Array, units: Array[BattleUnit]) -> void:
	var scratch: Array[BattleUnit] = []
	var cells := 0
	var candidates := 0
	var found := 0
	grid.dev_cells_read = 0
	grid.dev_candidates = 0
	var started := Time.get_ticks_usec()
	for point in points:
		var best := _box_nearest(grid, point, 8.0, scratch)
		if best == null:
			best = _box_nearest(grid, point, radius, scratch)
		if best != null:
			found += 1
	var spent := Time.get_ticks_usec() - started
	cells = grid.dev_cells_read
	candidates = grid.dev_candidates
	_report("ladder (8 then 32)", spent, points.size(), cells, candidates, found)


func _box_nearest(grid: BattleSpatialGrid, point: Vector2, r: float, scratch: Array[BattleUnit]) -> BattleUnit:
	# Both APIs take the side to *find* here: collect_within includes units of the side it is
	# given, and the bench's own walk is written for the same side. A bench that measured two
	# different questions would report a disagreement and mean nothing by it.
	grid.collect_within(point, r, BattleContext.SIDE_ENEMY, scratch)
	var best: BattleUnit = null
	var best_distance := INF
	var limit := r * r
	for candidate in scratch:
		var d2 := point.distance_squared_to(candidate.position)
		if d2 > limit:
			continue
		if d2 < best_distance or (d2 == best_distance and best != null and candidate.id < best.id):
			best_distance = d2
			best = candidate
	return best


## The same two boxes as the ladder, walked the same way, but keeping the best as it goes
## instead of collecting every candidate into an array first. This separates the two things
## the ladder pays for - walking the ground, and building a list of everyone standing on it -
## and it reaches into the grid's storage to do it, which is why it lives in dev tooling
## rather than in the grid.
func _bench_box_inline(grid: BattleSpatialGrid, points: PackedVector2Array, units: Array[BattleUnit]) -> void:
	var found := 0
	var cells := 0
	var candidates := 0
	var started := Time.get_ticks_usec()
	for point in points:
		var best := _inline_box(grid, point, 8.0)
		if best == null:
			best = _inline_box(grid, point, radius)
		cells += _last_cells
		candidates += _last_candidates
		if best != null:
			found += 1
	var spent := Time.get_ticks_usec() - started
	_report("box inline (no list)", spent, points.size(), cells, candidates, found)


func _inline_box(grid: BattleSpatialGrid, point: Vector2, r: float) -> BattleUnit:
	var side := BattleContext.SIDE_ENEMY
	var wanted := BattleSpatialGrid._side_bit_of(side)
	var reach := r + grid.query_margin
	var min_col := grid._clamp_col(int(floor((point.x - reach) / grid.cell_size)))
	var max_col := grid._clamp_col(int(floor((point.x + reach) / grid.cell_size)))
	var min_row := grid._clamp_row(int(floor((point.y - reach) / grid.cell_size)))
	var max_row := grid._clamp_row(int(floor((point.y + reach) / grid.cell_size)))
	var limit := r * r
	var best: BattleUnit = null
	var best_distance := INF
	var read := 0
	var measured := 0
	for row in range(min_row, max_row + 1):
		var base := row * grid.cols
		for col in range(min_col, max_col + 1):
			var cell := base + col
			if (grid._cell_mask[cell] ^ wanted) == grid._cell_mask[cell]:
				continue
			read += 1
			var slot := grid._head[cell]
			while slot >= 0:
				var unit := grid._slot_units[slot]
				if unit.alive and unit.side == side:
					measured += 1
					var d2 := point.distance_squared_to(unit.position)
					if d2 <= limit and (d2 < best_distance or (d2 == best_distance and best != null and unit.id < best.id)):
						best_distance = d2
						best = unit
				slot = grid._next[slot]
	# The bench keeps its own tallies: they belong to the bench's walk, not to the grid.
	_last_cells = read
	_last_candidates = measured
	return best


## The bench's own hand-written walk has to name the same soldier the shipped ladder names, on
## every query point: a measurement of a different question would be worse than no measurement.
func _agree(grid: BattleSpatialGrid, points: PackedVector2Array, units: Array[BattleUnit], config: GameConfig) -> void:
	var scratch: Array[BattleUnit] = []
	var checked := 0
	var mismatches := 0
	var resolved := 0
	# Sampled across the *whole* roster rather than off the front of it. The query points cycle
	# through the units in order, and the roster is built one army at a time - so taking the
	# first three thousand samples only soldiers standing in their own army's rear, where
	# nobody has an enemy within the ceiling and the check resolves nothing. It reported
	# "0 disagreements, 0 with somebody to find", which looks like evidence and is not: a
	# correctness check that cannot fail is worse than no check at all.
	var sample := mini(points.size(), 3000)
	var stride := maxi(1, points.size() / sample)
	for i in sample:
		var point := points[i * stride]
		# A soldier is not its own enemy, so the queried side is the one opposite the point's
		# owner. The traversal is positional and has no idea who is asking.
		var reference := _box_nearest(grid, point, 8.0, scratch)
		if reference == null:
			reference = _box_nearest(grid, point, radius, scratch)
		var got := _inline_box(grid, point, 8.0)
		if got == null:
			got = _inline_box(grid, point, radius)
		checked += 1
		var got_id := -1 if got == null else got.id
		var want_id := -1 if reference == null else reference.id
		if got_id != want_id:
			mismatches += 1
		if want_id >= 0:
			resolved += 1
	print("")
	print("  agreement: %d queries, %d with somebody to find, %d disagreements" % [checked, resolved, mismatches])
	if resolved == 0:
		print("  (nothing to resolve at this spacing: run it with --gap=0 to put the armies in")
		print("   contact, where the check has answers to compare.)")
	print("")


func _report(name: String, spent: int, count: int, cells: int, candidates: int, found: int) -> void:
	print("  %-22s %9.2f us/query | %8.1f cells/query | %7.1f candidates/query | found %.1f%%" % [
		name, float(spent) / float(count), float(cells) / float(count),
		float(candidates) / float(count), 100.0 * float(found) / float(count)])
