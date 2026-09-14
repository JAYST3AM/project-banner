extends TestCase
## Step 7.8: the separation pass's candidates against the locked reference.
##
## [b]Why generated states rather than examples.[/b] The reference pass is the oracle: it has
## shipped since Step 7.3 and every battle, every benchmark and every other test in this
## project is measured against it. A candidate that claims to be the same algorithm with a
## different memory layout does not get to argue that it is equivalent - it gets handed the
## same state as the reference and has to produce the same field.
##
## The states below are generated rather than hand-written, and cover the cases where a
## rewrite of a hot loop is most likely to differ: sparse and dense layouts, clusters, both
## cell cases (inside one cell, across neighbouring cells), cell corners, battlefield edges,
## units exactly on top of one another, one body, two friendly bodies, enemies in contact,
## loose troops, troops standing on their marks and troops shoved off them, the dead, and the
## two arrangements that put several bodies through each other at once.
##
## [b]What "the same" means here.[/b] Both passes see identical input - the same count, the
## same positions, the same bodies, the same slots - from separate [BattleUnit] objects, and
## the comparison is on the field they produce: every soldier's position to the last bit, and
## the counters that say what work was done to get there. Not "close enough": equal.
##
## [b]Every generated state is deterministic.[/b] One seed, one generator, and the same
## states every run, so a failure is reproducible from the seed printed with it.

const ORACLE_SEED := 78081
const GENERATED_STATES := 1500
## The native section runs fewer states: the same generator, the same comparison, and one
## boundary crossing per state instead of none. Enough to cover every shape many times over
## without making the suite about the bridge.
const NATIVE_STATES := 600

var _reference_minimum := 1.35
## Loaded once: the generator materialises thousands of bodies and re-reading the catalog
## file for each of them would make the suite about JSON parsing.
var _catalog: FormationCatalog = null


func run() -> void:
	await _tick()
	_test_named_arrangements()
	_test_generated_states()
	_test_the_oracle_finds_the_cases_it_claims_to()
	_test_the_native_pass_matches_the_reference()
	_test_the_boundary_is_timed()
	_test_compare_mode_sees_the_same_battle()
	_complete()


func _config() -> GameConfig:
	return GameManager.config()


func _run_native(units: Array[BattleUnit], settle: float) -> Dictionary:
	var grid := BattleOverlapNative.new()
	grid.configure(Vector2(100.0, 60.0), _config().get_float("battle.overlap_cell_size", 1.35))
	grid.max_push = _config().get_float("battle.max_separation_push", 1.35)
	grid.stats_enabled = true
	grid.resolve(units, _minimum(), settle)
	return grid.report()


func _minimum() -> float:
	return _config().get_float("battle.separation_radius", 1.5) * BattleSimulator.SEPARATION_FACTOR


func _settle() -> float:
	return _config().get_float("battle.separation_settle_epsilon", 0.15)


## ---------- fixtures ------------------------------------------------------

## One body's worth of members: which slots they stand on, and whether they are standing on
## them. A "loose" body is a body whose soldiers are nowhere near their marks.
class BodySpec:
	var id: String = ""
	var side: String = BattleContext.SIDE_PLAYER
	var anchor: Vector2 = Vector2.ZERO
	var facing: float = 0.0
	var shape: String = "line"
	var members: Array[int] = []
	var settle: bool = true
	var jitter: float = 0.0
	var radius: float = 0.0

	func _init(p_id: String = "", p_side: String = BattleContext.SIDE_PLAYER, p_anchor: Vector2 = Vector2.ZERO,
			p_facing: float = 0.0, p_shape: String = "line") -> void:
		id = p_id
		side = p_side
		anchor = p_anchor
		facing = p_facing
		shape = p_shape


## A whole state: units by id, where they stand, whether they are alive, and the bodies that
## claim them.
class StateSpec:
	var label: String = ""
	var positions: Dictionary = {}
	var sides: Dictionary = {}
	var alive: Dictionary = {}
	var bodies: Array = []
	var free: Array[int] = []


func _unit(id: int, side: String, position: Vector2, alive: bool = true) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_oracle_%d" % id
	unit.display_name = "Oracle %d" % id
	unit.max_hp = 60
	unit.hp = 60 if alive else 0
	unit.alive = alive
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = 5.0
	unit.attack_range = 2.0
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


