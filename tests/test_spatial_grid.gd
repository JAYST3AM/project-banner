extends TestCase
## Step 7.2: the battlefield proximity index.
##
## The rules this suite exists to pin down:
## [br]- the grid answers the same question the battlefield-wide scan answered;
## [br]- a cell boundary is not a wall, and a soldier standing one side of one is still
##   findable from the other;
## [br]- dead soldiers are not in the index and are not returned from it either, even
##   when they fall after it was built;
## [br]- nothing about the answer depends on how the buckets happen to be arranged.
##
## The strongest test here is the brute-force comparison, which reproduces the loop the
## grid replaced and checks the grid never disagrees with it about who is nearby.

const SEED := 72001
const FIELD := Vector2(100.0, 60.0)
const CELL := 4.0


func run() -> void:
	await _tick()
	_test_configuration()
	_test_empty_grid()
	_test_one_unit()
	_test_indexing_and_readback()
	_test_dead_units_are_not_indexed()
	_test_dead_units_are_not_returned()
	_test_rebuild_replaces_membership()
	_test_radius_queries()
	_test_side_filtering()
	_test_cell_boundaries_are_not_walls()
	_test_movement_between_cells()
	_test_a_unit_appears_once()
	_test_dense_cell()
	_test_large_radius_queries()
	_test_query_order_is_stable()
	_test_scratch_reuse()
	_test_brute_force_agreement()
	_test_margin_widens_the_query()
	_test_target_selection_matches_the_whole_field_scan()
	_test_target_selection_keeps_agreeing_as_soldiers_move()
	_test_the_search_escalates_to_find_a_distant_enemy()
	_test_the_search_bound_is_respected()
	_test_overlap_resolution_matches_the_pairwise_loop()
	_test_explicit_attack_orders_still_win()
	_test_a_seeded_battle_repeats_exactly()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _make_unit(id: int, side: String, position: Vector2) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_grid_%d" % id
	unit.display_name = "Grid %d" % id
	unit.max_hp = 100
	unit.hp = 100
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = 5.0
	# Tiny reach, so nothing in this suite ever swings at anything.
	unit.attack_range = 0.2
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


func _grid() -> BattleSpatialGrid:
	var grid := BattleSpatialGrid.new()
	grid.configure(FIELD, CELL)
	return grid


## Every unit the grid admits to having, sorted by id so the comparison is about
## membership rather than the order a bucket happens to be threaded in.
func _collected(grid: BattleSpatialGrid, position: Vector2, radius: float, side: String) -> Array[int]:
	var out: Array[BattleUnit] = []
	grid.collect_within(position, radius, side, out)
	var ids: Array[int] = []
	for unit in out:
		ids.append(unit.id)
	ids.sort()
	return ids


## The loop the grid replaced, kept here and here only. The rule is that the grid is a
## superset of this - it may hand back a soldier who turns out to be slightly too far
## once the caller measures properly, but it must never omit one this would have found.
func _brute_force(units: Array[BattleUnit], position: Vector2, radius: float, side: String) -> Array[int]:
	var ids: Array[int] = []
	for unit in units:
		if not unit.is_alive():
			continue
		if not side.is_empty() and unit.side != side:
			continue
		if unit.position.distance_to(position) > radius:
			continue
		ids.append(unit.id)
	ids.sort()
	return ids


## ---------- the grid itself ----------------------------------------------

func _test_configuration() -> void:
	var grid := _grid()
	equal(grid.cols, 25, "100 wide in 4-unit cells is 25 columns")
	equal(grid.rows, 15, "60 wide in 4-unit cells is 15 rows")
	approx(grid.cell_size, 4.0, 0.0001, "the cell size is what it was configured with")

	# A field that does not divide evenly must still be covered. Rounding down would
	# leave a strip along the top and right edges where nothing is ever found.
	var awkward := BattleSpatialGrid.new()
	awkward.configure(Vector2(10.0, 10.0), 3.0)
	equal(awkward.cols, 4, "a field that does not divide evenly rounds up rather than down")
	equal(awkward.rows, 4, "and does so on both axes")
	greater(float(awkward.cols) * awkward.cell_size, 10.0,
		"the grid is at least as wide as the field it describes")

	# Reconfiguring to the same size must be a no-op rather than a wipe.
	var units: Array[BattleUnit] = [_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 10.0))]
	grid.rebuild(units)
	grid.configure(FIELD, CELL)
	equal(grid.size(), 1, "configuring with the same size keeps the index intact")

	# A degenerate cell size must not divide by zero or make a zero-column grid.
	var tiny := BattleSpatialGrid.new()
	tiny.configure(FIELD, 0.0)
	greater(float(tiny.cols), 0.0, "a zero cell size is repaired rather than used")
	greater(float(tiny.cell_size), 0.0, "and the cell size it settled on is positive")


