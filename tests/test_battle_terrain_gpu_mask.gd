extends TestCase
## Slice D: the terrain collision mask - the read-only buffer the GPU walk and settle passes collide against,
## and the CPU reference the shader's collision rules were written against.
##
## The boundary this suite holds: BattlefieldTerrain supplies the authoritative traversability,
## BattleTerrainGpuMask encodes it into int32s and answers collision questions on the CPU, and nothing here
## touches the compute shader, the GPU dev scene, the unfinished LOD work or the terrain generator. The mask is
## data plus pure statics, which is exactly why it can be extracted and asserted without a GPU.
##
## SUPPORTED INPUT CONTRACT, recorded deliberately: an ENABLED mask is supported only in the shape
## from_terrain() produces - four header ints followed by exactly columns * rows flags. is_blocked() trusts
## that payload and indexes it directly, so a manually built enabled mask that is SHORTER than its geometry
## claims can read out of range. Validating malformed buffers is recorded here as a future integration
## hardening item and is deliberately NOT fixed in this slice, because fixing it would change the production
## file this slice is meant to carry over byte-identically.
##
## KNOWN CPU/GPU DIFFERENCE, recorded not resolved: the diagonal test in the mask uses Godot's is_equal_approx
## while the shader's terrain_slide uses a fixed 0.00001 threshold. The two are closely matched, but NOT
## perfectly equivalent near ZERO diagonal displacement, where one component is vanishingly small and the two
## epsilon checks can disagree about whether the move counts as diagonal at all. That belongs to the GPU parity
## work; neither the mask nor the shader is modified for it here.


func run() -> void:
	await _tick()
	_test_header_encodes_the_authoritative_terrain()
	_test_encoding_is_deterministic_across_independent_terrains()
	_test_null_or_invalid_terrain_yields_a_disabled_mask()
	_test_absent_disabled_and_malformed_geometry_are_treated_as_open()
	_test_outside_the_grid_is_blocked_on_all_four_sides()
	_test_exact_cell_edges_answer_for_the_cell_they_are_in()
	_test_slide_passes_through_a_disabled_mask_and_refuses_a_blocked_origin()
	_test_slide_against_a_wall_resolves_to_a_real_position()
	_test_slide_refuses_to_cut_the_corner_of_a_wall()
	_test_slide_cannot_tunnel_through_an_intermediate_wall()
	_test_substep_budget_processes_twenty_four_and_rejects_twenty_five()
	_test_live_gpu_bridge_authoritative_source()
	_test_live_gpu_bridge_rejects_invalid_deployment()
	_complete()


const SEED := 70717
const FIELD := Vector2(100.0, 60.0)
## Mirrors the mask's own budget constants so the bound can be asserted rather than assumed.
const SUBSTEPS := 24
const STEP_FRACTION := 0.33


func _terrain(seed_value: int = SEED, field: Vector2 = FIELD) -> BattlefieldTerrain:
	return BattlefieldTerrain.generate(seed_value, field, GameManager.config())


## The world position of the centre of a cell, taken from the terrain's own cell size.
func _centre(terrain: BattlefieldTerrain, col: int, row: int) -> Vector2:
	return Vector2((float(col) + 0.5) * terrain.cell_size, (float(row) + 0.5) * terrain.cell_size)


func _index(terrain: BattlefieldTerrain, col: int, row: int) -> int:
	return row * terrain.cols + col


func _first_cell_with(terrain: BattlefieldTerrain, blocked: bool, from_index: int = 0) -> int:
	for i in range(from_index, terrain.cell_count()):
		if terrain.is_cell_traversable(i) == (not blocked):
			return i
	return -1


## A complete, enabled mask with the given grid entirely clear or entirely blocked, built in the shape
## from_terrain() produces so it satisfies the supported input contract rather than probing the edges of it.
func _flat_mask(columns: int, rows: int, millimetres: int, blocked: bool) -> PackedInt32Array:
	var mask := PackedInt32Array()
	mask.resize(BattleTerrainGpuMask.HEADER_INTS + columns * rows)
	mask[0] = columns
	mask[1] = rows
	mask[2] = millimetres
	mask[3] = 1
	for i in range(BattleTerrainGpuMask.HEADER_INTS, mask.size()):
		mask[i] = 1 if blocked else 0
	return mask