## Materialise a state twice: two independent sets of units and bodies with identical
## numbers, so the two passes cannot influence each other through shared objects.
func _materialise(spec: StateSpec) -> Array:
	var roster: Array[BattleUnit] = []
	var ids: Array = spec.positions.keys()
	ids.sort()
	for id in ids:
		roster.append(_unit(int(id), str(spec.sides[id]), spec.positions[id], bool(spec.alive[id])))
	var bodies: Array[BattleFormation] = []
	if _catalog == null:
		_catalog = FormationCatalog.load_from()
	var catalog := _catalog
	for raw in spec.bodies:
		var body_spec := raw as BodySpec
		var body := BattleFormation.create(body_spec.id, body_spec.side, body_spec.anchor,
			body_spec.facing, body_spec.shape, catalog, _config())
		body.set_units(body_spec.members)
		body.ensure_slots()
		for i in body_spec.members.size():
			for unit in roster:
				if unit.id != body_spec.members[i]:
					continue
				unit.formation_ref = body
				unit.slot_index = i
				if body_spec.settle and i < body.slots.size():
					unit.position = body.slots[i]
					if body_spec.jitter > 0.0:
						var offset := Vector2(sin(float(unit.id) * 2.4), cos(float(unit.id) * 1.7))
						unit.position += offset * body_spec.jitter
				break
		bodies.append(body)
	return [roster, bodies]


## Everything a pass did, in one string: what would differ if the two disagreed.
func _digest(units: Array[BattleUnit], report: Dictionary) -> Dictionary:
	return {
		"positions": _positions(units),
		"pairs": int(report.get("pairs", 0)),
		"touching": int(report.get("touching", 0)),
		"cell_pairs": int(report.get("cell_pairs", 0)),
		"skipped": int(report.get("cell_pairs_skipped", 0)),
		"clamped": int(report.get("clamped", 0)),
		"moved": int(report.get("moved_units", 0)),
		"coincident": int(report.get("coincident", 0)),
	}


func _positions(units: Array[BattleUnit]) -> String:
	var parts := PackedStringArray()
	for unit in units:
		parts.append("%d:%.9f,%.9f" % [unit.id, unit.position.x, unit.position.y])
	return "|".join(parts)


## The first soldier the two runs disagree about, with everything needed to say why.
func _first_difference(a: Array[BattleUnit], b: Array[BattleUnit]) -> String:
	for i in mini(a.size(), b.size()):
		if a[i].position.x != b[i].position.x or a[i].position.y != b[i].position.y:
			return "unit %d: reference %.9f,%.9f vs candidate %.9f,%.9f (delta %.9f)" % [
				a[i].id, a[i].position.x, a[i].position.y, b[i].position.x, b[i].position.y,
				a[i].position.distance_to(b[i].position)]
	return "same size %d, no positional difference" % a.size()



## A body of soldiers standing on the places it gives them, added to a live simulator. The
## compare-mode section needs a battle, not a field of loose soldiers: bodies are what make
## soldiers walk, collide, hold a line and be shoved.
func _line_body(simulator: BattleSimulator, id: String, side: String, anchor: Vector2,
		facing: float, count: int, first_id: int) -> BattleFormation:
	var units: Array[BattleUnit] = []
	var ids: Array[int] = []
	for i in count:
		var unit_id := first_id + i
		units.append(_unit(unit_id, side, anchor))
		ids.append(unit_id)
	var existing := simulator.units
	existing.append_array(units)
	simulator.add_units(existing)
	if _catalog == null:
		_catalog = FormationCatalog.load_from()
	var body := BattleFormation.create(id, side, anchor, facing, "line", _catalog, _config())
	simulator.add_formation(body)
	simulator.assign_formation(body, ids)
	for i in body.unit_ids.size():
		var member := simulator.find_unit(body.unit_ids[i])
		if member != null:
			member.position = body.slots[i]
	return body

## ---------- the two passes -------------------------------------------------

func _run_reference(units: Array[BattleUnit], settle: float) -> Dictionary:
	var grid := BattleOverlapGrid.new()
	grid.configure(Vector2(100.0, 60.0), _config().get_float("battle.overlap_cell_size", 1.35))
	grid.max_push = _config().get_float("battle.max_separation_push", 1.35)
	grid.stats_enabled = true
	grid.resolve(units, _minimum(), settle)
	return grid.report()


func _run_candidate(units: Array[BattleUnit], settle: float) -> Dictionary:
	var grid := BattleOverlapGridPacked.new()
	grid.configure(Vector2(100.0, 60.0), _config().get_float("battle.overlap_cell_size", 1.35))
	grid.max_push = _config().get_float("battle.max_separation_push", 1.35)
	grid.stats_enabled = true
	grid.resolve(units, _minimum(), settle)
	return grid.report()


## One state through both passes. Returns the two digests.
func _compare(spec: StateSpec, settle: float) -> Array:
	var first := _materialise(spec)
	var second := _materialise(spec)
	var reference_units := first[0] as Array[BattleUnit]
	var candidate_units := second[0] as Array[BattleUnit]
	var reference := _digest(reference_units, _run_reference(reference_units, settle))
	var candidate := _digest(candidate_units, _run_candidate(candidate_units, settle))
	return [reference, candidate, reference_units, candidate_units]