func _test_empty_grid() -> void:
	var grid := _grid()
	var units: Array[BattleUnit] = []
	grid.rebuild(units)
	equal(grid.size(), 0, "an empty army indexes nothing")
	check(grid.is_empty(), "and says so")
	equal(_collected(grid, Vector2(50.0, 30.0), 50.0, "").size(), 0,
		"a query against an empty grid finds nothing")
	equal(grid.busiest_cell(), 0, "and no cell is busy")


func _test_one_unit() -> void:
	var grid := _grid()
	var units: Array[BattleUnit] = [_make_unit(7, BattleContext.SIDE_PLAYER, Vector2(20.0, 20.0))]
	grid.rebuild(units)
	equal(grid.size(), 1, "one unit is indexed")
	equal(grid.busiest_cell(), 1, "in a cell of its own")
	equal(_collected(grid, Vector2(20.0, 20.0), 1.0, ""), [7] as Array[int],
		"and is found by a query on top of it")
	equal(_collected(grid, Vector2(90.0, 50.0), 1.0, "").size(), 0,
		"and is not found from across the field")


func _test_indexing_and_readback() -> void:
	var grid := _grid()
	var units: Array[BattleUnit] = [
		_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 10.0)),
		_make_unit(1, BattleContext.SIDE_PLAYER, Vector2(11.0, 10.0)),
		_make_unit(2, BattleContext.SIDE_ENEMY, Vector2(80.0, 50.0)),
	]
	grid.rebuild(units)
	equal(grid.size(), 3, "every living unit is indexed")

	var here := grid.units_in_cell(2, 2)
	equal(here.size(), 2, "both units near (10,10) are in the same cell")
	var elsewhere := grid.units_in_cell(20, 12)
	equal(elsewhere.size(), 1, "and the distant one is in its own")

	var occupancy := grid.occupancy()
	equal(occupancy.size(), 2, "only occupied cells are reported")
	equal(int(occupancy[grid.cell_index_of(Vector2(10.0, 10.0))]), 2,
		"the busy cell reports two occupants")

	# Out of range cell lookups are empty rather than an error.
	equal(grid.units_in_cell(-1, 0).size(), 0, "a negative column is empty, not a crash")
	equal(grid.units_in_cell(0, 9999).size(), 0, "and so is a row past the end")


func _test_dead_units_are_not_indexed() -> void:
	var grid := _grid()
	var alive := _make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 10.0))
	var dead := _make_unit(1, BattleContext.SIDE_PLAYER, Vector2(10.5, 10.0))
	dead.hp = 0
	dead.alive = false
	var units: Array[BattleUnit] = [alive, dead]
	grid.rebuild(units)
	equal(grid.size(), 1, "a corpse is not indexed")
	equal(_collected(grid, Vector2(10.0, 10.0), 5.0, ""), [0] as Array[int],
		"and does not come back from a query")


## The one that a snapshot index gets wrong if it is only careful at build time. The
## index is built at the start of a tick and soldiers die during that same tick, so a
## query has to re-check liveness rather than trusting the buckets.
func _test_dead_units_are_not_returned() -> void:
	var grid := _grid()
	var doomed := _make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 10.0))
	var witness := _make_unit(1, BattleContext.SIDE_PLAYER, Vector2(10.5, 10.0))
	var units: Array[BattleUnit] = [doomed, witness]
	grid.rebuild(units)
	equal(_collected(grid, Vector2(10.0, 10.0), 5.0, ""), [0, 1] as Array[int],
		"both are found while both are standing")

	# The casualty falls without the grid being rebuilt - exactly what happens mid-tick.
	doomed.hp = 0
	doomed.alive = false
	equal(_collected(grid, Vector2(10.0, 10.0), 5.0, ""), [1] as Array[int],
		"a soldier who fell after the rebuild is not returned as a candidate")
	equal(grid.size(), 2, "the index itself is unchanged until the next rebuild")


func _test_rebuild_replaces_membership() -> void:
	var grid := _grid()
	var first: Array[BattleUnit] = [
		_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 10.0)),
		_make_unit(1, BattleContext.SIDE_PLAYER, Vector2(11.0, 10.0)),
	]
	grid.rebuild(first)
	equal(grid.size(), 2, "the first roster is indexed")

	var second: Array[BattleUnit] = [_make_unit(2, BattleContext.SIDE_ENEMY, Vector2(90.0, 50.0))]
	grid.rebuild(second)
	equal(grid.size(), 1, "a rebuild replaces rather than adds")
	equal(_collected(grid, Vector2(10.0, 10.0), 10.0, "").size(), 0,
		"units from the previous roster are gone")
	equal(_collected(grid, Vector2(90.0, 50.0), 10.0, ""), [2] as Array[int],
		"and the new roster is there")

	# Rebuilding the same roster twice must not double it up.
	grid.rebuild(second)
	equal(grid.size(), 1, "rebuilding the same roster is idempotent")
	equal(_collected(grid, Vector2(90.0, 50.0), 10.0, ""), [2] as Array[int],
		"and does not duplicate anyone")


