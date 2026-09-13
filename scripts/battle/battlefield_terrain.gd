class_name BattlefieldTerrain
extends RefCounted
## The battlefield ground, as data.
##
## Terrain exists here first and is rendered second. The simulation asks this object
## for a movement multiplier and gets a number; the view asks it for a colour and gets
## one. Neither knows about the other, which is what keeps terrain testable headlessly
## and lets the renderer be replaced without touching a single gameplay rule.
##
## [b]Determinism.[/b] The same [code]terrain_seed[/code], field size and
## [code]terrain.generation_version[/code] always produce the same battlefield. Noise
## is derived from a positional hash rather than a stateful generator, so a cell's
## value depends only on where it is - not on the order cells happen to be visited in.
##
## [b]Resolution.[/b] Cells are coarse (metres across, not pixels) and there is one
## integer and one float per cell. A 100x60 field is a few hundred cells; even a field
## ten times that size stays a flat pair of arrays with no per-cell objects.
##
## [b]Scope.[/b] Terrain affects movement, and only movement, in this milestone. The
## hooks a later milestone needs - height, slope, per-type data - are here and
## queryable; the combat modifiers that will read them are not.

const CELL_MIN := 1

## Drawn for a cell that somehow has no type. Presentation only: an untyped cell would
## still be walkable at whatever modifier the simulation had already resolved.
const FALLBACK_COLOUR := Color("2b3428")

## The field this terrain describes.
var size: Vector2 = Vector2(100.0, 60.0)
var cell_size: float = 4.0
var cols: int = 0
var rows: int = 0
var terrain_seed: int = 0
var generation_version: int = 1

## Per-cell data, row-major. One integer and one float per cell, no objects.
var _type_index: PackedInt32Array = PackedInt32Array()
var _heights: PackedFloat32Array = PackedFloat32Array()
## Movement multiplier resolved at generation time, so a query is an array read
## rather than a dictionary lookup in the middle of a movement step.
var _move: PackedFloat32Array = PackedFloat32Array()
## Lookup tables, indexed by the per-cell integer.
var _type_ids: Array[String] = []
var _type_names: Array[String] = []
var _type_move: PackedFloat32Array = PackedFloat32Array()
## Resolved at generation so that drawing a cell does not reach into the catalogue.
## The renderer reads the terrain; the terrain does not read the renderer.
var _type_colours: Array[Color] = []


## ---------- generation ---------------------------------------------------

## Build the battlefield for one battle. Deterministic in every input.
static func generate(
	p_seed: int,
	p_size: Vector2,
	config: GameConfig,
	catalog: TerrainCatalog = null
) -> BattlefieldTerrain:
	var terrain := BattlefieldTerrain.new()
	var types := catalog if catalog != null else TerrainCatalog.load_from()
	terrain._build(p_seed, p_size, config, types)
	return terrain


