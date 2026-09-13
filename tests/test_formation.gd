extends TestCase
## Step 7: formations as physical objects.
##
## The properties worth holding on to, and what each one is really guarding:
## [br]- geometry is generated, not tabulated, so arbitrary facings work;
## [br]- slots are deterministic, so a reformation is reproducible;
## [br]- a formation moves as a body, and its soldiers walk rather than teleport;
## [br]- reformation and turning are things that take time, and cohesion measures how
##   far through that process a body is.

const SEED := 70702


func run() -> void:
	await _tick()
	_test_catalog()
	_test_geometry_is_deterministic()
	_test_shape_consequences()
	_test_slots_are_distinct()
	_test_arbitrary_facing()
	_test_assignment()
	_test_movement_and_slots()
	_test_movement_does_not_teleport()
	_test_turning()
	_test_reformation_is_physical()
	_test_cohesion()
	_test_casualties_leave_gaps()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _catalog() -> FormationCatalog:
	return FormationCatalog.load_from()


func _config() -> GameConfig:
	return GameManager.config()


func _make_unit(id: int, side: String, position: Vector2, speed: float) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_form_%d" % id
	unit.display_name = "Form %d" % id
	unit.max_hp = 100
	unit.hp = 100
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = speed
	unit.attack_range = 0.2
	unit.attack_cooldown = 5.0
	unit.position = position
	return unit


## A body of soldiers standing on an empty field, facing [param facing].
##
## [param placement] is "dressed" (already on their slots), "scattered" (a
## deterministic mess somewhere near the anchor), or "at_anchor" (all piled on the
## centre, the worst possible start for a formation).
func _scenario(
	type_id: String,
	count: int,
	facing: float = 0.0,
	placement: String = "dressed"
) -> Dictionary:
	var config := _config()
	var anchor := Vector2(40.0, 30.0)
	var simulator := BattleSimulator.new(config, 24680)
	var units: Array[BattleUnit] = []
	for i in count:
		units.append(_make_unit(i, BattleContext.SIDE_PLAYER, anchor, 5.0))
	# A stationary enemy, far enough away that nobody swings at anything. Without a
	# target the movement code returns early, so this is what makes the scenario about
	# formation movement and nothing else.
	units.append(_make_unit(900, BattleContext.SIDE_ENEMY, Vector2(95.0, 5.0), 0.0))
	simulator.add_units(units)

	var formation := BattleFormation.create("test_body", BattleContext.SIDE_PLAYER, anchor, facing, type_id, _catalog(), config)
	# Stand fast unless a test orders otherwise. The default stance is to close with the
	# enemy, which would drag every geometry test off its marks.
	formation.order_hold()
	simulator.add_formation(formation)
	var ids: Array[int] = []
	for i in count:
		ids.append(i)
	simulator.assign_formation(formation, ids)

	match placement:
		"dressed":
			for i in count:
				units[i].position = formation.slots[i]
		"scattered":
			for i in count:
				var offset := Vector2(float(i % 5) * 7.0 - 14.0, float(i / 5) * 9.0 - 18.0)
				units[i].position = anchor + offset
		"at_anchor":
			for i in count:
				units[i].position = anchor

	return {"simulator": simulator, "formation": formation, "units": units, "anchor": anchor}


func _run(simulator: BattleSimulator, steps: int, delta: float = 0.05) -> void:
	for i in steps:
		simulator.step(delta)


func _max_slot_error(formation: BattleFormation, units: Array[BattleUnit]) -> float:
	var worst := 0.0
	for i in formation.unit_ids.size():
		var unit := units[formation.unit_ids[i]]
		worst = maxf(worst, unit.position.distance_to(formation.slots[i]))
	return worst


## ---------- the data -----------------------------------------------------