func _test_radius_queries() -> void:
	var grid := _grid()
	var units: Array[BattleUnit] = []
	for index in 10:
		units.append(_make_unit(index, BattleContext.SIDE_PLAYER, Vector2(10.0 + float(index) * 5.0, 30.0)))
	grid.rebuild(units)

	# The query answers in cells, not in a circle: it returns everyone whose cell the
	# search box touches. That is deliberate and it is what the caller wants - the caller
	# has to measure the exact distance anyway, to pick a nearest or to push a pair
	# apart - so the grid's job is to never omit anyone, not to be precise. These
	# assertions pin the superset contract; the exact radius is tested against the
	# simulator further down, where the radius is actually a promise to somebody.
	var tight := _collected(grid, Vector2(10.0, 30.0), 4.9, "")
	check(tight.has(0), "a short radius finds the unit it is centred on")
	equal(tight, [0, 1] as Array[int],
		"and the neighbour whose cell the box clips, for the caller to measure out")

	equal(_collected(grid, Vector2(10.0, 30.0), 5.1, ""), [0, 1] as Array[int],
		"a radius just past the gap finds the next one too")
	equal(_collected(grid, Vector2(10.0, 30.0), 25.1, "").size(), 6,
		"a wider radius finds more of them")
	equal(_collected(grid, Vector2(10.0, 30.0), 500.0, "").size(), 10,
		"a radius past the field finds everyone")
	equal(_collected(grid, Vector2(10.0, 30.0), 0.0, "").size(), 0,
		"a zero radius finds nobody rather than everybody")

	# Nobody outside the box ever comes back, however the box is clipped.
	for raw_radius in [1.0, 4.9, 5.1, 12.0, 25.1]:
		var probe_radius: float = raw_radius
		var found := _collected(grid, Vector2(10.0, 30.0), probe_radius, "")
		var limit := probe_radius + CELL
		var worst := 0.0
		for id in found:
			worst = maxf(worst, units[id].position.distance_to(Vector2(10.0, 30.0)))
		less(worst, limit + 0.001,
			"a radius of %.1f returns nobody further than the box plus one cell" % probe_radius)


func _test_side_filtering() -> void:
	var grid := _grid()
	var units: Array[BattleUnit] = [
		_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(50.0, 30.0)),
		_make_unit(1, BattleContext.SIDE_ENEMY, Vector2(50.5, 30.0)),
		_make_unit(2, BattleContext.SIDE_PLAYER, Vector2(51.0, 30.0)),
	]
	grid.rebuild(units)
	equal(_collected(grid, Vector2(50.0, 30.0), 10.0, BattleContext.SIDE_PLAYER), [0, 2] as Array[int],
		"a side filter returns only that side")
	equal(_collected(grid, Vector2(50.0, 30.0), 10.0, BattleContext.SIDE_ENEMY), [1] as Array[int],
		"and only the other side when asked for the other side")
	equal(_collected(grid, Vector2(50.0, 30.0), 10.0, "").size(), 3,
		"an empty side string means everyone")


## The bug this suite would most like to have caught in a real battle: a cell boundary
## is an implementation detail and must never behave like a wall.
func _test_cell_boundaries_are_not_walls() -> void:
	var grid := _grid()
	# Straddle the boundary at x = 20 exactly, and another at y = 40.
	var units: Array[BattleUnit] = [
		_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(19.9, 30.0)),
		_make_unit(1, BattleContext.SIDE_PLAYER, Vector2(20.1, 30.0)),
		_make_unit(2, BattleContext.SIDE_PLAYER, Vector2(50.1, 39.9)),
		_make_unit(3, BattleContext.SIDE_PLAYER, Vector2(49.9, 40.1)),
	]
	grid.rebuild(units)

	# Sanity: the pairs really are in different cells.
	not_equal(grid.cell_index_of(units[0].position), grid.cell_index_of(units[1].position),
		"the first pair really is split across a cell boundary")
	not_equal(grid.cell_index_of(units[2].position), grid.cell_index_of(units[3].position),
		"and so is the second pair")

	equal(_collected(grid, units[0].position, 1.0, ""), [0, 1] as Array[int],
		"units either side of a boundary still see each other")
	equal(_collected(grid, units[3].position, 1.0, ""), [2, 3] as Array[int],
		"and so do the ones split the other way")

	# And a search centred on one of them reaches across without being told to.
	equal(_collected(grid, Vector2(19.95, 30.0), 0.5, ""), [0, 1] as Array[int],
		"a search centred on the boundary crosses it")


func _test_movement_between_cells() -> void:
	var grid := _grid()
	var walker := _make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 10.0))
	var units: Array[BattleUnit] = [walker]
	grid.rebuild(units)
	var start_cell := grid.cell_index_of(walker.position)
	equal(_collected(grid, Vector2(50.0, 40.0), 1.0, "").size(), 0,
		"the walker is not where it is about to be")

	# Walk it across several cells without telling the grid.
	walker.position = Vector2(50.0, 40.0)
	equal(_collected(grid, Vector2(50.0, 40.0), 1.0, "").size(), 0,
		"a moved unit is still indexed where it was - the index is a snapshot")
	equal(_collected(grid, Vector2(10.0, 10.0), 1.0, ""), [0] as Array[int],
		"and is still found at its old address")

	# Now tell the grid, which is what a rebuild per tick does.
	grid.rebuild(units)
	not_equal(grid.cell_index_of(walker.position), start_cell,
		"the walker really did change cell")
	equal(_collected(grid, Vector2(50.0, 40.0), 1.0, ""), [0] as Array[int],
		"after a rebuild it is found at its new address")
	equal(_collected(grid, Vector2(10.0, 10.0), 1.0, "").size(), 0,
		"and no longer at the old one")


