class_name BattleFormationNavigator
extends RefCounted
## Deterministic terrain-aware routing for whole formation anchors.
## A wider/deeper formation needs a larger corridor than a single soldier.
## No per-frame or per-agent path searches: callers plan only when ordering.
##
## The integral occupancy map allows O(1) rectangular clearance checks.
## Grids are cached by clearance radius; each expensive grid is built once.

const SEARCH_RADIUS_CELLS := 12
const PATH_EPSILON := 0.001

var _terrain: BattlefieldTerrain = null
var _grids: Dictionary = {} # clearance radius in cells -> AStarGrid2D
var _blocked_prefix := PackedInt32Array()


func setup(terrain: BattlefieldTerrain) -> bool:
	_terrain = terrain
	_grids.clear()
	_blocked_prefix = PackedInt32Array()
	if terrain == null or not terrain.is_valid():
		return false
	_build_occupancy()
	_grid_for_radius(0)
	return true


func is_ready() -> bool:
	return _terrain != null and _terrain.is_valid() and _grids.has(0)


## Radius is the disc enclosing the actual files/ranks at any facing,
## conservatively reduced by half a cell because A* works on cell centres.
## The body never silently squeezes through narrower gaps or changes its
## player-selected formation width.
static func footprint_radius(files: int, ranks: int, spacing: float) -> float:
	var half_span := float(maxi(0, files - 1)) * maxf(0.1, spacing) * 0.5 + 0.5
	var half_depth := float(maxi(0, ranks - 1)) * maxf(0.1, spacing) * 0.5 + 0.5
	# A rotated rectangle's far corner is the diagonal, not the larger
	# half-dimension. The previous max() allowed corners to clip into walls.
	return sqrt(half_span * half_span + half_depth * half_depth)


static func clearance_cells(terrain: BattlefieldTerrain, files: int,
		ranks: int, spacing: float) -> int:
	if terrain == null or not terrain.is_valid():
		return 0
	return maxi(0, ceili((footprint_radius(files, ranks, spacing) -
		terrain.cell_size * 0.5) / maxf(0.1, terrain.cell_size)))


func _build_occupancy() -> void:
	var pitch := _terrain.cols + 1
	_blocked_prefix.resize(pitch * (_terrain.rows + 1))
	_blocked_prefix.fill(0)
	for row in _terrain.rows:
		for col in _terrain.cols:
			var idx := row * _terrain.cols + col
			var slot := (row + 1) * pitch + col + 1
			var blocked := 0 if _terrain.is_cell_traversable(idx) else 1
			_blocked_prefix[slot] = blocked + _blocked_prefix[slot - 1] 				+ _blocked_prefix[slot - pitch] 				- _blocked_prefix[slot - pitch - 1]


func _fits(cell: Vector2i, radius: int) -> bool:
	var x0 := cell.x - radius
	var y0 := cell.y - radius
	var x1 := cell.x + radius
	var y1 := cell.y + radius
	if x0 < 0 or y0 < 0 or x1 >= _terrain.cols or y1 >= _terrain.rows:
		return false
	var pitch := _terrain.cols + 1
	var occupied := _blocked_prefix[(y1 + 1) * pitch + x1 + 1] 		- _blocked_prefix[y0 * pitch + x1 + 1] 		- _blocked_prefix[(y1 + 1) * pitch + x0] 		+ _blocked_prefix[y0 * pitch + x0]
	return occupied == 0


func _grid_for_radius(radius: int) -> AStarGrid2D:
	if _grids.has(radius):
		return _grids[radius] as AStarGrid2D
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, _terrain.cols, _terrain.rows)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	for row in _terrain.rows:
		for col in _terrain.cols:
			var cell := Vector2i(col, row)
			if not _fits(cell, radius):
				grid.set_point_solid(cell, true)
				continue
			var index := row * _terrain.cols + col
			grid.set_point_weight_scale(cell, 1.0 / maxf(0.05,
				_terrain.move_multiplier_of_cell(index)))
	_grids[radius] = grid
	return grid


func _cell(point: Vector2) -> Vector2i:
	return Vector2i(_terrain.cell_col_at(point), _terrain.cell_row_at(point))