func _build(p_seed: int, p_size: Vector2, config: GameConfig, catalog: TerrainCatalog) -> void:
	terrain_seed = p_seed
	size = Vector2(maxf(8.0, p_size.x), maxf(8.0, p_size.y))

	var lattice := 7.0
	var amplitude := 5.0
	var high_threshold := 0.66
	var woods_threshold := 0.60
	var rough_threshold := 0.42
	if config != null:
		cell_size = maxf(0.5, config.get_float("terrain.cell_size", 4.0))
		generation_version = config.get_int("terrain.generation_version", 1)
		lattice = maxf(2.0, config.get_float("terrain.lattice_cells", 7.0))
		amplitude = config.get_float("terrain.elevation_amplitude", 5.0)
		high_threshold = config.get_float("terrain.high_ground_threshold", 0.66)
		woods_threshold = config.get_float("terrain.woods_threshold", 0.60)
		rough_threshold = config.get_float("terrain.rough_threshold", 0.42)

	cols = maxi(CELL_MIN, int(ceil(size.x / cell_size)))
	rows = maxi(CELL_MIN, int(ceil(size.y / cell_size)))

	_type_ids = catalog.order.duplicate()
	if _type_ids.is_empty():
		_type_ids = [TerrainCatalog.FALLBACK_ID]
	_type_names.clear()
	_type_move = PackedFloat32Array()
	_type_colours.clear()
	for id in _type_ids:
		_type_names.append(catalog.display_name(id))
		_type_move.append(catalog.move_multiplier(id))
		_type_colours.append(catalog.colour(id))
	var open_index := maxi(0, _type_ids.find(TerrainCatalog.FALLBACK_ID))

	var total := cols * rows
	_type_index.resize(total)
	_heights.resize(total)
	_move.resize(total)

	for row in rows:
		for col in cols:
			var index := row * cols + col
			# Cell centre in lattice space, so the noise is sampled per cell rather
			# than per world unit.
			var u := (float(col) + 0.5) / float(cols) * lattice
			var v := (float(row) + 0.5) / float(rows) * lattice
			var elevation := _noise(p_seed, generation_version, u, v)
			# A second, offset sample is enough to decorrelate cover from height
			# without a second generator or a second pass over the grid.
			var cover := _noise(p_seed + 7919, generation_version, u, v)

			var type_index := open_index
			if elevation >= high_threshold:
				type_index = _index_or(_type_ids, "high_ground", open_index)
			elif cover >= woods_threshold:
				type_index = _index_or(_type_ids, "woods", open_index)
			elif cover >= rough_threshold or elevation <= (1.0 - rough_threshold) * 0.5:
				type_index = _index_or(_type_ids, "rough", open_index)

			_type_index[index] = type_index
			_heights[index] = elevation * amplitude
			_move[index] = _type_move[type_index]

	if not is_valid():
		DebugLogger.error("terrain generation produced an invalid battlefield", "Terrain")


static func _index_or(ids: Array[String], id: String, fallback: int) -> int:
	var found := ids.find(id)
	return found if found >= 0 else fallback


## Smoothed value noise in 0..1. Position-determined: no generator state, so two
## terrains built in different orders still agree cell for cell.
static func _noise(seed_value: int, version: int, u: float, v: float) -> float:
	var x0 := int(floor(u))
	var y0 := int(floor(v))
	var tx := u - float(x0)
	var ty := v - float(y0)
	var sx := tx * tx * (3.0 - 2.0 * tx)
	var sy := ty * ty * (3.0 - 2.0 * ty)
	var n00 := _lattice_value(seed_value, version, x0, y0)
	var n10 := _lattice_value(seed_value, version, x0 + 1, y0)
	var n01 := _lattice_value(seed_value, version, x0, y0 + 1)
	var n11 := _lattice_value(seed_value, version, x0 + 1, y0 + 1)
	return lerpf(lerpf(n00, n10, sx), lerpf(n01, n11, sx), sy)


## One lattice corner, hashed from its own coordinates.
static func _lattice_value(seed_value: int, version: int, ix: int, iy: int) -> float:
	var key := "%d:%d:%d:%d" % [seed_value, version, ix, iy]
	return float(RngService.stable_hash(key) % 100000) / 100000.0


## ---------- queries ------------------------------------------------------
## Cheap enough for a per-unit, per-step call: bounds check, one integer division,
## one array read. Nothing here allocates.

func is_valid() -> bool:
	return cols > 0 and rows > 0 and _type_index.size() == cols * rows


func inside(point: Vector2) -> bool:
	return point.x >= 0.0 and point.y >= 0.0 and point.x < size.x and point.y < size.y


func cell_col_at(point: Vector2) -> int:
	return clampi(int(floor(point.x / cell_size)), 0, cols - 1)


func cell_row_at(point: Vector2) -> int:
	return clampi(int(floor(point.y / cell_size)), 0, rows - 1)


## Cell index for a world point, or -1 when the point is off the field.
func cell_index_at(point: Vector2) -> int:
	if not inside(point):
		return -1
	return cell_row_at(point) * cols + cell_col_at(point)


func type_index_at(point: Vector2) -> int:
	var index := cell_index_at(point)
	return _type_index[index] if index >= 0 else maxi(0, _type_ids.find(TerrainCatalog.FALLBACK_ID))


func type_id_at(point: Vector2) -> String:
	var index := type_index_at(point)
	return _type_ids[index] if index >= 0 and index < _type_ids.size() else TerrainCatalog.FALLBACK_ID


func type_name_at(point: Vector2) -> String:
	var index := type_index_at(point)
	return _type_names[index] if index >= 0 and index < _type_names.size() else TerrainCatalog.FALLBACK_ID