func _test_a_unit_appears_once() -> void:
	var grid := _grid()
	var units: Array[BattleUnit] = []
	for index in 40:
		units.append(_make_unit(index, BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0)))
	grid.rebuild(units)
	# Everyone is in one cell, and the whole field is asked for.
	var found := _collected(grid, Vector2(30.0, 30.0), 500.0, "")
	equal(found.size(), 40, "every unit is returned exactly once")
	var unique := {}
	for id in found:
		unique[id] = true
	equal(unique.size(), 40, "and none of them twice")
	equal(grid.busiest_cell(), 40, "a pile of forty is reported as one busy cell")


## Uniform grids degrade when everything lands in one cell. The brief asks for this case
## to be measured rather than hoped about, so here it is: it must still answer correctly,
## just more slowly, and it must not hang or lose anybody.
func _test_dense_cell() -> void:
	var grid := _grid()
	var units: Array[BattleUnit] = []
	for index in 500:
		# All inside one 4-unit cell, at deterministic offsets.
		var offset_x := float(index % 25) * 0.15
		var offset_y := float(index / 25) * 0.15
		units.append(_make_unit(index, BattleContext.SIDE_PLAYER, Vector2(20.0 + offset_x, 20.0 + offset_y)))
	grid.rebuild(units)
	equal(grid.size(), 500, "five hundred units in one cell are all indexed")
	equal(grid.busiest_cell(), 500, "and the grid says so honestly rather than pretending")

	var found := _collected(grid, Vector2(21.0, 21.0), 500.0, "")
	equal(found.size(), 500, "a query over a saturated cell still returns everyone")
	var local := _collected(grid, Vector2(20.0, 20.0), 1.0, "")
	greater(float(local.size()), 0.0, "and a local query still returns the locals")

	# The same pile, but split across cells, is the case the grid exists for.
	var spread: Array[BattleUnit] = []
	var spread_grid := _grid()
	for index in 500:
		spread.append(_make_unit(index, BattleContext.SIDE_PLAYER, Vector2(10.0 + float(index % 50) * 1.6, 10.0 + float(index / 50) * 1.6)))
	spread_grid.rebuild(spread)
	less(float(spread_grid.busiest_cell()), 500.0,
		"the same five hundred spread over the field do not share one cell")
	less(float(spread_grid.busiest_cell()), 25.0,
		"and no cell holds more than a couple of dozen")


## Ranged combat is not in this milestone, but a search that cannot reach across cells is
## a search that ranged combat could never be built on.
func _test_large_radius_queries() -> void:
	var grid := _grid()
	var units: Array[BattleUnit] = [
		_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 30.0)),
		_make_unit(1, BattleContext.SIDE_ENEMY, Vector2(90.0, 30.0)),
	]
	grid.rebuild(units)
	equal(_collected(grid, Vector2(10.0, 30.0), 10.0, ""), [0] as Array[int],
		"a short search does not reach the other side of the field")
	equal(_collected(grid, Vector2(10.0, 30.0), 85.0, ""), [0, 1] as Array[int],
		"a long search crosses twenty cells and finds it")
	equal(grid.cell_index_of(Vector2(10.0, 30.0)), 7 * grid.cols + 2,
		"the near unit is in the third column of the eighth row")
	equal(grid.cell_index_of(Vector2(90.0, 30.0)), 7 * grid.cols + 22,
		"and the far one is twenty cells further along the same row")

	# A search anchored on the far edge must still be clamped rather than overrunning.
	equal(_collected(grid, Vector2(99.5, 59.5), 500.0, "").size(), 2,
		"a search that overhangs the field is clamped and still finds everyone")
	equal(_collected(grid, Vector2(0.5, 0.5), 500.0, "").size(), 2,
		"and so is one anchored in the opposite corner")


func _test_query_order_is_stable() -> void:
	# Two rosters with the same units in different index order must give the same
	# answer. Bucket order is an implementation detail and must not leak into results.
	var forwards: Array[BattleUnit] = []
	var backwards: Array[BattleUnit] = []
	for index in 12:
		var unit := _make_unit(index, BattleContext.SIDE_PLAYER, Vector2(30.0 + float(index) * 2.0, 30.0))
		forwards.append(unit)
		backwards.push_front(unit)

	var grid_a := _grid()
	grid_a.rebuild(forwards)
	var grid_b := _grid()
	grid_b.rebuild(backwards)

	var a := _collected(grid_a, Vector2(36.0, 30.0), 20.0, "")
	var b := _collected(grid_b, Vector2(36.0, 30.0), 20.0, "")
	equal(a, b, "the same units in a different order give the same answer, sorted")
	equal(a.size(), 12, "and the answer is every unit the box reaches")

	# Repeat the identical query and get the identical answer.
	equal(_collected(grid_a, Vector2(36.0, 30.0), 20.0, ""), a,
		"repeating a query returns the same result")


