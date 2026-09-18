class_name TravelCosts

## What a piece of ground costs to cross, as a coarse grid, and the A* that runs on it.
##
## The owner's model, and it replaces two: "stop thinking about it as in follow road and follow terrain,
## and instead think of it as a pathfinding system where each tile is point based."
##
## One number per cell - game hours to cross one world unit of it - and everything else falls out of
## that. Roads are not a special case: a road is a run of cells with a lower cost, so a route prefers one
## for exactly the same reason it avoids a marsh. The straight-line-versus-road comparison that used to
## live in the travel service has nothing left to compare.
##
## The grid is 64 world units a cell, and that is a measurement rather than a taste. A field sample costs
## 33 microseconds; at 64 units a world of 4096 is 4,096 cells and about 136 ms to build once, where at
## the field's own 8 units it would be 262,144 cells and eight and a half seconds.

const CELL := 64.0
const COLUMNS := 64
const ROWS := 64

## Game hours to cross one world unit. Indexed row * COLUMNS + column.
var _cost := PackedFloat32Array()
var _ready := false


func build(seed_value: int, config: GameConfig, roads: Array, settlements: Dictionary) -> void:
	var started := Time.get_ticks_msec()
	var world := WorldChunks.build(seed_value)
	_cost.resize(COLUMNS * ROWS)
	var base := maxf(1.0, config.get_float("travel.world_units_per_game_hour", 150.0))
	var water := config.get_float("travel.water_speed_factor", 0.30)
	var marsh := config.get_float("travel.marsh_speed_factor", 0.55)
	var water_height := config.get_float("travel.water_height", 0.335)
	var marsh_height := config.get_float("travel.marsh_height", 0.375)
	var road_bonus := config.get_float("travel.road_speed_bonus", 1.4)

	for row in ROWS:
		for column in COLUMNS:
			var point := Vector2((float(column) + 0.5) * CELL, (float(row) + 0.5) * CELL)
			var here: Dictionary = world.sample(point)
			var height := float(here.get("height", 0.5))
			var wear := float(here.get("wear", 0.0))
			var moisture := float(here.get("moisture", 0.5))
			var factor := 1.0
			if height < water_height:
				factor = water
			elif height < marsh_height:
				factor = marsh
			elif wear > 0.5:
				factor = 1.1
			elif moisture > 0.6:
				factor = 0.9
			_cost[row * COLUMNS + column] = 1.0 / (base * maxf(0.05, factor))

	# Roads are cheaper ground. Every cell a road passes through gets the road's speed, found by walking
	# the same curve the map draws, so what the player sees and what the pathfinder prices agree.
	var road_cost := 1.0 / (base * road_bonus)
	for road in roads:
		var a := settlements.get(str(road.get("a", "")), null) as Settlement
		var b := settlements.get(str(road.get("b", "")), null) as Settlement
		if a == null or b == null:
			continue
		var path := RoadPath.between(a.position, b.position)
		for i in path.size() - 1:
			var from := path[i]
			var to := path[i + 1]
			var span := from.distance_to(to)
			var steps := maxi(1, int(ceil(span / (CELL * 0.5))))
			for s in steps + 1:
				var at := from.lerp(to, float(s) / float(steps))
				var cell := cell_at(at)
				if cell.x < 0 or cell.y < 0 or cell.x >= COLUMNS or cell.y >= ROWS:
					continue
				var index := cell.y * COLUMNS + cell.x
				_cost[index] = minf(_cost[index], road_cost)

	_ready = true
	print("travel costs: %dx%d cells of %d units in %.0f ms" % [COLUMNS, ROWS, int(CELL), float(Time.get_ticks_msec() - started)])


func is_ready() -> bool:
	return _ready


## The highest cost on the grid, for scaling a colour ramp. Water is near-impassable and would flatten
## everything else, so the top two per cent are ignored when finding it.
func dearest() -> float:
	if not _ready:
		return 1.0
	var sorted := Array(_cost)
	sorted.sort()
	var index := maxi(0, int(float(sorted.size()) * 0.98) - 1)
	return maxf(0.0001, float(sorted[index]))


func cell_at(position: Vector2) -> Vector2i:
	return Vector2i(int(floorf(position.x / CELL)), int(floorf(position.y / CELL)))