## A field that actually contains obstacles, found by searching seeds and a larger field. The default field is
## entirely walkable, so on it the encoding's two flag states cannot both be exercised and the agreement check
## would be satisfied by a constant. Returns null rather than a half-qualifying field so the caller can fail
## closed, and callers assert what they need of it. Cached because generating a field is not free and two tests
## want the same one.
var _obstacle_field: BattlefieldTerrain = null


func _field_with_obstacles() -> BattlefieldTerrain:
	if _obstacle_field != null:
		return _obstacle_field
	for offset in 16:
		var candidate := _terrain(SEED + offset, Vector2(200.0, 120.0))
		if not candidate.is_valid():
			continue
		var blocked := 0
		var clear := 0
		for i in candidate.cell_count():
			if candidate.is_cell_traversable(i):
				clear += 1
			else:
				blocked += 1
		if blocked > 0 and clear > 0:
			_obstacle_field = candidate
			return candidate
	return null


## The number of sub-steps one move requires, stated explicitly because the bound under test IS this
## arithmetic: the mask walks a move in steps of a third of a cell and rejects anything needing more than 24.
func _steps_for(distance: float, stride: float) -> int:
	return maxi(1, ceili(distance / maxf(0.01, stride * STEP_FRACTION)))


func _test_header_encodes_the_authoritative_terrain() -> void:
	section("the mask header describes the terrain it came from")
	var terrain := _field_with_obstacles()
	if terrain == null:
		check(false, "a field containing both blocked and clear cells was found")
		return
	check(terrain.is_valid(), "the source terrain exists")
	var before := terrain.signature()
	var mask := BattleTerrainGpuMask.from_terrain(terrain)
	# Encoding is read-only: it must not disturb the terrain it describes.
	equal(terrain.signature(), before, "the terrain's own signature is unchanged by encoding")
	equal(mask.size(), BattleTerrainGpuMask.HEADER_INTS + terrain.cols * terrain.rows,
		"four header ints and exactly one flag per cell")
	equal(mask[0], terrain.cols, "column count comes from the terrain")
	equal(mask[1], terrain.rows, "row count comes from the terrain")
	equal(mask[3], 1, "a real terrain produces an enabled mask")
	equal(mask[2], maxi(1, roundi(terrain.cell_size * float(BattleTerrainGpuMask.MILLIMETRES))),
		"the cell size is carried in millimetres, not as a rounded count")
	var mismatches := 0
	var blocked_seen := 0
	var clear_seen := 0
	for i in terrain.cell_count():
		var expected := 0 if terrain.is_cell_traversable(i) else 1
		if mask[BattleTerrainGpuMask.HEADER_INTS + i] != expected:
			mismatches += 1
		if expected == 1:
			blocked_seen += 1
		else:
			clear_seen += 1
	equal(mismatches, 0, "every flag agrees with the terrain's OWN is_cell_traversable")
	# Both flag states must actually occur, or the agreement above would be satisfied by a constant.
	check(blocked_seen > 0, "the field contains blocked cells to encode (%d)" % blocked_seen)
	check(clear_seen > 0, "and clear cells (%d)" % clear_seen)


func _test_encoding_is_deterministic_across_independent_terrains() -> void:
	section("encoding is a function of the terrain data, not of identity or call order")
	# Independently generated twins from the same seed, encoded separately: this is what rules out the mask
	# depending on object identity, allocation order or a previous call.
	var terrain := _terrain()
	var twin := _terrain()
	equal(terrain.signature(), twin.signature(), "the twin really is an equivalent terrain")
	var a := BattleTerrainGpuMask.from_terrain(terrain)
	var b := BattleTerrainGpuMask.from_terrain(twin)
	equal(a.size(), b.size(), "the two encodings are the same length")
	var differing := 0
	for i in a.size():
		if a[i] != b[i]:
			differing += 1
	equal(differing, 0, "and every int32 agrees")
	equal(BattleTerrainGpuMask.from_terrain(terrain), a, "re-encoding the same terrain reproduces the same buffer")


