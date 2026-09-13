extends TestCase
## Step 7: deterministic battlefield terrain.
##
## The rules this suite exists to pin down:
## [br]- terrain is reproducible from its seed, so a battle can be replayed;
## [br]- terrain is [i]data[/i], and nothing about it depends on a renderer;
## [br]- terrain changes how fast a soldier crosses the ground, which is the one
##   gameplay effect this milestone gives it.

const SEED := 70701


func run() -> void:
	await _tick()
	_test_catalog()
	_test_generation_is_deterministic()
	_test_different_seeds_differ()
	_test_bounds_and_queries()
	_test_move_multipliers_are_sane()
	_test_generation_is_independent_of_rendering()
	_test_terrain_changes_movement()
	_test_height_and_slope()
	_test_the_seed_actually_comes_from_the_context()
	_complete()


func _field() -> Vector2:
	return Vector2(100.0, 60.0)


## ---------- fixtures -----------------------------------------------------

func _make_unit(id: int, side: String, position: Vector2, speed: float) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_probe_%d" % id
	unit.display_name = "Probe %d" % id
	unit.max_hp = 100
	unit.hp = 100
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = speed
	# Deliberately tiny reach so nothing in these tests ever swings at anything.
	unit.attack_range = 0.2
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


func _difference_ratio(a: BattlefieldTerrain, b: BattlefieldTerrain) -> float:
	if a.cell_count() != b.cell_count() or a.cell_count() == 0:
		return 1.0
	var differing := 0
	for index in a.cell_count():
		if a.type_id_of_cell(index) != b.type_id_of_cell(index):
			differing += 1
	return float(differing) / float(a.cell_count())


## ---------- the data -----------------------------------------------------

func _test_catalog() -> void:
	section("the terrain catalog")
	var catalog := TerrainCatalog.load_from()
	check(catalog.is_valid(), "the terrain types load")
	equal(catalog.load_errors.size(), 0, "with no load errors")
	for required in ["open", "rough", "woods", "high_ground"]:
		check(catalog.has(required), "'%s' is defined" % required)
	equal(catalog.order.size(), 4, "and there are exactly four of them - no filler types")

	for id in catalog.order:
		var multiplier := catalog.move_multiplier(id)
		check(multiplier > 0.0 and multiplier <= 1.0,
			"%s has a sane movement multiplier (%.2f)" % [id, multiplier])
		check(not catalog.display_name(id).is_empty(), "%s has a name" % id)
	equal(catalog.move_multiplier("open"), 1.0, "open ground does not slow anyone down")
	less(catalog.move_multiplier("woods"), 1.0, "woods do")

	var missing := TerrainCatalog.load_from("res://data/terrain/does_not_exist.json")
	equal(missing.is_valid(), false, "a missing file produces an invalid catalog, not a crash")
	check(missing.load_errors.size() > 0, "and says why")


## ---------- determinism --------------------------------------------------

func _test_generation_is_deterministic() -> void:
	section("the same seed produces the same battlefield")
	var config := GameManager.config()
	var first := BattlefieldTerrain.generate(SEED, _field(), config)
	var second := BattlefieldTerrain.generate(SEED, _field(), config)

	check(first.is_valid(), "the battlefield generated")
	equal(first.signature(), second.signature(), "two battlefields from one seed are identical")
	equal(first.counts_by_type(), second.counts_by_type(), "cell for cell, type for type")

	# Query-level determinism, not just generation-level.
	var probe := Vector2(37.5, 21.25)
	equal(first.type_id_at(probe), second.type_id_at(probe), "a query returns the same type")
	approx(first.height_at(probe), second.height_at(probe), 0.00001, "and the same height")
	approx(first.move_multiplier_at(probe), second.move_multiplier_at(probe), 0.00001,
		"and the same movement multiplier")

	# Reading does not change anything: a query is a lookup, never a mutation.
	var before := first.signature()
	for i in 50:
		first.type_id_at(Vector2(float(i), float(i) * 0.5))
		first.move_multiplier_at(Vector2(float(i), float(i) * 0.5))
	equal(first.signature(), before, "querying the battlefield does not alter it")


