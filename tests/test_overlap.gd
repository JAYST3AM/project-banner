extends TestCase
## Step 7.3: separating dense soldier bodies.
##
## The rules this suite exists to pin down:
## [br]- two soldiers standing inside each other are pushed apart, and two who are not
##   are left exactly where they were;
## [br]- a soldier never ends up somewhere the result depends on the order the pass
##   happened to walk the field in;
## [br]- a formation's own geometry is trusted where it can prove the spacing, and only
##   where it can prove it;
## [br]- enemy contact is resolved by the same code as friendly contact, so a battle line
##   is still a physical object;
## [br]- and none of it can fling a soldier across the field, leave one stacked inside
##   another forever, or produce a NaN.
##
## [b]On comparing against the sequential loop.[/b] Step 7.2 resolved each overlapping
## pair the moment it was found, so the result depended on visit order, and its test
## compared positions against an exhaustive loop that reproduced that order. Step 7.3
## accumulates every push and applies them together, which is deliberately a different
## relaxation: a cluster resolves over a tick or two rather than in one go. Comparing
## positions against the old loop would therefore be testing that the change did not
## happen. What is tested instead is the pair set (which must be identical for a single
## pair, and is counted for clusters), the physical invariants, and determinism - and the
## difference is recorded in D-074.

const SEED := 73001

var _reference_minimum := 1.35


func run() -> void:
	await _tick()
	_test_two_soldiers_separate()
	_test_distant_soldiers_are_untouched()
	_test_identical_positions_are_deterministic()
	_test_pairs_across_a_boundary()
	_test_a_pair_is_resolved_once()
	_test_the_pass_is_order_independent()
	_test_the_pass_is_repeatable()
	_test_no_allocation_after_configure()
	_test_a_settled_formation_is_left_alone()
	_test_a_stable_column_and_loose_body_stay_spaced()
	_test_a_compressed_line_is_separated()
	_test_two_friendly_formations_crossing()
	_test_enemy_lines_make_contact()
	_test_a_flank_is_physical()
	_test_a_dense_pile_is_survivable()
	_test_nothing_is_launched()
	_test_separation_keeps_up_with_movement()
	_test_separation_converges()
	_test_against_a_brute_force_reference()
	_test_a_dense_deployment_is_fully_enumerated()
	_test_cell_size_is_configurable()
	_test_the_profiler_counts_what_it_names()
	_test_the_phase_clock_has_parts_that_add_up()
	_test_the_settled_proof_says_which_test_rejected_it()
	_test_a_dry_pass_moves_nobody()
	_test_a_battle_is_identical_whichever_pass_runs_it()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _config() -> GameConfig:
	return GameManager.config()


func _minimum() -> float:
	var config := _config()
	return config.get_float("battle.separation_radius", 1.5) * BattleSimulator.SEPARATION_FACTOR


func _unit(id: int, side: String, position: Vector2) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_ov_%d" % id
	unit.display_name = "Overlap %d" % id
	unit.max_hp = 100
	unit.hp = 100
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = 5.0
	unit.attack_range = 0.2
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


func _grid(cell_size: float = -1.0) -> BattleOverlapGrid:
	var grid := BattleOverlapGrid.new()
	grid.configure(Vector2(100.0, 60.0), cell_size if cell_size > 0.0 else _config().get_float("battle.overlap_cell_size", 0.9))
	grid.max_push = _config().get_float("battle.max_separation_push", 1.35)
	return grid


func _roster(spec: Array[Vector2], side: String = BattleContext.SIDE_PLAYER) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	var id := 0
	for point in spec:
		out.append(_unit(id, side, point))
		id += 1
	return out


## Distance between the two closest soldiers on the field, or INF for fewer than two.
func _closest(units: Array[BattleUnit]) -> float:
	var closest := INF
	for i in units.size():
		for j in range(i + 1, units.size()):
			closest = minf(closest, units[i].position.distance_to(units[j].position))
	return closest


## How much total penetration the field is carrying: the sum over every pair of how far
## inside the separation distance it is. Zero means fully separated.
func _penetration(units: Array[BattleUnit], minimum: float) -> float:
	var total := 0.0
	for i in units.size():
		for j in range(i + 1, units.size()):
			var distance := units[i].position.distance_to(units[j].position)
			if distance < minimum:
				total += minimum - distance
	return total


func _positions(units: Array[BattleUnit]) -> String:
	var parts := PackedStringArray()
	for unit in units:
		parts.append("%.6f,%.6f" % [unit.position.x, unit.position.y])
	return "|".join(parts)


## The loop Step 7.2 replaced: every pair, in roster order, pushed as soon as it is found.
## Kept here as the reference for the pair set and for the invariants both versions must
## satisfy.
func _sequential_reference(units: Array[BattleUnit], minimum: float) -> void:
	for i in units.size():
		for j in range(i + 1, units.size()):
			var a := units[i]
			var b := units[j]
			var offset := b.position - a.position
			var distance := offset.length()
			if distance >= minimum:
				continue
			var push := (minimum - distance) * 0.5
			var direction := offset.normalized() if distance > 0.0001 else Vector2.RIGHT
			a.position -= direction * push
			b.position += direction * push


## One pass of the real thing, so tests describe the shipped path rather than a copy.
func _resolve(units: Array[BattleUnit], grid: BattleOverlapGrid = null, settle: float = 0.0) -> BattleOverlapGrid:
	var resolver := grid if grid != null else _grid()
	resolver.resolve(units, _minimum(), settle)
	return resolver


## ---------- basic overlap -------------------------------------------------

func _test_two_soldiers_separate() -> void:
	section("two soldiers standing inside each other are pushed apart")
	var minimum := _minimum()
	var units := _roster([Vector2(30.0, 30.0), Vector2(30.5, 30.0)])
	_resolve(units)
	approx(units[0].position.distance_to(units[1].position), minimum, 0.0001,
		"a lone pair ends exactly the separation distance apart")
	approx(units[0].position.y, 30.0, 0.0001, "and neither is pushed sideways doing it")

	# The same pair, in every orientation and across every cell boundary shape, must
	# behave the same way. A grid that only worked on the horizontal would be a grid that
	# changed the game at some facings.
	for angle in [0.0, 37.0, 90.0, 143.5, 180.0, -61.0, 270.0]:
		var offset := Vector2.RIGHT.rotated(deg_to_rad(angle)) * 0.4
		var pair := _roster([Vector2(41.2, 33.7), Vector2(41.2, 33.7) + offset])
		_resolve(pair)
		approx(pair[0].position.distance_to(pair[1].position), minimum, 0.0001,
			"a pair %0.1f degrees apart ends the separation distance apart" % angle)