func _test_scratch_reuse() -> void:
	# The query result array is reused between calls; it must be cleared rather than
	# appended to, or a later query would inherit an earlier one's answer.
	var grid := _grid()
	var units: Array[BattleUnit] = [
		_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 10.0)),
		_make_unit(1, BattleContext.SIDE_PLAYER, Vector2(90.0, 50.0)),
	]
	grid.rebuild(units)
	var scratch: Array[BattleUnit] = []
	grid.collect_within(Vector2(10.0, 10.0), 5.0, "", scratch)
	equal(scratch.size(), 1, "the first query fills the scratch array")
	grid.collect_within(Vector2(90.0, 50.0), 5.0, "", scratch)
	equal(scratch.size(), 1, "the second query replaces rather than appends")
	equal(scratch[0].id, 1, "and holds the second query's answer")


## The reference comparison. Generated layouts, many query points and radii, and the
## grid must never claim a unit is absent that the exhaustive loop finds.
func _test_brute_force_agreement() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var units: Array[BattleUnit] = []
	for index in 300:
		units.append(_make_unit(index, BattleContext.SIDE_PLAYER if index % 2 == 0 else BattleContext.SIDE_ENEMY,
			Vector2(rng.randf_range(0.0, FIELD.x), rng.randf_range(0.0, FIELD.y))))
	# Drop a tenth of them, so the dead-exclusion rule is exercised by the comparison.
	for index in range(0, 300, 10):
		units[index].hp = 0
		units[index].alive = false

	var grid := _grid()
	grid.rebuild(units)
	equal(grid.size(), 270, "a tenth of the roster is dead and unindexed")

	var checked := 0
	var missing := 0
	var extra_side := 0
	var extra_dead := 0
	for probe_index in 200:
		var position := Vector2(rng.randf_range(0.0, FIELD.x), rng.randf_range(0.0, FIELD.y))
		var radius := rng.randf_range(0.5, 40.0)
		var side := "" if probe_index % 3 == 0 else (BattleContext.SIDE_PLAYER if probe_index % 3 == 1 else BattleContext.SIDE_ENEMY)
		var expected := _brute_force(units, position, radius, side)
		var found := _collected(grid, position, radius, side)
		var found_set := {}
		for id in found:
			found_set[id] = true
		for id in expected:
			checked += 1
			if not found_set.has(id):
				missing += 1
		# And nothing comes back that should not: no corpses, no wrong side.
		var by_id := {}
		for unit in units:
			by_id[unit.id] = unit
		for id in found:
			var unit: BattleUnit = by_id[id]
			if not unit.is_alive():
				extra_dead += 1
			if not side.is_empty() and unit.side != side:
				extra_side += 1

	equal(missing, 0, "the grid found every unit the brute-force loop found, across 200 queries")
	greater(float(checked), 500.0, "and there were a meaningful number of them to find")
	equal(extra_dead, 0, "the grid never returned a dead soldier")
	equal(extra_side, 0, "and never returned one from the wrong side")


## The margin is what lets a query see a unit that has walked since the rebuild. Without
## it a soldier crossing a cell boundary mid-tick would vanish from searches.
func _test_margin_widens_the_query() -> void:
	var grid := _grid()
	var walker := _make_unit(0, BattleContext.SIDE_PLAYER, Vector2(22.0, 30.0))
	var units: Array[BattleUnit] = [walker]
	grid.rebuild(units)

	# It walks just over a cell boundary after the rebuild.
	walker.position = Vector2(26.4, 30.0)
	grid.query_margin = 0.0
	var tight := _collected(grid, Vector2(27.0, 30.0), 1.0, "")
	grid.query_margin = 5.0
	var widened := _collected(grid, Vector2(27.0, 30.0), 1.0, "")

	equal(tight.size(), 0, "without a margin a unit that has crossed a boundary is missed")
	equal(widened, [0] as Array[int], "with one it is found")
	grid.query_margin = 0.0


## ---------- what the simulator asks of it ---------------------------------

## The nearest living enemy, found the way the simulator used to find it: by looking at
## every soldier on the field. This is the reference the local search has to match, and
## it lives in this file rather than in the simulator precisely so that no production
## path can accidentally keep using it.
func _brute_force_nearest(units: Array[BattleUnit], seeker: BattleUnit) -> BattleUnit:
	var enemy_side := BattleContext.SIDE_ENEMY if seeker.side == BattleContext.SIDE_PLAYER else BattleContext.SIDE_PLAYER
	var best: BattleUnit = null
	var best_distance := INF
	for candidate in units:
		if not candidate.is_alive() or candidate.side != enemy_side:
			continue
		var distance := seeker.position.distance_to(candidate.position)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best