func _walkable(cell: Vector2i, grid: AStarGrid2D) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= _terrain.cols or cell.y >= _terrain.rows:
		return false
	return not grid.is_point_solid(cell)


## Uses the terrain's authoritative composed movement multiplier.
static func speed_scale(terrain: BattlefieldTerrain, point: Vector2) -> float:
	if terrain == null or not terrain.is_valid():
		return 1.0
	var cell := terrain.cell_index_at(point)
	if cell < 0:
		return 1.0
	return clampf(terrain.move_multiplier_of_cell(cell), 0.05, 1.0)


func _nearest_walkable(wanted: Vector2i, grid: AStarGrid2D) -> Vector2i:
	if _walkable(wanted, grid):
		return wanted
	for radius in range(1, SEARCH_RADIUS_CELLS + 1):
		var chosen := Vector2i(-1, -1)
		var best := INF
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if maxi(absi(x), absi(y)) != radius:
					continue
				var candidate := wanted + Vector2i(x, y)
				if not _walkable(candidate, grid):
					continue
				var score := float((candidate - wanted).length_squared())
				if score < best:
					best = score
					chosen = candidate
		if chosen.x >= 0:
			return chosen
	return Vector2i(-1, -1)


## clearance_radius is a world-unit radius enclosing the formation; zero
## retains legacy single-anchor behaviour for old tests and probes.
## When a destination lies in an obstacle, seek the nearest *reachable*
## alternative on the army's side of the wall.
func route(start: Vector2, destination: Vector2,
		clearance_radius: float = 0.0) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not is_ready():
		return result
	var radius := maxi(0, ceili((clearance_radius - _terrain.cell_size * 0.5) /
		maxf(0.1, _terrain.cell_size)))
	var grid := _grid_for_radius(radius)
	var from := _nearest_walkable(_cell(start), grid)
	if from.x < 0:
		return result
	var wanted := _cell(destination)
	var to := wanted
	var cells: Array[Vector2i] = []
	if _walkable(wanted, grid):
		cells = grid.get_id_path(from, wanted)
	else:
		for search_radius in range(1, SEARCH_RADIUS_CELLS + 1):
			var best_score := INF
			for y in range(-search_radius, search_radius + 1):
				for x in range(-search_radius, search_radius + 1):
					if maxi(absi(x), absi(y)) != search_radius:
						continue
					var candidate := wanted + Vector2i(x, y)
					if not _walkable(candidate, grid):
						continue
					var attempt: Array[Vector2i] = grid.get_id_path(from, candidate)
					if attempt.is_empty():
						continue
					# A one-element path whose only cell is the formation's own tile
					# means walking anywhere was impossible: standing still is not a
					# routing plan, so the command must be rejected, not rewritten
					# onto the formation's current position.
					if attempt.size() == 1 and attempt[0] == from:
						continue
					var score := float((candidate - wanted).length_squared())
					if score < best_score:
						best_score = score
						to = candidate
						cells = attempt
			if not cells.is_empty():
				break
	if cells.is_empty():
		return result
	if cells.size() > 1:
		var last_direction := Vector2i.ZERO
		for i in range(1, cells.size()):
			var direction := cells[i] - cells[i - 1]
			if i > 1 and direction != last_direction:
				var corner := cells[i - 1]
				result.append(_terrain.cell_centre(
					_terrain.cell_of_col_row(corner.x, corner.y)))
			last_direction = direction
	# Cell-centre final targets prevent the corners of a broad formation
	# from clipping an obstacle because the click landed at a tile boundary.
	var end := destination if radius == 0 and to == wanted else 		_terrain.cell_centre(_terrain.cell_of_col_row(to.x, to.y))
	if result.is_empty() or result[result.size() - 1].distance_to(end) > PATH_EPSILON:
		result.append(end)
	return result


func route_avoids_obstacles(points: PackedVector2Array,
		clearance_radius: float = 0.0) -> bool:
	if not is_ready():
		return false
	var radius := maxi(0, ceili((clearance_radius - _terrain.cell_size * 0.5) /
		maxf(0.1, _terrain.cell_size)))
	var grid := _grid_for_radius(radius)
	for point in points:
		if not _walkable(_cell(point), grid):
			return false
	return true