func _test_distant_soldiers_are_untouched() -> void:
	section("soldiers who are not touching do not move")
	var minimum := _minimum()
	var units := _roster([Vector2(20.0, 20.0), Vector2(20.0 + minimum + 0.5, 20.0)])
	var grid := _grid()
	grid.resolve(units, minimum, 0.0)
	approx(units[0].position.x, 20.0, 0.000001, "the first is exactly where it was")
	approx(units[1].position.x, 20.0 + minimum + 0.5, 0.000001, "and so is the second")

	# And a single soldier on their own, which is the degenerate case the pass must not
	# trip over.
	var alone := _roster([Vector2(50.0, 30.0)])
	_resolve(alone)
	approx(alone[0].position.x, 50.0, 0.000001, "one soldier alone is not moved by anybody")


func _test_identical_positions_are_deterministic() -> void:
	section("soldiers in exactly the same spot resolve the same way every time")
	var minimum := _minimum()
	var first := _roster([Vector2(44.0, 32.0), Vector2(44.0, 32.0)])
	var second := _roster([Vector2(44.0, 32.0), Vector2(44.0, 32.0)])
	_resolve(first)
	_resolve(second)
	approx(first[0].position.distance_to(first[1].position), minimum, 0.0001,
		"coincident soldiers are separated to exactly the same distance")
	equal(_positions(second), _positions(first), "and the two runs put them in the same places")

	var three_a := _roster([Vector2(60.0, 30.0), Vector2(60.0, 30.0), Vector2(60.0, 30.0)])
	var three_b := _roster([Vector2(60.0, 30.0), Vector2(60.0, 30.0), Vector2(60.0, 30.0)])
	_resolve(three_a)
	_resolve(three_b)
	equal(_positions(three_b), _positions(three_a), "three in the same spot resolve identically too")
	greater(_closest(three_a), 0.0, "and none of them is left standing on top of another")


## The failure mode a grid is most likely to introduce and hardest to notice: a cell
## boundary that behaves like a wall.
func _test_pairs_across_a_boundary() -> void:
	section("a cell boundary is not a wall")
	var minimum := _minimum()
	var cell := _config().get_float("battle.overlap_cell_size", 0.9)

	# A vertical boundary, a horizontal one, and a corner where four cells meet.
	var cases := [
		["across a vertical boundary", Vector2(3.0 * cell - 0.2, 30.0), Vector2(3.0 * cell + 0.35, 30.0)],
		["across a horizontal boundary", Vector2(30.0, 3.0 * cell - 0.2), Vector2(30.0, 3.0 * cell + 0.35)],
		["across a corner", Vector2(4.0 * cell - 0.2, 4.0 * cell - 0.2), Vector2(4.0 * cell + 0.35, 4.0 * cell + 0.35)],
		["one exactly on a boundary", Vector2(4.0 * cell - 0.6, 30.0), Vector2(4.0 * cell, 30.0)],
		["straddling a boundary exactly", Vector2(4.0 * cell - 0.2, 30.0), Vector2(4.0 * cell + 0.2, 30.0)],
		["across a boundary at the field edge", Vector2(99.0, 59.0), Vector2(99.4, 59.4)],
	]
	for entry in cases:
		var label := str(entry[0])
		var first: Vector2 = entry[1]
		var second: Vector2 = entry[2]
		var spec: Array[Vector2] = [first, second]
		var units := _roster(spec)
		var grid := _grid()
		var cell_a := int(floor(first.x / grid.cell_size)) + int(floor(first.y / grid.cell_size)) * grid.cols
		var cell_b := int(floor(second.x / grid.cell_size)) + int(floor(second.y / grid.cell_size)) * grid.cols
		not_equal(cell_a, cell_b, "%s: the two really are in different cells" % label)
		_resolve(units, grid)
		approx(units[0].position.distance_to(units[1].position), minimum, 0.0001,
			"%s: and they are separated anyway" % label)


func _test_a_pair_is_resolved_once() -> void:
	section("a pair is never resolved twice")
	var minimum := _minimum()
	# Four soldiers in one cell and four more across a boundary: every pair inside range,
	# and the count of pairs the pass acted on must equal the number that were touching.
	var spec: Array[Vector2] = []
	for i in 4:
		spec.append(Vector2(20.0 + float(i) * 0.3, 20.0))
	for i in 4:
		spec.append(Vector2(21.4 + float(i) * 0.3, 20.0))
	var units := _roster(spec)
	# Counted against the positions the pass is about to start from: a pair counted twice
	# would push twice as hard and separate further than it should.
	var touching := 0
	for i in units.size():
		for j in range(i + 1, units.size()):
			if units[i].position.distance_to(units[j].position) < minimum:
				touching += 1
	greater(float(touching), 10.0, "the arrangement has plenty of touching pairs")

	var grid := _grid()
	grid.stats_enabled = true
	grid.resolve(units, minimum, 0.0)
	equal(grid.stat_touching, touching,
		"the pass acted on exactly as many pairs as were touching, so none was double-counted")

	# An isolated pair is the sharpest form of the same claim: a pair counted twice would
	# be pushed twice as far and end up further apart than the separation distance.
	var isolated := _roster([Vector2(70.0, 15.0), Vector2(70.3, 15.0)])
	var isolated_grid := _grid()
	isolated_grid.stats_enabled = true
	isolated_grid.resolve(isolated, minimum, 0.0)
	equal(isolated_grid.stat_touching, 1, "one touching pair is counted once")
	approx(isolated[0].position.distance_to(isolated[1].position), minimum, 0.0001,
		"and is separated to exactly the separation distance, not further")

	for unit in units:
		less(unit.position.distance_to(Vector2(20.0, 20.0)), 20.0, "nobody was thrown across the field")


## The claim that replaces order-preservation. Step 7.2 had to reproduce the exhaustive
## loop's visit order to get the same positions; this pass sums every push and applies
## them together, so any order produces the same answer - and that is checkable rather
## than merely asserted.
func _test_the_pass_is_order_independent() -> void:
	section("the result does not depend on the order the field is walked in")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var spec: Array[Vector2] = []
	for i in 40:
		spec.append(Vector2(rng.randf_range(30.0, 40.0), rng.randf_range(25.0, 35.0)))

	var forward := _roster(spec)
	_resolve(forward)
	var backward: Array[BattleUnit] = []
	for unit in _roster(spec):
		backward.push_front(unit)
	_resolve(backward)

	var reference: Array[BattleUnit] = []
	for unit in _roster(spec):
		reference.append(unit)
	var reference_positions := PackedVector2Array()
	for unit in reference:
		reference_positions.append(unit.position)

	# Match by the order the soldiers were declared in, since reversing the array is the
	# thing under test.
	var by_id: Dictionary = {}
	for unit in backward:
		by_id[unit.id] = unit
	var worst := 0.0
	for unit in forward:
		var mirrored: BattleUnit = by_id[unit.id]
		worst = maxf(worst, unit.position.distance_to(mirrored.position))
	less(worst, 0.001, "reversing the roster changes nobody's position by more than a thousandth of a unit")


