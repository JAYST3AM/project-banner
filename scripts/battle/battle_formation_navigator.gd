class_name BattleFormationNavigator
extends RefCounted
## CPU-side routes for *formation anchors*, not an individual-soldier pathfinder.
## Reads the authoritative battle terrain and its applied prop obstacles.
## No pathfinding is performed inside a per-frame/per-soldier GPU loop.

const SEARCH_RADIUS_CELLS := 12
const PATH_EPSILON := 0.001

var _terrain: BattlefieldTerrain = null
var _grid: AStarGrid2D = null


func setup(terrain: BattlefieldTerrain) -> bool:
	_terrain = terrain
	_grid = null
	if terrain == null or not terrain.is_valid():
		return false
	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, terrain.cols, terrain.rows)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	for row in terrain.rows:
		for col in terrain.cols:
			var index := row * terrain.cols + col
			var cell := Vector2i(col, row)
			if not terrain.is_cell_traversable(index):
				astar.set_point_solid(cell, true)
				continue
			# Slow ground should be expensive to cross, not merely darker on screen.
			astar.set_point_weight_scale(cell,
				1.0 / maxf(0.05, terrain.move_multiplier_of_cell(index)))
	_grid = astar
	return true


func is_ready() -> bool:
	return _grid != null and _terrain != null


func _cell(point: Vector2) -> Vector2i:
	return Vector2i(_terrain.cell_col_at(point), _terrain.cell_row_at(point))


func _walkable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= _terrain.cols or cell.y >= _terrain.rows:
		return false
	return not _grid.is_point_solid(cell)


## Authoritative movement pace from the field's already-composed terrain,
## soil, moisture and slope penalty. This is used by body advance and never
## recomputed from the visual textures or the colour of a tile.
static func speed_scale(terrain: BattlefieldTerrain, point: Vector2) -> float:
	if terrain == null or not terrain.is_valid():
		return 1.0
	var cell := terrain.cell_index_at(point)
	if cell < 0:
		return 1.0
	return clampf(terrain.move_multiplier_of_cell(cell), 0.05, 1.0)


## Choose a nearby reachable-looking cell when a waypoint falls inside a
## boulder, lake or cliff. The actual path search still decides connectivity.
func _nearest_walkable(wanted: Vector2i) -> Vector2i:
	if _walkable(wanted):
		return wanted
	var chosen := Vector2i(-1, -1)
	var best_distance := INF
	for radius in range(1, SEARCH_RADIUS_CELLS + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if maxi(absi(x), absi(y)) != radius:
					continue
				var candidate := wanted + Vector2i(x, y)
				if not _walkable(candidate):
					continue
				var distance := float((candidate - wanted).length_squared())
				if distance < best_distance:
					best_distance = distance
					chosen = candidate
		if chosen.x >= 0:
			break
	return chosen


## Deterministic path to a world point, with long straight runs reduced to
## corners. For blocked destinations, searches the nearest *reachable* free
## neighbour rather than choosing an inaccessible location across a barrier.
## Empty means the route is blocked/unavailable — never send a formation
## straight through the obstruction.
func route(start: Vector2, destination: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not is_ready():
		return result
	var from := _nearest_walkable(_cell(start))
	if from.x < 0:
		return result
	var requested := _cell(destination)
	var to := requested
	var cells: Array[Vector2i] = []
	if _walkable(requested):
		cells = _grid.get_id_path(from, requested)
	else:
		# A blocked click should resolve to a cell the army can actually
		# reach from its current side of the obstacle. The nearest unblocked
		# cell can otherwise be across an impassable wall.
		for radius in range(1, SEARCH_RADIUS_CELLS + 1):
			var best_score := INF
			for y in range(-radius, radius + 1):
				for x in range(-radius, radius + 1):
					if maxi(absi(x), absi(y)) != radius:
						continue
					var candidate := requested + Vector2i(x, y)
					if not _walkable(candidate):
						continue
					var attempt: Array[Vector2i] = _grid.get_id_path(from, candidate)
					if attempt.is_empty():
						continue
					var score := float((candidate - requested).length_squared())
					if score < best_score:
						best_score = score
						to = candidate
						cells = attempt
			if not cells.is_empty():
				break
	if cells.is_empty():
		return result
	if cells.size() == 1:
		result.append(destination if to == _cell(destination) else _terrain.cell_centre(
			_terrain.cell_of_col_row(to.x, to.y)))
		return result
	var last_direction := Vector2i.ZERO
	for i in range(1, cells.size()):
		var direction := cells[i] - cells[i - 1]
		# Each bend is a waypoint. Skipping straight runs keeps formation
		# movement smooth and reduces command traffic.
		if i > 1 and direction != last_direction:
			var corner := cells[i - 1]
			result.append(_terrain.cell_centre(
				_terrain.cell_of_col_row(corner.x, corner.y)))
		last_direction = direction
	var end := destination if to == _cell(destination) else _terrain.cell_centre(
		_terrain.cell_of_col_row(to.x, to.y))
	if result.is_empty() or result[result.size() - 1].distance_to(end) > PATH_EPSILON:
		result.append(end)
	return result


## For gameplay tests: no sampled waypoint may live in a blocked terrain cell.
func route_avoids_obstacles(route_points: PackedVector2Array) -> bool:
	if not is_ready():
		return false
	for point in route_points:
		if not _walkable(_cell(point)):
			return false
	return true
