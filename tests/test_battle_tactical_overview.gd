extends TestCase
## Tactical map's unit-strength visuals must reflect actual surviving men, and the overview must
## retain exactly the formation snapshot the battle hands it.
##
## Strengthened on GPT-6's directive (2026-10-09): the six assertions that existed here verified only
## strength_fraction(). They did not test whether the component receives and retains formation
## snapshots, handles selection state, or switches between medium and full-map modes. The additions
## below assert those behaviours; none of them exist to move a number.


func run() -> void:
	await _tick()
	_test_strength_from_roster()
	_test_invalid_strength_values()
	_test_formations_are_retained_as_given()
	_test_selection_is_replaced_not_accumulated()
	_test_zoom_modes_are_accepted_and_switch()
	_test_font_size_is_clamped_to_a_legible_floor()
	_test_empty_snapshot_clears_previous_state()
	_complete()


func _body(id: int, side: int, anchor: Vector2, forward: Vector2, started: int, alive: int,
		type_key: String) -> Dictionary:
	## One formation snapshot entry, shaped exactly as the battle builds it.
	return {
		"id": id,
		"side": side,
		"anchor": anchor,
		"forward": forward,
		"started": started,
		"alive": alive,
		"type_key": type_key,
		"name": "Body %d" % id,
		"half_span": 3.0,
		"half_depth": 1.5,
	}


func _test_strength_from_roster() -> void:
	section("formation map strength strips show actual losses")
	equal(BattleTacticalOverview.strength_fraction(40, 40), 1.0,
		"an intact formation has a complete strip")
	equal(BattleTacticalOverview.strength_fraction(20, 40), 0.5,
		"half of the original troops means half the strip")
	equal(BattleTacticalOverview.strength_fraction(0, 40), 0.0,
		"a destroyed body has no strength")


func _test_invalid_strength_values() -> void:
	section("strength indicators stay within valid bounds")
	equal(BattleTacticalOverview.strength_fraction(-1, 40), 0.0,
		"negative troop counts never draw negative widths")
	equal(BattleTacticalOverview.strength_fraction(55, 40), 1.0,
		"survivors above the starting count never overflow the frame")
	equal(BattleTacticalOverview.strength_fraction(0, 0), 0.0,
		"zero-sized bodies never divide by zero")


func _test_formations_are_retained_as_given() -> void:
	section("the overview consumes the battle's snapshot unchanged")
	var overview := BattleTacticalOverview.new()
	runner.add_child(overview)
	var snapshot: Array[Dictionary] = [
		_body(1, 0, Vector2(120.0, 340.0), Vector2(0.0, 1.0), 40, 26, "spears"),
		_body(2, 1, Vector2(400.0, 120.0), Vector2(1.0, 0.5), 32, 12, "bows"),
	]
	overview.set_formations(snapshot, [1], 3, true)
	equal(overview._formations.size(), 2, "both bodies of the snapshot are held")
	if overview._formations.size() == 2:
		var first: Dictionary = overview._formations[0]
		equal(int(first.get("id", -1)), 1, "the formation id survives")
		equal(first.get("anchor", Vector2.ZERO), Vector2(120.0, 340.0),
			"the position survives, so strips and blocks land where the men are")
		equal(first.get("forward", Vector2.ZERO), Vector2(0.0, 1.0),
			"the facing vector survives, so a block points the way the body faces")
		equal(int(first.get("started", -1)), 40, "the starting count survives")
		equal(int(first.get("alive", -1)), 26, "the surviving troop count survives")
		equal(int(first.get("side", -1)), 0, "the faction survives")
		equal(str(first.get("type_key", "")), "spears", "the unit key survives")
		var second: Dictionary = overview._formations[1]
		equal(int(second.get("side", -1)), 1, "the hostile body keeps its faction too")
		equal(first.get("anchor", Vector2.ZERO) != second.get("anchor", Vector2.ZERO), true,
			"two bodies do not collapse onto one another")
	overview.free()


