extends TestCase
## Formation routing must respect all real map obstructions and terrain costs.
## The GPU agent solver is separate: this suite pins formation-anchor orders.


func run() -> void:
	await _tick()
	_test_route_avoids_obstacle_wall()
	_test_route_is_deterministic()
	_test_blocked_destination_resolves_to_nearest_open()
	_test_no_blocked_destination_is_not_a_straight_line()
	_test_blocked_cell_prefers_reachable_side()
	_test_ground_speed_from_authoritative_channel()
	_test_narrow_gap_rejects_wide_formation()
	_test_broad_gap_allows_formed_unit()
	_test_clearance_restricts_field_edges()
	_complete()


func _fixture() -> BattlefieldTerrain:
	var terrain := BattlefieldTerrain.generate(83406, Vector2(82.0, 50.0),
		GameManager.config())
	if not terrain.is_valid():
		return terrain
	# Test custom obstacles against an otherwise clean actual grid. This
	# isolates A* behaviour from the random biome's particular rivers.
	terrain._traversable.fill(1)
	terrain._move.fill(1.0)
	return terrain


func _point(terrain: BattlefieldTerrain, col: int, row: int) -> Vector2:
	return terrain.cell_centre(terrain.cell_of_col_row(col, row))


func _test_route_avoids_obstacle_wall() -> void:
	section("orders go around obstructions instead of marching through them")
	var terrain := _fixture()
	check(terrain.is_valid(), "test field builds")
	if not terrain.is_valid() or terrain.cols < 12 or terrain.rows < 12:
		return
	var wall := terrain.cols / 2
	var opening := terrain.rows / 2
	for y in terrain.rows:
		if y != opening:
			terrain._traversable[y * terrain.cols + wall] = 0
	var navigator := BattleFormationNavigator.new()
	check(navigator.setup(terrain), "pathfinding grid is ready")
	var route := navigator.route(_point(terrain, 2, 2),
		_point(terrain, terrain.cols - 3, 2))
	check(route.size() > 2, "a route needs intermediate turns through the wall opening")
	check(navigator.route_avoids_obstacles(route), "each waypoint remains on passable ground")
	var crossed_near_gap := false
	var previous := _point(terrain, 2, 2)
	for point in route:
		var count := maxi(1, ceili(previous.distance_to(point) /
			maxf(0.2, terrain.cell_size * 0.25)))
		for i in range(count + 1):
			var sample := previous.lerp(point, float(i) / float(count))
			var cell := terrain.cell_index_at(sample)
			if cell >= 0:
				if terrain.cell_col_at(sample) == wall and terrain.cell_row_at(sample) == opening:
					crossed_near_gap = true
				check(terrain.is_cell_traversable(cell),
					"sampled route segment avoids blocked cells")
		previous = point
	check(crossed_near_gap, "route crosses through the actual wall opening")

func _test_route_is_deterministic() -> void:
	section("identical battle state produces identical movement orders")
	var terrain := _fixture()
	var navigator := BattleFormationNavigator.new()
	navigator.setup(terrain)
	var start := _point(terrain, 2, 2)
	var target := _point(terrain, terrain.cols - 3, terrain.rows - 3)
	var a := navigator.route(start, target)
	var b := navigator.route(start, target)
	equal(a, b, "same formation order and terrain yield identical path corners")


func _test_blocked_destination_resolves_to_nearest_open() -> void:
	section("a command on a rock moves to accessible ground nearby")
	var terrain := _fixture()
	var target := Vector2i(terrain.cols / 2, terrain.rows / 2)
	terrain._traversable[target.y * terrain.cols + target.x] = 0
	var navigator := BattleFormationNavigator.new()
	navigator.setup(terrain)
	var result := navigator.route(_point(terrain, 1, 1),
		_point(terrain, target.x, target.y))
	check(not result.is_empty(), "a blocked target can resolve to an adjacent open tile")
	if not result.is_empty():
		check(terrain.cell_index_at(result[result.size() - 1]) >= 0,
			"replacement destination is in the field")
		check(navigator.route_avoids_obstacles(result),
			"new destination remains traversable")


func _test_no_blocked_destination_is_not_a_straight_line() -> void:
	section("unreachable destination does not silently issue unsafe movement")
	var terrain := _fixture()
	var target := Vector2i(terrain.cols / 2, terrain.rows / 2)
	for y in terrain.rows:
		for x in terrain.cols:
			var cell := Vector2i(x, y)
			if cell != Vector2i(1, 1):
				terrain._traversable[y * terrain.cols + x] = 0
	var navigator := BattleFormationNavigator.new()
	navigator.setup(terrain)
	var result := navigator.route(_point(terrain, 1, 1),
		_point(terrain, target.x, target.y))
	check(result.is_empty(), "a blocked command is rejected, not routed through solid cells")