func _test_catalog() -> void:
	section("the formation catalog")
	var catalog := _catalog()
	check(catalog.is_valid(), "the formation types load")
	equal(catalog.load_errors.size(), 0, "with no load errors")
	for required in ["line", "column", "loose"]:
		check(catalog.has(required), "'%s' is defined" % required)
	equal(catalog.order.size(), 3, "and there are exactly three - no speculative shapes")

	greater(float(catalog.max_files("line")), float(catalog.max_files("column")),
		"a line is willing to spread wider than a column")
	greater(float(catalog.spacing_multiplier("loose")), 1.0, "loose stands further apart")
	for id in catalog.order:
		check(not catalog.display_name(id).is_empty(), "%s has a name" % id)
		greater(catalog.turn_rate_deg(id), 0.0, "%s can turn" % id)

	# Future shapes must be addable without touching this catalogue's code: it holds
	# whatever the file says and nothing knows the three names in advance.
	var missing := FormationCatalog.load_from("res://data/formations/nope.json")
	equal(missing.is_valid(), false, "a missing file produces an invalid catalog, not a crash")


## ---------- geometry -----------------------------------------------------

func _test_geometry_is_deterministic() -> void:
	section("slot geometry is deterministic")
	var config := _config()
	var catalog := _catalog()
	for type_id in ["line", "column", "loose"]:
		var a := BattleFormation.create("a", BattleContext.SIDE_PLAYER, Vector2(30.0, 20.0), 0.4, type_id, catalog, config)
		var b := BattleFormation.create("b", BattleContext.SIDE_PLAYER, Vector2(30.0, 20.0), 0.4, type_id, catalog, config)
		var ids_a: Array[int] = []
		var ids_b: Array[int] = []
		for i in 13:
			ids_a.append(i)
			ids_b.append(i)
		a.unit_ids = ids_a
		b.unit_ids = ids_b
		a.ensure_slots()
		b.ensure_slots()
		equal(a.slots, b.slots, "%s: two formations of the same size produce identical slots" % type_id)
		equal(a.file_count, b.file_count, "%s: the same file count" % type_id)
		equal(a.rank_count, b.rank_count, "%s: the same rank count" % type_id)
		equal(a.slots.size(), 13, "%s: one slot per soldier" % type_id)


func _test_shape_consequences() -> void:
	section("shape has physical consequences")
	var config := _config()
	var catalog := _catalog()
	var count := 20

	var line := BattleFormation.create("l", BattleContext.SIDE_PLAYER, Vector2(50.0, 30.0), 0.0, "line", catalog, config)
	var column := BattleFormation.create("c", BattleContext.SIDE_PLAYER, Vector2(50.0, 30.0), 0.0, "column", catalog, config)
	var loose := BattleFormation.create("s", BattleContext.SIDE_PLAYER, Vector2(50.0, 30.0), 0.0, "loose", catalog, config)
	for f in [line, column, loose]:
		var ids: Array[int] = []
		for i in count:
			ids.append(i)
		f.unit_ids = ids
		f.ensure_slots()

	greater(line.frontage(), column.frontage(),
		"a line occupies more frontage than a column (%.1f vs %.1f)" % [line.frontage(), column.frontage()])
	greater(column.depth(), line.depth(),
		"a column occupies more depth than a line (%.1f vs %.1f)" % [column.depth(), line.depth()])
	greater(loose.spacing, line.spacing,
		"loose order stands further apart than line (%.2f vs %.2f)" % [loose.spacing, line.spacing])
	greater(loose.depth(), line.depth(),
		"so the same army in loose order reaches further back than in line")

	# The same army, three shapes, three genuinely different footprints.
	not_equal(line.frontage(), column.frontage(), "line and column are not the same shape relabelled")
	not_equal(line.frontage(), loose.frontage(), "nor are line and loose")

	# A line that fits in a single rank has no depth at all.
	var short_line := BattleFormation.create("sl", BattleContext.SIDE_PLAYER, Vector2(50.0, 30.0), 0.0, "line", catalog, config)
	var short_ids: Array[int] = []
	for i in 6:
		short_ids.append(i)
	short_line.unit_ids = short_ids
	short_line.ensure_slots()
	equal(short_line.rank_count, 1, "six men fit in one rank of a line")
	approx(short_line.depth(), 0.0, 0.001, "and a single-rank line has no depth at all")
	greater(short_line.frontage(), 0.0, "but it does have a front")

	# Every shape holds the same number of soldiers, so the shape is the only variable.
	for f in [line, column, loose]:
		equal(f.slots.size(), count, "%s: the formation is exactly as big as its army" % f.type_id)


