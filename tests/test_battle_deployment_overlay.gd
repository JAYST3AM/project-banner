extends TestCase
## Scenery and deployment markers must share the same actual field coordinates.


func run() -> void:
	await _tick()
	_test_side_by_side_zones()
	_test_small_fields_remain_distinct()
	_test_zone_bounds()
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