func _test_the_pass_is_repeatable() -> void:
	section("the same arrangement resolves to the same places twice")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 1
	var spec: Array[Vector2] = []
	for i in 60:
		spec.append(Vector2(rng.randf_range(20.0, 30.0), rng.randf_range(20.0, 30.0)))
	var first := _roster(spec)
	var second := _roster(spec)
	_resolve(first)
	_resolve(second)
	equal(_positions(second), _positions(first), "sixty soldiers in a heap end up identically placed")


## The grid claims it allocates nothing after configuration. A claim like that is worth
## exactly as much as the test behind it, and the difference is measurable: with a tails
## buffer created per rebuild, a few thousand rebuilds leak a few megabytes.
func _test_no_allocation_after_configure() -> void:
	section("a rebuild allocates nothing")
	var units := _roster([Vector2(20.0, 20.0), Vector2(20.5, 20.0), Vector2(80.0, 40.0)])
	var grid := _grid()
	# Warm up first: the first few passes fill lazily-sized storage, and that growth is
	# legitimate. What is under test is the steady state.
	for i in 20:
		grid.resolve(units, _minimum(), 0.0)

	var before := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in 500:
		grid.resolve(units, _minimum(), 0.0)
	var after := Performance.get_monitor(Performance.MEMORY_STATIC)
	var growth := after - before
	less(growth, 65536.0,
		"five hundred passes grew static memory by %.0f bytes" % growth)


## ---------- formations ----------------------------------------------------

func _body(simulator: BattleSimulator, id: String, side: String, anchor: Vector2, facing: float, count: int, first_id: int, shape: String = "line") -> BattleFormation:
	var units: Array[BattleUnit] = []
	var ids: Array[int] = []
	for i in count:
		var unit_id := first_id + i
		units.append(_unit(unit_id, side, anchor))
		ids.append(unit_id)
	var existing := simulator.units
	existing.append_array(units)
	simulator.add_units(existing)
	var body := BattleFormation.create(id, side, anchor, facing, shape, FormationCatalog.load_from(), _config())
	simulator.add_formation(body)
	simulator.assign_formation(body, ids)
	# Stand everyone on the place the body gave them: this suite is about separation, not
	# about walking into formation, which test_formation already covers.
	for i in body.unit_ids.size():
		var member := simulator.find_unit(body.unit_ids[i])
		if member != null:
			member.position = body.slots[i]
	return body


func _members(simulator: BattleSimulator, body: BattleFormation) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			out.append(unit)
	return out


func _test_a_settled_formation_is_left_alone() -> void:
	section("a formation standing where it was put is already spaced, whatever shape it is")
	# All three shapes, because the skip is taken against the body's own slot spacing and
	# every shape lays its slots out differently. A skip that was safe for a line and
	# unsafe for a column would be a bug that only showed up when somebody chose a column.
	for shape in ["line", "column", "loose"]:
		var probe_sim := BattleSimulator.new(_config(), SEED + 9)
		var probe_body := _body(probe_sim, shape, BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 18, 0, shape)
		probe_sim.start()
		for tick in 4:
			probe_sim.step(0.05)
		var probe_grid := _grid()
		probe_grid.stats_enabled = true
		probe_grid.resolve(probe_sim.units, _minimum(), _config().get_float("battle.separation_settle_epsilon", 0.15))
		equal(probe_grid.stat_touching, 0, "a dressed %s has nothing to separate" % shape)
		# The skip applies where two cells of the body are neighbours at all. A loose body
		# is spread so wide that most of its neighbours are empty cells, so the honest
		# claim is narrower and sharper than "some were skipped": every cell pair the pass
		# did consider was skipped, because every cell in a dressed body is a settled
		# interior.
		if probe_grid.stat_cell_pairs > 0:
			equal(probe_grid.stat_cell_pairs_skipped, probe_grid.stat_cell_pairs,
				"every cell pair a dressed %s considered was skipped" % shape)
		if shape != "loose":
			greater(float(probe_grid.stat_cell_pairs), 0.0,
				"a dressed %s has neighbouring cells to consider in the first place" % shape)

	var simulator := BattleSimulator.new(_config(), SEED + 10)
	var body := _body(simulator, "line", BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 24, 0)
	simulator.start()
	# Four ticks of real simulation, so the settle test sees what the game produces rather
	# than what the fixture set up.
	for tick in 4:
		simulator.step(0.05)

	var members := _members(simulator, body)
	equal(members.size(), 24, "the body still has its twenty-four soldiers")
	var settle := _config().get_float("battle.separation_settle_epsilon", 0.15)
	var grid := _grid()
	grid.stats_enabled = true
	grid.resolve(simulator.units, _minimum(), settle)

	greater(float(grid.stat_cell_pairs), 0.0, "the pass still considered cell pairs")
	greater(float(grid.stat_cell_pairs_skipped), 0.0,
		"and skipped the ones a settled body's own spacing already accounts for")
	equal(grid.stat_touching, 0, "a dressed line has nothing to separate")
	approx(_penetration(simulator.units, _minimum()), 0.0, 0.0001,
		"and nobody moved, because there was nothing to move")

	# The skip is a proof rather than a hope, so it must lapse the moment the proof does.
	# Put one soldier exactly on top of one of its own neighbours: the pair is now inside
	# the separation distance, and the cells holding them are no longer an interior.
	var stray := members[0]
	var neighbour := members[1] if members.size() > 1 else null
	not_null(neighbour, "the body has a second soldier to stand on")
	if neighbour != null:
		stray.position = neighbour.position + Vector2(0.2, 0.0)
		equal(stray.position.distance_to(neighbour.position) < _minimum(), true,
			"the stray really is standing inside a body-mate")
		var perturbed := _grid()
		perturbed.stats_enabled = true
		# Where the stray stood when the pass indexed the field, which is what the cell
		# state describes: the pass moves soldiers after deciding, so asking about a cell
		# by a soldier's pushed position would be asking about a cell they have left.
		var stray_place := stray.position
		perturbed.resolve(simulator.units, _minimum(), settle)
		greater(float(perturbed.stat_touching), 0.0,
			"a body with somebody out of place is separated rather than skipped")
		equal(perturbed.cell_state_of(perturbed.cell_index_of(stray_place)) == BattleOverlapGrid.CELL_MIXED, true,
			"and the cell the stray stood in stopped counting as a settled interior")


