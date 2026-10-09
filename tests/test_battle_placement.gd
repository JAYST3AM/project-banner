extends TestCase
## Pure placement mathematics used by the live GPU battle's player controls.


func run() -> void:
	await _tick()
	_test_translation_preserves_formation_offsets()
	_test_drag_distributes_separate_bodies()
	_test_drag_frontage_and_facing()
	_test_drag_preserves_existing_order()
	_test_field_bounds()
	_test_edge_translation_keeps_spacing()
	_test_edge_frontage_keeps_spacing()
	_test_overwide_group_refused()
	_test_planning_does_not_mutate_input()
	_test_rejected_orders_preserve_full_command_snapshot()
	_test_non_finite_placement_is_rejected()
	_complete()


func _bodies() -> Array[Dictionary]:
	return [
		{"id": 2, "anchor": Vector2(10.0, 20.0), "forward": Vector2.UP,
			"members": 16, "files": 4, "spacing": 2.0},
		{"id": 6, "anchor": Vector2(30.0, 20.0), "forward": Vector2.UP,
			"members": 16, "files": 4, "spacing": 2.0},
	]


func _test_translation_preserves_formation_offsets() -> void:
	section("moving several bodies preserves their formation footprint")
	var plan := BattlePlacementPlanner.translated(_bodies(), Vector2(100, 40), Vector2(200, 120))
	equal(plan.size(), 2, "two independent bodies receive orders")
	equal(plan[0]["id"], 2, "the first body retains its identity")
	equal(plan[1]["id"], 6, "the second body retains its identity")
	equal(plan[0]["anchor"], Vector2(90, 40), "first move destination keeps its offset")
	equal(plan[1]["anchor"], Vector2(110, 40), "second move destination keeps its offset")
	equal(plan[0]["files"], 4, "regular right-click movement preserves frontage")


func _test_drag_distributes_separate_bodies() -> void:
	section("dragging sets different destinations for each formation")
	var plan := BattlePlacementPlanner.frontage(_bodies(), Vector2(45, 70),
		Vector2(145, 70), Vector2(200, 120))
	equal(plan.size(), 2, "both units remain independent")
	less(float((plan[0]["anchor"] as Vector2).x),
		float((plan[1]["anchor"] as Vector2).x), "formation centres are placed in order")
	greater((plan[1]["anchor"] as Vector2).distance_to(plan[0]["anchor"]),
		20.0, "formations are separated, not piled onto the same point")


func _test_drag_frontage_and_facing() -> void:
	section("longer drag produces more files and units face the original direction")
	var short_plan := BattlePlacementPlanner.frontage(_bodies(), Vector2(45, 70),
		Vector2(65, 70), Vector2(200, 120))
	var wide_plan := BattlePlacementPlanner.frontage(_bodies(), Vector2(45, 70),
		Vector2(145, 70), Vector2(200, 120))
	greater(float(wide_plan[0]["files"]), float(short_plan[0]["files"]),
		"frontage controls number of files")
	equal(wide_plan[0]["forward"], Vector2.UP,
		"dragging horizontally preserves a north-facing army")
	equal(wide_plan[1]["forward"], Vector2.UP,
		"both formations share the requested facing")


func _test_drag_preserves_existing_order() -> void:
	section("formation order is spatial, not selection order")
	var reversed := _bodies()
	reversed.reverse()
	var plan := BattlePlacementPlanner.frontage(reversed, Vector2(45, 70),
		Vector2(145, 70), Vector2(200, 120))
	equal(plan[0]["id"], 2, "left body stays left even if selected second")
	equal(plan[1]["id"], 6, "right body stays right even if selected first")


func _test_field_bounds() -> void:
	section("placement orders do not leave the battlefield")
	var plan := BattlePlacementPlanner.translated(_bodies(), Vector2(2000, -900),
		Vector2(200, 120))
	for placement in plan:
		var target: Vector2 = placement["anchor"]
		check(target.x >= 4.0 and target.x <= 196.0
			and target.y >= 4.0 and target.y <= 116.0,
			"the target stays inside the field")