## Elevation in the same units as the field, zero on open ground.
func height_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _heights[index] if index >= 0 else 0.0


## The multiplier a unit's move speed is scaled by at this point. One is unpenalised.
func move_multiplier_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _move[index] if index >= 0 else 1.0


## Height difference per unit travelled. Zero when either point is off the field, so
## callers never have to check first.
##
## That zero is the contract, and it was not always honoured. Off-field ground reads as
## zero height, so taking the two heights independently made two off-field points happen
## to give zero while a point inside and a point outside gave a fake slope - the edge of
## the field appearing to fall away into nothing. The contract is now checked first,
## because a slope from here to somewhere that does not exist is not a small number, it
## is not a slope. See D-057.
func slope_between(from: Vector2, to: Vector2) -> float:
	if not inside(from) or not inside(to):
		return 0.0
	var run := from.distance_to(to)
	if run <= 0.0001:
		return 0.0
	return (height_at(to) - height_at(from)) / run


func cell_centre(index: int) -> Vector2:
	if index < 0 or index >= _type_index.size():
		return Vector2.ZERO
	return Vector2(
		(float(index % cols) + 0.5) * cell_size,
		(float(index / cols) + 0.5) * cell_size
	)


func cell_rect(index: int) -> Rect2:
	if index < 0 or index >= _type_index.size():
		return Rect2()
	return Rect2(
		Vector2(float(index % cols) * cell_size, float(index / cols) * cell_size),
		Vector2(cell_size, cell_size)
	)


func set_type_at(point: Vector2, type_id: String) -> bool:
	var index := cell_index_at(point)
	var type_index := _type_ids.find(type_id)
	if index < 0 or type_index < 0:
		return false
	_type_index[index] = type_index
	_move[index] = _type_move[type_index]
	return true


func cell_count() -> int:
	return _type_index.size()


## Height of a cell by index. The by-position query is the one gameplay uses; this is
## for tooling that already has an index in hand and does not want to go round again.
func height_of_cell(index: int) -> float:
	if index < 0 or index >= _heights.size():
		return 0.0
	return _heights[index]


## The colour this cell's ground should be drawn in. Presentation only - nothing in the
## simulation reads this.
func colour_of_cell(index: int) -> Color:
	if index < 0 or index >= _type_index.size():
		return FALLBACK_COLOUR
	var type_index := _type_index[index]
	if type_index < 0 or type_index >= _type_colours.size():
		return FALLBACK_COLOUR
	return _type_colours[type_index]


## The tallest ground on the field, so a view can shade elevations without a second
## pass to find the range.
func max_height() -> float:
	var tallest := 0.0
	for height in _heights:
		tallest = maxf(tallest, height)
	return tallest


func type_id_of_cell(index: int) -> String:
	if index < 0 or index >= _type_index.size():
		return TerrainCatalog.FALLBACK_ID
	return _type_ids[_type_index[index]]


## How many cells of each type the battlefield holds. Used by tests and by the
## benchmark's summary line.
func counts_by_type() -> Dictionary:
	var counts := {}
	for id in _type_ids:
		counts[id] = 0
	for index in _type_index.size():
		var id := _type_ids[_type_index[index]]
		counts[id] = int(counts.get(id, 0)) + 1
	return counts


## A compact fingerprint of the whole battlefield. Two terrains with the same
## signature are identical cell for cell, which is what the determinism tests assert.
func signature() -> String:
	var parts := PackedStringArray()
	parts.append("%d:%d:%d:%d" % [terrain_seed, generation_version, cols, rows])
	for index in _type_index.size():
		parts.append("%d.%d" % [_type_index[index], int(round(_heights[index] * 100.0))])
	return "%08x" % RngService.stable_hash("|".join(parts))


func summary() -> String:
	if not is_valid():
		return "terrain: invalid"
	return "terrain seed %d v%d: %dx%d cells of %.1f, %s" % [
		terrain_seed, generation_version, cols, rows, cell_size, str(counts_by_type()),
	]


func to_dict() -> Dictionary:
	return {
		"terrain_seed": terrain_seed,
		"generation_version": generation_version,
		"cell_size": cell_size,
		"cols": cols,
		"rows": rows,
		"size": DataUtils.vec2_to(size),
		"signature": signature(),
		"counts": counts_by_type(),
	}