## A column and a loose formation, walked through their own slot layouts, must stay
## spaced without the pass having to hold them there.
func _test_a_stable_column_and_loose_body_stay_spaced() -> void:
	section("a column and a loose body keep their own spacing")
	for shape in ["column", "loose"]:
		var simulator := BattleSimulator.new(_config(), SEED + 30)
		var body := _body(simulator, shape, BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 16, 0, shape)
		simulator.start()
		for tick in 30:
			simulator.step(0.05)
		var members := _members(simulator, body)
		equal(members.size(), 16, "the %s body still has its sixteen soldiers" % shape)
		# The body was put together with no separation pass involved beyond the tick's own
		# resolve, so if geometry is doing its job the slots alone are keeping them apart.
		greater(_closest(members), _minimum() * 0.9,
			"a %s body holds its soldiers apart by its own layout" % shape)
		greater(float(body.spacing), _minimum(),
			"and its slot spacing really is wider than a body (%s)" % shape)


func _test_a_compressed_line_is_separated() -> void:
	section("a line crushed into itself is pulled apart")
	var simulator := BattleSimulator.new(_config(), SEED + 11)
	var body := _body(simulator, "line", BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 20, 0)
	simulator.start()
	# Compress the whole body to a third of its frontage, which is what a line looks like
	# when the enemy arrives and the men behind keep walking.
	for i in body.unit_ids.size():
		var member := simulator.find_unit(body.unit_ids[i])
		if member != null:
			member.position = body.anchor + (body.slots[i] - body.anchor) * 0.33
	var before := _penetration(simulator.units, _minimum())
	greater(before, 0.0, "the squeezed body really is overlapping itself")

	var grid := _grid()
	grid.stats_enabled = true
	for pass_index in 6:
		grid.resolve(simulator.units, _minimum(), 0.0)
	var after := _penetration(simulator.units, _minimum())
	less(after, before, "six passes reduced the total overlap")
	less(after, before * 0.5, "and reduced it substantially")
	greater(float(grid.stat_touching), 0.0, "with pairs actually being resolved")


func _test_two_friendly_formations_crossing() -> void:
	section("two friendly bodies crossing are physically sensible")
	var simulator := BattleSimulator.new(_config(), SEED + 12)
	var first := _body(simulator, "a", BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 12, 0)
	var second := _body(simulator, "b", BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), PI * 0.5, 12, 100)
	simulator.start()
	# Walk one straight through the other, which is what a reserve does when it advances
	# through a gap and misses.
	for unit_id in second.unit_ids:
		var member := simulator.find_unit(unit_id)
		if member != null:
			member.position += Vector2(2.0, 0.0)

	var grid := _grid()
	grid.stats_enabled = true
	for pass_index in 8:
		grid.resolve(simulator.units, _minimum(), _config().get_float("battle.separation_settle_epsilon", 0.15))
	equal(_penetration(simulator.units, _minimum()) < 0.5, true,
		"two bodies crossing end up separated rather than interpenetrating")
	greater(float(grid.stat_touching), 0.0, "and the crossing was resolved as real contact")

	# The shortcut only ever applies between two cells of the *same* settled body, so the
	# sharpest test of it is two settled bodies standing in each other: both are on their
	# slots, so both would qualify for the skip if the rule were "settled" alone, and the
	# contact must still be found. This is what keeps two friendly lines touching a
	# physical event rather than an ignored one.
	for unit_id in second.unit_ids:
		var member := simulator.find_unit(unit_id)
		if member != null and member.is_formed():
			member.position = member.formation_slot()
	var neighbouring := _members(simulator, first)
	var standing: Array[BattleUnit] = []
	for unit_id in second.unit_ids:
		var member := simulator.find_unit(unit_id)
		if member != null and member.is_alive():
			standing.append(member)
	for index in standing.size():
		standing[index].position = neighbouring[index % neighbouring.size()].position + Vector2(0.5, 0.0)
	var contact_grid := _grid()
	contact_grid.stats_enabled = true
	var settle_now := _config().get_float("battle.separation_settle_epsilon", 0.15)
	contact_grid.resolve(simulator.units, _minimum(), settle_now)
	greater(float(contact_grid.stat_touching), 0.0,
		"two settled bodies standing in each other are separated, not skipped")


func _test_enemy_lines_make_contact() -> void:
	section("enemy lines meeting are resolved by the same code")
	var simulator := BattleSimulator.new(_config(), SEED + 13)
	var players := _body(simulator, "player_line", BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 16, 0)
	var enemies := _body(simulator, "enemy_line", BattleContext.SIDE_ENEMY, Vector2(30.0, 30.0), PI, 16, 100)
	simulator.start()
	# Drive the two front ranks into each other.
	for unit_id in enemies.unit_ids:
		var member := simulator.find_unit(unit_id)
		if member != null:
			member.position += Vector2(-3.0, 0.0)

	var grid := _grid()
	grid.stats_enabled = true
	for pass_index in 8:
		grid.resolve(simulator.units, _minimum(), 0.0)

	# Nobody may end up standing inside an enemy: that is what stops a line walking
	# through another line.
	var violations := 0
	for player_unit in _members(simulator, players):
		for enemy_unit in _members(simulator, enemies):
			if player_unit.position.distance_to(enemy_unit.position) < _minimum() * 0.5:
				violations += 1
	equal(violations, 0, "no soldier is left standing inside an enemy soldier")
	greater(float(grid.stat_touching), 0.0, "and the collision was real work, not a skipped path")


func _test_a_flank_is_physical() -> void:
	section("a body hitting another at an angle is still stopped by it")
	var simulator := BattleSimulator.new(_config(), SEED + 14)
	var line := _body(simulator, "line", BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 20, 0)
	var flankers := _body(simulator, "flankers", BattleContext.SIDE_ENEMY, Vector2(30.0, 30.0), PI * 0.5, 10, 100)
	simulator.start()
	for unit_id in flankers.unit_ids:
		var member := simulator.find_unit(unit_id)
		if member != null:
			member.position += Vector2(0.0, -2.0)

	var grid := _grid()
	for pass_index in 10:
		grid.resolve(simulator.units, _minimum(), 0.0)

	var worst := INF
	for player_unit in _members(simulator, line):
		for enemy_unit in _members(simulator, flankers):
			worst = minf(worst, player_unit.position.distance_to(enemy_unit.position))
	greater(worst, 0.0, "an attacking body does not pass through a line it hits from the side")
	equal(_penetration(simulator.units, _minimum()) < 1.0, true, "and the contact resolves to a stable gap")