## ---------- the native pass -------------------------------------------------

## The accelerator, on the same states as the packed pass and against the same oracle.
##
## The kernel answers the whole pass and hands back one displacement per soldier per axis, so
## it is compared the same way the packed pass is: identical input, identical output, bit for
## bit. A disagreement here is a real difference in the arithmetic rather than a difference in
## who is holding the numbers, which is exactly what this section exists to catch.
##
## When the library is not built the section reports that and stops. CI builds it and passes
## --require-native, where a missing accelerator is a failure.
func _test_the_native_pass_matches_the_reference() -> void:
	section("the native pass matches the reference on the same generated states")
	if not ClassDB.class_exists("NativeOverlapKernel"):
		if "--require-native" in OS.get_cmdline_user_args():
			equal(false, true, "the native overlap kernel is required but was not loaded")
		else:
			equal(false, false, "no native overlap kernel is loaded, so there is nothing to compare")
			print("    SKIP the native overlap section: no accelerator loaded (run `bash native/build.sh`)")
		return

	equal(ClassDB.class_exists("NativeOverlapKernel"), true,
		"the overlap kernel class is registered with the engine")
	var settle := _settle()
	var rng := RandomNumberGenerator.new()
	rng.seed = ORACLE_SEED + 3
	var mismatches := 0
	var touching_states := 0
	var skipped_states := 0
	for state_index in NATIVE_STATES:
		var spec := _random_state(rng, state_index)
		var first := _materialise(spec)
		var second := _materialise(spec)
		var reference_units := first[0] as Array[BattleUnit]
		var native_units := second[0] as Array[BattleUnit]
		var reference := _digest(reference_units, _run_reference(reference_units, settle))
		var native := _digest(native_units, _run_native(native_units, settle))
		if int(reference["touching"]) > 0:
			touching_states += 1
		if int(reference["skipped"]) > 0:
			skipped_states += 1
		var agree: bool = native["positions"] == reference["positions"]
		if not agree:
			mismatches += 1
		equal(native["positions"], reference["positions"],
			"state %d (%s): %s" % [state_index, spec.label, _first_difference(reference_units, native_units)])
		equal(native["touching"], reference["touching"],
			"state %d (%s): the kernel found the same touching pairs" % [state_index, spec.label])
	equal(mismatches, 0, "every one of the %d generated states came out identical" % NATIVE_STATES)
	greater(float(touching_states), 100.0, "and plenty of them had something to separate")
	greater(float(skipped_states), 0.0, "and some of them took the settled-cell skip")

	# The kernel's own counters, straight from the boundary: they say the same things the
	# reference's do about the same field.
	var probe_spec := _random_state(rng, 3)
	var probe := _materialise(probe_spec)
	var probe_units := probe[0] as Array[BattleUnit]
	var reference_report := _run_reference(probe_units, settle)
	var native_probe := _materialise(probe_spec)
	var native_report := _run_native(native_probe[0] as Array[BattleUnit], settle)
	equal(native_report.get("pairs", 0), reference_report.get("pairs", 0),
		"the kernel measured the same number of pairs")
	equal(native_report.get("cell_pairs", 0), reference_report.get("cell_pairs", 0),
		"and considered the same number of cell pairs")
	equal(native_report.get("cell_pairs_skipped", 0), reference_report.get("cell_pairs_skipped", 0),
		"and skipped the same ones")
	equal(native_report.get("coincident", 0), reference_report.get("coincident", 0),
		"and agreed about which pairs were coincident")


## The boundary is timed, not guessed at: a kernel that computes in twenty milliseconds but
## costs seventy to marshal is not a twenty-millisecond solution. These assertions are only
## that the clocks exist and see work - the size of the numbers is the benchmark's business.
func _test_the_boundary_is_timed() -> void:
	section("the native pass reports what crossing the boundary cost")
	if not ClassDB.class_exists("NativeOverlapKernel"):
		equal(false, false, "no native overlap kernel is loaded, so there is no boundary to time")
		return
	var settle := _settle()
	var rng := RandomNumberGenerator.new()
	rng.seed = ORACLE_SEED + 11
	var spec := _random_state(rng, 1)
	var built := _materialise(spec)
	var units := built[0] as Array[BattleUnit]
	var grid := BattleOverlapNative.new()
	grid.configure(Vector2(100.0, 60.0), _config().get_float("battle.overlap_cell_size", 1.35))
	grid.max_push = _config().get_float("battle.max_separation_push", 1.35)
	grid.stats_enabled = true
	grid.resolve(units, _minimum(), settle)
	var boundary := grid.boundary_report()
	greater(float(boundary["sync_us"]), 0.0, "packing the field is timed")
	greater(float(boundary["native_us"]), 0.0, "the kernel's own time is timed")
	greater(float(boundary["total_us"]), 0.0, "and the whole pass is timed")
	check(float(boundary["total_us"]) >= float(boundary["sync_us"]) + float(boundary["native_us"]),
		"the parts fit inside the whole (%d + %d <= %d)" % [
			int(boundary["sync_us"]), int(boundary["native_us"]), int(boundary["total_us"])])
	greater(float(boundary["applied"]), 0.0, "and the displacements were applied to units the pass owns")

