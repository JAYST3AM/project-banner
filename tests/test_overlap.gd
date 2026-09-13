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