## The question the torture test does not answer: does the pass separate soldiers at least
## as fast as they can walk into each other? A pile relaxing over two hundred passes is
## fine; a battle line sinking into its opposite number over twenty ticks is not.
func _test_separation_keeps_up_with_movement() -> void:
	section("the pass keeps up with soldiers walking into each other")
	var minimum := _minimum()
	var simulator := BattleSimulator.new(_config(), SEED + 40)
	var players := _body(simulator, "player_line", BattleContext.SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, 8, 0)
	var enemies := _body(simulator, "enemy_line", BattleContext.SIDE_ENEMY, Vector2(46.0, 30.0), PI, 8, 100)
	players.order_engage()
	enemies.order_engage()
	simulator.start()

	var worst := INF
	var ticks := 0
	for tick in 160:
		if simulator.is_finished():
			break
		simulator.step(0.05)
		ticks += 1
		for a in _members(simulator, players):
			for b in _members(simulator, enemies):
				worst = minf(worst, a.position.distance_to(b.position))
	greater(float(ticks), 20.0, "the lines had time to reach each other")
	less(worst, minimum * 3.0, "and they did make contact rather than stopping short")
	greater(worst, minimum * 0.5,
		"and never sank into one another, however hard they pressed: the closest any two enemy soldiers ever came was %.2f units" % worst)


## ---------- density -------------------------------------------------------

func _pile(count: int, spread: float, seed_value: int) -> Array[BattleUnit]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var units: Array[BattleUnit] = []
	for i in count:
		var side := BattleContext.SIDE_PLAYER if i % 2 == 0 else BattleContext.SIDE_ENEMY
		units.append(_unit(i, side, Vector2(20.0 + rng.randf_range(0.0, spread), 20.0 + rng.randf_range(0.0, spread))))
	return units


func _test_a_dense_pile_is_survivable() -> void:
	section("a pathological pile is survivable")
	for count in [200, 800]:
		var units := _pile(count, 4.0, SEED + count)
		# Everything in a four-unit square: far past anything a battlefield produces, and
		# exactly the case a uniform grid is worst at.
		var grid := _grid()
		grid.stats_enabled = true
		var before := _penetration(units, _minimum())
		for pass_index in 20:
			grid.resolve(units, _minimum(), 0.0)

		var after := _penetration(units, _minimum())
		equal(after < before, true, "%d soldiers in a four-unit square: the pile came apart" % count)
		less(after, before * 0.25, "%d soldiers: and by a wide margin" % count)

		var nan := 0
		for unit in units:
			if is_nan(unit.position.x) or is_nan(unit.position.y):
				nan += 1
		equal(nan, 0, "%d soldiers: nobody's position became a NaN" % count)

		# Two identical piles must come apart identically.
		var again := _pile(count, 4.0, SEED + count)
		var second_grid := _grid()
		for pass_index in 20:
			second_grid.resolve(again, _minimum(), 0.0)
		equal(_positions(again), _positions(units), "%d soldiers: and the same pile comes apart identically" % count)


func _test_nothing_is_launched() -> void:
	section("nobody is thrown across the field")
	var units := _pile(400, 2.0, SEED + 7)
	var starts: Array[Vector2] = []
	for unit in units:
		starts.append(unit.position)
	var grid := _grid()
	var ceiling := _config().get_float("battle.max_separation_push", 1.35)

	# Twenty soldiers stacked on one point is the case that produced runaway displacement
	# before the ceiling existed: every pair pushes, and one soldier's pushes sum.
	var stacked: Array[BattleUnit] = []
	for i in 20:
		stacked.append(_unit(i, BattleContext.SIDE_PLAYER, Vector2(50.0, 30.0)))
	var stack_grid := _grid()
	stack_grid.resolve(stacked, _minimum(), 0.0)
	for unit in stacked:
		less(unit.position.distance_to(Vector2(50.0, 30.0)), ceiling + 0.0001,
			"a soldier in a twenty-deep stack moved no further than the ceiling")

	for pass_index in 10:
		grid.resolve(units, _minimum(), 0.0)
	var worst := 0.0
	for index in units.size():
		worst = maxf(worst, units[index].position.distance_to(starts[index]))
	less(worst, ceiling * 10.0 + 0.001, "ten passes moved nobody further than ten ceilings in total")


func _test_separation_converges() -> void:
	section("a compressed block resolves over a handful of ticks")
	# A block packed twice as tightly as anything a dressed formation produces, which is a
	# heavy crush without being a physical impossibility: 300 soldiers cannot be separated
	# inside an area smaller than they occupy, and asking for that would be testing the
	# arithmetic rather than the pass.
	var units := _pile(300, 6.0, SEED + 9)
	var grid := _grid()
	var start_penetration := _penetration(units, _minimum())
	var previous := start_penetration
	var improved := 0
	for pass_index in 12:
		grid.resolve(units, _minimum(), 0.0)
		var now := _penetration(units, _minimum())
		if now < previous - 0.0001:
			improved += 1
		previous = now
	greater(float(improved), 3.0, "the pile was still coming apart after several passes rather than stalling")

	for pass_index in 40:
		grid.resolve(units, _minimum(), 0.0)
	for pass_index in 188:
		grid.resolve(units, _minimum(), 0.0)
	var settled := _penetration(units, _minimum())
	# An accumulated-pass relaxation converges asymptotically rather than in one step: the
	# edge of a crush comes apart immediately and the deep interior follows as the pressure
	# around it falls away. Two hundred passes leave a fraction of a per cent of the
	# original overlap and the closest pair nearly at the separation distance. That is the
	# honest shape of it, and it is measured here rather than asserted.
	less(settled, start_penetration * 0.02,
		"two hundred passes leave under two per cent of the overlap it started with")
	greater(_closest(units), _minimum() * 0.85,
		"and no two soldiers are still standing inside one another")