## ---------- named arrangements --------------------------------------------

## The cases worth naming, each one a thing a fast path can get wrong. They are the same
## states the generator produces by the thousand; these are the ones a reader can check by
## eye, and their labels are what a failure report says first.
func _test_named_arrangements() -> void:
	section("the packed pass matches the reference on the arrangements that matter")
	var settle := _settle()

	for case in _named_cases():
		var spec := case[1] as StateSpec
		var outcome := _compare(spec, settle)
		var reference := outcome[0] as Dictionary
		var candidate := outcome[1] as Dictionary
		var reference_units := outcome[2] as Array[BattleUnit]
		var candidate_units := outcome[3] as Array[BattleUnit]
		equal(candidate["positions"], reference["positions"],
			"%s: the same field comes out (%s)" % [spec.label, _first_difference(reference_units, candidate_units)])
		equal(candidate["pairs"], reference["pairs"], "%s: the same pairs were measured" % spec.label)
		equal(candidate["touching"], reference["touching"], "%s: and the same pairs were touching" % spec.label)
		equal(candidate["skipped"], reference["skipped"], "%s: and the same cell pairs were skipped" % spec.label)
		equal(candidate["clamped"], reference["clamped"], "%s: and the same pushes were clamped" % spec.label)
		if int(reference["touching"]) > 0:
			var positions := reference["positions"] as String
			check(not positions.contains("nan"), "%s: no soldier ends up at a NaN" % spec.label)