func centre(cell: Vector2i) -> Vector2:
	return Vector2((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL)


func cost_of(cell: Vector2i) -> float:
	if not _ready or cell.x < 0 or cell.y < 0 or cell.x >= COLUMNS or cell.y >= ROWS:
		return INF
	return _cost[cell.y * COLUMNS + cell.x]


## Whether a straight line between two points stays off the expensive ground. Used to pull the staircase
## out of a path: a corner may be dropped when the line that replaces it crosses nothing worse than the
## cells the path already uses.
func clear_line(from: Vector2, to: Vector2, limit: float) -> bool:
	var span := from.distance_to(to)
	var steps := maxi(1, int(ceil(span / (CELL * 0.5))))
	for s in steps + 1:
		var at := from.lerp(to, float(s) / float(steps))
		if cost_of(cell_at(at)) > limit:
			return false
	return true


## The cheapest path between two world points, as world points. A* over eight neighbours with a
## deterministic tie-break, because the same order must produce the same path every time - the same rule
## the battle simulation lives by.
func path_between(from: Vector2, to: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not _ready:
		return PackedVector2Array([from, to])
	var start := cell_at(from)
	var goal := cell_at(to)
	if start == goal:
		return PackedVector2Array([from, to])

	var total := COLUMNS * ROWS
	var came := PackedInt32Array()
	came.resize(total)
	came.fill(-1)
	var g := PackedFloat32Array()
	g.resize(total)
	g.fill(INF)
	var closed := PackedByteArray()
	closed.resize(total)
	closed.fill(0)

	var start_index := start.y * COLUMNS + start.x
	var goal_index := goal.y * COLUMNS + goal.x
	g[start_index] = 0.0
	var open: Array[int] = [start_index]

	var neighbours: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]

	while not open.is_empty():
		# Cheapest by f, then by index: the tie-break is what makes two runs identical.
		var best := 0
		for i in open.size():
			var candidate := open[i]
			var fb := g[candidate] + _heuristic(candidate, goal_index)
			var current := open[best]
			var fc := g[current] + _heuristic(current, goal_index)
			if fb < fc - 0.0000001 or (absf(fb - fc) <= 0.0000001 and candidate < current):
				best = i
		var node := open[best]
		open.remove_at(best)
		if node == goal_index:
			break
		if closed[node] == 1:
			continue
		closed[node] = 1

		var cell := Vector2i(node % COLUMNS, node / COLUMNS)
		for step in neighbours:
			var next: Vector2i = cell + step
			if next.x < 0 or next.y < 0 or next.x >= COLUMNS or next.y >= ROWS:
				continue
			var next_index: int = next.y * COLUMNS + next.x
			if closed[next_index] == 1:
				continue
			var diagonal: bool = step.x != 0 and step.y != 0
			var leg := (CELL * 1.4142) if diagonal else CELL
			var step_cost := cost_of(next) * leg
			if diagonal:
				# Do not cut a corner between two blocked cells.
				step_cost = maxf(step_cost, (_cost_of_raw(cell) + _cost_of_raw(Vector2i(cell.x + step.x, cell.y)) + _cost_of_raw(Vector2i(cell.x, cell.y + step.y))) * leg * 0.5)
			var tentative := g[node] + step_cost
			if tentative < g[next_index]:
				g[next_index] = tentative
				came[next_index] = node
				open.append(next_index)

	if came[goal_index] == -1 and goal_index != start_index:
		return PackedVector2Array([from, to])

	# Walk the parents back, then reverse: cell centres, with the true endpoints at each end.
	var chain: Array[Vector2i] = []
	var at := goal_index
	while at != -1 and at != start_index:
		chain.append(Vector2i(at % COLUMNS, at / COLUMNS))
		at = came[at]
	chain.reverse()

	var limit := cost_of(goal) * 1.6
	var smoothed := PackedVector2Array([from])
	var anchor := from
	for point in chain:
		var centre_point := centre(point)
		if clear_line(anchor, centre_point, limit):
			continue
		smoothed.append(anchor)
		anchor = centre_point
	smoothed.append(to)
	return smoothed


func _cost_of_raw(cell: Vector2i) -> float:
	if cell.x < 0 or cell.y < 0 or cell.x >= COLUMNS or cell.y >= ROWS:
		return 0.0
	return _cost[cell.y * COLUMNS + cell.x]


func _heuristic(from_index: int, to_index: int) -> float:
	var a := Vector2i(from_index % COLUMNS, from_index / COLUMNS)
	var b := Vector2i(to_index % COLUMNS, to_index / COLUMNS)
	return Vector2(float(a.x - b.x), float(a.y - b.y)).length() * CELL * 0.0001