func _test_slots_are_distinct() -> void:
	section("no two soldiers are given the same place")
	var config := _config()
	var catalog := _catalog()
	for type_id in ["line", "column", "loose"]:
		for count in [1, 2, 7, 20, 37]:
			var f := BattleFormation.create("d", BattleContext.SIDE_PLAYER, Vector2(25.0, 25.0), 0.9, type_id, catalog, config)
			var ids: Array[int] = []
			for i in count:
				ids.append(i)
			f.unit_ids = ids
			f.ensure_slots()
			equal(f.slots.size(), count, "%s/%d: the right number of slots" % [type_id, count])
			var duplicates := 0
			for i in f.slots.size():
				for j in range(i + 1, f.slots.size()):
					if f.slots[i].distance_to(f.slots[j]) < 0.0001:
						duplicates += 1
			equal(duplicates, 0, "%s/%d: every slot is its own place" % [type_id, count])


func _test_arbitrary_facing() -> void:
	section("geometry rotates with facing, at any angle")
	var config := _config()
	var catalog := _catalog()
	# Not just the two directions deployment happens to use.
	for degrees in [0.0, 37.0, 90.0, 143.5, 180.0, -61.0, 270.0]:
		var angle := deg_to_rad(degrees)
		var f := BattleFormation.create("r", BattleContext.SIDE_PLAYER, Vector2(60.0, 30.0), angle, "line", catalog, config)
		var ids: Array[int] = []
		for i in 8:
			ids.append(i)
		f.unit_ids = ids
		f.ensure_slots()

		# Two soldiers in the same rank are exactly one spacing apart, along the
		# formation's own width - not along a world axis.
		var along_width := f.slots[1] - f.slots[0]
		approx(along_width.length(), f.spacing, 0.001, "%d deg: neighbours are one spacing apart" % int(degrees))
		approx(along_width.angle(), f.right_vector().angle(), 0.001,
			"%d deg: and the rank runs along the formation's own width" % int(degrees))

		# The anchor is the centre: the soldiers' average position is the anchor.
		var total := Vector2.ZERO
		for slot in f.slots:
			total += slot
		var centre := total / float(f.slots.size())
		less(centre.distance_to(f.anchor), 0.001, "%d deg: the anchor is the body's centre" % int(degrees))

		# Rotating must actually move the places, not merely relabel them.
		var before := f.slots.duplicate()
		f.set_facing(angle + PI * 0.5)
		f.ensure_slots()
		var moved := 0
		for i in f.slots.size():
			if f.slots[i].distance_to(before[i]) > 0.01:
				moved += 1
		greater(float(moved), 0.0, "%d deg: turning moved the slots" % int(degrees))


## ---------- assignment ---------------------------------------------------

