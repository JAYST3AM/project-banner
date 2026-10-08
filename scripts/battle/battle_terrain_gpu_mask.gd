class_name BattleTerrainGpuMask
extends RefCounted
## Read-only terrain-collision buffer shared by the GPU walk and settle passes.
## Four int32 header values: width, height, world-cell-size in millimetres,
## enabled (0/1); followed by one int32 blocked flag for each terrain cell.
## No visual art, random numbers, or new gameplay terrain is generated here.
const HEADER_INTS := 4
const MILLIMETRES := 1000


static func from_terrain(terrain: BattlefieldTerrain) -> PackedInt32Array:
	var grid := PackedInt32Array()
	if terrain == null or not terrain.is_valid():
		grid.resize(HEADER_INTS + 1)
		grid[0] = 1
		grid[1] = 1
		grid[2] = MILLIMETRES
		grid[3] = 0
		return grid
	var count := terrain.cols * terrain.rows
	grid.resize(HEADER_INTS + count)
	grid[0] = terrain.cols
	grid[1] = terrain.rows
	grid[2] = maxi(1, roundi(terrain.cell_size * MILLIMETRES))
	grid[3] = 1
	for i in count:
		grid[HEADER_INTS + i] = 0 if terrain.is_cell_traversable(i) else 1
	return grid


## CPU reference for the shader's collision rules. Used in tests to catch
## indexing, boundary, and axis-slide regressions without requiring a GPU.
static func is_blocked(mask: PackedInt32Array, point: Vector2) -> bool:
	if mask.size() < HEADER_INTS + 1 or mask[3] == 0:
		return false
	var columns := mask[0]
	var rows := mask[1]
	var cell_size := float(mask[2]) / float(MILLIMETRES)
	if columns < 1 or rows < 1 or cell_size <= 0.0:
		return true
	var col := int(floorf(point.x / cell_size))
	var row := int(floorf(point.y / cell_size))
	if col < 0 or row < 0 or col >= columns or row >= rows:
		return true
	return mask[HEADER_INTS + row * columns + col] != 0


static func slide(mask: PackedInt32Array, origin: Vector2,
		proposed: Vector2) -> Vector2:
	if not is_blocked(mask, proposed):
		return proposed
	var x_only := Vector2(proposed.x, origin.y)
	var y_only := Vector2(origin.x, proposed.y)
	var x_safe := not is_blocked(mask, x_only)
	var y_safe := not is_blocked(mask, y_only)
	if x_safe and y_safe:
		return x_only if absf(proposed.x - origin.x) >= absf(
			proposed.y - origin.y) else y_only
	if x_safe:
		return x_only
	if y_safe:
		return y_only
	return origin