func _named_cases() -> Array:
	var cases: Array = []
	var settle := _settle()

	# Two soldiers inside each other, alone on the field.
	var pair := StateSpec.new()
	pair.label = "a lone touching pair"
	pair.positions = {0: Vector2(20.0, 20.0), 1: Vector2(20.4, 20.0)}
	pair.sides = {0: BattleContext.SIDE_PLAYER, 1: BattleContext.SIDE_ENEMY}
	pair.alive = {0: true, 1: true}
	pair.free = [0, 1]
	cases.append(["pair", pair])

	# Exactly on top of each other.
	var stacked := StateSpec.new()
	stacked.label = "three soldiers in exactly the same place"
	stacked.positions = {0: Vector2(30.0, 30.0), 1: Vector2(30.0, 30.0), 2: Vector2(30.0, 30.0)}
	stacked.sides = {0: BattleContext.SIDE_PLAYER, 1: BattleContext.SIDE_PLAYER, 2: BattleContext.SIDE_ENEMY}
	stacked.alive = {0: true, 1: true, 2: true}
	stacked.free = [0, 1, 2]
	cases.append(["stacked", stacked])

	# Across a cell boundary and across a corner.
	var crossing := StateSpec.new()
	crossing.label = "pairs across cell boundaries and corners"
	var cell := _config().get_float("battle.overlap_cell_size", 1.35)
	crossing.positions = {
		0: Vector2(3.0 * cell - 0.2, 30.0), 1: Vector2(3.0 * cell + 0.35, 30.0),
		2: Vector2(4.0 * cell - 0.2, 4.0 * cell - 0.2), 3: Vector2(4.0 * cell + 0.35, 4.0 * cell + 0.35),
		4: Vector2(99.0, 59.0), 5: Vector2(99.4, 59.4),
	}
	crossing.sides = {0: BattleContext.SIDE_PLAYER, 1: BattleContext.SIDE_ENEMY, 2: BattleContext.SIDE_PLAYER,
		3: BattleContext.SIDE_ENEMY, 4: BattleContext.SIDE_PLAYER, 5: BattleContext.SIDE_ENEMY}
	crossing.alive = {0: true, 1: true, 2: true, 3: true, 4: true, 5: true}
	crossing.free = [0, 1, 2, 3, 4, 5]
	cases.append(["crossing", crossing])

	# One dressed body: the settled path, which is the one the packed version reproduces
	# from codes rather than from body references.
	var dressed := StateSpec.new()
	dressed.label = "a dressed body at three shapes"
	for shape in ["line", "column", "loose"]:
		var body := BodySpec.new("body_%s" % shape, BattleContext.SIDE_PLAYER, Vector2(30.0, 30.0), 0.0, shape)
		for i in 24:
			body.members.append(100 + body.members.size())
		body.settle = true
		dressed.bodies.append(body)
	for raw in dressed.bodies:
		for id in (raw as BodySpec).members:
			dressed.positions[id] = Vector2(30.0, 30.0)
			dressed.sides[id] = BattleContext.SIDE_PLAYER
			dressed.alive[id] = true
	cases.append(["dressed", dressed])

	# A body shoved off its marks: the same cells, no longer settled.
	var shoved := StateSpec.new()
	shoved.label = "a body whose soldiers have been shoved off their marks"
	var shoved_body := BodySpec.new("shoved", BattleContext.SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, "line")
	for i in 30:
		shoved_body.members.append(200 + shoved_body.members.size())
	shoved_body.settle = false
	shoved.bodies.append(shoved_body)
	for id in shoved_body.members:
		shoved.positions[id] = Vector2(38.0 + float(id % 6) * 0.9, 26.0 + float(id / 6) * 0.8)
		shoved.sides[id] = BattleContext.SIDE_PLAYER
		shoved.alive[id] = true
	cases.append(["shoved", shoved])

	# Two friendly bodies crossing, and two enemies in contact: the same code resolves both,
	# and a body-aware fast path must not confuse the two.
	var meeting := StateSpec.new()
	meeting.label = "two friendly bodies crossing and two enemy lines in contact"
	var left := BodySpec.new("player_a", BattleContext.SIDE_PLAYER, Vector2(25.0, 30.0), 0.0, "line")
	var right := BodySpec.new("player_b", BattleContext.SIDE_PLAYER, Vector2(42.0, 30.0), PI, "line")
	var enemy := BodySpec.new("enemy_a", BattleContext.SIDE_ENEMY, Vector2(34.0, 30.0), 0.0, "line")
	for body in [left, right, enemy]:
		for i in 36:
			body.members.append(300 + body.members.size())
		body.settle = false
		meeting.bodies.append(body)
	for id in left.members:
		meeting.positions[id] = Vector2(20.0 + float(id % 6) * 2.6, 22.0 + float(id / 6) * 2.6)
		meeting.sides[id] = BattleContext.SIDE_PLAYER
		meeting.alive[id] = true
	for id in right.members:
		meeting.positions[id] = Vector2(48.0 - float(id % 6) * 2.6, 22.0 + float(id / 6) * 2.6)
		meeting.sides[id] = BattleContext.SIDE_PLAYER
		meeting.alive[id] = true
	for id in enemy.members:
		meeting.positions[id] = Vector2(31.0 + float(id % 6) * 1.2, 30.0 + float(id / 6) * 1.2)
		meeting.sides[id] = BattleContext.SIDE_ENEMY
		meeting.alive[id] = true
	cases.append(["meeting", meeting])

	# The dead are not part of the field, and the pass must agree about that too.
	var fallen := StateSpec.new()
	fallen.label = "a field with the dead mixed into it"
	fallen.positions = {0: Vector2(50.0, 30.0), 1: Vector2(50.3, 30.0), 2: Vector2(50.1, 30.2), 3: Vector2(50.2, 29.9)}
	fallen.sides = {0: BattleContext.SIDE_PLAYER, 1: BattleContext.SIDE_ENEMY, 2: BattleContext.SIDE_PLAYER, 3: BattleContext.SIDE_ENEMY}
	fallen.alive = {0: true, 1: true, 2: false, 3: false}
	fallen.free = [0, 1, 2, 3]
	cases.append(["fallen", fallen])

	# A loose body spread so wide that most of its neighbouring cells are empty: the shape
	# whose skip rate is lowest, and the one where a code-based body comparison could slip.
	var loose := StateSpec.new()
	loose.label = "a loose body spread across empty cells"
	var loose_body := BodySpec.new("loose", BattleContext.SIDE_PLAYER, Vector2(60.0, 30.0), 0.0, "loose")
	for i in 18:
		loose_body.members.append(400 + loose_body.members.size())
	loose_body.settle = true
	loose.bodies.append(loose_body)
	for id in loose_body.members:
		loose.positions[id] = Vector2(60.0, 30.0)
		loose.sides[id] = BattleContext.SIDE_PLAYER
		loose.alive[id] = true
	cases.append(["loose", loose])

	# Settled and unsettled in the same body: the cell that holds both stops being an
	# interior, which is a state only the counter for it can see.
	var mixed := StateSpec.new()
	mixed.label = "one body with half its soldiers off their marks"
	var mixed_body := BodySpec.new("mixed", BattleContext.SIDE_PLAYER, Vector2(70.0, 30.0), 0.0, "line")
	for i in 20:
		mixed_body.members.append(500 + mixed_body.members.size())
	mixed_body.settle = true
	mixed_body.jitter = 0.05
	mixed.bodies.append(mixed_body)
	var index := 0
	for id in mixed_body.members:
		mixed.positions[id] = Vector2(70.0, 30.0)
		mixed.sides[id] = BattleContext.SIDE_PLAYER
		mixed.alive[id] = true
		if index % 2 == 1:
			mixed.positions[id] = Vector2(70.0 + float(index % 5) * 1.4, 26.0 + float(index / 5) * 1.4)
		index += 1
	cases.append(["mixed", mixed])

	return cases


