extends TestCase
## Scenery and deployment markers must share the same actual field coordinates.


func run() -> void:
	await _tick()
	_test_side_by_side_zones()
	_test_small_fields_remain_distinct()
	_test_zone_bounds()
	_test_deployment_clears_blocked_starting_cell()
	_complete()


func _test_side_by_side_zones() -> void:
	section("battle deployment zones come from one authoritative geometry")
	var field := Vector2(260, 130)
	var zones := BattleDeploymentOverlay.zones(field, 20.0, 8.0)
	equal(zones.size(), 2, "both armies have marked deployment zones")
	equal(zones[0].position, Vector2.ZERO, "friendly zone touches left field edge")
	equal(zones[1].end.x, field.x, "enemy zone touches right field edge")
	equal(zones[0].size, zones[1].size, "both factions receive equal deployment depth")
	check(zones[0].end.x < zones[1].position.x,
		"there is open battlefield separating both armies")


func _test_small_fields_remain_distinct() -> void:
	section("small battlefield zones do not overlap")
	var field := Vector2(40, 18)
	var zones := BattleDeploymentOverlay.zones(field, 70.0, 15.0)
	check(zones[0].end.x < zones[1].position.x,
		"zone fraction prevents deployments from overlapping")
	check(zones[0].size.x > 0.0, "small field still allows placement")


func _test_zone_bounds() -> void:
	section("deployment dimensions stay inside the world")
	var field := Vector2(120, 75)
	var zones := BattleDeploymentOverlay.zones(field, 20.0, 8.0)
	for zone in zones:
		check(zone.position.x >= 0.0 and zone.position.y >= 0.0
			and zone.end.x <= field.x and zone.end.y <= field.y,
			"deployment rectangle is fully within the field")


func _test_deployment_clears_blocked_starting_cell() -> void:
	section("terrain is safely cleared before art and pathfinding are built")
	var terrain := BattlefieldTerrain.generate(87431, Vector2(100, 60),
		GameManager.config())
	check(terrain.is_valid(), "battle terrain exists")
	var zones := BattleDeploymentOverlay.zones(terrain.size, 20.0, 8.0)
	var blocked := terrain.cell_of_col_row(2, terrain.rows / 2)
	terrain._type_index[blocked] = terrain.type_slot("water")
	terrain.refresh_maps_of_cell(blocked)
	check(not terrain.is_cell_traversable(blocked),
		"fixture water is initially impassable")
	var changed := terrain.clear_for_deployment(zones)
	check(changed >= 1, "the existing deployment-clearing rule repairs water")
	check(terrain.is_cell_traversable(blocked),
		"a soldier's starting zone is now traversable before routing")
	check(zones[0].has_point(terrain.cell_centre(blocked)),
		"the repaired cell belongs to the actual marked deployment area")