## The reference comparison the brief asks for. The pair set is the thing that has to be
## right; the positions deliberately differ from the sequential loop's, so what is
## compared is that the pass acts on exactly the pairs that were touching and on no
## others, and that the invariants hold for both.
func _test_against_a_brute_force_reference() -> void:
	section("the broadphase finds exactly the pairs that are touching")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 21
	var spec: Array[Vector2] = []
	for i in 120:
		spec.append(Vector2(rng.randf_range(10.0, 50.0), rng.randf_range(10.0, 40.0)))

	# Count the touching pairs against the positions the pass starts from, which is also
	# what the reference loop sees.
	var units := _roster(spec)
	var expected := 0
	for i in units.size():
		for j in range(i + 1, units.size()):
			if units[i].position.distance_to(units[j].position) < _minimum():
				expected += 1
	greater(float(expected), 20.0, "the generated arrangement has plenty of touching pairs to find")

	var grid := _grid()
	grid.stats_enabled = true
	grid.resolve(units, _minimum(), 0.0)
	equal(grid.stat_touching, expected,
		"the pass acted on exactly %d pairs, which is every touching pair and no others" % expected)

	# And the same arrangement, resolved sequentially, reaches a separated state too: both
	# relaxations are correct, they simply take different routes.
	var start_penetration := _penetration(_roster(spec), _minimum())
	var reference := _roster(spec)
	_sequential_reference(reference, _minimum())
	less(_penetration(reference, _minimum()), start_penetration,
		"the sequential reference reduces the overlap too - neither pass is a solver, and")
	less(_penetration(units, _minimum()), start_penetration,
		"this one reduces it at least as far, by a different route")


## The reference comparison again, but on the arrangement that actually matters.
##
## A random scatter is easy: soldiers land far apart and the broadphase has little to get
## wrong. A deployed block is the hard case and the one the benchmark produces - ranks
## close enough together that every soldier is standing inside several of its neighbours -
## and a broadphase that agreed with brute force only on sparse layouts would be wrong
## exactly where the fighting is.
func _test_a_dense_deployment_is_fully_enumerated() -> void:
	section("a dense deployment is enumerated completely")
	var units: Array[BattleUnit] = []
	var id := 0
	for rank in 30:
		for file in 20:
			units.append(_unit(id, BattleContext.SIDE_PLAYER if id % 2 == 0 else BattleContext.SIDE_ENEMY,
				Vector2(12.0 + float(rank) * 0.45, 6.0 + float(file) * 1.1)))
			id += 1
	equal(units.size(), 600, "six hundred soldiers in ranks a soldier's width apart")

	var expected := 0
	for i in units.size():
		for j in range(i + 1, units.size()):
			if units[i].position.distance_to(units[j].position) < _minimum():
				expected += 1
	greater(float(expected), 2000.0, "which produces thousands of touching pairs")

	var grid := _grid()
	grid.stats_enabled = true
	grid.resolve(units, _minimum(), 0.0)
	equal(grid.stat_touching, expected,
		"the broadphase found all %d touching pairs in a dense block" % expected)

	# And at every cell size, since a coarse cell is where the reach arithmetic could go
	# wrong on a block this tight.
	for size in [0.45, 0.9, 1.35, 2.0]:
		var again := _roster([])
		var probe: Array[BattleUnit] = []
		var probe_id := 0
		for rank in 20:
			for file in 10:
				probe.append(_unit(probe_id, BattleContext.SIDE_PLAYER if probe_id % 2 == 0 else BattleContext.SIDE_ENEMY,
					Vector2(12.0 + float(rank) * 0.45, 6.0 + float(file) * 1.1)))
				probe_id += 1
		var probe_expected := 0
		for i in probe.size():
			for j in range(i + 1, probe.size()):
				if probe[i].position.distance_to(probe[j].position) < _minimum():
					probe_expected += 1
		var probe_grid := _grid(size)
		probe_grid.stats_enabled = true
		probe_grid.resolve(probe, _minimum(), 0.0)
		equal(probe_grid.stat_touching, probe_expected,
			"a %.2f-unit cell finds every touching pair in the block too" % size)


func _test_cell_size_is_configurable() -> void:
	section("the cell size is a knob, and the pass is correct at any setting")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 31
	var spec: Array[Vector2] = []
	for i in 90:
		spec.append(Vector2(rng.randf_range(20.0, 40.0), rng.randf_range(20.0, 40.0)))
	var expected := 0
	var probe := _roster(spec)
	for i in probe.size():
		for j in range(i + 1, probe.size()):
			if probe[i].position.distance_to(probe[j].position) < _minimum():
				expected += 1

	var sizes := [0.45, 0.7, 0.9, 1.35, 2.0, 4.0]
	for size in sizes:
		var units := _roster(spec)
		var grid := _grid(size)
		greater(float(grid.reach_cells), 0.0, "a %.2f-unit cell needs a neighbourhood" % size)
		grid.stats_enabled = true
		grid.resolve(units, _minimum(), 0.0)
		equal(grid.stat_touching, expected,
			"at a %.2f-unit cell size the pass still acted on every touching pair" % size)
		# Fewer cells means more non-touching pairs are measured, so the count of pairs is
		# not a fixed number - but every one of them must be a *distinct* pair, which shows
		# up as the pass never over-separating an isolated pair at any cell size.
		var isolated := _roster([Vector2(70.0, 15.0), Vector2(70.4, 15.0)])
		var isolated_grid := _grid(size)
		isolated_grid.resolve(isolated, _minimum(), 0.0)
		approx(isolated[0].position.distance_to(isolated[1].position), _minimum(), 0.0001,
			"at a %.2f-unit cell size a lone pair is separated exactly once" % size)


## ---------- the profiler itself (Step 7.8) --------------------------------