func _test_assignment() -> void:
	section("slot assignment")
	var scenario := _scenario("line", 12, 0.0, "scattered")
	var simulator: BattleSimulator = scenario["simulator"]
	var formation: BattleFormation = scenario["formation"]
	var units: Array[BattleUnit] = scenario["units"]

	equal(formation.unit_ids.size(), 12, "the body holds the soldiers it was given")
	var seen := {}
	var shared := 0
	for i in formation.unit_ids.size():
		var unit := units[formation.unit_ids[i]]
		equal(unit.slot_index, i, "soldier %d knows its own place" % unit.id)
		equal(unit.formation_ref, formation, "and knows which body it belongs to")
		equal(unit.is_formed(), true, "so it counts as formed")
		equal(formation.slot_index_of(unit.id), i, "and the body agrees")
		if seen.has(i):
			shared += 1
		seen[i] = true
	equal(shared, 0, "no place is given to two soldiers")

	# Assigning the same list again changes nothing - a reformation must not reshuffle
	# soldiers who were already in the right order.
	var ids_before := formation.unit_ids.duplicate()
	var slots_before := formation.slots.duplicate()
	var assign_again: Array[int] = []
	for i in 12:
		assign_again.append(i)
	simulator.assign_formation(formation, assign_again)
	equal(formation.unit_ids, ids_before, "re-assigning the same soldiers keeps the same order")
	equal(formation.slots, slots_before, "and the same places")

	# Removing a soldier releases its place and does not disturb the rest.
	var removed := formation.unit_ids[3]
	formation.remove_unit(removed)
	equal(formation.unit_ids.size(), 11, "removing a soldier shrinks the body")
	equal(formation.has_unit(removed), false, "and it is gone from the rolls")

	# A unit that is not on the field must not break anything.
	var stranger := BattleFormation.create("stranger", BattleContext.SIDE_PLAYER, Vector2.ZERO, 0.0, "line", _catalog(), _config())
	stranger.unit_ids = [4242]
	stranger.ensure_slots()
	stranger.update_cohesion(simulator.units_by_id(), 8.0)
	equal(stranger.cohesion, 0.0, "a body of soldiers who do not exist has no cohesion, and no crash")


## ---------- movement -----------------------------------------------------

func _test_movement_and_slots() -> void:
	section("a formation moves, and its places move with it")
	var scenario := _scenario("line", 10, 0.0, "dressed")
	var simulator: BattleSimulator = scenario["simulator"]
	var formation: BattleFormation = scenario["formation"]
	var anchor: Vector2 = scenario["anchor"]

	var slots_before := formation.slots.duplicate()
	equal(formation.is_moving(), false, "a body with no order is not moving")

	formation.order_move_to(anchor + Vector2(24.0, 0.0))
	equal(formation.is_moving(), true, "once told to move, it is moving")
	simulator.start()
	simulator.step(0.05)

	greater(formation.anchor.distance_to(anchor), 0.0, "the centre moved")
	greater(float(formation.slots[0].distance_to(slots_before[0])), 0.0,
		"and every place it hands out moved with it")

	# The body advances at the pace of its slowest soldier, so the ranks are never
	# left behind by their own formation.
	_run(simulator, 200)
	less(formation.anchor.distance_to(anchor + Vector2(24.0, 0.0)), 2.0,
		"the body reached where it was sent")
	equal(formation.order, BattleFormation.ORDER_HOLD, "and stopped when it got there")

	_run(simulator, 60)
	less(_max_slot_error(formation, scenario["units"]), 0.6,
		"and its soldiers are standing on the places they were given")


func _test_movement_does_not_teleport() -> void:
	section("nobody is teleported")
	var scenario := _scenario("line", 10, 0.0, "scattered")
	var simulator: BattleSimulator = scenario["simulator"]
	var formation: BattleFormation = scenario["formation"]
	var units: Array[BattleUnit] = scenario["units"]
	var config := _config()

	var delta := 0.05
	var fastest := 0.0
	for i in 10:
		fastest = maxf(fastest, units[i].move_speed)
	# The most a soldier could possibly move in one step, given the slowest ground.
	var allowance := fastest * delta * 1.05

	var before: Array[Vector2] = []
	for i in 10:
		before.append(units[i].position)

	simulator.start()
	simulator.step(delta)

	var jumped := 0
	for i in 10:
		if units[i].position.distance_to(before[i]) > allowance:
			jumped += 1
	equal(jumped, 0, "no soldier moved further in one step than its legs allow")

	# A reformation is not an exception: changing shape must also be walked. Take the
	# baseline immediately before the order, so a step taken earlier cannot be mistaken
	# for the reformation moving somebody.
	simulator.step(delta)
	var before_reform: Array[Vector2] = []
	for i in 10:
		before_reform.append(units[i].position)
	var slots_before := formation.slots.duplicate()
	formation.set_type("column")
	formation.ensure_slots()
	var moved_by_the_order := 0
	for i in 10:
		if units[i].position.distance_to(before_reform[i]) > 0.001:
			moved_by_the_order += 1
	equal(moved_by_the_order, 0, "giving a new shape does not move a single soldier by itself")
	greater(float(formation.slots[0].distance_to(slots_before[0])), 0.0, "only the places moved")

	simulator.step(delta)
	var jumped_after_reform := 0
	for i in 10:
		if units[i].position.distance_to(before_reform[i]) > allowance * 3.0:
			jumped_after_reform += 1
	equal(jumped_after_reform, 0, "and they walk to the new shape at walking pace")


