extends TestCase
## Minimap projection is independent of UI scale, terrain art and GPU state.


func run() -> void:
	await _tick()
	_test_world_to_map_roundtrip()
	_test_edges_are_clamped()
	_test_non_square_maps()
	_complete()


func _test_world_to_map_roundtrip() -> void:
	section("minimap coordinates round-trip to real battlefield positions")
	var field := Vector2(200, 120)
	var panel := Rect2(Vector2(8, 26), Vector2(210, 128))
	for point in [Vector2.ZERO, Vector2(100, 60), Vector2(200, 120),
			Vector2(43, 81)]:
		var picture := BattleMinimap.world_to_map(point, field, panel)
		var world := BattleMinimap.map_to_world(picture, field, panel)
		check(world.distance_to(point) < 0.001,
			"world point maps back to same battlefield position")


func _test_edges_are_clamped() -> void:
	section("dragging minimap cannot navigate outside the field")
	var field := Vector2(200, 120)
	var rect := Rect2(8, 26, 210, 128)
	equal(BattleMinimap.map_to_world(Vector2(-40, -10), field, rect),
		Vector2.ZERO, "above-left click clamps to map origin")
	equal(BattleMinimap.map_to_world(Vector2(900, 900), field, rect),
		field, "below-right click clamps to far corner")


func _test_non_square_maps() -> void:
	section("minimap preserves world point on an asymmetric field")
	var field := Vector2(900, 75)
	var rect := Rect2(8, 26, 210, 128)
	var centre := BattleMinimap.world_to_map(field * 0.5, field, rect)
	check(centre.distance_to(rect.get_center()) < 0.001,
		"field centre is displayed in the middle of minimap")