func _scattered(rng: RandomNumberGenerator, count: int, half: int) -> Array[BattleUnit]:
	var units: Array[BattleUnit] = []
	for index in count:
		var side := BattleContext.SIDE_PLAYER if index < half else BattleContext.SIDE_ENEMY
		units.append(_make_unit(index, side, Vector2(rng.randf_range(1.0, FIELD.x - 1.0), rng.randf_range(1.0, FIELD.y - 1.0))))
	return units


func _test_target_selection_matches_the_whole_field_scan() -> void:
	section("inside the search bound, selection agrees with the scan it replaced")
	var config := GameManager.config()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 1
	var units := _scattered(rng, 60, 30)
	var simulator := BattleSimulator.new(config, 99)
	simulator.add_units(units)
	# Rebuild as a tick would, so the comparison is about the search rather than about
	# how stale the snapshot happens to be.
	simulator.call("_rebuild_spatial", 0.05)
	simulator.call("_refresh_focus")

	# The guarantee is conditional and the condition matters: within the bound, the local
	# search returns what the exhaustive scan would have returned, exactly. Beyond it,
	# the soldier is pointed at the fighting instead, and that is a deliberate answer
	# rather than a nearest-enemy answer (D-067). This test pins the first half; the next
	# one pins the second.
	var checked := 0
	var beyond := 0
	var failed := 0
	for unit in units:
		if not unit.is_alive():
			continue
		var reference := _brute_force_nearest(units, unit)
		if reference == null:
			continue
		if unit.position.distance_to(reference.position) > simulator.target_search_max_radius:
			beyond += 1
			continue
		checked += 1
		if reference != simulator.call("_choose_target", unit):
			failed += 1
	greater(float(checked), 20.0, "plenty of soldiers had an enemy inside the bound to compare against")
	equal(failed, 0, "and every one of them named the same soldier the exhaustive scan named")
	equal(checked + beyond, 60, "every soldier on the field was accounted for")


func _test_target_selection_keeps_agreeing_as_soldiers_move() -> void:
	section("and keeps agreeing while they move")
	var config := GameManager.config()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 2
	var units: Array[BattleUnit] = []
	for index in 40:
		var side := BattleContext.SIDE_PLAYER if index < 20 else BattleContext.SIDE_ENEMY
		units.append(_make_unit(index, side, Vector2(rng.randf_range(25.0, 75.0), rng.randf_range(15.0, 45.0))))
	var simulator := BattleSimulator.new(config, 7)
	simulator.add_units(units)

	var comparisons := 0
	var disagreed := 0
	for tick in 80:
		if simulator.is_finished():
			break
		simulator.step(0.05)
		simulator.call("_rebuild_spatial", 0.05)
		simulator.call("_refresh_focus")
		for unit in units:
			if not unit.is_alive():
				continue
			var reference := _brute_force_nearest(units, unit)
			if reference == null:
				continue
			if unit.position.distance_to(reference.position) > simulator.target_search_max_radius:
				continue
			comparisons += 1
			if reference != simulator.call("_choose_target", unit):
				disagreed += 1
	greater(float(comparisons), 200.0, "there were plenty of comparisons to make")
	equal(disagreed, 0, "the local search never once disagreed with the exhaustive one")


## Ranged combat is not in this milestone, but a search that cannot reach across cells is
## a search ranged combat could never be built on.
func _test_the_search_escalates_to_find_a_distant_enemy() -> void:
	section("the search reaches further when it has to")
	var config := GameManager.config()
	var watcher := _make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 30.0))
	var distant := _make_unit(1, BattleContext.SIDE_ENEMY, Vector2(94.0, 30.0))
	var units: Array[BattleUnit] = [watcher, distant]
	var simulator := BattleSimulator.new(config, 13)
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", 0.05)

	var apart := watcher.position.distance_to(distant.position)
	greater(apart, 80.0, "the enemy really is the better part of a battlefield away")
	less(simulator.target_search_radius, apart, "which is further than the starting radius reaches")
	equal(simulator.call("_choose_target", watcher), distant,
		"the escalating search still finds the only enemy on the field")

	# The ladder is bounded, so a soldier with nobody to find must stop looking.
	var alone: Array[BattleUnit] = [_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 30.0))]
	var lonely := BattleSimulator.new(config, 17)
	lonely.add_units(alone)
	lonely.call("_rebuild_spatial", 0.05)
	lonely.call("_refresh_focus")
	equal(lonely.call("_choose_target", alone[0]), null,
		"a soldier alone on the field answers nothing rather than searching forever")


