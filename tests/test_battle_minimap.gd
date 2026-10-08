extends TestCase
## B2a's sibling: the tactical minimap. Presentation-only, and it must not know what drew its terrain.
##
## Two things are being pinned here. First the acceptance scope: coordinate projection, formation markers
## and facing, selection highlighting, the camera footprint, click and drag navigation, edge clamping and
## resize behaviour - all with synthetic fixtures, because the live GPU battlefield is explicitly out of
## scope for this slice. Second the architecture: terrain imagery is an OPTIONAL INPUT, so the class is
## asserted to contain no reference to the ground painter that the original called into.
##
## Note on helpers: TestCase.approx() takes floats only, so vector comparisons go through check() with
## Vector2.is_equal_approx(), and a comparison that needs a real tolerance uses distance_to().


func run() -> void:
	await _tick()
	_test_no_terrain_slice_dependency()
	_test_projection_and_its_clamping()
	_test_marker_geometry_follows_the_facing()
	_test_marker_size_floors_and_scaling()
	_test_selection_highlighting()
	_test_camera_footprint()
	_test_navigation_clicks_and_drags()
	_test_resize_behaviour()
	_test_markers_stay_inside_the_map_at_the_edges()
	_test_the_camera_footprint_never_leaves_the_map()
	_test_a_hostile_formation_can_never_be_highlighted()
	_test_a_drag_started_outside_the_map_never_navigates()
	_test_functional_without_terrain_imagery()
	_complete()


const FIELD := Vector2(200.0, 100.0)


func _rect() -> Rect2:
	return Rect2(Vector2(10.0, 20.0), Vector2(400.0, 200.0))


static func _formation(id: int, side: int, anchor: Vector2, forward: Vector2, alive: int = 20,
		half_depth: float = 4.0, half_span: float = 6.0) -> Dictionary:
	return {"id": id, "side": side, "anchor": anchor, "forward": forward, "alive": alive,
		"half_depth": half_depth, "half_span": half_span}


func _minimap(world: Vector2 = FIELD) -> BattleMinimap:
	var minimap := BattleMinimap.new()
	runner.add_child(minimap)
	minimap.set_terrain_texture(null, world)
	return minimap


func _test_no_terrain_slice_dependency() -> void:
	section("the minimap does not depend on the ground painter or a terrain slice")
	var source := FileAccess.get_file_as_string("res://scripts/battle/battle_minimap.gd")
	check(source.length() > 0, "the minimap source is readable")
	# Scan the CODE, not the prose: this file's own comments name the painter it had to be freed from, and a
	# comment cannot call anything.
	var code := _code_of(source)
	check(not code.contains("BattleGroundPainter"), "no call into BattleGroundPainter")
	check(not code.contains("BattlefieldTerrain"), "no BattlefieldTerrain parameter")
	check(code.contains("set_terrain_texture"), "imagery arrives as an optional texture instead")


func _test_projection_and_its_clamping() -> void:
	section("world and map coordinates project both ways, and both ends clamp")
	var rect := _rect()
	check(BattleMinimap.world_to_map(Vector2.ZERO, FIELD, rect).is_equal_approx(rect.position),
		"the world origin lands at the map's top-left corner")
	check(BattleMinimap.world_to_map(FIELD, FIELD, rect).is_equal_approx(rect.end),
		"the far corner lands at the map's bottom-right corner")
	check(BattleMinimap.world_to_map(FIELD * 0.5, FIELD, rect).is_equal_approx(rect.get_center()),
		"the field's centre lands at the map's centre")
	check(BattleMinimap.world_to_map(Vector2(-50.0, -50.0), FIELD, rect).is_equal_approx(rect.position),
		"a world point before the origin clamps to the corner rather than leaving the map")
	check(BattleMinimap.world_to_map(FIELD * 3.0, FIELD, rect).is_equal_approx(rect.end),
		"a world point past the field clamps to the far corner")
	check(BattleMinimap.map_to_world(rect.position, FIELD, rect).is_equal_approx(Vector2.ZERO),
		"the map's corner reads back as the world origin")
	check(BattleMinimap.map_to_world(rect.end, FIELD, rect).is_equal_approx(FIELD),
		"the map's far corner reads back as the field's far corner")
	check(BattleMinimap.map_to_world(rect.position - Vector2(40.0, 40.0), FIELD, rect)
		.is_equal_approx(Vector2.ZERO), "a click off the left of the map clamps to the world origin")
	check(BattleMinimap.map_to_world(rect.end + Vector2(40.0, 40.0), FIELD, rect).is_equal_approx(FIELD),
		"a drag past the right of the map clamps to the field's far corner")
	var world := Vector2(37.5, 62.5)
	check(BattleMinimap.map_to_world(BattleMinimap.world_to_map(world, FIELD, rect), FIELD, rect)
		.is_equal_approx(world), "projecting out and back returns the same world point")