func _test_null_or_invalid_terrain_yields_a_disabled_mask() -> void:
	section("no terrain, or an unbuilt one, produces a disabled mask")
	# This is the dev path the caller takes when the collision flag is off, so it is a real path, not an edge.
	var mask := BattleTerrainGpuMask.from_terrain(null)
	equal(mask.size(), BattleTerrainGpuMask.HEADER_INTS + 1, "a disabled mask still has a complete header and one flag")
	equal(mask[3], 0, "and it reports itself disabled")
	check(not BattleTerrainGpuMask.is_blocked(mask, Vector2(5.0, 5.0)),
		"a disabled mask blocks nothing, whatever the point")
	var blank := BattlefieldTerrain.new()
	check(not blank.is_valid(), "a fresh, ungenerated terrain is invalid")
	var from_blank := BattleTerrainGpuMask.from_terrain(blank)
	equal(from_blank[3], 0, "and it too produces a disabled mask")


func _test_absent_disabled_and_malformed_geometry_are_treated_as_open() -> void:
	section("an unusable mask does not block, but unusable geometry does")
	var empty := PackedInt32Array()
	check(not BattleTerrainGpuMask.is_blocked(empty, Vector2.ZERO), "an empty buffer blocks nothing")
	var short := PackedInt32Array()
	short.resize(BattleTerrainGpuMask.HEADER_INTS)
	check(not BattleTerrainGpuMask.is_blocked(short, Vector2.ZERO), "a header with no flag word blocks nothing")
	var disabled := _flat_mask(4, 4, 1000, true)
	disabled[3] = 0
	check(not BattleTerrainGpuMask.is_blocked(disabled, Vector2(1.0, 1.0)),
		"even an all-blocked grid blocks nothing while it is disabled")
	# Geometry that cannot be interpreted is a different case: the mask says so by blocking.
	var no_columns := _flat_mask(4, 4, 1000, false)
	no_columns[0] = 0
	check(BattleTerrainGpuMask.is_blocked(no_columns, Vector2(0.5, 0.5)), "zero columns cannot be indexed, so it blocks")
	var no_rows := _flat_mask(4, 4, 1000, false)
	no_rows[1] = 0
	check(BattleTerrainGpuMask.is_blocked(no_rows, Vector2(0.5, 0.5)), "zero rows likewise")
	var no_stride := _flat_mask(4, 4, 1000, false)
	no_stride[2] = 0
	check(BattleTerrainGpuMask.is_blocked(no_stride, Vector2(0.5, 0.5)), "a zero cell size would divide by zero, so it blocks")


func _test_outside_the_grid_is_blocked_on_all_four_sides() -> void:
	section("points outside the grid are blocked on all four sides")
	var mask := _flat_mask(4, 4, 1000, false)
	check(not BattleTerrainGpuMask.is_blocked(mask, Vector2(2.0, 2.0)), "a point inside a clear grid is free")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(-0.01, 2.0)), "one step left of the grid is blocked")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(2.0, -0.01)), "one step above it is blocked")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(4.0, 2.0)), "the right edge is EXCLUSIVE, so x == columns * stride is outside")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(2.0, 4.0)), "and so is the bottom edge")