func _test_turning() -> void:
	section("a formation turns rather than snapping round")
	var scenario := _scenario("line", 8, 0.0, "dressed")
	var simulator: BattleSimulator = scenario["simulator"]
	var formation: BattleFormation = scenario["formation"]
	var units: Array[BattleUnit] = scenario["units"]

	equal(formation.is_turning(), false, "a body with no facing order is not turning")

	var facing_before := formation.facing
	var positions_before: Array[Vector2] = []
	for i in 8:
		positions_before.append(units[i].position)

	# Turn about - not merely from left to right.
	formation.order_face(deg_to_rad(120.0))
	equal(formation.is_turning(), true, "once told to face elsewhere, it is turning")
	equal(formation.facing, facing_before, "but its facing has not changed yet")

	simulator.start()
	simulator.step(0.05)
	not_equal(formation.facing, facing_before, "it has begun to turn")
	greater(absf(formation.facing - facing_before), 0.0, "in the right direction")
	less(absf(formation.facing - deg_to_rad(120.0)), absf(facing_before - deg_to_rad(120.0)),
		"and it is closer to where it was told to face than it was")

	var snapped := 0
	for i in 8:
		if units[i].position.distance_to(positions_before[i]) > 5.0 * 0.05 * 1.05:
			snapped += 1
	equal(snapped, 0, "and no soldier was spun round with it")

	# Given time, it arrives - and its places rotate with it.
	_run(simulator, 120)
	equal(formation.is_turning(), false, "the turn finished")
	approx(formation.facing, deg_to_rad(120.0), 0.01, "facing where it was told to face")
	var along_width := formation.slots[1] - formation.slots[0]
	approx(along_width.angle(), formation.right_vector().angle(), 0.001,
		"and its ranks now run along the new width")


## ---------- reformation --------------------------------------------------