func _test_marker_geometry_follows_the_facing() -> void:
	section("a formation marker's long axis follows its facing")
	var rect := _rect()
	var anchor := Vector2(100.0, 50.0)
	var facing_right := BattleMinimap.marker_polygon(anchor, Vector2.RIGHT, 10.0, 4.0, FIELD, rect)
	equal(facing_right.size(), 4, "a marker is a four-corner footprint")
	var right_bounds := _bounds(facing_right)
	check(right_bounds.size.x > right_bounds.size.y,
		"facing right, the footprint is longer across the screen than down it")
	var facing_down := BattleMinimap.marker_polygon(anchor, Vector2.DOWN, 10.0, 4.0, FIELD, rect)
	var down_bounds := _bounds(facing_down)
	check(down_bounds.size.y > down_bounds.size.x,
		"facing down, the footprint turns with it and becomes taller than it is wide")
	check(BattleMinimap.facing(Vector2.ZERO).is_equal_approx(Vector2.RIGHT),
		"a formation with no facing reads as facing right rather than vanishing")
	check(BattleMinimap.facing(Vector2(0.0, 5.0)).is_equal_approx(Vector2.DOWN), "facing normalises")
	var centre := BattleMinimap.world_to_map(anchor, FIELD, rect)
	check(_centroid(facing_right).is_equal_approx(centre),
		"the footprint is centred on the projected anchor")
	var tip := BattleMinimap.facing_tip(anchor, Vector2.RIGHT, FIELD, rect)
	check(tip.is_equal_approx(centre + Vector2(BattleMinimap.FACING_TIP_PX, 0.0)),
		"the facing tip sits off the centre in map pixels, so it survives a tiny footprint")


func _test_marker_size_floors_and_scaling() -> void:
	section("marker size follows the formation, with a floor so small bodies stay visible")
	var rect := _rect()
	var anchor := Vector2(100.0, 50.0)
	var small := _bounds(BattleMinimap.marker_polygon(anchor, Vector2.RIGHT, 1.0, 1.0, FIELD, rect))
	var large := _bounds(BattleMinimap.marker_polygon(anchor, Vector2.RIGHT, 8.0, 20.0, FIELD, rect))
	check(large.size.x > small.size.x, "a wider formation draws a wider footprint")
	check(large.size.y > small.size.y, "a deeper formation draws a deeper footprint")
	var floored := _bounds(BattleMinimap.marker_polygon(anchor, Vector2.RIGHT, 0.0, 0.0, FIELD, rect))
	check(floored.size.x > 0.0 and floored.size.y > 0.0,
		"a degenerate formation still draws something rather than collapsing to a point")


func _test_selection_highlighting() -> void:
	section("a chosen formation is outlined in the selection colour, and only it")
	equal(BattleMinimap.marker_outline(true, true), BattleMinimap.SELECTION,
		"a chosen friendly formation takes the selection colour")
	check(BattleMinimap.marker_outline(true, false) != BattleMinimap.SELECTION,
		"an unchosen friendly formation does not")
	equal(BattleMinimap.marker_tip_colour(true, true), BattleMinimap.SELECTION,
		"its facing tip is highlighted too")
	equal(BattleMinimap.marker_tip_colour(false, false), BattleMinimap.marker_ink(false).lightened(0.45),
		"an enemy tip uses the enemy ink")
	equal(BattleMinimap.marker_ink(true), BattleMinimap.PLAYER, "friendly markers use the player colour")
	equal(BattleMinimap.marker_ink(false), BattleMinimap.ENEMY, "hostile markers use the enemy colour")