func _test_exact_cell_edges_answer_for_the_cell_they_are_in() -> void:
	section("an exact internal cell edge answers for the cell the point is actually in")
	# One blocked cell in the second column, so the edge between columns 0 and 1 differs across its two sides.
	var mask := _flat_mask(4, 4, 1000, false)
	mask[BattleTerrainGpuMask.HEADER_INTS + 0 * 4 + 1] = 1
	check(not BattleTerrainGpuMask.is_blocked(mask, Vector2(0.99, 0.5)), "just left of the edge is the clear cell")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(1.0, 0.5)), "exactly on the edge belongs to the blocked cell, by floor, not by rounding")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(1.99, 0.5)), "and to the end of that cell")
	check(not BattleTerrainGpuMask.is_blocked(mask, Vector2(2.0, 0.5)), "the next edge starts the clear cell after it")
	var terrain := _field_with_obstacles()
	if terrain == null:
		check(false, "a field containing both blocked and clear cells was found")
		return
	var terrain_mask := BattleTerrainGpuMask.from_terrain(terrain)
	var stride := terrain.cell_size
	# The same rule against the real terrain: the point exactly on an internal boundary must agree with the
	# cell floor() selects, so the two agree cell by cell across the whole interior edge.
	var checked := 0
	for row in mini(terrain.rows, 8):
		for col in mini(terrain.cols - 1, 8):
			var edge := Vector2((float(col) + 1.0) * stride, (float(row) + 0.5) * stride)
			equal(BattleTerrainGpuMask.is_blocked(terrain_mask, edge),
				not terrain.is_cell_traversable(_index(terrain, col + 1, row)),
				"the boundary at column %d row %d belongs to the cell to its right" % [col, row])
			checked += 1
	check(checked >= 49, "enough interior edges were exercised (%d)" % checked)


func _test_slide_passes_through_a_disabled_mask_and_refuses_a_blocked_origin() -> void:
	section("slide passes through when it cannot collide, and refuses a blocked origin")
	var disabled := _flat_mask(4, 4, 1000, true)
	disabled[3] = 0
	var from := Vector2(0.25, 0.25)
	var to := Vector2(3.75, 3.75)
	check(BattleTerrainGpuMask.slide(disabled, from, to) == to,
		"a disabled mask moves the soldier where it was asked to go")
	var clear := _flat_mask(4, 4, 1000, false)
	check(BattleTerrainGpuMask.slide(clear, from, Vector2(1.25, 0.25)) == Vector2(1.25, 0.25),
		"a clear path arrives unchanged")
	# A blocked origin is not repaired by teleporting through the obstruction, so the move is refused outright.
	var blocked_origin := _flat_mask(4, 4, 1000, false)
	blocked_origin[BattleTerrainGpuMask.HEADER_INTS + 0 * 4 + 0] = 1
	check(BattleTerrainGpuMask.is_blocked(blocked_origin, from), "the origin cell really is blocked")
	check(BattleTerrainGpuMask.slide(blocked_origin, from, Vector2(3.75, 3.75)) == from,
		"a blocked origin holds its ground rather than sliding out of the wall")


func _test_slide_against_a_wall_resolves_to_a_real_position() -> void:
	section("a move into a wall resolves to a real position, not merely to an unblocked destination")
	# A wall down column 2. The move aims diagonally past it from the clear column 1, so the x component is
	# refused while the y component survives: the resolved position must be a genuine position, on the safe
	# axis, past the origin but short of the wall.
	var mask := _flat_mask(6, 6, 1000, false)
	for row in 6:
		mask[BattleTerrainGpuMask.HEADER_INTS + row * 6 + 2] = 1
	var from := Vector2(1.5, 2.5)
	var to := Vector2(3.5, 3.5)
	check(not BattleTerrainGpuMask.is_blocked(mask, from), "the origin is clear")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(2.5, 2.5)), "the wall column is blocked")
	var resolved := BattleTerrainGpuMask.slide(mask, from, to)
	check(resolved != to, "the diagonal into the wall was not granted")
	check(not BattleTerrainGpuMask.is_blocked(mask, resolved), "the resolved position itself is a legal one")
	# The soldier advances up to the wall's own boundary and no further: x stays strictly inside the column to
	# the left of the wall, which is exactly where the mask stops it rather than at the origin.
	check(resolved.x < 2.0, "x never enters the wall's column (%.4f)" % resolved.x)
	check(resolved.x >= from.x, "and it did not retreat")
	check(resolved.y > from.y, "the y component made real progress")
	check(resolved.y <= to.y + 0.0001, "and it did not overshoot the request")


