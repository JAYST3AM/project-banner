extends TestCase
## The CPU-side exact reference for binding-14 GPU terrain collision.


func run() -> void:
	await _tick()
	_test_header_matches_authoritative_terrain()
	_test_mask_blocks_existing_terrain_cells()
	_test_slide_prevents_solid_overlap()
	_test_empty_mask_preserves_dev_probe()
	_test_packing_does_not_mutate_simulation()
	_complete()


func _fixture() -> BattlefieldTerrain:
	var ground := BattlefieldTerrain.generate(50731, Vector2(84, 64),
		GameManager.config())
	for index in ground.cell_count():
		ground._traversable[index] = 1
	return ground


func _test_header_matches_authoritative_terrain() -> void:
	section("GPU obstacle buffer has an explicit deterministic layout")
	var terrain := _fixture()
	var mask := BattleTerrainGpuMask.from_terrain(terrain)
	equal(mask.size(), terrain.cols * terrain.rows + BattleTerrainGpuMask.HEADER_INTS,
		"buffer includes one flag per actual terrain cell")
	equal(mask[0], terrain.cols, "width matches generator")
	equal(mask[1], terrain.rows, "height matches generator")
	equal(mask[2], roundi(terrain.cell_size * 1000.0),
		"cell size agrees with shader's millimetre world scale")
	equal(mask[3], 1, "campaign terrain collision is enabled")


func _test_mask_blocks_existing_terrain_cells() -> void:
	section("the same ground cell is solid for CPU and GPU soldiers")
	var terrain := _fixture()
	var blocked := terrain.cell_of_col_row(5, 5)
	terrain._traversable[blocked] = 0
	var mask := BattleTerrainGpuMask.from_terrain(terrain)
	check(BattleTerrainGpuMask.is_blocked(mask, terrain.cell_centre(blocked)),
		"blocked cliff or prop is marked solid")
	check(not BattleTerrainGpuMask.is_blocked(mask,
		terrain.cell_centre(terrain.cell_of_col_row(4, 5))),
		"neighbouring open ground remains passable")
	check(BattleTerrainGpuMask.is_blocked(mask, Vector2(-2, 1)),
		"off-field negative world positions are outside the mask")


func _test_slide_prevents_solid_overlap() -> void:
	section("soldiers slide along blocked terrain rather than entering it")
	var terrain := _fixture()
	var blocked := terrain.cell_of_col_row(5, 5)
	terrain._traversable[blocked] = 0
	var mask := BattleTerrainGpuMask.from_terrain(terrain)
	var start := terrain.cell_centre(terrain.cell_of_col_row(4, 4))
	var stop := terrain.cell_centre(blocked)
	var adjusted := BattleTerrainGpuMask.slide(mask, start, stop)
	check(not BattleTerrainGpuMask.is_blocked(mask, adjusted),
		"diagonal movement never ends inside the boulder")
	check(adjusted != stop, "a blocked destination does not consume movement")
	check(adjusted.x == start.x or adjusted.y == start.y,
		"free axis is used when diagonal motion is blocked")
	terrain._traversable[terrain.cell_of_col_row(4, 5)] = 0
	terrain._traversable[terrain.cell_of_col_row(5, 4)] = 0
	mask = BattleTerrainGpuMask.from_terrain(terrain)
	equal(BattleTerrainGpuMask.slide(mask, start, stop), start,
		"movement halts when both adjacent slides are impassable")


func _test_empty_mask_preserves_dev_probe() -> void:
	section("legacy GPU dev probe keeps its original free movement")
	var mask := BattleTerrainGpuMask.from_terrain(null)
	equal(mask[3], 0, "dev/profiling mode has collision disabled")
	var start := Vector2(1, 2)
	var destination := Vector2(14, 17)
	check(not BattleTerrainGpuMask.is_blocked(mask, destination),
		"disabled occupancy never blocks a move")
	equal(BattleTerrainGpuMask.slide(mask, start, destination), destination,
		"legacy movement is unaffected")


func _test_packing_does_not_mutate_simulation() -> void:
	section("GPU mask is a read-only copy of terrain gameplay data")
	var terrain := _fixture()
	var before := terrain.to_dict()
	var mask := BattleTerrainGpuMask.from_terrain(terrain)
	check(mask.size() > 4, "GPU mask exists")
	equal(terrain.to_dict(), before, "source terrain is unchanged by encoding")