func _test_camera_footprint() -> void:
	section("the camera footprint follows the camera's span, not a fixed crosshair")
	var rect := _rect()
	var full := BattleMinimap.viewport_rect(FIELD * 0.5, FIELD, FIELD, rect)
	check(full.size.is_equal_approx(rect.size), "a camera spanning the whole field covers the whole map")
	var half := BattleMinimap.viewport_rect(FIELD * 0.5, FIELD * 0.5, FIELD, rect)
	check(half.size.is_equal_approx(rect.size * 0.5), "halving the camera span halves the footprint")
	check(half.get_center().is_equal_approx(rect.get_center()),
		"a centred camera keeps the footprint centred")
	var zoomed := BattleMinimap.viewport_rect(Vector2.ZERO, Vector2.ZERO, FIELD, rect)
	check(zoomed.size.is_equal_approx(BattleMinimap.MIN_VIEWPORT_PX),
		"a fully zoomed-in camera still draws a visible footprint")
	var off_map := BattleMinimap.viewport_rect(Vector2(-500.0, -500.0), FIELD * 4.0, FIELD, rect)
	check(off_map.position.x >= rect.position.x - 0.01 and off_map.position.y >= rect.position.y - 0.01,
		"a camera beyond the field clamps inside the map rather than drawing outside it")


func _test_navigation_clicks_and_drags() -> void:
	section("clicking and dragging the map asks for a camera move, and nothing else")
	var minimap := _minimap()
	minimap.size = Vector2(420.0, 260.0)
	var asked: Array[Vector2] = []
	minimap.navigate_requested.connect(func(world: Vector2): asked.append(world))
	var map := minimap._map_rect()
	minimap._gui_input(_press(map.get_center(), true))
	equal(asked.size(), 1, "a press inside the map asks for one move")
	if asked.size() == 1:
		check(asked[0].distance_to(FIELD * 0.5) < 1.5,
			"and it asks for the world point that was clicked")
	minimap._gui_input(_motion(map.get_center() + Vector2(40.0, 0.0)))
	equal(asked.size(), 2, "dragging inside the map asks again as the pointer moves")
	minimap._gui_input(_press(map.get_center(), false))
	var before_release := asked.size()
	minimap._gui_input(_motion(map.get_center() + Vector2(80.0, 0.0)))
	equal(asked.size(), before_release, "after the release, moving the pointer asks for nothing")
	# A press that never touched the map asks for nothing at all - including, per its own dedicated test
	# below, one that later slides onto the map.
	minimap._gui_input(_press(Vector2(1.0, 1.0), true))
	equal(asked.size(), before_release, "a press outside the map asks for nothing")
	minimap._gui_input(_press(Vector2(1.0, 1.0), false))
	minimap.free()


func _test_resize_behaviour() -> void:
	section("the layout follows the control's size instead of caching a rectangle")
	var minimap := _minimap()
	minimap.size = Vector2(300.0, 200.0)
	var small := minimap._map_rect()
	minimap.size = Vector2(600.0, 400.0)
	var large := minimap._map_rect()
	check(large.size.x > small.size.x and large.size.y > small.size.y,
		"a larger control gets a larger map rectangle")
	equal(large.position, small.position, "and the margins stay the same")
	var anchor := Vector2(100.0, 50.0)
	var before := BattleMinimap.world_to_map(anchor, FIELD, small)
	var after := BattleMinimap.world_to_map(anchor, FIELD, large)
	check(not after.is_equal_approx(before), "a fixed world point projects somewhere new after a resize")
	minimap.size = Vector2(10.0, 10.0)
	var tiny := minimap._map_rect()
	check(tiny.size.x >= 1.0 and tiny.size.y >= 1.0,
		"an absurdly small control still yields a usable rect")
	minimap.free()