func _test_slide_refuses_to_cut_the_corner_of_a_wall() -> void:
	section("a diagonal whose own destination is clear is still refused if it cuts a blocked corner")
	# The destination here is genuinely traversable, but both axial neighbours are walls, so granting it would
	# walk through the corner between them. This is the case the shader comment calls out.
	var mask := _flat_mask(5, 5, 1000, false)
	mask[BattleTerrainGpuMask.HEADER_INTS + 2 * 5 + 3] = 1
	mask[BattleTerrainGpuMask.HEADER_INTS + 3 * 5 + 2] = 1
	var from := Vector2(2.5, 2.5)
	var to := Vector2(3.5, 3.5)
	check(not BattleTerrainGpuMask.is_blocked(mask, from), "the origin is clear")
	check(not BattleTerrainGpuMask.is_blocked(mask, to), "and so is the destination on its own")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(3.5, 2.5)), "but the x-only neighbour is a wall")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(2.5, 3.5)), "and so is the y-only neighbour")
	var resolved := BattleTerrainGpuMask.slide(mask, from, to)
	check(resolved != to, "the corner was not cut, even though the destination alone was clear")
	check(not BattleTerrainGpuMask.is_blocked(mask, resolved), "the resolved position is still a legal one")


func _test_slide_cannot_tunnel_through_an_intermediate_wall() -> void:
	section("a wall between origin and destination stops the move rather than being tunnelled through")
	# A single blocked column with clear ground beyond it on both sides: a move across it must stop short of the
	# wall, not appear on the far side.
	var mask := _flat_mask(12, 4, 1000, false)
	for row in 4:
		mask[BattleTerrainGpuMask.HEADER_INTS + row * 12 + 3] = 1
	var from := Vector2(0.5, 0.5)
	var to := Vector2(5.5, 0.5)
	# The move must fit inside the sub-step budget, or this test would be measuring the budget instead of the
	# wall. Five units at a third of a unit per step is sixteen steps, comfortably inside twenty-four.
	check(_steps_for(from.distance_to(to), 1.0) <= SUBSTEPS, "the move fits the sub-step budget")
	check(not BattleTerrainGpuMask.is_blocked(mask, from), "the origin is clear")
	check(not BattleTerrainGpuMask.is_blocked(mask, to), "and so is the far side")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(3.5, 0.5)), "the wall is between them")
	var resolved := BattleTerrainGpuMask.slide(mask, from, to)
	check(not BattleTerrainGpuMask.is_blocked(mask, resolved), "the resolved position is legal")
	check(resolved.x < 3.0, "it stopped on the near side of the wall (%.3f)" % resolved.x)
	check(resolved.x > from.x, "and it did make progress toward it")
	equal(resolved.y, from.y, "with no reason to move sideways, y is untouched")