func _test_reformation_is_physical() -> void:
	section("changing shape is something the soldiers do")
	var scenario := _scenario("line", 16, 0.0, "dressed")
	var simulator: BattleSimulator = scenario["simulator"]
	var formation: BattleFormation = scenario["formation"]
	var units: Array[BattleUnit] = scenario["units"]

	equal(formation.type_id, "line", "the body starts as a line")
	equal(formation.file_count, 10, "ten men wide")
	equal(formation.rank_count, 2, "two ranks deep")
	var line_slots := formation.slots.duplicate()
	var line_frontage := formation.frontage()

	# Let it settle as a line first.
	_run(simulator, 40)
	equal(formation.is_stable(), true, "the line is steady")
	greater(formation.cohesion, 0.9, "and dressed")

	formation.set_type("column")
	equal(formation.type_id, "column", "the order was taken")
	equal(formation.is_reforming(), true, "and the body knows it is out of order")
	equal(formation.is_stable(), false, "so it is not steady")

	formation.ensure_slots()
	equal(formation.file_count, 2, "a column is two men wide")
	equal(formation.rank_count, 8, "and eight deep")
	less(formation.frontage(), line_frontage, "with a much narrower front")
	not_equal(formation.slots, line_slots, "and completely different places to stand")

	# The soldiers have not moved yet, so they are now badly out of place.
	equal(formation.unit_ids.size(), 16, "every soldier is still in the body")
	greater(_max_slot_error(formation, units), 3.0, "and every one of them is out of position")
	var cohesion_at_order := formation.cohesion

	simulator.start()
	_run(simulator, 6)
	less(formation.cohesion, cohesion_at_order + 0.0001,
		"cohesion does not go up the instant a new shape is ordered")

	# Given time they walk into the column and dress.
	_run(simulator, 400)
	less(_max_slot_error(formation, units), 0.8, "the soldiers found their new places")
	greater(formation.cohesion, 0.85, "and the body is dressed again")
	equal(formation.is_reforming(), false, "so the reformation is over")
	equal(formation.is_stable(), true, "and it is steady")

	# What actually changed is the shape, not the army.
	equal(formation.unit_ids.size(), 16, "no soldier was lost in the change")
	# Depth is measured along the way the body faces, which is not a world axis.
	var fwd := formation.forward()
	var span := 0.0
	for slot in formation.slots:
		span = maxf(span, absf((slot - formation.anchor).dot(fwd)))
	greater(span, formation.spacing * 2.0, "and the body is now genuinely deep")


func _test_cohesion() -> void:
	section("cohesion measures how well the shape is being held")
	var scenario := _scenario("line", 12, 0.0, "dressed")
	var simulator: BattleSimulator = scenario["simulator"]
	var formation: BattleFormation = scenario["formation"]
	var units: Array[BattleUnit] = scenario["units"]

	simulator.start()
	simulator.step(0.05)
	greater(formation.cohesion, 0.9, "soldiers standing on their places are at high cohesion")
	less(formation.cohesion, 1.0001, "and never above one")

	# Scatter them and the number falls.
	for i in 12:
		units[i].position = formation.anchor + Vector2(float(i % 4) * 14.0 - 21.0, float(i / 4) * 16.0 - 16.0)
	simulator.step(0.05)
	less(formation.cohesion, 0.5, "scattering the same soldiers drops it sharply")

	# Put them back and it recovers, without anyone being told to do anything.
	for i in 12:
		units[i].position = formation.slots[i]
	simulator.step(0.05)
	greater(formation.cohesion, 0.9, "and putting them back raises it again")

	# A body with no soldiers has nothing to measure.
	var empty := BattleFormation.create("empty", BattleContext.SIDE_PLAYER, Vector2.ZERO, 0.0, "line", _catalog(), _config())
	empty.update_cohesion(simulator.units_by_id(), 8.0)
	equal(empty.cohesion, 1.0, "an empty formation reports full cohesion rather than a division by zero")


func _test_casualties_leave_gaps() -> void:
	section("a casualty leaves a gap in the line")
	var scenario := _scenario("line", 12, 0.0, "dressed")
	var simulator: BattleSimulator = scenario["simulator"]
	var formation: BattleFormation = scenario["formation"]
	var units: Array[BattleUnit] = scenario["units"]

	simulator.start()
	simulator.step(0.05)
	var cohesion_before := formation.cohesion
	var slots_before := formation.slots.duplicate()

	# Two soldiers fall.
	units[2].take_damage(99999, -1)
	units[7].take_damage(99999, -1)
	simulator.step(0.05)

	equal(formation.unit_ids.size(), 12,
		"the fallen keep their places on the roll, so the line does not shuffle")
	equal(formation.slots, slots_before, "and everyone else is still told to stand where they were")
	less(formation.cohesion, cohesion_before + 0.0001,
		"the body is less formed for having lost two men out of it")

	# The survivors carry on holding their shape.
	for i in 12:
		if units[i].is_alive():
			units[i].position = formation.slots[i]
	simulator.step(0.05)
	greater(formation.cohesion, 0.9,
		"the remaining ten can still hold a dressed line - the gap is a gap, not a rout")