func _test_markers_stay_inside_the_map_at_the_edges() -> void:
	section("a marker on the field's edge stays inside the map instead of spilling over the panel")
	var rect := _rect()
	var depth := 10.0
	var span := 4.0
	var edge_anchors := [Vector2.ZERO, Vector2(FIELD.x, 0.0), Vector2(0.0, FIELD.y), FIELD,
		Vector2(FIELD.x * 0.5, 0.0), Vector2(FIELD.x * 0.5, FIELD.y),
		Vector2(0.0, FIELD.y * 0.5), Vector2(FIELD.x, FIELD.y * 0.5)]
	for anchor in edge_anchors:
		var polygon := BattleMinimap.marker_polygon(anchor, Vector2.RIGHT, depth, span, FIELD, rect)
		var inside := true
		for point in polygon:
			var past_left := point.x < rect.position.x - 0.01
			var past_right := point.x > rect.end.x + 0.01
			var past_top := point.y < rect.position.y - 0.01
			var past_bottom := point.y > rect.end.y + 0.01
			if past_left or past_right or past_top or past_bottom:
				inside = false
		check(inside, "a marker anchored at %s stays within the map rectangle" % str(anchor))
	var centred := _bounds(BattleMinimap.marker_polygon(FIELD * 0.5, Vector2.RIGHT, depth, span,
		FIELD, rect))
	check(absf(centred.size.x - depth * 2.0 * (rect.size.x / FIELD.x)) < 0.01,
		"a marker in open field keeps its full width, so the clamp only bites at the boundary")
	check(absf(centred.size.y - span * 2.0 * (rect.size.y / FIELD.y)) < 0.01,
		"and keeps its full height")


func _test_the_camera_footprint_never_leaves_the_map() -> void:
	section("a camera footprint stays wholly inside the map, at every corner and at any zoom")
	var rect := _rect()
	var corners := [Vector2.ZERO, Vector2(FIELD.x, 0.0), Vector2(0.0, FIELD.y), FIELD]
	var spans := [Vector2.ZERO, Vector2(4.0, 4.0), Vector2(12.0, 8.0)]
	for corner in corners:
		for span in spans:
			var footprint := BattleMinimap.viewport_rect(corner, span, FIELD, rect)
			var inside_left := footprint.position.x >= rect.position.x - 0.01
			var inside_top := footprint.position.y >= rect.position.y - 0.01
			var inside_right := footprint.end.x <= rect.end.x + 0.01
			var inside_bottom := footprint.end.y <= rect.end.y + 0.01
			check(inside_left and inside_top and inside_right and inside_bottom,
				"a camera at %s with span %s keeps its whole footprint inside the map" % [
					str(corner), str(span)])
	for span in [FIELD, FIELD * 2.0, FIELD * 8.0]:
		var footprint := BattleMinimap.viewport_rect(FIELD * 0.5, span, FIELD, rect)
		check(footprint.position.is_equal_approx(rect.position)
			and footprint.end.is_equal_approx(rect.end),
			"a camera span of %s covers the map and no more" % str(span))
	var corner_cam := BattleMinimap.viewport_rect(Vector2(FIELD.x, FIELD.y * 0.5), Vector2.ZERO,
		FIELD, rect)
	check(corner_cam.size.is_equal_approx(BattleMinimap.MIN_VIEWPORT_PX),
		"a zero-span camera at the map's right edge keeps its minimum size rather than being squashed")
	check(corner_cam.end.y <= rect.end.y + 0.01,
		"and is moved inside rather than allowed to hang past the edge")
	check(corner_cam.position.x < rect.end.x, "so the whole footprint sits within the map")


func _test_a_hostile_formation_can_never_be_highlighted() -> void:
	section("the helpers refuse to highlight a hostile formation, whatever a caller passes")
	check(BattleMinimap.marker_outline(false, true) != BattleMinimap.SELECTION,
		"marker_outline(false, true) does not return the selection colour")
	equal(BattleMinimap.marker_outline(false, true), BattleMinimap.marker_ink(false).lightened(0.35),
		"it returns the hostile outline instead")
	check(BattleMinimap.marker_tip_colour(false, true) != BattleMinimap.SELECTION,
		"marker_tip_colour(false, true) does not return the selection colour")
	equal(BattleMinimap.marker_tip_colour(false, true), BattleMinimap.marker_ink(false).lightened(0.45),
		"it returns the hostile tip colour instead")
	equal(BattleMinimap.marker_outline(true, true), BattleMinimap.SELECTION,
		"a friendly chosen formation still gets the selection colour")
	equal(BattleMinimap.marker_tip_colour(true, true), BattleMinimap.SELECTION, "and so does its tip")