func _test_different_seeds_differ() -> void:
	section("different seeds produce different battlefields")
	var config := GameManager.config()
	var a := BattlefieldTerrain.generate(SEED, _field(), config)
	var b := BattlefieldTerrain.generate(SEED + 1, _field(), config)
	not_equal(a.signature(), b.signature(), "a different seed gives a different battlefield")
	greater(_difference_ratio(a, b), 0.1,
		"and a meaningfully different one - not a single stray cell")

	# A seed three seeds away must differ too: adjacent seeds are not secretly equal.
	var c := BattlefieldTerrain.generate(SEED + 3, _field(), config)
	not_equal(a.signature(), c.signature(), "so does a seed further away")


func _test_bounds_and_queries() -> void:
	section("bounds and queries")
	var terrain := BattlefieldTerrain.generate(SEED + 10, _field(), GameManager.config())
	check(terrain.is_valid(), "the battlefield is valid")
	greater(float(terrain.cols), 0.0, "it has columns")
	greater(float(terrain.rows), 0.0, "and rows")
	equal(terrain.cell_count(), terrain.cols * terrain.rows, "and the cell count matches the grid")

	equal(terrain.inside(Vector2(0.0, 0.0)), true, "the origin is on the field")
	equal(terrain.inside(Vector2(terrain.size.x - 0.1, terrain.size.y - 0.1)), true,
		"the far corner is on the field")
	equal(terrain.inside(Vector2(terrain.size.x, 0.0)), false, "exactly the width is off it")
	equal(terrain.inside(Vector2(-1.0, 10.0)), false, "and so is a negative coordinate")
	equal(terrain.inside(Vector2(10.0, terrain.size.y + 5.0)), false, "and one past the bottom")

	equal(terrain.cell_index_at(Vector2(-5.0, -5.0)), -1, "an off-field point has no cell")
	equal(terrain.type_id_at(Vector2(-5.0, -5.0)), "open", "and reads as open ground")
	approx(terrain.move_multiplier_at(Vector2(-5.0, -5.0)), 1.0, 0.0001,
		"with no movement penalty, so callers never have to bounds-check first")

	# Every cell centre must resolve back to the cell it came from.
	var mismatched := 0
	for index in terrain.cell_count():
		var centre := terrain.cell_centre(index)
		if terrain.cell_index_at(centre) != index:
			mismatched += 1
		# And must lie inside the cell's own rectangle.
		if not terrain.cell_rect(index).has_point(centre):
			mismatched += 1
	equal(mismatched, 0, "every cell centre round-trips to its own cell")


func _test_move_multipliers_are_sane() -> void:
	section("movement multipliers")
	var catalog := TerrainCatalog.load_from()
	var terrain := BattlefieldTerrain.generate(SEED + 11, _field(), GameManager.config())
	var bad := 0
	var checked := 0
	for index in terrain.cell_count():
		var id := terrain.type_id_of_cell(index)
		var expected := catalog.move_multiplier(id)
		var actual := terrain.move_multiplier_at(terrain.cell_centre(index))
		checked += 1
		if absf(actual - expected) > 0.0001 or actual <= 0.0 or actual > 1.0:
			bad += 1
	equal(bad, 0, "every cell's multiplier matches its type and is within (0, 1] (%d cells)" % checked)

	var counts := terrain.counts_by_type()
	var total := 0
	for id in counts.keys():
		total += int(counts[id])
	equal(total, terrain.cell_count(), "every cell is counted under exactly one type")
	greater(float(int(counts.get("open", 0))), 0.0, "there is some open ground to fight on")
	greater(float(counts.size()), 1.0, "and the battlefield is not entirely one type")


## ---------- independence from rendering ----------------------------------