## ---------- generated states ----------------------------------------------

func _test_generated_states() -> void:
	section("the packed pass matches the reference on generated states")
	var rng := RandomNumberGenerator.new()
	rng.seed = ORACLE_SEED
	var mismatches := 0
	var touching_states := 0
	var skipped_states := 0
	var coincident_states := 0
	var settle := _settle()
	for state_index in GENERATED_STATES:
		var spec := _random_state(rng, state_index)
		var outcome := _compare(spec, settle)
		var reference := outcome[0] as Dictionary
		var candidate := outcome[1] as Dictionary
		if int(reference["touching"]) > 0:
			touching_states += 1
		if int(reference["skipped"]) > 0:
			skipped_states += 1
		if int(reference["coincident"]) > 0:
			coincident_states += 1
		# One assertion per state rather than one for the whole run: a failure then names the
		# state that produced it, and the count of assertions says how many states were
		# actually compared rather than how many times the suite was called.
		var fields_agree: bool = candidate["positions"] == reference["positions"]
		if not fields_agree:
			mismatches += 1
		equal(candidate["positions"], reference["positions"],
			"state %d (%s): %s" % [state_index, spec.label,
				_first_difference(outcome[2] as Array[BattleUnit], outcome[3] as Array[BattleUnit])
				if not fields_agree else "identical"])
		var counters_agree: bool = candidate["pairs"] == reference["pairs"] \
			and candidate["touching"] == reference["touching"] \
			and candidate["skipped"] == reference["skipped"] \
			and candidate["clamped"] == reference["clamped"] \
			and candidate["coincident"] == reference["coincident"]
		if not counters_agree:
			mismatches += 1
		equal(counters_agree, true,
			"state %d (%s): the counters agree (reference pairs %d touching %d skipped %d, candidate pairs %d touching %d skipped %d)" % [
				state_index, spec.label, int(reference["pairs"]), int(reference["touching"]),
				int(reference["skipped"]), int(candidate["pairs"]), int(candidate["touching"]),
				int(candidate["skipped"])])
	equal(mismatches, 0, "every one of the %d generated states came out identical" % GENERATED_STATES)
	greater(float(touching_states), 100.0, "and plenty of them had something to separate")
	greater(float(skipped_states), 0.0, "and some of them took the settled-cell skip")
	greater(float(coincident_states), 0.0, "and some of them had a coincident pair on them")