func _test_substep_budget_processes_twenty_four_and_rejects_twenty_five() -> void:
	section("the sub-step budget is a real bound: 24 steps are processed, 25 are rejected")
	# The budget exists so a broken or malicious displacement cannot create an unbounded GPU loop, and the
	# mask's rule is a step per third of a cell. The two distances below are chosen from that arithmetic - the
	# first needs exactly 24 steps, the second exactly 25 - so the bound is what is under test.
	var mask := _flat_mask(40, 8, 1000, false)
	var stride := 1.0
	var within := Vector2(0.5, 4.5) + Vector2(stride * STEP_FRACTION * 24.0 - 0.006, 0.0)
	var beyond := Vector2(0.5, 4.5) + Vector2(stride * STEP_FRACTION * 24.5, 0.0)
	var within_steps := _steps_for(Vector2(0.5, 4.5).distance_to(within), stride)
	var beyond_steps := _steps_for(Vector2(0.5, 4.5).distance_to(beyond), stride)
	equal(within_steps, SUBSTEPS, "the first displacement requires exactly the budget, no more")
	equal(beyond_steps, SUBSTEPS + 1, "and the second requires exactly one step beyond it")
	check(not BattleTerrainGpuMask.is_blocked(mask, within), "the destination within budget is clear ground")
	check(not BattleTerrainGpuMask.is_blocked(mask, beyond), "and so is the one beyond it, so only the budget differs")
	# The path is clear in both cases, so any difference between these two results comes from the bound alone.
	# Twenty-four sub-steps accumulate floating-point drift, so the arrival is asserted to a tolerance; the
	# rejection returns the origin untouched and is asserted exactly.
	var arrived := BattleTerrainGpuMask.slide(mask, Vector2(0.5, 4.5), within)
	approx(arrived.x, within.x, 0.0001, "a move needing the full budget is processed and arrives in x")
	approx(arrived.y, within.y, 0.0001, "and in y")
	check(BattleTerrainGpuMask.slide(mask, Vector2(0.5, 4.5), beyond) == Vector2(0.5, 4.5),
		"a move needing one step more is rejected, leaving the soldier where it stood")

## E3 source contract: the bridge receives the exact terrain object the CPU
## battle/visual view owns. It never creates a second terrain from the seed.
func _test_live_gpu_bridge_authoritative_source() -> void:
	section("GPU staging retains the live battlefield source identity")
	var terrain := _terrain()
	var free_cell := -1
	for index in terrain.cell_count():
		if terrain.is_cell_traversable(index):
			free_cell = index
			break
	check(free_cell >= 0, "terrain contains a legal deployment cell")
	if free_cell < 0:
		return
	var unit := BattleUnit.new()
	unit.id = 71
	unit.position = terrain.cell_centre(free_cell)
	var soldiers: Array[BattleUnit] = [unit]
	var before := terrain.signature()
	var report := BattleTerrainGpuBridge.capture(terrain, soldiers)
	check(bool(report["ready"]), "authoritative terrain produces a ready GPU snapshot")
	equal(str(report["source_signature"]), before, "snapshot belongs to existing terrain")
	equal(terrain.signature(), before, "capture never changes the terrain")
	equal(int(report["units_checked"]), 1, "live unit was checked")
	var mask: PackedInt32Array = report["mask"]
	var payload: PackedByteArray = report["bytes"]
	equal(mask, BattleTerrainGpuMask.from_terrain(terrain),
		"GPU mask comes from the same source as the CPU battle")
	equal(payload, mask.to_byte_array(), "serialized GPU payload matches captured mask")
	check(BattleTerrainGpuBridge.matches_source(report, terrain),
		"matching source is accepted for GPU upload")
	var twin := _terrain()
	check(not BattleTerrainGpuBridge.matches_source(report, twin),
		"a separately generated terrain is rejected even with the same seed")


func _test_live_gpu_bridge_rejects_invalid_deployment() -> void:
	section("GPU terrain bridge refuses absent ground and illegal soldiers")
	var empty: Array[BattleUnit] = []
	var absent := BattleTerrainGpuBridge.capture(null, empty)
	check(not bool(absent["ready"]), "null source is never uploaded as disabled fallback")
	var terrain := _terrain()
	var outside := BattleUnit.new()
	outside.id = 107
	outside.position = Vector2(-1.0, 1.0)
	var soldiers: Array[BattleUnit] = [outside]
	var report := BattleTerrainGpuBridge.capture(terrain, soldiers)
	check(not bool(report["ready"]), "an off-field soldier blocks GPU activation")
	equal(int(report["blocked_count"]), 1, "exactly one illegal soldier was counted")
	var blocked: PackedInt32Array = report["blocked_ids"]
	equal(blocked.size(), 1, "invalid IDs are reported for diagnostics")
	equal(blocked[0], 107, "the offending soldier is identified")
	check(not BattleTerrainGpuBridge.matches_source(report, terrain),
		"a rejected capture cannot be uploaded")