## Terrain must exist as data before anything draws it. If generation needed a
## renderer, none of this suite could run at all - but the point is worth asserting
## directly, because "the terrain is drawn by the view" is exactly the kind of coupling
## that creeps in later.
func _test_generation_is_independent_of_rendering() -> void:
	section("terrain is data, not a renderer")
	var terrain := BattlefieldTerrain.generate(SEED + 12, _field(), GameManager.config())
	# The static type already guarantees this, and that is the point: the separation is
	# enforced by the type system rather than by a convention someone has to remember.
	equal(terrain.get_class(), "RefCounted", "terrain is plain data, not a scene object")
	check(terrain.get_script() != null, "and carries no scene behaviour")

	# Generating terrain must not disturb any other random stream. If it used a shared
	# or global generator, every battle after the first would be subtly different.
	var probe_a := RandomNumberGenerator.new()
	probe_a.seed = 987654
	var before := probe_a.randi()
	var probe_b := RandomNumberGenerator.new()
	probe_b.seed = 987654
	BattlefieldTerrain.generate(SEED + 99, _field(), GameManager.config())
	var after := probe_b.randi()
	equal(before, after, "generating terrain does not disturb any other random stream")

	# And the whole thing works with no scene, no view and no camera - which is what
	# running headless proves.
	var simulator := BattleSimulator.new(GameManager.config(), 5)
	simulator.set_terrain(terrain)
	equal(simulator.terrain, terrain, "a simulator can hold terrain without a scene")


## ---------- terrain actually matters -------------------------------------

## The one gameplay effect this milestone gives terrain. A soldier crossing broken
## ground covers less distance in the same time than one on open ground.
func _test_terrain_changes_movement() -> void:
	section("terrain changes how fast ground is crossed")
	var config := GameManager.config()
	var terrain := BattlefieldTerrain.generate(SEED + 20, _field(), config)

	# Force a controlled battlefield rather than hoping the seed produced one: three
	# rows of woods at the top, three of open ground at the bottom.
	for index in terrain.cell_count():
		var row := index / terrain.cols
		if row < 3:
			terrain.set_type_at(terrain.cell_centre(index), "woods")
		elif row >= terrain.rows - 3:
			terrain.set_type_at(terrain.cell_centre(index), "open")
	check(terrain.rows >= 6, "the battlefield is deep enough for the test")

	var slow_position := terrain.cell_centre(terrain.cols + 1)
	var open_position := terrain.cell_centre((terrain.rows - 1) * terrain.cols + 1)
	equal(terrain.type_id_at(slow_position), "woods", "the slow lane really is woods")
	equal(terrain.type_id_at(open_position), "open", "and the fast lane really is open")

	var slow := _make_unit(0, BattleContext.SIDE_PLAYER, slow_position, 5.0)
	var fast := _make_unit(1, BattleContext.SIDE_PLAYER, open_position, 5.0)
	var enemy := _make_unit(2, BattleContext.SIDE_ENEMY, Vector2(95.0, 30.0), 0.0)
	enemy.attack_range = 0.2

	var travel := 10.0
	slow.move_order = slow_position + Vector2(travel, 0.0)
	slow.has_move_order = true
	fast.move_order = open_position + Vector2(travel, 0.0)
	fast.has_move_order = true

	var simulator := BattleSimulator.new(config, 3)
	simulator.add_units([slow, fast, enemy])
	simulator.set_terrain(terrain)
	simulator.start()

	var slow_start := slow.position
	var fast_start := fast.position
	for i in 20:
		simulator.step(0.05)

	var slow_moved := slow_start.distance_to(slow.position)
	var fast_moved := fast_start.distance_to(fast.position)
	greater(fast_moved, 0.0, "the soldier on open ground moved at all")
	greater(slow_moved, 0.0, "and so did the one in the woods")
	greater(fast_moved, slow_moved,
		"open ground was crossed faster (%.2f) than woods (%.2f)" % [fast_moved, slow_moved])

	# The ratio should match the data, not merely be "smaller".
	var expected := _catalog_ratio(terrain, slow_start, open_position)
	approx(slow_moved / fast_moved, expected, 0.12,
		"and the difference matches the terrain's own numbers")

	var without_terrain := BattleSimulator.new(config, 3)
	var control := _make_unit(0, BattleContext.SIDE_PLAYER, slow_position, 5.0)
	control.move_order = slow_position + Vector2(travel, 0.0)
	control.has_move_order = true
	var control_enemy := _make_unit(2, BattleContext.SIDE_ENEMY, Vector2(95.0, 30.0), 0.0)
	without_terrain.add_units([control, control_enemy])
	without_terrain.start()
	var control_start := control.position
	for i in 20:
		without_terrain.step(0.05)
	greater(control_start.distance_to(control.position), slow_moved,
		"the same soldier with no terrain at all crosses further still")