func _test_blocked_cell_prefers_reachable_side() -> void:
	section("blocked target resolves to the army's reachable side of a wall")
	var terrain := _fixture()
	if terrain.cols < 10 or terrain.rows < 8:
		check(false, "wall fixture has adequate cells")
		return
	var wall := terrain.cols / 2
	var middle := terrain.rows / 2
	for row in terrain.rows:
		terrain._traversable[row * terrain.cols + wall] = 0
	var navigator := BattleFormationNavigator.new()
	check(navigator.setup(terrain), "routing grid initialized")
	var source := _point(terrain, wall + 3, middle)
	var blocked_target := _point(terrain, wall, middle)
	var plan := navigator.route(source, blocked_target)
	check(not plan.is_empty(), "right-side army can route beside the solid target")
	if not plan.is_empty():
		var last := plan[plan.size() - 1]
		check(terrain.cell_col_at(last) > wall,
			"the resolved target remains on the source's accessible side")
		check(navigator.route_avoids_obstacles(plan),
			"no route corners go into blocked cells")


func _test_ground_speed_from_authoritative_channel() -> void:
	section("ground movement speed comes from terrain data rather than visuals")
	var terrain := _fixture()
	var slow := terrain.cell_of_col_row(3, 3)
	var normal := terrain.cell_of_col_row(4, 3)
	terrain._move[slow] = 0.30
	terrain._move[normal] = 1.0
	var slowdown := BattleFormationNavigator.speed_scale(
		terrain, terrain.cell_centre(slow))
	var full := BattleFormationNavigator.speed_scale(
		terrain, terrain.cell_centre(normal))
	check(is_equal_approx(slowdown, 0.30), "wet or rough ground slows a formation")
	check(is_equal_approx(full, 1.0), "clear terrain has full march pace")
	check(is_equal_approx(BattleFormationNavigator.speed_scale(null, Vector2.ZERO),
		1.0), "legacy probe without battle terrain retains normal pace")


func _test_narrow_gap_rejects_wide_formation() -> void:
	section("a full line cannot squeeze its ranks through a one-cell gate")
	var terrain := _fixture()
	var wall := terrain.cols / 2
	var gate := terrain.rows / 2
	for row in terrain.rows:
		if row != gate:
			terrain._traversable[row * terrain.cols + wall] = 0
	var nav := BattleFormationNavigator.new()
	check(nav.setup(terrain), "wall clearance grid constructed")
	var start := _point(terrain, 3, gate)
	var end := _point(terrain, terrain.cols - 4, gate)
	var single := nav.route(start, end)
	check(not single.is_empty(), "a single-file anchor can pass a one-cell opening")
	var large_radius := BattleFormationNavigator.footprint_radius(7, 2, 2.0)
	var wide := nav.route(start, end, large_radius)
	check(wide.is_empty(), "a wide formation is correctly denied the same narrow gap")
	# Planner must leave the simulation's terrain array unchanged.
	equal(terrain._traversable[gate * terrain.cols + wall], 1,
		"route planning never changes traversability or digs a new opening")


func _test_broad_gap_allows_formed_unit() -> void:
	section("units march through gaps that fit their actual frontage")
	var terrain := _fixture()
	var wall := terrain.cols / 2
	var middle := terrain.rows / 2
	for row in terrain.rows:
		if absi(row - middle) > 2:
			terrain._traversable[row * terrain.cols + wall] = 0
	var nav := BattleFormationNavigator.new()
	nav.setup(terrain)
	var radius := BattleFormationNavigator.footprint_radius(4, 2, 2.0)
	var route := nav.route(_point(terrain, 3, middle),
		_point(terrain, terrain.cols - 4, middle), radius)
	check(not route.is_empty(), "four-file formation finds the wide opening")
	check(nav.route_avoids_obstacles(route, radius),
		"every planned waypoint has the required formation clearance")
	equal(route, nav.route(_point(terrain, 3, middle),
		_point(terrain, terrain.cols - 4, middle), radius),
		"cached clearance-grid routes are deterministic")


func _test_clearance_restricts_field_edges() -> void:
	section("wide formations are kept clear of the battlefield edge")
	var terrain := _fixture()
	var nav := BattleFormationNavigator.new()
	nav.setup(terrain)
	var radius := BattleFormationNavigator.footprint_radius(4, 2, 2.0)
	var route := nav.route(_point(terrain, 4, 4),
		_point(terrain, terrain.cols - 1, 4), radius)
	check(not route.is_empty(), "border click resolves to a nearby safe position")
	if not route.is_empty():
		var last := route[route.size() - 1]
		check(terrain.cell_col_at(last) <= terrain.cols - 2,
			"formation centre stays far enough from the world edge")
		check(nav.route_avoids_obstacles(route, radius),
			"the rounded destination satisfies width clearance")