## One generated state. The generator walks a list of shapes, so a run of nine hundred states
## covers all of them many times over rather than covering the first one nine hundred times.
func _random_state(rng: RandomNumberGenerator, index: int) -> StateSpec:
	var spec := StateSpec.new()
	var shape_kind := index % 6
	var cell := _config().get_float("battle.overlap_cell_size", 1.35)
	var next_id := 0

	match shape_kind:
		0:
			# Sparse: a handful of soldiers anywhere on the field.
			spec.label = "sparse"
			for i in rng.randi_range(2, 8):
				spec.positions[next_id] = Vector2(rng.randf_range(1.0, 99.0), rng.randf_range(1.0, 59.0))
				spec.sides[next_id] = _side(rng)
				spec.alive[next_id] = true
				spec.free.append(next_id)
				next_id += 1
		1:
			# Dense cluster: everybody inside a couple of cells.
			spec.label = "dense cluster"
			var centre := Vector2(rng.randf_range(10.0, 90.0), rng.randf_range(10.0, 50.0))
			for i in rng.randi_range(6, 40):
				spec.positions[next_id] = centre + Vector2(rng.randf_range(-1.5, 1.5), rng.randf_range(-1.5, 1.5))
				spec.sides[next_id] = _side(rng)
				spec.alive[next_id] = true
				spec.free.append(next_id)
				next_id += 1
		2:
			# Random soldiers over the whole field: the general case.
			spec.label = "field-wide scatter"
			for i in rng.randi_range(4, 60):
				spec.positions[next_id] = Vector2(rng.randf_range(0.5, 99.5), rng.randf_range(0.5, 59.5))
				spec.sides[next_id] = _side(rng)
				spec.alive[next_id] = true
				spec.free.append(next_id)
				next_id += 1
		3:
			# A lattice on the cell size, so soldiers land exactly on boundaries and corners.
			spec.label = "on the cell lattice"
			var step := cell * rng.randi_range(1, 2)
			for i in 8:
				for j in 6:
					spec.positions[next_id] = Vector2(float(i) * step + rng.randf_range(-0.05, 0.05),
						float(j) * step + rng.randf_range(-0.05, 0.05))
					spec.sides[next_id] = _side(rng)
					spec.alive[next_id] = true
					spec.free.append(next_id)
					next_id += 1
		4:
			# Bodies: one or two, dressed or shoved, with some of their soldiers dead.
			spec.label = "bodies"
			var body_count := rng.randi_range(1, 2)
			for b in body_count:
				var shape: String = ["line", "column", "loose"][rng.randi_range(0, 2)]
				var side := _side(rng)
				var anchor := Vector2(rng.randf_range(20.0, 80.0), rng.randf_range(15.0, 45.0))
				var body := BodySpec.new("body_%d_%d" % [index, b], side, anchor, rng.randf_range(-PI, PI), shape)
				var count := rng.randi_range(0, 30)
				for i in count:
					body.members.append(next_id + i)
				body.settle = rng.randf() < 0.6
				body.jitter = 0.0 if body.settle else rng.randf_range(0.2, 1.2)
				spec.bodies.append(body)
				for id in body.members:
					spec.positions[id] = anchor + _scatter(rng, body.jitter)
					spec.sides[id] = side
					spec.alive[id] = rng.randf() > 0.15
					next_id += 1
		5:
			# Coincident pairs and small stacks, salted through a field that also has
			# ordinary pairs and soldiers standing on their own.
			spec.label = "coincident pairs and stacks"
			for i in rng.randi_range(2, 10):
				var point := Vector2(rng.randf_range(5.0, 95.0), rng.randf_range(5.0, 55.0))
				var stack := rng.randi_range(2, 4)
				for j in stack:
					# The first two of every stack stand in exactly the same place, so every
					# run of these states contains a genuine coincident pair as well as
					# ordinary touching ones.
					var offset := Vector2.ZERO if j <= 1 else Vector2(rng.randf_range(-1.2, 1.2), rng.randf_range(-1.2, 1.2))
					spec.positions[next_id] = point + offset
					spec.sides[next_id] = _side(rng)
					spec.alive[next_id] = true
					next_id += 1
			for i in rng.randi_range(0, 6):
				spec.positions[next_id] = Vector2(rng.randf_range(1.0, 99.0), rng.randf_range(1.0, 59.0))
				spec.sides[next_id] = _side(rng)
				spec.alive[next_id] = true
				next_id += 1
	return spec


func _scatter(rng: RandomNumberGenerator, amount: float) -> Vector2:
	if amount <= 0.0:
		return Vector2.ZERO
	return Vector2(rng.randf_range(-amount, amount), rng.randf_range(-amount, amount))


func _side(rng: RandomNumberGenerator) -> String:
	return BattleContext.SIDE_PLAYER if rng.randf() < 0.5 else BattleContext.SIDE_ENEMY


## ---------- is the oracle actually exercising anything? --------------------

## An equivalence suite that never produced a touching pair, a skipped cell or a coincident
## pair would pass while proving nothing. This section is the proof that it is not doing that,
## and it also pins the two passes' agreement on a state where the skip and the push both
## happen on the same field.
func _test_the_oracle_finds_the_cases_it_claims_to() -> void:
	section("the oracle exercises the cases it claims to")
	var settle := _settle()

	# A dressed body with a shove in one corner of it: skipped pairs and touching pairs on
	# the same field, which is the state that would expose a body-code mistake.
	var spec := StateSpec.new()
	spec.label = "a dressed body with one shoved soldier"
	var body := BodySpec.new("body", BattleContext.SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, "line")
	for i in 40:
		body.members.append(i)
	body.settle = true
	spec.bodies.append(body)
	for id in body.members:
		spec.positions[id] = Vector2(40.0, 30.0)
		spec.sides[id] = BattleContext.SIDE_PLAYER
		spec.alive[id] = true

	var outcome := _compare(spec, settle)
	var reference := outcome[0] as Dictionary
	var candidate := outcome[1] as Dictionary
	greater(float(reference["skipped"]), 0.0, "the dressed body is skipped where its spacing proves it")
	equal(candidate["positions"], reference["positions"], "and both passes agree about where it ends up")
	equal(candidate["skipped"], reference["skipped"], "and about how much of it was skipped")

	# Now put two of its soldiers on top of each other, in the middle of the body.
	var reference_units := outcome[2] as Array[BattleUnit]
	var target := reference_units[0]
	var mate := reference_units[1]
	if target != null and mate != null:
		mate.position = target.position
		var second_spec := StateSpec.new()
		second_spec.label = "the same body with two soldiers in one place"
		# Same body, but its soldiers are not put back on their marks: this state is about
		# what happens to the two standing in one place.
		var loosened := BodySpec.new("body", BattleContext.SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, "line")
		loosened.members = body.members
		loosened.settle = false
		second_spec.bodies = [loosened]
		for unit in reference_units:
			second_spec.positions[unit.id] = unit.position
			second_spec.sides[unit.id] = unit.side
			second_spec.alive[unit.id] = unit.is_alive()
		var second := _compare(second_spec, settle)
		var second_reference := second[0] as Dictionary
		var second_candidate := second[1] as Dictionary
		greater(float(second_reference["touching"]), 0.0, "the stack makes the pair touch")
		greater(float(second_reference["coincident"]), 0.0, "and the pass calls it coincident")
		equal(second_candidate["coincident"], second_reference["coincident"],
			"which the packed pass also calls coincident, the same number of times")
		equal(second_candidate["positions"], second_reference["positions"],
			"and the pair resolves to the same place in both passes")

	# And the dead are not on the field for either pass.
	var dead_spec := StateSpec.new()
	dead_spec.label = "only the dead are touching"
	dead_spec.positions = {0: Vector2(10.0, 10.0), 1: Vector2(10.0, 10.0), 2: Vector2(10.1, 10.0)}
	dead_spec.sides = {0: BattleContext.SIDE_PLAYER, 1: BattleContext.SIDE_ENEMY, 2: BattleContext.SIDE_PLAYER}
	dead_spec.alive = {0: false, 1: false, 2: true}
	dead_spec.free = [0, 1, 2]
	var dead_outcome := _compare(dead_spec, settle)
	var dead_reference := dead_outcome[0] as Dictionary
	equal(dead_reference["touching"], 0, "three soldiers in one spot, two of them dead, is nothing to separate")
	equal((dead_outcome[1] as Dictionary)["positions"], dead_reference["positions"],
		"and both passes leave the one living soldier alone")


