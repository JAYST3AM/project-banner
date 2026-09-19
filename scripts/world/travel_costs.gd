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
## The pace the grid was built with, kept so walking can recover a speed factor from a stored cost.
var _base := 150.0
var _ready := false
## What the grid was built from, kept so one link can be re-stamped in place: a road changing tier
## must not cost the whole map a rebuild (D-129). The roads array is the campaign's own, so a link
## whose kind changed is visible here the moment it changes.
var _world: WorldChunks = null
var _config: GameConfig = null
var _roads: Array = []
var _settlements: Dictionary = {}
var _water_factor := 0.30
var _marsh_factor := 0.55
var _water_height := 0.335
var _marsh_height := 0.375
var _bridge_max := 64.0


func build(seed_value: int, config: GameConfig, roads: Array, settlements: Dictionary) -> void:
	var started := Time.get_ticks_msec()
	_world = WorldChunks.build(seed_value)
	_config = config
	_roads = roads
	_settlements = settlements
	_base = maxf(1.0, config.get_float("travel.world_units_per_game_hour", 150.0))
	_water_factor = config.get_float("travel.water_speed_factor", 0.30)
	_marsh_factor = config.get_float("travel.marsh_speed_factor", 0.55)
	_water_height = config.get_float("travel.water_height", 0.335)
	_marsh_height = config.get_float("travel.marsh_height", 0.375)
	_bridge_max = config.get_float("roads.bridge_max_span", 64.0)
	_cost.resize(COLUMNS * ROWS)

	for row in ROWS:
		for column in COLUMNS:
			var point := Vector2((float(column) + 0.5) * CELL, (float(row) + 0.5) * CELL)
			_cost[row * COLUMNS + column] = _terrain_cost_at(point)

	# Roads are cheaper ground, at the price their tier carries. Every cell a road passes through gets
	# that link's speed, found by walking the same curve the map draws, so what the player sees and
	# what the pathfinder prices agree. A roadless link (tier "none") stamps nothing at all.
	for raw in roads:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		_stamp_link(raw as Dictionary, {})

	_ready = true
	print("travel costs: %dx%d cells of %d units in %.0f ms" % [COLUMNS, ROWS, int(CELL), float(Time.get_ticks_msec() - started)])


## The price of one cell of bare ground, from the same field the ground is painted from.
func _terrain_cost_at(point: Vector2) -> float:
	var here: Dictionary = _world.sample(point)
	var height := float(here.get("height", 0.5))
	var wear := float(here.get("wear", 0.0))
	var moisture := float(here.get("moisture", 0.5))
	var factor := 1.0
	if height < _water_height:
		factor = _water_factor
	elif height < _marsh_height:
		factor = _marsh_factor
	elif wear > 0.5:
		factor = 1.1
	elif moisture > 0.6:
		factor = 0.9
	return 1.0 / (_base * maxf(0.05, factor))


## A link's curve: the same terrain-shaped line the map draws and the snap rides, bridges included.
func _link_path(road: Dictionary) -> PackedVector2Array:
	var a := _settlements.get(str(road.get("a", "")), null) as Settlement
	var b := _settlements.get(str(road.get("b", "")), null) as Settlement
	if a == null or b == null:
		return PackedVector2Array()
	return RoadPath.between(a.position, b.position, _world, _water_height, _bridge_max)


## One link's stamp, at the price its tier carries. [param only] limits the write to the cells it
## names (empty = every cell the curve touches). A roadless link stamps nothing.
func _stamp_link(road: Dictionary, only: Dictionary) -> void:
	var tier := str(road.get("kind", "road"))
	if tier == "none":
		return
	var path := _link_path(road)
	if path.size() < 2:
		return
	var road_cost := 1.0 / (_base * _tier_bonus(_config, tier))
	for i in path.size() - 1:
		var from := path[i]
		var to := path[i + 1]
		var span := from.distance_to(to)
		var steps := maxi(1, int(ceil(span / (CELL * 0.5))))
		for s in steps + 1:
			var cell := cell_at(from.lerp(to, float(s) / float(steps)))
			if cell.x < 0 or cell.y < 0 or cell.x >= COLUMNS or cell.y >= ROWS:
				continue
			if not only.is_empty() and not only.has(cell):
				continue
			var index := cell.y * COLUMNS + cell.x
			_cost[index] = minf(_cost[index], road_cost)


## One link changed tier: re-price the ground it touches, and only that ground. Its cells are
## recomputed as bare terrain, then every link stamps them again - so a cell shared with another
## road keeps that road's price, and the result is the grid a full rebuild would have produced.
## Where a full rebuild froze the map for a fifth of a second, this costs one link's footprint.
func apply_tier(link_index: int) -> void:
	if not _ready or _world == null or link_index < 0 or link_index >= _roads.size():
		return
	var raw: Variant = _roads[link_index]
	if typeof(raw) != TYPE_DICTIONARY:
		return
	var path := _link_path(raw as Dictionary)
	if path.size() < 2:
		return
	var touched := {}
	for i in path.size() - 1:
		var from := path[i]
		var to := path[i + 1]
		var span := from.distance_to(to)
		var steps := maxi(1, int(ceil(span / (CELL * 0.5))))
		for s in steps + 1:
			var cell := cell_at(from.lerp(to, float(s) / float(steps)))
			if cell.x < 0 or cell.y < 0 or cell.x >= COLUMNS or cell.y >= ROWS:
				continue
			touched[cell] = true
	for cell in touched:
		_cost[cell.y * COLUMNS + cell.x] = _terrain_cost_at(centre(cell))
	for other in _roads:
		if typeof(other) != TYPE_DICTIONARY:
			continue
		_stamp_link(other as Dictionary, touched)


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


## The speed factor the grid itself was built from at a point: walking reads the exact number the
## pathfinder priced, so the pace on a road is the road's own price and not a second opinion.
func factor_at(point: Vector2) -> float:
	var cost := cost_of(cell_at(point))
	if cost == INF:
		return 1.0
	return 1.0 / maxf(0.0001, cost * _base)


## The speed factor a link's tier carries, from the roads block of the config. The old single
## travel.road_speed_bonus stays the fallback for the top tier, so a config from before the tiers
## still prices its roads the same.
func _tier_bonus(config: GameConfig, tier: String) -> float:
	var fallback := config.get_float("travel.road_speed_bonus", 1.4) if tier == "road" else 1.0
	return maxf(1.0, config.get_float("roads.speed_bonus." + tier, fallback))


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