## The other half of the search contract: the bound is a real distance, and beyond it a
## soldier is still given something to face rather than left standing.
func _test_the_search_bound_is_respected() -> void:
	section("beyond the bound, a soldier is pointed at the fighting")
	var config := GameManager.config()
	var seeker := _make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 30.0))
	var distant := _make_unit(1, BattleContext.SIDE_ENEMY, Vector2(92.0, 30.0))
	var units: Array[BattleUnit] = [seeker, distant]
	var simulator := BattleSimulator.new(config, 131)
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", 0.05)
	simulator.call("_refresh_focus")

	# The bound is a local distance rather than the battlefield diagonal. A bound of "as
	# far as the field goes" is the exhaustive per-soldier scan this milestone removed,
	# and it was measured at ninety-seven per cent of the soldier loop.
	less(simulator.target_search_max_radius, 100.0, "the bound is a local distance, not the whole battlefield")
	greater(simulator.target_search_max_radius, simulator.target_search_radius - 0.0001,
		"and it never cuts the ladder off below its own first rung")

	var apart := seeker.position.distance_to(distant.position)
	greater(apart, simulator.target_search_max_radius, "the only enemy is beyond the bound")
	equal(simulator.call("_choose_target", seeker), distant,
		"and the soldier is pointed at it rather than given nothing")

	# The same rule with nobody at all: nothing to be pointed at, so nothing returned.
	var empty: Array[BattleUnit] = [_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(50.0, 30.0))]
	var bare := BattleSimulator.new(config, 137)
	bare.add_units(empty)
	bare.call("_rebuild_spatial", 0.05)
	bare.call("_refresh_focus")
	equal(bare.call("_choose_target", empty[0]), null, "with no enemy left there is nothing to face")

	# And it is not a one-off: the same arrangement gives the same answer every time.
	var again := BattleSimulator.new(config, 131)
	again.add_units([_make_unit(0, BattleContext.SIDE_PLAYER, Vector2(10.0, 30.0)),
		_make_unit(1, BattleContext.SIDE_ENEMY, Vector2(92.0, 30.0))])
	again.call("_rebuild_spatial", 0.05)
	again.call("_refresh_focus")
	equal(again.call("_choose_target", again.units[0]), again.units[1],
		"the long-range answer is the same every time it is asked")


## The overlap resolver's pair rule and processing order both exist to reproduce the
## exhaustive loop, so it is checked against the exhaustive loop itself on the awkward
## arrangements rather than on one comfortable one.
func _test_overlap_resolution_matches_the_pairwise_loop() -> void:
	section("overlap resolution agrees with the pairwise loop")
	_overlap_matches([Vector2(30.0, 30.0), Vector2(30.5, 30.0)], "a pair shoved together")
	_overlap_matches([Vector2(30.0, 30.0), Vector2(30.4, 30.0), Vector2(30.8, 30.0)], "three in a heap")
	_overlap_matches([
		Vector2(30.0, 30.0), Vector2(31.0, 30.0), Vector2(32.0, 30.0), Vector2(33.0, 30.0),
		Vector2(34.0, 30.0), Vector2(35.0, 30.0), Vector2(36.0, 30.0), Vector2(37.0, 30.0),
	], "a line standing too close together")
	_overlap_matches([
		Vector2(20.0, 20.0), Vector2(20.4, 20.0), Vector2(20.8, 20.0), Vector2(21.2, 20.0),
		Vector2(22.0, 21.0), Vector2(22.0, 21.4), Vector2(22.0, 21.8), Vector2(22.0, 22.2),
	], "two groups crossing at an angle")
	_overlap_matches([Vector2(19.9, 30.0), Vector2(20.1, 30.0)], "a pair straddling a cell boundary")
	_overlap_matches([Vector2(39.9, 39.9), Vector2(40.1, 40.1)], "a pair straddling a corner")
	_overlap_matches([Vector2(50.0, 30.0), Vector2(50.0, 30.0)], "two soldiers in exactly the same place")
	_overlap_matches([Vector2(50.0, 30.0)], "a soldier standing on their own")


func _arrangement(spec: Array[Vector2]) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	var id := 0
	for point in spec:
		out.append(_make_unit(id, BattleContext.SIDE_PLAYER, point))
		id += 1
	return out


## The old overlap loop, kept here as the reference. It walks every pair on the field in
## unit order; the spatial version walks only the nearby ones and has to arrive at the
## same positions anyway.
func _pairwise_overlaps(units: Array[BattleUnit], minimum: float) -> void:
	var alive: Array[BattleUnit] = []
	for unit in units:
		if unit.is_alive():
			alive.append(unit)
	for i in alive.size():
		for j in range(i + 1, alive.size()):
			var a := alive[i]
			var b := alive[j]
			var offset := b.position - a.position
			var distance := offset.length()
			if distance >= minimum:
				continue
			var push := (minimum - distance) * 0.5
			var direction := offset.normalized() if distance > 0.0001 else Vector2.RIGHT
			a.position -= direction * push
			b.position += direction * push


## The distance between the two soldiers standing closest together. Infinite when there
## are fewer than two of them, which is a real answer here rather than a placeholder.
func _closest_pair(units: Array[BattleUnit]) -> float:
	var closest := INF
	for i in units.size():
		for j in range(i + 1, units.size()):
			closest = minf(closest, units[i].position.distance_to(units[j].position))
	return closest