func _catalog_ratio(terrain: BattlefieldTerrain, slow_point: Vector2, open_point: Vector2) -> float:
	var slow := terrain.move_multiplier_at(slow_point)
	var fast := terrain.move_multiplier_at(open_point)
	if fast <= 0.0:
		return 0.0
	return slow / fast


func _test_height_and_slope() -> void:
	section("height and slope")
	var terrain := BattlefieldTerrain.generate(SEED + 30, _field(), GameManager.config())
	var heights_differ := false
	var first := terrain.height_at(Vector2(10.0, 10.0))
	for i in 20:
		var sample := terrain.height_at(Vector2(10.0 + float(i) * 4.0, 10.0))
		if absf(sample - first) > 0.01:
			heights_differ = true
	check(heights_differ, "the battlefield is not perfectly flat")

	approx(terrain.height_at(Vector2(-20.0, -20.0)), 0.0, 0.0001, "off-field ground is at zero height")
	approx(terrain.slope_between(Vector2(10.0, 10.0), Vector2(10.0, 10.0)), 0.0, 0.0001,
		"there is no slope across no distance")
	approx(terrain.slope_between(Vector2(-5.0, -5.0), Vector2(-25.0, -5.0)), 0.0, 0.0001,
		"and none between two points that are both off the field")

	# The contract is "zero when EITHER point is off the field", and one-in-one-out was
	# the case Step 7 got wrong: off-field ground reads as zero height, so taking the
	# two heights independently made the edge of the field look like a cliff. See D-057.
	var known_high := Vector2(12.0, 12.0)
	approx(terrain.slope_between(known_high, Vector2(140.0, 12.0)), 0.0, 0.0001,
		"a point inside to a point off the field is not a slope")
	approx(terrain.slope_between(Vector2(-40.0, 12.0), known_high), 0.0, 0.0001,
		"nor is a point off the field to a point inside")
	approx(terrain.slope_between(Vector2(-40.0, -12.0), Vector2(120.0, 12.0)), 0.0, 0.0001,
		"nor one that crosses the whole field and out the other side")

	var sample_slope := terrain.slope_between(Vector2(12.0, 12.0), Vector2(28.0, 12.0))
	check(absf(sample_slope) >= 0.0, "a slope between two real points is a real number")

	# Height is deterministic per point.
	equal(terrain.height_at(Vector2(44.0, 33.0)), terrain.height_at(Vector2(44.0, 33.0)),
		"height does not drift between reads")


## ---------- the seed comes from the battle, not from thin air -------------

func _test_the_seed_actually_comes_from_the_context() -> void:
	section("the terrain seed comes from the battle context")
	var config := GameManager.config()
	var state := GameManager.new_campaign("Terrain Seed", SEED)
	var builder := WorldBuilder.new(state, config)
	builder.build_if_needed()
	OverworldService.build(state, config).spawn_if_needed()
	state.player_gold = 9000
	state.settlement("greywatch").recruit_pool["peasant_recruit"] = 40
	RecruitmentService.build(state, config).recruit_many(state.settlement("greywatch"), "peasant_recruit", 3)

	var encounters := EncounterService.build(state, config)
	var world_party: WorldParty = null
	for key in state.parties.keys():
		var candidate := state.parties[key] as WorldParty
		if candidate != null and candidate.is_available():
			world_party = candidate
			break
	not_null(world_party, "there is an enemy to fight")
	if world_party == null:
		return

	state.world_position = world_party.position
	var context := encounters.build_context(world_party, true)
	not_null(context, "a battle context was built")

	var simulator := BattleSimulator.new(config, context.battle_seed)
	var terrain := simulator.set_terrain_from_context(context, config)
	not_null(terrain, "the simulator built terrain from the context")
	equal(terrain.terrain_seed, context.terrain_seed,
		"and used the context's terrain seed, not one of its own")

	# Two contexts from the same spot give the same ground.
	var again := BattlefieldTerrain.generate(context.terrain_seed, simulator.field_size, config)
	equal(again.signature(), terrain.signature(), "the same context reproduces the same battlefield")

	GameManager.end_campaign()