func _test_a_drag_started_outside_the_map_never_navigates() -> void:
	section("a drag that starts outside the map cannot navigate, even once it moves inside")
	var minimap := _minimap()
	minimap.size = Vector2(420.0, 260.0)
	var asked: Array[Vector2] = []
	minimap.navigate_requested.connect(func(world: Vector2): asked.append(world))
	var map := minimap._map_rect()
	var outside := Vector2(4.0, 4.0)
	check(not map.has_point(outside), "the point being pressed really is outside the map")
	minimap._gui_input(_press(outside, true))
	equal(asked.size(), 0, "pressing outside the map asks for nothing")
	minimap._gui_input(_motion(map.get_center()))
	equal(asked.size(), 0, "dragging in from outside asks for nothing, even over the map")
	minimap._gui_input(_motion(map.get_center() + Vector2(30.0, 10.0)))
	equal(asked.size(), 0, "and keeps asking for nothing while the button is held")
	minimap._gui_input(_press(outside, false))
	minimap._gui_input(_motion(map.get_center()))
	equal(asked.size(), 0, "and nothing after the release either")
	minimap._gui_input(_press(map.get_center(), true))
	equal(asked.size(), 1, "but a press that starts on the map still navigates")
	minimap._gui_input(_motion(map.get_center() + Vector2(30.0, 10.0)))
	equal(asked.size(), 2, "and its drag keeps navigating")
	minimap.free()


func _test_functional_without_terrain_imagery() -> void:
	section("no terrain image is a first-class state, not a broken one")
	var minimap := _minimap(Vector2(300.0, 150.0))
	check(not minimap.has_terrain_texture(), "it reports that it has no imagery")
	check(minimap._world_size.is_equal_approx(Vector2(300.0, 150.0)),
		"the world size is recorded even with no image, so projection still means something")
	var rect := BattleMinimap.viewport_rect(Vector2(150.0, 75.0), Vector2(300.0, 150.0),
		minimap._world_size, minimap._map_rect())
	check(rect.size.x > 0.0 and rect.size.y > 0.0,
		"the camera footprint still draws with no terrain image")
	minimap.set_battle_state([_formation(1, 0, Vector2(50.0, 25.0), Vector2.RIGHT)], [1],
		Vector2(150.0, 75.0), Vector2(300.0, 150.0))
	var polygon := BattleMinimap.marker_polygon(Vector2(50.0, 25.0), Vector2.RIGHT, 4.0, 6.0,
		minimap._world_size, minimap._map_rect())
	equal(polygon.size(), 4, "and formation markers still project with no terrain image")
	minimap.set_terrain_texture(null, Vector2(100.0, 100.0))
	check(minimap._world_size.is_equal_approx(Vector2(100.0, 100.0)),
		"clearing the image keeps a usable world size")
	minimap.free()


func _code_of(source: String) -> String:
	## The source with its comments removed, so an assertion about what the code CALLS cannot be tripped by a
	## comment that merely mentions the same name.
	var code := ""
	for line in source.split("\n"):
		var marker := line.find("#")
		code += (line if marker < 0 else line.substr(0, marker)) + "\n"
	return code


func _bounds(points: PackedVector2Array) -> Rect2:
	var low := points[0]
	var high := points[0]
	for point in points:
		low = Vector2(minf(low.x, point.x), minf(low.y, point.y))
		high = Vector2(maxf(high.x, point.x), maxf(high.y, point.y))
	return Rect2(low, high - low)


func _centroid(points: PackedVector2Array) -> Vector2:
	var total := Vector2.ZERO
	for point in points:
		total += point
	return total / float(points.size())


func _press(position: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	return event


func _motion(position: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = position
	return event