func _overlap_matches(spec: Array[Vector2], label: String) -> void:
	var config := GameManager.config()
	var spatial := _arrangement(spec)
	var reference := _arrangement(spec)
	var gap_before := _closest_pair(spatial)
	var simulator := BattleSimulator.new(config, 5)
	simulator.add_units(spatial)
	simulator.call("_rebuild_spatial", 0.05)
	simulator.call("_resolve_overlaps")
	_pairwise_overlaps(reference, simulator.separation_radius * BattleSimulator.SEPARATION_FACTOR)

	var worst := 0.0
	for index in spatial.size():
		worst = maxf(worst, spatial[index].position.distance_to(reference[index].position))
	less(worst, 0.0001, "%s: every soldier ended up where the pairwise loop would have put them" % label)

	# And the pass did something. Not "and everything is now separated": relaxation is
	# not a solver, and shoving one pair apart can push a soldier towards a third - the
	# exhaustive loop behaved exactly the same way, which is why the equivalence check
	# above is the one that matters. The claim worth making is that a pass with
	# something to resolve moved somebody, and a pass with nothing to resolve moved
	# nobody.
	var minimum := simulator.separation_radius * BattleSimulator.SEPARATION_FACTOR
	var moved := 0.0
	for index in spatial.size():
		moved = maxf(moved, spec[index].distance_to(spatial[index].position))
	if spec.size() < 2:
		approx(moved, 0.0, 0.0001, "%s: a soldier standing alone is left standing" % label)
	elif gap_before < minimum:
		greater(moved, 0.0, "%s: the pass moved somebody" % label)
	else:
		approx(moved, 0.0, 0.0001, "%s: nothing to resolve, nobody moved" % label)


## An ordered target is a player instruction, and a faster search must not quietly
## overrule it.
func _test_explicit_attack_orders_still_win() -> void:
	section("an ordered target still beats a nearer one")
	var config := GameManager.config()
	var attacker := _make_unit(0, BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0))
	attacker.attack_range = 100.0
	attacker.attack_cooldown = 0.05
	var nearer := _make_unit(1, BattleContext.SIDE_ENEMY, Vector2(36.0, 30.0))
	var ordered := _make_unit(2, BattleContext.SIDE_ENEMY, Vector2(60.0, 30.0))
	var units: Array[BattleUnit] = [attacker, nearer, ordered]
	var simulator := BattleSimulator.new(config, 11)
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", 0.05)
	equal(simulator.call("_choose_target", attacker), nearer, "with no order, the nearest enemy is chosen")

	attacker.attack_order_target_id = ordered.id
	var nearer_before := nearer.hp
	var ordered_before := ordered.hp
	simulator.start()
	# A dozen swings rather than one: whether any single blow lands is a die roll, and
	# this test is about who was aimed at, not about whether the sword connected.
	for tick in 12:
		simulator.step(0.05)
	equal(nearer.hp, nearer_before, "the nearer enemy is left alone when another has been ordered")
	less(float(ordered.hp), float(ordered_before), "and the ordered enemy is the one taking the blows")

	# When the ordered target dies the order lapses rather than pointing at a corpse.
	ordered.hp = 0
	ordered.alive = false
	simulator.call("_rebuild_spatial", 0.05)
	simulator.step(0.05)
	equal(attacker.attack_order_target_id, -1, "a dead order is dropped")
	var nearer_mid := nearer.hp
	for tick in 12:
		simulator.step(0.05)
	less(float(nearer.hp), float(nearer_mid), "and the soldier goes back to the nearest living enemy")

	attacker.attack_order_target_id = -1


## Same seed, same soldiers, same answer - the grid must not have introduced a source of
## variation. The signature covers the whole battle, not just who won.
func _test_a_seeded_battle_repeats_exactly() -> void:
	section("a seeded battle repeats exactly")
	var config := GameManager.config()
	var first := _battle_signature(config, SEED + 5)
	var second := _battle_signature(config, SEED + 5)
	equal(second, first, "the same seed produces a tick-identical battle")
	var third := _battle_signature(config, SEED + 6)
	not_equal(third, first, "and a different seed produces a different one")
	greater(float(first.length()), 100.0, "the signature is detailed enough to be worth comparing")


func _battle_signature(config: GameConfig, seed_value: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var units: Array[BattleUnit] = []
	for index in 24:
		var side := BattleContext.SIDE_PLAYER if index < 12 else BattleContext.SIDE_ENEMY
		units.append(_make_unit(index, side, Vector2(rng.randf_range(25.0, 75.0), rng.randf_range(15.0, 45.0))))
	var simulator := BattleSimulator.new(config, seed_value)
	simulator.add_units(units)
	var ticks := 0
	while not simulator.is_finished() and ticks < 4000:
		simulator.step(0.05)
		ticks += 1
	var parts := PackedStringArray()
	parts.append("%d:%d" % [ticks, simulator.state])
	for unit in units:
		parts.append("%d:%d:%d:%.3f:%.3f" % [unit.id, unit.hp, unit.kills, unit.position.x, unit.position.y])
	return "|".join(parts)