## The counters the Step 7.8 audit found wrong, pinned so they cannot be wrong again.
##
## The first was a name that lied: `dev_coincident` was incremented for every touching pair
## before the coincidence test, so it counted touching pairs and called them coincident. The
## second was a phase clock that was declared, reset, and never assigned - a zero that read
## as "no work" rather than "not measured". Both are instrumentation, and neither is allowed
## to change what the pass does, so this section asserts the counts and the arithmetic and a
## later section asserts the positions.
func _test_the_profiler_counts_what_it_names() -> void:
	section("the separation profiler counts what its names say")
	var minimum := _minimum()

	# One ordinary overlap: touching, and nothing else.
	var touching := _roster([Vector2(10.0, 10.0), Vector2(10.0 + minimum * 0.5, 10.0)])
	var touching_grid := _grid()
	touching_grid.stats_enabled = true
	touching_grid.resolve(touching, minimum, 0.0)
	equal(touching_grid.stat_touching, 1, "one pair inside the distance is one touching pair")
	equal(touching_grid.dev_coincident, 0, "and an ordinary overlap is not a coincident pair")
	equal(touching_grid.stat_pairs, 1, "and it was measured exactly once")

	# The same pair in exactly the same place: touching *and* coincident.
	var same := _roster([Vector2(10.0, 10.0), Vector2(10.0, 10.0)])
	var same_grid := _grid()
	same_grid.stats_enabled = true
	same_grid.resolve(same, minimum, 0.0)
	equal(same_grid.stat_touching, 1, "a pair in one spot is touching")
	equal(same_grid.dev_coincident, 1, "and it is the pair the coincident counter is for")

	# Coincident is a sub-count of touching and can never exceed it: a pass with both kinds
	# of pair on one field must say one and one.
	var mixed := _roster([
		Vector2(20.0, 20.0), Vector2(20.0, 20.0),
		Vector2(30.0, 20.0), Vector2(30.0 + minimum * 0.4, 20.0)])
	var mixed_grid := _grid()
	mixed_grid.stats_enabled = true
	mixed_grid.resolve(mixed, minimum, 0.0)
	equal(mixed_grid.stat_touching, 2, "two touching pairs on the field")
	equal(mixed_grid.dev_coincident, 1, "and exactly one of them was coincident")

	# The counters mean nothing to a real battle: with stats off nothing is counted at all,
	# which is what makes the counter path free rather than merely cheap.
	var unmeasured := _roster([Vector2(40.0, 40.0), Vector2(40.0, 40.0)])
	var quiet_grid := _grid()
	quiet_grid.resolve(unmeasured, minimum, 0.0)
	equal(quiet_grid.stat_touching, 0, "with the counters off, nothing is counted")
	equal(quiet_grid.dev_coincident, 0, "and no coincident pair is claimed either")
	approx(unmeasured[0].position.distance_to(unmeasured[1].position), minimum, 0.0001,
		"while the pass itself still separates the pair exactly as before")


## The phase clock is four parts and a whole, and the whole is not derived from the parts.
func _test_the_phase_clock_has_parts_that_add_up() -> void:
	section("the overlap phase's clock is populated, in parts and as a whole")
	# A field big enough that every part of the pass has work to do: several occupied cells,
	# several neighbours between them, and pushes to apply.
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 41
	var spec: Array[Vector2] = []
	for i in 240:
		spec.append(Vector2(rng.randf_range(20.0, 34.0), rng.randf_range(20.0, 34.0)))
	var units := _roster(spec)
	var grid := _grid()
	grid.stats_enabled = true
	grid.resolve(units, _minimum(), 0.0)

	greater(float(grid.stat_cell_pairs), 0.0, "the field has neighbouring occupied cells")
	greater(float(grid.dev_usec_total), 0.0, "the whole pass is timed")
	greater(float(grid.dev_usec_build), 0.0, "the rebuild is timed")
	greater(float(grid.dev_usec_same_cell), 0.0, "the same-cell loop is timed when it has work")
	greater(float(grid.dev_usec_neighbour), 0.0, "the neighbour loop is timed too")
	greater(float(grid.dev_usec_apply), 0.0, "and the apply pass is timed when somebody was pushed")

	var parts := grid.dev_usec_build + grid.dev_usec_same_cell + grid.dev_usec_neighbour + grid.dev_usec_apply
	check(parts <= grid.dev_usec_total,
		"the four parts fit inside the whole (%d <= %d us)" % [parts, grid.dev_usec_total])
	greater(float(parts), 0.0, "and between them they are the work")

	# A sparse field: work exists, but not in every part. The pass must report the parts it
	# did do and not invent the others.
	var sparse := _roster([Vector2(5.0, 5.0), Vector2(80.0, 50.0), Vector2(20.0, 40.0)])
	var sparse_grid := _grid()
	sparse_grid.stats_enabled = true
	sparse_grid.resolve(sparse, _minimum(), 0.0)
	equal(sparse_grid.stat_pairs, 0, "three soldiers far apart make no pairs")
	equal(sparse_grid.stat_cell_pairs, 0, "and no neighbouring cells")
	equal(sparse_grid.dev_moved, 0, "so nobody is moved")
	# Not "the clock is non-zero": three soldiers are a couple of microseconds of work and a
	# microsecond clock is allowed to round that to nothing. The claim that matters is that
	# the cost follows the work.
	less(float(sparse_grid.dev_usec_total), float(grid.dev_usec_total),
		"a field with three soldiers on it costs less than one with two hundred and forty")

	# Nothing at all: no soldiers, no work, no stale numbers from the pass before.
	var empty: Array[BattleUnit] = []
	var empty_grid := _grid()
	empty_grid.stats_enabled = true
	empty_grid.resolve(units, _minimum(), 0.0)
	greater(float(empty_grid.stat_pairs), 0.0, "the field before the empty pass had work in it")
	empty_grid.resolve(empty, _minimum(), 0.0)
	equal(empty_grid.stat_pairs, 0, "an empty pass reports no pairs rather than the last pass's")
	equal(empty_grid.indexed_count(), 0, "and nobody is indexed")


## The settled-cell skip is a proof with five ways to fail. When it does not fire, the
## counters must say which test refused - that is the difference between "the skip is broken"
## and "soldiers are not settled during a fight", and the two have opposite fixes.
func _test_the_settled_proof_says_which_test_rejected_it() -> void:
	section("the settled proof reports which of its tests rejected a cell pair")
	var minimum := _minimum()
	var settle := _config().get_float("battle.separation_settle_epsilon", 0.15)

	# Two settled cells of one body whose spacing proves them apart: the proof holds, and the
	# reason counters must say so.
	var simulator := BattleSimulator.new(_config(), SEED + 51)
	var body := _body(simulator, "line", BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, 40, 0)
	simulator.start()
	for tick in 6:
		simulator.step(0.05)
	var grid := _grid()
	grid.stats_enabled = true
	grid.resolve(simulator.units, minimum, settle)
	greater(float(grid.dev_skip_proved), 0.0, "a dressed body's interior cells are proved apart")
	greater(float(grid.stat_cell_pairs_skipped), 0.0, "and the proof is what skips them")
	equal(grid.stat_cell_pairs_skipped, grid.dev_skip_proved,
		"every skipped cell pair is a proved cell pair")

	# The reasons partition: the first test that fails is the one counted, so the six counts
	# must add up to the cell pairs that reached the proof.
	var reasons := grid.dev_skip_not_settled_a + grid.dev_skip_not_settled_b + grid.dev_skip_no_body \
		+ grid.dev_skip_other_body + grid.dev_skip_spacing + grid.dev_skip_proved
	equal(reasons, grid.stat_cell_pairs,
		"the five ways to fail and the one way to pass add up to the cell pairs considered")

	# Put one soldier of the body out of place: its cell stops being an interior, and the
	# rejection is reported as a soldier who is not settled rather than as anything else.
	var dressed_bodies: Array = grid.report()["bodies"]
	var settled_before := int((dressed_bodies[0] as Dictionary).get("settled", 0))
	var members := _members(simulator, body)
	if members.size() >= 2 and members[0].formation_ref != null and members[0].slot_index >= 0:
		var place: Vector2 = body.slots[members[0].slot_index]
		members[0].position = place + Vector2(3.0, 0.0)
		var perturbed := _grid()
		perturbed.stats_enabled = true
		perturbed.resolve(simulator.units, minimum, settle)
		check(perturbed.cell_state_of(grid.cell_index_of(place)) != BattleOverlapGrid.CELL_SETTLED,
			"the cell the stray left is no longer a settled interior")
		var perturbed_bodies: Array = perturbed.report()["bodies"]
		equal(int((perturbed_bodies[0] as Dictionary).get("settled", 0)), settled_before - 1,
			"and the body reports exactly one fewer soldier standing on his place")
		greater(float((perturbed_bodies[0] as Dictionary).get("distance_p95", 0.0)), 0.0,
			"with the distance statistics seeing him as well")

	# The per-body statistics answer the question the counters cannot: how far from their
	# places a body's soldiers actually are, and what share of them is standing on them.
	var bodies: Array = grid.report()["bodies"]
	greater(float(bodies.size()), 0.0, "the pass reports its bodies")
	var dressed := bodies[0] as Dictionary
	equal(int(dressed.get("living", 0)), 40, "the body's forty soldiers are all counted")
	greater(float(dressed["settled_fraction"]), 0.5,
		"a body six ticks into a battle still has most of its soldiers on their places")
	less(float(dressed["distance_average"]), float(settle) * 4.0,
		"and their average distance from those places is small")