## ---------- compare mode, over a live battle ---------------------------------

## The strongest form of the equivalence claim: a real battle, every tick, with the native pass
## and the reference answering the same pre-overlap field, and the reference's answer being the
## one that is applied.
##
## The comparison is the only mode that can fail loudly *during* a fight rather than at the end
## of one, and it reports the first disagreement with everything needed to explain it - the tick,
## the soldier, the body, the cell, both displacements and how far apart they were. Zero
## disagreements is the claim; this is where it is checked for a battle whose soldiers move,
## fight, die and get shoved around by the pass itself.
func _test_compare_mode_sees_the_same_battle() -> void:
	section("compare mode resolves a live battle twice and finds no disagreement")
	if not ClassDB.class_exists("NativeOverlapKernel"):
		if "--require-native" in OS.get_cmdline_user_args():
			equal(false, true, "the native overlap kernel is required but was not loaded")
		else:
			equal(false, false, "no native overlap kernel is loaded, so there is nothing to compare")
		return

	var simulator := BattleSimulator.new(_config(), ORACLE_SEED + 77)
	simulator.overlap_backend = BattleSimulator.OverlapBackend.COMPARE
	_line_body(simulator, "player_body", BattleContext.SIDE_PLAYER, Vector2(34.0, 30.0), 0.0, 120, 0)
	_line_body(simulator, "enemy_body", BattleContext.SIDE_ENEMY, Vector2(50.0, 30.0), PI, 120, 200)
	for body in simulator.formations:
		body.order_engage()
		body.ensure_slots()
	simulator.start()
	equal(simulator.overlap_backend_active, BattleSimulator.OverlapBackend.COMPARE,
		"the battle runs the comparing pass")
	var pass_object := simulator.overlap_grid as BattleOverlapNative
	not_null(pass_object, "and it is the native pass doing the comparing")

	# Long enough for the lines to meet, fight, take casualties and shove each other around -
	# which is when the two implementations have the most opportunities to disagree.
	for tick in 400:
		simulator.step(0.05)

	var report := simulator.overlap_backend_report()
	greater(float(report.get("passes", 0)), 300.0, "the pass ran on essentially every tick")
	equal(int(report.get("mismatches", -1)), 0,
		"and found no disagreement in the whole battle%s" % (
			"" if pass_object == null or pass_object.native_first_mismatch.is_empty()
			else ": first at tick %s, unit %s, %s" % [
				str(pass_object.native_first_mismatch.get("tick", "?")),
				str(pass_object.native_first_mismatch.get("unit_id", "?")),
				str(pass_object.native_first_mismatch)]))
	# What this section does *not* assert is anything about how the battle goes. The two
	# fixtures here are formed bodies with no commander attached, so what they do over four
	# hundred ticks is a formation-layer question (and a standoff can hold for a very long time
	# - that is D-100). The claim under test is narrower and stronger: on every tick of
	# whatever this battle does, the kernel and the reference produce the same field.
	equal(int(report.get("mismatches", -1)), 0,
		"and the two implementations agreed on every tick of it")
	equal(simulator.overlap_backend_active, BattleSimulator.OverlapBackend.COMPARE,
		"with the comparison still the pass the battle ran")
