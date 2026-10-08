extends TestCase
## Formation routing must respect all real map obstructions and terrain costs.
## The GPU agent solver is separate: this suite pins formation-anchor orders.


func run() -> void:
	await _tick()
	_test_route_avoids_obstacle_wall()
	_test_route_is_deterministic()
	_test_blocked_destination_resolves_to_nearest_open()
	_test_no_blocked_destination_is_not_a_straight_line()
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