func _test_edge_translation_keeps_spacing() -> void:
	section("boundary clicks shift all units together instead of stacking them")
	var plan := BattlePlacementPlanner.translated(_bodies(),
		Vector2(2000, -900), Vector2(200, 120))
	equal(plan.size(), 2, "both bodies receive a legal plan")
	if plan.size() != 2:
		return
	equal(plan[0]["anchor"], Vector2(176, 4), "first body remains separate")
	equal(plan[1]["anchor"], Vector2(196, 4), "second body reaches edge")
	approx((plan[1]["anchor"] as Vector2).distance_to(plan[0]["anchor"]),
		20.0, 0.001, "original 20-unit body spacing is preserved")


func _test_edge_frontage_keeps_spacing() -> void:
	section("short drags near the wall cannot pile both bodies on one spot")
	var plan := BattlePlacementPlanner.frontage(_bodies(),
		Vector2(20, 12), Vector2(21, 12), Vector2(25, 25))
	equal(plan.size(), 2, "short boundary drag has two legal targets")
	if plan.size() != 2:
		return
	var first: Vector2 = plan[0]["anchor"]
	var second: Vector2 = plan[1]["anchor"]
	approx(second.x - first.x, 5.0, 0.001,
		"drag preserves body separation even after clamping")
	check(first.x >= 4.0 and second.x <= 21.0,
		"both formation centres are inside safe map margins")


func _test_overwide_group_refused() -> void:
	section("impossible group width is refused instead of compressed")
	var plan := BattlePlacementPlanner.translated(_bodies(),
		Vector2(10, 10), Vector2(20, 20))
	check(plan.is_empty(), "20-wide group cannot fit inside 12-wide usable field")


func _test_planning_does_not_mutate_input() -> void:
	section("ordering never changes selection anchors or widths in place")
	var bodies := _bodies()
	var original := bodies.duplicate(true)
	BattlePlacementPlanner.translated(bodies,
		Vector2(2000, -900), Vector2(200, 120))
	BattlePlacementPlanner.frontage(bodies,
		Vector2(20, 12), Vector2(21, 12), Vector2(25, 25))
	equal(bodies, original, "existing formation state was not modified")


## PB-205 precursor: proves atomicity only at the pure placement-planner
## boundary. It DOES NOT certify the live GPU battle's order transaction,
## route cursor, or formation state; those require an integration fixture.
func _test_rejected_orders_preserve_full_command_snapshot() -> void:
	section("rejected layouts cannot rewrite any existing formation command fields")
	var bodies := _bodies()
	for body in bodies:
		body["order"] = "MOVE"
		body["target_anchor"] = Vector2(40.0, 70.0)
		body["route"] = PackedVector2Array([Vector2(20, 40), Vector2(40, 70)])
		body["waypoint_cursor"] = 1
		body["formation_width"] = 4
	var before := bodies.duplicate(true)
	var impossible_field := Vector2(10.0, 10.0)
	var translated := BattlePlacementPlanner.translated(bodies, Vector2(5, 5), impossible_field)
	check(translated.is_empty(), "a group wider than the map rejects translation")
	equal(bodies, before, "translation rejection preserves orders, widths and route cursors")
	var frontage := BattlePlacementPlanner.frontage(bodies,
		Vector2(5, 5), Vector2(6, 5), impossible_field)
	check(frontage.is_empty(), "an impossible frontage rejects the whole group")
	equal(bodies, before, "frontage rejection preserves every prior command field")
	var retry := BattlePlacementPlanner.translated(bodies, Vector2(5, 5), impossible_field)
	equal(retry, translated, "repeating an invalid command does not accumulate changes")
	equal(bodies, before, "a repeat rejection also leaves the source unchanged")


func _test_non_finite_placement_is_rejected() -> void:
	section("invalid formation coordinates fail closed rather than returning a corrupt plan")
	var bodies := _bodies()
	bodies[1]["anchor"] = Vector2(INF, 20.0)
	var before := bodies.duplicate(true)
	var plan := BattlePlacementPlanner.translated(bodies, Vector2(90, 40), Vector2(200, 120))
	check(plan.is_empty(), "non-finite source coordinates cannot produce legal orders")
	equal(bodies, before, "rejecting an invalid anchor does not edit the source")