func _test_selection_is_replaced_not_accumulated() -> void:
	section("a later selection replaces the earlier one")
	var overview := BattleTacticalOverview.new()
	runner.add_child(overview)
	var snapshot: Array[Dictionary] = [
		_body(1, 0, Vector2(100.0, 100.0), Vector2.RIGHT, 40, 40, "spears"),
		_body(2, 0, Vector2(200.0, 100.0), Vector2.RIGHT, 30, 30, "bows"),
	]
	overview.set_formations(snapshot, [1, 2], 3, true)
	equal(overview._selected.size(), 2, "both selected ids are stored")
	if overview._selected.size() == 2:
		equal(overview._selected[0], 1, "the first id is stored in order")
		equal(overview._selected[1], 2, "the second id is stored in order")
	overview.set_formations(snapshot, [2], 3, true)
	equal(overview._selected.size(), 1,
		"a later update replaces the selection rather than adding to it - a stale id would keep an "
		+ "outline on a body the player no longer has selected")
	if overview._selected.size() == 1:
		equal(overview._selected[0], 2, "the surviving id is the new one")
	overview.set_formations(snapshot, [], 3, true)
	equal(overview._selected.size(), 0, "an empty selection clears it")
	overview.free()


func _test_zoom_modes_are_accepted_and_switch() -> void:
	section("both zoom modes are accepted and a switch takes effect")
	var overview := BattleTacticalOverview.new()
	runner.add_child(overview)
	var snapshot: Array[Dictionary] = [_body(1, 0, Vector2(50.0, 50.0), Vector2.RIGHT, 20, 20, "spears")]
	overview.set_formations(snapshot, [], 3, true)
	equal(overview._full_map, true, "full-map mode is recorded")
	overview.set_formations(snapshot, [], 3, false)
	equal(overview._full_map, false, "medium-map mode is recorded")
	overview.set_formations(snapshot, [], 3, true)
	equal(overview._full_map, true, "switching back is recorded, so the mode is not sticky")
	overview.set_formations(snapshot, [], 3)
	equal(overview._full_map, true, "omitting the mode takes the documented default")
	overview.free()


func _test_font_size_is_clamped_to_a_legible_floor() -> void:
	section("lettering below the legible floor clamps, valid sizes pass through")
	var overview := BattleTacticalOverview.new()
	runner.add_child(overview)
	var snapshot: Array[Dictionary] = [_body(1, 0, Vector2(50.0, 50.0), Vector2.RIGHT, 20, 20, "spears")]
	overview.set_formations(snapshot, [], 0, true)
	equal(overview._font_world_size, 2, "zero clamps to the floor")
	overview.set_formations(snapshot, [], 1, true)
	equal(overview._font_world_size, 2, "one clamps to the floor")
	overview.set_formations(snapshot, [], -5, true)
	equal(overview._font_world_size, 2, "a negative request clamps rather than shrinking further")
	overview.set_formations(snapshot, [], 2, true)
	equal(overview._font_world_size, 2, "the floor itself is kept")
	overview.set_formations(snapshot, [], 9, true)
	equal(overview._font_world_size, 9, "a valid size is not altered")
	overview.set_formations(snapshot, [], 3, true)
	equal(overview._font_world_size, 3, "the default working size is kept as given")
	overview.free()


func _test_empty_snapshot_clears_previous_state() -> void:
	section("an empty snapshot clears formations and selection")
	var overview := BattleTacticalOverview.new()
	runner.add_child(overview)
	var snapshot: Array[Dictionary] = [
		_body(1, 0, Vector2(10.0, 10.0), Vector2.RIGHT, 10, 10, "spears"),
		_body(2, 1, Vector2(90.0, 10.0), Vector2.LEFT, 10, 4, "bows"),
	]
	overview.set_formations(snapshot, [1, 2], 4, false)
	equal(overview._formations.size(), 2, "state is present before the clear")
	overview.set_formations([], [], 4, false)
	equal(overview._formations.size(), 0, "no formation survives a cleared snapshot")
	equal(overview._selected.size(), 0, "no selection survives it either")
	overview.free()