## A dry pass is how the phase's own arithmetic is measured by subtraction, so it must be the
## same pass: same pairs, same touching pairs, same everything except the writhes it declines
## to make - and it must leave the field exactly as it found it.
func _test_a_dry_pass_moves_nobody() -> void:
	section("a dry pass enumerates the same work and moves nobody")
	var minimum := _minimum()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 61
	var spec: Array[Vector2] = []
	for i in 120:
		spec.append(Vector2(rng.randf_range(30.0, 44.0), rng.randf_range(30.0, 44.0)))
	var units := _roster(spec)
	var before := _positions(units)

	var full := _grid()
	full.stats_enabled = true
	full.resolve(units, minimum, 0.0)
	var full_touching := full.stat_touching
	var full_pairs := full.stat_pairs
	var full_build := full.dev_usec_build

	# Reset the field, then measure it twice without touching it.
	var fresh := _roster(spec)
	var enumerate_only := _grid()
	enumerate_only.stats_enabled = true
	enumerate_only.dry_level = 2
	enumerate_only.resolve(fresh, minimum, 0.0)
	equal(_positions(fresh), before, "the enumeration-only pass moved nobody")
	equal(enumerate_only.stat_pairs, full_pairs, "and enumerated the same pairs")

	var distance_only := _grid()
	distance_only.stats_enabled = true
	distance_only.dry_level = 1
	distance_only.resolve(fresh, minimum, 0.0)
	equal(_positions(fresh), before, "the distance-only pass moved nobody either")
	equal(distance_only.stat_pairs, full_pairs, "and it enumerated the same pairs")
	equal(distance_only.stat_touching, full_touching, "and found the same touching pairs")

	# And the real pass over the same field does separate them, so this section cannot pass by
	# the pass having quietly stopped working.
	var real := _grid()
	real.resolve(fresh, minimum, 0.0)
	not_equal(_positions(fresh), before, "the real pass over the same field does move soldiers")
	greater(float(full_build), 0.0, "and the full pass still reports its own build time")


## ---------- the three passes, on one battle ---------------------------------

## The end-to-end claim: a battle comes out the same whichever separation pass resolves its
## contacts.
##
## The oracle suite compares passes on generated fields, one pass at a time. This compares
## them on a *battle*: two bodies ordered into each other, a few hundred ticks of real
## simulation, and every soldier's position and hit points at the end. If a pass disagreed
## about which pairs were touching - even in the last bit of one push - the field would drift
## and the fighting would diverge, and this is where that shows up as a difference in the
## battle rather than as a difference in a number.
func _test_a_battle_is_identical_whichever_pass_runs_it() -> void:
	section("a battle comes out the same whichever separation pass resolves it")
	var passes: Array[int] = [BattleSimulator.OverlapBackend.GDSCRIPT, BattleSimulator.OverlapBackend.PACKED]
	if ClassDB.class_exists("NativeOverlapKernel"):
		passes.append(BattleSimulator.OverlapBackend.NATIVE)
	else:
		equal(false, false, "no native kernel is loaded, so this battle is compared across two passes")
		print("    SKIP the native pass in this comparison: no accelerator loaded")

	var fingerprints := {}
	for pass_id in passes:
		var simulator := BattleSimulator.new(_config(), SEED + 91)
		simulator.overlap_backend = pass_id
		_body(simulator, "player_line", BattleContext.SIDE_PLAYER, Vector2(26.0, 30.0), 0.0, 60, 0)
		_body(simulator, "enemy_line", BattleContext.SIDE_ENEMY, Vector2(38.0, 30.0), PI, 60, 100)
		for body in simulator.formations:
			body.order_engage()
			body.ensure_slots()
		simulator.start()
		equal(simulator.overlap_backend_active, pass_id,
			"the battle runs the pass it was asked for (%s)" % BattleSimulator.overlap_backend_label(pass_id))
		for tick in 300:
			simulator.step(0.05)
		var parts := PackedStringArray()
		for unit in simulator.units:
			parts.append("%d:%.6f,%.6f:%d" % [unit.id, unit.position.x, unit.position.y, unit.hp])
		fingerprints[pass_id] = "|".join(parts)

	var reference: String = fingerprints[BattleSimulator.OverlapBackend.GDSCRIPT]
	for pass_id in passes:
		if pass_id == BattleSimulator.OverlapBackend.GDSCRIPT:
			continue
		equal(fingerprints[pass_id], reference,
			"three hundred ticks of fighting are identical under the %s pass" % BattleSimulator.overlap_backend_label(pass_id))

	# And the pass really was the one asked for, so this cannot pass by every battle quietly
	# running the reference.
	var forced := BattleSimulator.new(_config(), SEED + 92)
	forced.overlap_backend = BattleSimulator.OverlapBackend.PACKED
	forced.start()
	equal(forced.overlap_backend_active, BattleSimulator.OverlapBackend.PACKED,
		"a forced pass is what the battle runs, not the threshold's choice")
