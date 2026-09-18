class_name BattlefieldTerrain
extends RefCounted
## The battlefield ground, as data.
##
## Terrain exists here first and is rendered second. The simulation asks this object for a movement
## multiplier and gets a number; the view asks it for the ground's looks and gets weights. Neither
## knows about the other, which is what keeps terrain testable headlessly and lets the renderer be
## replaced without touching a single gameplay rule.
##
## [b]One cell, many channels.[/b] Every cell carries a height, a slope, a type, a soil, a biome and
## its blend, a movement multiplier, a vegetation density, a cover value, a wetness, a sight-line
## opacity, an obstacle state and a traversability. They are parallel packed arrays with no per-cell
## objects, so a field of a hundred thousand cells is still a few megabytes and no allocations.
## Adding a channel is an array, a query and a row in [method to_dict] - see the extension notes in
## docs/TERRAIN_ARCHITECTURE.md.
##
## [b]Determinism.[/b] The same [code]terrain_seed[/code], field size, biome and
## [code]terrain.generation_version[/code] always produce the same battlefield. Every random value is
## derived from a positional hash rather than from a generator's state, so a cell's value depends
## only on where it is - not on the order cells happen to be visited in - and generating a battlefield
## cannot disturb any other random stream in the game.
##
## [b]Two layers, one truth.[/b] The gameplay layer is this object. The visual layer is generated
## from it ([method build_ground_map], [method build_overlay_map]) and never feeds back: nothing in
## the simulation reads a texture, a colour or a variant.
##
## [b]Scope.[/b] Terrain affects movement today; cover, sight lines, elevation and traversability are
## generated, cached and queryable, and the rules that will read them are a later milestone. That is
## deliberate: the maps are the expensive part and they are here now.

const CELL_MIN := 1

## Drawn for a cell that somehow has no type. Presentation only: an untyped cell would still be
## walkable at whatever modifier the simulation had already resolved.
const FALLBACK_COLOUR := Color("2b3428")

## Obstacle state, a bitfield per cell. Bit 0 is the ground itself (a cliff face); bit 1 is something
## standing on it (a boulder, a trunk, a wall). They are separate bits because a formation cares
## about the difference - one can be walked around, the other is the shape of the country.
const OBSTACLE_TERRAIN := 1
const OBSTACLE_PROP := 2
## Neither bit set: open going.
const OBSTACLE_NONE := 0

## The channels a batch query can be asked for.
enum Channel {
	HEIGHT,
	SLOPE,
	MOVE,
	COST,
	VEGETATION,
	COVER,
	WETNESS,
	LOS,
	TRAVERSABLE,
	TYPE_INDEX,
	SOIL_INDEX,
	BIOME_INDEX,
	OBSTACLE,
	BLEND,
	## How wet the country is, as opposed to how wet the ground is after the river: this is the field
	## that decided the soil and the look, kept so a season or a weather system can read it.
	MOISTURE,
}

## How opaque a sight line has to get before it counts as blocked. A single wood cell (0.7) does not
## block a line on its own - three of them do. A cliff (1.0) blocks by itself.
const LOS_BLOCKED_AT := 0.75
## How dense vegetation has to be before it hides anything, and how much opacity it adds once it is.
## Below the threshold the growth is not in the way of a man's eyes - which is most ground in most
## countries - and above it, it hides like the thicket it is.
const LOS_VEGETATION_THRESHOLD := 0.5
const LOS_VEGETATION_OPACITY := 0.6
## How far above a sight line the ground has to rise to cut it, in world units. A ridge hides what is
## behind it; the ground being level with the line does not, and neither does a bump of a few feet.
## This is deliberately about a man's height rather than about a pixel: with it set low, ordinary
## rolling ground reported as a wall, because every cell between two points sits a little above the
## straight line drawn over it.
const LOS_GROUND_CLEARANCE := 1.5
## How many cells a sight-line walk may cross before it gives up and calls the line blocked. A line
## longer than this is a question nobody in a battle asks, and the answer is not worth the walk.
const LOS_MAX_CELLS := 256

## How many pixels a baked visual map may have. A weight map only needs a couple of pixels per cell;
## beyond that the bake is time nobody asked for, on battlefields scaled for armies nobody has.
const VISUAL_PIXEL_BUDGET := 262144.0

## The field this terrain describes.
var size: Vector2 = Vector2(100.0, 60.0)
var cell_size: float = 4.0
var cols: int = 0
var rows: int = 0
var terrain_seed: int = 0
var generation_version: int = 1

## The country this field was grown as, and the second country mixed into it - a transition band
## rather than a border. [member blend_biome_id] is empty on a field that is one biome throughout,
## which is the common case: a battlefield is usually one kind of country.
var biome_id: String = ""
var blend_biome_id: String = ""
var blend_width_cells: float = 0.0

## Per-cell data, row-major. Integers and floats, no objects.
var _type_index: PackedInt32Array = PackedInt32Array()
var _soil_index: PackedInt32Array = PackedInt32Array()
var _obstacle: PackedInt32Array = PackedInt32Array()
var _traversable: PackedInt32Array = PackedInt32Array()
var _heights: PackedFloat32Array = PackedFloat32Array()
var _slope: PackedFloat32Array = PackedFloat32Array()
var _move: PackedFloat32Array = PackedFloat32Array()
var _vegetation: PackedFloat32Array = PackedFloat32Array()
var _cover: PackedFloat32Array = PackedFloat32Array()
var _wetness: PackedFloat32Array = PackedFloat32Array()
var _los: PackedFloat32Array = PackedFloat32Array()
## The country's own wetness (as opposed to the ground's): what grew the soil and the look.
var _moisture: PackedFloat32Array = PackedFloat32Array()
## How much of the secondary biome this cell is, 0..1.
var _blend: PackedFloat32Array = PackedFloat32Array()
## Four ground-variant weights per cell (stride 4) and four overlay coverages per cell (stride 4).
var _variant_w: PackedFloat32Array = PackedFloat32Array()
var _overlay_w: PackedFloat32Array = PackedFloat32Array()

## A coarse mean-height grid over the field, for "is this spot above its surroundings" without a
## second pass. Blocked to [constant MEAN_BLOCK] cells.
const MEAN_BLOCK := 8
var _mean_height: PackedFloat32Array = PackedFloat32Array()
var _mean_cols: int = 0
var _mean_rows: int = 0

## Lookup tables, indexed by the per-cell integer.
var _type_ids: Array[String] = []
var _type_names: Array[String] = []
var _type_move: PackedFloat32Array = PackedFloat32Array()
var _type_cover: PackedFloat32Array = PackedFloat32Array()
var _type_los: PackedFloat32Array = PackedFloat32Array()
var _type_traversable: PackedInt32Array = PackedInt32Array()
var _type_colours: Array[Color] = []
var _soil_ids: Array[String] = []

## The catalogues this field was grown against. Kept so a cell can be recomposed - by a test that
## forces a type, or by a tool that paints terrain - without re-reading the JSON.
var _types: TerrainCatalog = null
var _biomes: BiomeCatalog = null
var _soils: SoilCatalog = null

## What a slope costs a soldier, per biome: x is the field's own biome, y the one blended into it.
## Read through [method drag_at], which is where the blend is applied.
var _veg_drag := Vector2(0.14, 0.14)
var _wet_drag := Vector2(0.3, 0.3)
var _slope_penalty := Vector2(0.55, 0.55)
## Steeper than this and no formation crosses the ground, whatever its type says. A cliff is the
## extreme case of it; the rule is what makes a steep hillside behave like one.
var max_traversable_slope: float = 0.6

## The things standing on the ground, once they have been grown. Null on a field nobody has scattered
## props over - a headless test that only wants the ground does not pay for them.
var props: TerrainProps = null

## Generation tuning resolved once, kept for the tools and the debug overlay.
var cliff_type_id: String = "cliff"
var water_type_id: String = "water"
var mud_type_id: String = "mud"
var high_type_id: String = "high_ground"
var woods_type_id: String = "woods"
var rough_type_id: String = "rough"


## ---------- generation ---------------------------------------------------

## Build the battlefield for one battle. Deterministic in every input.
##
## [param catalog] and [param biomes] are injectable so a test can generate against a deliberately
## broken or deliberately different catalogue; the defaults are the project's own data.
static func generate(
	p_seed: int,
	p_size: Vector2,
	config: GameConfig,
	catalog: TerrainCatalog = null,
	biomes: BiomeCatalog = null,
	p_biome_id: String = ""
) -> BattlefieldTerrain:
	var terrain := BattlefieldTerrain.new()
	terrain._build(p_seed, p_size, config, catalog, biomes, p_biome_id)
	return terrain


func _build(
	p_seed: int,
	p_size: Vector2,
	config: GameConfig,
	catalog: TerrainCatalog,
	biomes: BiomeCatalog,
	p_biome_id: String
) -> void:
	terrain_seed = p_seed
	size = Vector2(maxf(8.0, p_size.x), maxf(8.0, p_size.y))
	cell_size = maxf(0.5, config.get_float("terrain.cell_size", 4.0)) if config != null else 4.0
	generation_version = config.get_int("terrain.generation_version", 1) if config != null else 1
	cols = maxi(CELL_MIN, int(ceilf(size.x / cell_size)))
	rows = maxi(CELL_MIN, int(ceilf(size.y / cell_size)))

	var types := catalog if catalog != null else TerrainCatalog.load_from()
	var biome_source := biomes if biomes != null else BiomeCatalog.load_from()
	var soils := SoilCatalog.load_from()
	_types = types
	_biomes = biome_source
	_soils = soils
	_adopt_type_table(types)
	_adopt_soil_table(soils)
	_allocate()

	var wanted := p_biome_id
	if wanted.is_empty() and config != null:
		wanted = config.get_string("terrain.biome", "")
	var blend := ""
	var blend_width := 0.0
	if config != null:
		blend = config.get_string("terrain.blend_biome", "")
		blend_width = maxf(0.0, config.get_float("terrain.blend_width_cells", 0.0))
		max_traversable_slope = config.get_float("terrain.max_traversable_slope", 0.6)
	biome_id = biome_source.resolve_id(wanted)
	blend_biome_id = biome_source.resolve_id(blend) if not blend.is_empty() else ""
	if blend_biome_id == biome_id:
		blend_biome_id = ""
	blend_width_cells = blend_width if not blend_biome_id.is_empty() else 0.0
	_veg_drag = Vector2(
		biome_source.number(biome_id, "vegetation_drag", 0.14, "movement"),
		biome_source.number(blend_biome_id, "vegetation_drag", 0.14, "movement")
	)
	_wet_drag = Vector2(
		biome_source.number(biome_id, "wetness_drag", 0.3, "movement"),
		biome_source.number(blend_biome_id, "wetness_drag", 0.3, "movement")
	)
	_slope_penalty = Vector2(
		biome_source.number(biome_id, "slope_penalty", 0.55, "movement"),
		biome_source.number(blend_biome_id, "slope_penalty", 0.55, "movement")
	)

	TerrainGenerator.build(self, config, types, biome_source, soils, generation_version)

	# The coarse mean-height grid and the derived maps are built here rather than by the generator:
	# they are consequences of the channels, not inputs to them.
	_build_mean_height()

	if not is_valid():
		DebugLogger.error("terrain generation produced an invalid battlefield", "Terrain")


func _allocate() -> void:
	var total := cols * rows
	_type_index.resize(total)
	_soil_index.resize(total)
	_obstacle.resize(total)
	_traversable.resize(total)
	_heights.resize(total)
	_slope.resize(total)
	_move.resize(total)
	_vegetation.resize(total)
	_cover.resize(total)
	_wetness.resize(total)
	_los.resize(total)
	_moisture.resize(total)
	_blend.resize(total)
	_variant_w.resize(total * 4)
	_overlay_w.resize(total * 4)
	for index in total:
		_type_index[index] = 0
		_soil_index[index] = 0
		_obstacle[index] = OBSTACLE_NONE
		_traversable[index] = 1


func _adopt_type_table(catalog: TerrainCatalog) -> void:
	_type_ids = catalog.order.duplicate()
	if _type_ids.is_empty():
		_type_ids = [TerrainCatalog.FALLBACK_ID]
	_type_names.clear()
	_type_move = PackedFloat32Array()
	_type_cover = PackedFloat32Array()
	_type_los = PackedFloat32Array()
	_type_traversable = PackedInt32Array()
	_type_colours.clear()
	for id in _type_ids:
		_type_names.append(catalog.display_name(id))
		_type_move.append(catalog.move_multiplier(id))
		_type_cover.append(catalog.cover(id))
		_type_los.append(catalog.los_blocking(id))
		_type_traversable.append(1 if catalog.traversable(id) else 0)
		_type_colours.append(catalog.colour(id))


func _adopt_soil_table(catalog: SoilCatalog) -> void:
	_soil_ids = catalog.order.duplicate()
	if _soil_ids.is_empty():
		_soil_ids = [SoilCatalog.FALLBACK_ID]


## The type index of an id, or the index of the fallback type.
func type_slot(id: String) -> int:
	var found := _type_ids.find(id)
	return found if found >= 0 else maxi(0, _type_ids.find(TerrainCatalog.FALLBACK_ID))


## A per-biome number, blended for this cell: where a second biome is mixed in, the two values are
## interpolated by the cell's own blend weight, so the transition band is a gradient in behaviour as
## well as in looks rather than a line.
func drag_at(pair: Vector2, index: int) -> float:
	if blend_biome_id.is_empty():
		return pair.x
	return lerpf(pair.x, pair.y, clampf(blend_of_cell(index), 0.0, 1.0))


## The movement multiplier one cell's own numbers compose to.
##
## This is the only place the rule lives, and it is called once per cell at generation time - the
## answer is cached, so nothing per step ever does this arithmetic: the type says what the ground
## does, the soil seasons it, vegetation and water drag on it, and a slope costs something to climb.
## [method set_type_at] recomposes a single cell through the same path, so a forced type cannot leave
## the field describing ground it is not.
func resolve_move_of_cell(index: int) -> float:
	var base := 1.0
	if _type_move.size() > 0:
		base = _type_move[clampi(_type_index[index], 0, _type_move.size() - 1)]
	var soil_mult := 1.0
	if _soils != null and index < _soil_index.size() and not _soil_ids.is_empty():
		soil_mult = _soils.move_modifier(_soil_ids[clampi(_soil_index[index], 0, _soil_ids.size() - 1)])
	return compose_move(
		base,
		soil_mult,
		_vegetation[index] if index < _vegetation.size() else 0.0,
		_wetness[index] if index < _wetness.size() else 0.0,
		_slope[index] if index < _slope.size() else 0.0,
		drag_at(_veg_drag, index),
		drag_at(_wet_drag, index),
		drag_at(_slope_penalty, index)
	)


## The composition itself, as a pure function so the generator, this object and any tool agree.
static func compose_move(
	base: float,
	soil_multiplier: float,
	vegetation: float,
	wetness: float,
	slope: float,
	vegetation_drag: float,
	wetness_drag: float,
	slope_penalty: float
) -> float:
	var value := base * soil_multiplier
	value *= 1.0 - clampf(vegetation_drag * vegetation, 0.0, 0.8)
	value *= 1.0 - clampf(wetness_drag * wetness, 0.0, 0.8)
	value *= 1.0 - clampf(slope_penalty * minf(1.0, slope), 0.0, 0.75)
	return clampf(value, 0.05, 1.0)


func _build_mean_height() -> void:
	_mean_cols = maxi(1, int(ceilf(float(cols) / float(MEAN_BLOCK))))
	_mean_rows = maxi(1, int(ceilf(float(rows) / float(MEAN_BLOCK))))
	_mean_height = PackedFloat32Array()
	_mean_height.resize(_mean_cols * _mean_rows)
	for by in _mean_rows:
		for bx in _mean_cols:
			var total := 0.0
			var count := 0
			for y in range(by * MEAN_BLOCK, mini(rows, (by + 1) * MEAN_BLOCK)):
				for x in range(bx * MEAN_BLOCK, mini(cols, (bx + 1) * MEAN_BLOCK)):
					total += _heights[y * cols + x]
					count += 1
			_mean_height[by * _mean_cols + bx] = total / maxf(1.0, float(count))


## ---------- validity and geometry ----------------------------------------

func is_valid() -> bool:
	return cols > 0 and rows > 0 and _type_index.size() == cols * rows and _heights.size() == cols * rows


func inside(point: Vector2) -> bool:
	return point.x >= 0.0 and point.y >= 0.0 and point.x < size.x and point.y < size.y


func cell_col_at(point: Vector2) -> int:
	return clampi(int(floorf(point.x / cell_size)), 0, cols - 1)


func cell_row_at(point: Vector2) -> int:
	return clampi(int(floorf(point.y / cell_size)), 0, rows - 1)


## Cell index for a world point, or -1 when the point is off the field.
func cell_index_at(point: Vector2) -> int:
	if not inside(point):
		return -1
	return cell_row_at(point) * cols + cell_col_at(point)


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


func cell_count() -> int:
	return _type_index.size()


func cell_of_col_row(col: int, row: int) -> int:
	if col < 0 or row < 0 or col >= cols or row >= rows:
		return -1
	return row * cols + col


## ---------- the channels, by cell ----------------------------------------

func type_index_of_cell(index: int) -> int:
	return _type_index[index] if index >= 0 and index < _type_index.size() else 0


func type_id_of_cell(index: int) -> String:
	if index < 0 or index >= _type_index.size():
		return TerrainCatalog.FALLBACK_ID
	var slot := _type_index[index]
	return _type_ids[slot] if slot >= 0 and slot < _type_ids.size() else TerrainCatalog.FALLBACK_ID


func height_of_cell(index: int) -> float:
	return _heights[index] if index >= 0 and index < _heights.size() else 0.0


func slope_of_cell(index: int) -> float:
	return _slope[index] if index >= 0 and index < _slope.size() else 0.0


func move_multiplier_of_cell(index: int) -> float:
	return _move[index] if index >= 0 and index < _move.size() else 1.0


func vegetation_of_cell(index: int) -> float:
	return _vegetation[index] if index >= 0 and index < _vegetation.size() else 0.0


func cover_of_cell(index: int) -> float:
	return _cover[index] if index >= 0 and index < _cover.size() else 0.0


func wetness_of_cell(index: int) -> float:
	return _wetness[index] if index >= 0 and index < _wetness.size() else 0.0


func los_of_cell(index: int) -> float:
	return _los[index] if index >= 0 and index < _los.size() else 0.0


func moisture_of_cell(index: int) -> float:
	return _moisture[index] if index >= 0 and index < _moisture.size() else 0.0


func blend_of_cell(index: int) -> float:
	return _blend[index] if index >= 0 and index < _blend.size() else 0.0


func soil_index_of_cell(index: int) -> int:
	return _soil_index[index] if index >= 0 and index < _soil_index.size() else 0


func soil_id_of_cell(index: int) -> String:
	var slot := soil_index_of_cell(index)
	return _soil_ids[slot] if slot >= 0 and slot < _soil_ids.size() else SoilCatalog.FALLBACK_ID


func obstacle_of_cell(index: int) -> int:
	return _obstacle[index] if index >= 0 and index < _obstacle.size() else OBSTACLE_NONE


func is_cell_traversable(index: int) -> bool:
	return _traversable[index] == 1 if index >= 0 and index < _traversable.size() else true


## Which of the four ground variants this cell mostly is.
func variant_of_cell(index: int) -> int:
	if index < 0 or index * 4 + 3 >= _variant_w.size():
		return 0
	var best := 0
	var best_weight := -1.0
	for slot in 4:
		var weight := _variant_w[index * 4 + slot]
		if weight > best_weight:
			best_weight = weight
			best = slot
	return best


func variant_weight_of_cell(index: int, slot: int) -> float:
	if index < 0 or slot < 0 or slot > 3 or index * 4 + slot >= _variant_w.size():
		return 0.0
	return _variant_w[index * 4 + slot]


func overlay_weight_of_cell(index: int, slot: int) -> float:
	if index < 0 or slot < 0 or slot > 3 or index * 4 + slot >= _overlay_w.size():
		return 0.0
	return _overlay_w[index * 4 + slot]


## The biome a cell is mostly made of.
func biome_id_of_cell(index: int) -> String:
	if blend_biome_id.is_empty():
		return biome_id
	return blend_biome_id if blend_of_cell(index) > 0.5 else biome_id


## ---------- the channels, by world position ------------------------------
## Every one of these is a bounds check, one integer division and one array read: cheap enough for
## a per-soldier, per-step call, which is what the simulation's hot path does with two of them.

func type_index_at(point: Vector2) -> int:
	var index := cell_index_at(point)
	return type_index_of_cell(index if index >= 0 else 0)


func type_id_at(point: Vector2) -> String:
	var index := cell_index_at(point)
	return type_id_of_cell(index) if index >= 0 else TerrainCatalog.FALLBACK_ID


func type_name_at(point: Vector2) -> String:
	var slot := type_index_at(point)
	return _type_names[slot] if slot >= 0 and slot < _type_names.size() else TerrainCatalog.FALLBACK_ID


func height_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _heights[index] if index >= 0 else 0.0


func slope_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _slope[index] if index >= 0 else 0.0


func vegetation_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _vegetation[index] if index >= 0 else 0.0


func cover_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _cover[index] if index >= 0 else 0.0


func wetness_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _wetness[index] if index >= 0 else 0.0


func los_blocking_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _los[index] if index >= 0 else 0.0


func moisture_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _moisture[index] if index >= 0 else 0.0


func soil_id_at(point: Vector2) -> String:
	var index := cell_index_at(point)
	return soil_id_of_cell(index) if index >= 0 else SoilCatalog.FALLBACK_ID


func biome_id_at(point: Vector2) -> String:
	var index := cell_index_at(point)
	return biome_id_of_cell(index) if index >= 0 else biome_id


func obstacle_bits_at(point: Vector2) -> int:
	var index := cell_index_at(point)
	return _obstacle[index] if index >= 0 else OBSTACLE_NONE


func is_traversable(point: Vector2) -> bool:
	var index := cell_index_at(point)
	return _traversable[index] == 1 if index >= 0 else true


## What it costs to cross the ground under a point, as a multiplier on TIME rather than on speed:
## open ground costs 1.0 and a wood costs about 1.67. The simulation moves soldiers with
## [method move_multiplier_at]; this is the same number read the way a pathfinder or an AI wants it.
func movement_cost_at(point: Vector2) -> float:
	return 1.0 / maxf(0.05, move_multiplier_at(point))


## The movement multiplier for the ground under a point.
##
## The hot path is per moving soldier per tick - twenty thousand times at twenty thousand soldiers -
## and this used to cost five nested calls to do one array read: `_effective_speed`, this method, the
## cell index, and the two integer divisions inside it. The cell arithmetic is spelled out here
## instead, reading the same array with the same guards, so the callers that need this once per
## soldier pay for one call rather than five. [method move_multiplier_via_cells] is the previous
## shape, kept so the two can be measured against each other in one build. See D-114.
func move_multiplier_at(point: Vector2) -> float:
	if point.x < 0.0 or point.y < 0.0 or point.x >= size.x or point.y >= size.y:
		return 1.0
	var col := clampi(int(floorf(point.x / cell_size)), 0, cols - 1)
	var row := clampi(int(floorf(point.y / cell_size)), 0, rows - 1)
	return _move[row * cols + col]


## The reference: the same multiplier through `cell_index_at`, which is what the engine called before
## the cell arithmetic was spelled out above. Kept for paired measurement and for callers that are not
## hot.
func move_multiplier_via_cells(point: Vector2) -> float:
	var index := cell_index_at(point)
	return _move[index] if index >= 0 else 1.0


## How much the ground under a point stands above the country around it, in world units. Positive is
## a knoll, negative a hollow. Elevation mattered the moment it was generated; this is the number a
## formation asks for when the question is "are we charging uphill".
func elevation_advantage_at(point: Vector2) -> float:
	var index := cell_index_at(point)
	if index < 0:
		return 0.0
	var block := int(index / cols / MEAN_BLOCK) * _mean_cols + int(index % cols / MEAN_BLOCK)
	if _mean_height.size() == 0 or block < 0 or block >= _mean_height.size():
		return 0.0
	return _heights[index] - _mean_height[block]


## The direction the ground rises in, at a point. Zero on flat ground.
func uphill_direction_at(point: Vector2) -> Vector2:
	var gradient := gradient_at(point)
	if gradient.length() <= 0.00001:
		return Vector2.ZERO
	return gradient.normalized()


## The height gradient at a point, in world units of rise per world unit travelled, per axis.
func gradient_at(point: Vector2) -> Vector2:
	var index := cell_index_at(point)
	if index < 0:
		return Vector2.ZERO
	var col := index % cols
	var row := index / cols
	var left := height_of_cell(cell_of_col_row(maxi(0, col - 1), row))
	var right := height_of_cell(cell_of_col_row(mini(cols - 1, col + 1), row))
	var up := height_of_cell(cell_of_col_row(col, maxi(0, row - 1)))
	var down := height_of_cell(cell_of_col_row(col, mini(rows - 1, row + 1)))
	return Vector2((right - left) * 0.5, (down - up) * 0.5) / maxf(0.001, cell_size)


## Height difference per unit travelled. Zero when either point is off the field, so callers never
## have to check first.
##
## That zero is the contract, and it was not always honoured. Off-field ground reads as zero height,
## so taking the two heights independently made two off-field points happen to give zero while a point
## inside and a point outside gave a fake slope - the edge of the field appearing to fall away into
## nothing. The contract is now checked first, because a slope from here to somewhere that does not
## exist is not a small number, it is not a slope. See D-057.
func slope_between(from: Vector2, to: Vector2) -> float:
	if not inside(from) or not inside(to):
		return 0.0
	var run := from.distance_to(to)
	if run <= 0.0001:
		return 0.0
	return (height_at(to) - height_at(from)) / run


## ---------- sight lines ---------------------------------------------------

## How opaque the ground is along a sight line, 0..1, ignoring height: the sum of the cells it
## crosses, capped. A caller that wants a yes or no should use [method blocks_line_of_sight].
##
## A line of no length has no opacity: it crosses no ground at all. That is the same contract
## [method slope_between] honours, and it is worth honouring here because a caller asking about a
## point is otherwise handed the opacity of whatever cell the point happens to be in.
func sight_line_opacity(from: Vector2, to: Vector2) -> float:
	var run := from.distance_to(to)
	if run <= 0.0001:
		return 0.0
	var step := maxf(0.5, cell_size * 0.5)
	var count := mini(LOS_MAX_CELLS, maxi(1, int(ceilf(run / step))))
	var direction := (to - from) / run
	var opacity := 0.0
	var last := -1
	for i in range(count + 1):
		var point := from + direction * minf(run, float(i) * step)
		var index := cell_index_at(point)
		if index < 0 or index == last:
			continue
		last = index
		opacity += _los[index]
	return clampf(opacity, 0.0, 1.0)


## How much memory the field's per-cell channels occupy, in bytes.
##
## Every channel is a packed array of 32-bit values, so this is a count of them, and the number is
## worth being able to read off rather than guess at: a battlefield quadrupled in each direction costs
## sixteen times this, and that - not the generation time - is what decides whether an enormous battle
## fits. It is a measurement of the field, not an estimate of the process.
func memory_bytes() -> int:
	var total := 0
	for array in [_type_index, _soil_index, _obstacle, _traversable]:
		total += (array as PackedInt32Array).size() * 4
	for array in [_heights, _slope, _move, _vegetation, _cover, _wetness, _los, _moisture, _blend,
			_variant_w, _overlay_w, _mean_height, _type_move, _type_cover, _type_los]:
		total += (array as PackedFloat32Array).size() * 4
	total += _type_traversable.size() * 4
	return total


## The channels the field carries, for a caller that has to describe it: one entry per channel, each
## with its name and how many values it holds. A tool prints this; nothing in the game reads it.
func channel_census() -> Array:
	return [
		{"name": "heights", "values": _heights.size()},
		{"name": "slope", "values": _slope.size()},
		{"name": "movement", "values": _move.size()},
		{"name": "vegetation", "values": _vegetation.size()},
		{"name": "cover", "values": _cover.size()},
		{"name": "wetness", "values": _wetness.size()},
		{"name": "sight lines", "values": _los.size()},
		{"name": "moisture", "values": _moisture.size()},
		{"name": "blend", "values": _blend.size()},
		{"name": "variant weights", "values": _variant_w.size()},
		{"name": "overlay weights", "values": _overlay_w.size()},
	]

## Whether the ground stops a sight line from [param from] to [param to].
##
## Two things stop it, and both are the ground rather than a rule about it: enough opaque cells
## (a wood is a thicket - one cell does not hide what is behind it, three do), and the land rising
## into the line (a ridge hides the far side of it). The walk is at cell resolution and the height
## test is taken at the same steps - *as a fraction of the line's own length*, which is the part that
## has to be right: measuring the line against the longest line the walk will take made ordinary
## ground report as a ridge, because the line's height never rose off its starting height.
##
## A line with an end off the field is not blocked: there is no ground there to block it, and the
## caller is more likely to have mis-measured than to have found a wall at the edge of the world.
func blocks_line_of_sight(from: Vector2, to: Vector2) -> bool:
	if not inside(from) or not inside(to):
		return false
	var run := from.distance_to(to)
	if run <= 0.0001:
		return false
	var step := maxf(0.5, cell_size * 0.5)
	var count := mini(LOS_MAX_CELLS, maxi(1, int(ceilf(run / step))))
	var direction := (to - from) / run
	var start_height := height_at(from)
	var end_height := height_at(to)
	var opacity := 0.0
	for i in range(count + 1):
		var travelled := minf(run, float(i) * step)
		var index := cell_index_at(from + direction * travelled)
		if index < 0:
			continue
		opacity += _los[index]
		if opacity >= LOS_BLOCKED_AT:
			return true
		var line_height := lerpf(start_height, end_height, travelled / run)
		if _heights[index] > line_height + LOS_GROUND_CLEARANCE:
			return true
	return false


## ---------- grids ---------------------------------------------------------
## Read-only views of the cached maps, for tooling, native kernels and anything that wants to walk
## the field rather than query it point by point. Packed arrays are copied on write, so handing one
## out costs nothing until somebody changes it.

func height_grid() -> PackedFloat32Array:
	return _heights


func slope_grid() -> PackedFloat32Array:
	return _slope


func move_grid() -> PackedFloat32Array:
	return _move


func vegetation_grid() -> PackedFloat32Array:
	return _vegetation


func cover_grid() -> PackedFloat32Array:
	return _cover


func wetness_grid() -> PackedFloat32Array:
	return _wetness


func los_grid() -> PackedFloat32Array:
	return _los


func moisture_grid() -> PackedFloat32Array:
	return _moisture


func obstacle_grid() -> PackedInt32Array:
	return _obstacle


func traversable_grid() -> PackedInt32Array:
	return _traversable


func type_grid() -> PackedInt32Array:
	return _type_index


func soil_grid() -> PackedInt32Array:
	return _soil_index


func blend_grid() -> PackedFloat32Array:
	return _blend


## ---------- batch queries -------------------------------------------------

## One channel for many positions, in one call.
##
## This is the seam a large army goes through. The per-point methods above are already one array read
## each, which is what the per-soldier loop uses; a batch exists so that a caller who has twenty
## thousand positions - an AI considering a line, a renderer, a native kernel - pays one crossing
## instead of twenty thousand. Answers are in the same order as the questions, and a point off the
## field answers with the same value its own single-point query would: never a surprise.
##
## The answers are collected into an [Array] and copied into the packed result at the end, and that is
## not ceremony: a packed array is a *value* type in GDScript, so filling one inside another function
## would fill a copy and the caller would get a row of zeroes. The copy is one allocation per batch,
## against twenty thousand calls.
func sample_batch(points: PackedVector2Array, channel: Channel) -> PackedFloat32Array:
	var values: Array = []
	values.resize(points.size())
	fill_batch(points, channel, values)
	var out := PackedFloat32Array()
	out.resize(values.size())
	for index in values.size():
		out[index] = float(values[index])
	return out


## The same, into an array the caller already owns. [param out] is an [Array] rather than a packed
## array on purpose: packed arrays are value types in GDScript, so filling one in place would fill a
## copy and the caller would never see it. An [Array] is a reference, which is what makes a
## per-tick refill allocation-free.
func fill_batch(points: PackedVector2Array, channel: Channel, out: Array) -> void:
	if out.size() < points.size():
		out.resize(points.size())
	for i in points.size():
		out[i] = sample_one(points[i], channel)


func sample_one(point: Vector2, channel: Channel) -> float:
	match channel:
		Channel.HEIGHT:
			return height_at(point)
		Channel.SLOPE:
			return slope_at(point)
		Channel.MOVE:
			return move_multiplier_at(point)
		Channel.COST:
			return movement_cost_at(point)
		Channel.VEGETATION:
			return vegetation_at(point)
		Channel.COVER:
			return cover_at(point)
		Channel.WETNESS:
			return wetness_at(point)
		Channel.LOS:
			return los_blocking_at(point)
		Channel.TRAVERSABLE:
			return 1.0 if is_traversable(point) else 0.0
		Channel.TYPE_INDEX:
			return float(type_index_at(point))
		Channel.SOIL_INDEX:
			var soil_index := cell_index_at(point)
			return float(soil_index_of_cell(soil_index) if soil_index >= 0 else 0)
		Channel.BIOME_INDEX:
			var index := cell_index_at(point)
			return blend_of_cell(index) if index >= 0 else 0.0
		Channel.OBSTACLE:
			return float(obstacle_bits_at(point))
		Channel.BLEND:
			var blend_index := cell_index_at(point)
			return blend_of_cell(blend_index) if blend_index >= 0 else 0.0
		Channel.MOISTURE:
			return moisture_at(point)
	return 0.0


## ---------- the visual layer, generated from the data ---------------------
## Two images, at a resolution the caller chooses, both read from the channels above and never
## written back to them. The ground map carries the four variant weights and the height; the overlay
## map carries the four overlay coverages. Both are meant to be filtered linearly by the shader, so
## a weight that steps per cell reads as a blend across the ground.

## The resolution the visual maps are baked at.
##
## One pixel per cell is the floor, because that is the resolution the data itself has; the config's
## own number is the preference; and a ceiling keeps a battlefield scaled for a huge army from
## spending a second baking pictures nobody asked for. The maps are read back with linear filtering,
## so what the camera sees is a blend of these pixels rather than the pixels themselves.
func visual_pixels_per_unit(config: GameConfig = null) -> float:
	var wanted := 1.0
	if config != null:
		wanted = maxf(0.05, config.get_float("terrain.visual_pixels_per_unit", 1.0))
	var ppu := maxf(wanted, 1.0 / maxf(0.5, cell_size))
	var pixels := size.x * ppu * size.y * ppu
	if pixels > VISUAL_PIXEL_BUDGET:
		ppu *= sqrt(VISUAL_PIXEL_BUDGET / pixels)
	return maxf(0.02, ppu)


## A cell's own value, at a point that may fall between cells.
##
## The simulation reads the nearest cell and always will - a soldier is standing in one cell or
## another. A *picture* of the ground should not be a mosaic of those cells, so the baked maps are
## blended across the cell boundaries instead: the river gets banks, the ground changes character over
## a few units rather than at a line, and the eye stops finding the grid. The two readings are
## deliberately different, and neither is wrong.
func sample_cell_weights(point: Vector2, values: PackedFloat32Array, stride: int, slot: int) -> float:
	if values.is_empty() or cols <= 0 or rows <= 0:
		return 0.0
	var cx := point.x / cell_size - 0.5
	var cy := point.y / cell_size - 0.5
	var x0 := int(floorf(cx))
	var y0 := int(floorf(cy))
	var tx := clampf(cx - float(x0), 0.0, 1.0)
	var ty := clampf(cy - float(y0), 0.0, 1.0)
	var top := lerpf(_weight_at(x0, y0, values, stride, slot), _weight_at(x0 + 1, y0, values, stride, slot), tx)
	var bottom := lerpf(_weight_at(x0, y0 + 1, values, stride, slot), _weight_at(x0 + 1, y0 + 1, values, stride, slot), tx)
	return lerpf(top, bottom, ty)


## A whole record's four values at a point, blended across cell boundaries in one walk.
##
## The bake reads a record at every pixel of a map, and asking [method sample_cell_weights] for each of
## the four slots in turn walks the same four neighbours four times over - which on a map of a quarter
## of a million pixels is the difference between a bake measured in tenths of a second and one measured
## in seconds. Same answer, a quarter of the walking, no vector allocated per pixel.
##
## The values come back as a [Vector4] rather than written into an array the caller owns, because a
## packed array is a value type: filling one inside a function fills a copy the caller never sees.
func sample_cell_record(point: Vector2, values: PackedFloat32Array, stride: int) -> Vector4:
	if values.is_empty() or cols <= 0 or rows <= 0:
		return Vector4.ZERO
	var cx := point.x / cell_size - 0.5
	var cy := point.y / cell_size - 0.5
	var x0 := int(floorf(cx))
	var y0 := int(floorf(cy))
	var tx := clampf(cx - float(x0), 0.0, 1.0)
	var ty := clampf(cy - float(y0), 0.0, 1.0)
	var max_col := maxi(0, cols - 1)
	var max_row := maxi(0, rows - 1)
	var row0 := clampi(y0, 0, max_row) * cols
	var row1 := clampi(y0 + 1, 0, max_row) * cols
	var base00 := (row0 + clampi(x0, 0, max_col)) * stride
	var base10 := (row0 + clampi(x0 + 1, 0, max_col)) * stride
	var base01 := (row1 + clampi(x0, 0, max_col)) * stride
	var base11 := (row1 + clampi(x0 + 1, 0, max_col)) * stride
	var top := Vector4(
		lerpf(values[base00], values[base10], tx),
		lerpf(values[base00 + mini(1, stride - 1)], values[base10 + mini(1, stride - 1)], tx),
		lerpf(values[base00 + mini(2, stride - 1)], values[base10 + mini(2, stride - 1)], tx),
		lerpf(values[base00 + mini(3, stride - 1)], values[base10 + mini(3, stride - 1)], tx))
	var bottom := Vector4(
		lerpf(values[base01], values[base11], tx),
		lerpf(values[base01 + mini(1, stride - 1)], values[base11 + mini(1, stride - 1)], tx),
		lerpf(values[base01 + mini(2, stride - 1)], values[base11 + mini(2, stride - 1)], tx),
		lerpf(values[base01 + mini(3, stride - 1)], values[base11 + mini(3, stride - 1)], tx))
	return top.lerp(bottom, ty)


func _weight_at(col: int, row: int, values: PackedFloat32Array, stride: int, slot: int) -> float:
	var c := clampi(col, 0, maxi(0, cols - 1))
	var r := clampi(row, 0, maxi(0, rows - 1))
	var index := (r * cols + c) * stride + slot
	return values[index] if index >= 0 and index < values.size() else 0.0


## A single float channel, blended the same way.
func sample_cell_channel(point: Vector2, values: PackedFloat32Array) -> float:
	return sample_cell_weights(point, values, 1, 0)


## R,G,B = the four variant weights and the height, in the resolution the view asked for.
func build_ground_map(pixels_per_unit: float = 1.0, smooth: bool = true) -> Image:
	var width := maxi(2, int(roundf(size.x * maxf(0.02, pixels_per_unit))))
	var height := maxi(2, int(roundf(size.y * maxf(0.02, pixels_per_unit))))
	var lowest := min_height()
	var span := maxf(0.001, max_height() - lowest)
	var data := PackedByteArray()
	data.resize(width * height * 4)
	var at := 0
	for y in height:
		var world_y := (float(y) + 0.5) / float(height) * size.y
		for x in width:
			var point := Vector2((float(x) + 0.5) / float(width) * size.x, world_y)
			var record := sample_cell_record(point, _variant_w, 4)
			data[at] = _byte(record.y)
			data[at + 1] = _byte(record.z)
			data[at + 2] = _byte(record.w)
			data[at + 3] = _byte((sample_cell_channel(point, _heights) - lowest) / span)
			at += 4
	return _smooth(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data), smooth)


## R,G,B,A = the coverage of the biome's first four overlays.
func build_overlay_map(pixels_per_unit: float = 1.0, smooth: bool = true) -> Image:
	var width := maxi(2, int(roundf(size.x * maxf(0.02, pixels_per_unit))))
	var height := maxi(2, int(roundf(size.y * maxf(0.02, pixels_per_unit))))
	var data := PackedByteArray()
	data.resize(width * height * 4)
	var at := 0
	for y in height:
		var world_y := (float(y) + 0.5) / float(height) * size.y
		for x in width:
			var point := Vector2((float(x) + 0.5) / float(width) * size.x, world_y)
			var record := sample_cell_record(point, _overlay_w, 4)
			data[at] = _byte(record.x)
			data[at + 1] = _byte(record.y)
			data[at + 2] = _byte(record.z)
			data[at + 3] = _byte(record.w)
			at += 4
	return _smooth(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data), smooth)


## Where the ground is not plain ground: R = water, G = rock (a cliff face), B = mud.
##
## A separate map from the variant weights because these are *types* rather than looks: a river is
## water in every country, and the renderer needs to know where to stop drawing grass. Sampled
## linearly, so the bank between land and water is a soft edge rather than a staircase.
func build_type_map(pixels_per_unit: float = 1.0, smooth: bool = true) -> Image:
	var width := maxi(2, int(roundf(size.x * maxf(0.02, pixels_per_unit))))
	var height := maxi(2, int(roundf(size.y * maxf(0.02, pixels_per_unit))))
	# One channel per look, built once: the interpolation reads them like any other channel.
	var water := PackedFloat32Array()
	var rock := PackedFloat32Array()
	var mud := PackedFloat32Array()
	water.resize(_type_index.size())
	rock.resize(_type_index.size())
	mud.resize(_type_index.size())
	for index in _type_index.size():
		var type_id := type_id_of_cell(index)
		water[index] = 1.0 if type_id == water_type_id else 0.0
		rock[index] = 1.0 if type_id == cliff_type_id else 0.0
		mud[index] = 1.0 if type_id == mud_type_id else 0.0
	var data := PackedByteArray()
	data.resize(width * height * 4)
	var at := 0
	for y in height:
		var world_y := (float(y) + 0.5) / float(height) * size.y
		for x in width:
			var point := Vector2((float(x) + 0.5) / float(width) * size.x, world_y)
			data[at] = _byte(sample_cell_channel(point, water))
			data[at + 1] = _byte(sample_cell_channel(point, rock))
			data[at + 2] = _byte(sample_cell_channel(point, mud))
			data[at + 3] = 255
			at += 4
	return _smooth(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data), smooth)


## A 0..1 value as a byte, for the baked maps. Clamped rather than trusted: a weight can be a hair
## over one after interpolation, and a byte that wraps would turn a bright pixel into a black one.
func _byte(value: float) -> int:
	return clampi(int(roundf(value * 255.0)), 0, 255)


## Feather a baked map, so a value that steps per cell reads as a transition rather than as a grid.
##
## This is the difference between a river drawn as a row of blue squares and a river with banks: the
## cells are the truth and stay the truth, but the picture of them is allowed to blend. Blurring a
## weight map is safe precisely because it is a weight map - nothing in the simulation reads it.
func _smooth(image: Image, enabled: bool) -> Image:
	if enabled and image.has_method("blur"):
		image.blur()
	return image


## The colour this cell's ground should be drawn in when there is no art: the biome's variant colour,
## shaded by the type. Presentation only - nothing in the simulation reads this.
func colour_of_cell(index: int) -> Color:
	if index < 0 or index >= _type_index.size():
		return FALLBACK_COLOUR
	var type_slot_index := _type_index[index]
	if type_slot_index < 0 or type_slot_index >= _type_colours.size():
		return FALLBACK_COLOUR
	return _type_colours[type_slot_index]


## The tallest ground on the field, so a view can shade elevations without a second pass to find the
## range.
func max_height() -> float:
	var tallest := 0.0
	for height in _heights:
		tallest = maxf(tallest, height)
	return tallest


func min_height() -> float:
	var lowest := 0.0
	var started := false
	for height in _heights:
		if not started or height < lowest:
			lowest = height
			started = true
	return lowest


## Make the ground under a set of rectangles passable, whatever it was.
##
## Only ever called for a deployment zone, and only for ground that is genuinely impassable under the
## whole thing: the type is reset to the biome's own default ground, which is what the country would
## be if the river had gone elsewhere. Cover and sight lines are recomposed with it, so the ground
## does not keep describing a river that is no longer there.
func clear_for_deployment(zones: Array[Rect2]) -> int:
	var changed := 0
	for zone in zones:
		var min_col := cell_col_at(zone.position)
		var max_col := cell_col_at(zone.position + zone.size - Vector2(0.01, 0.01))
		var min_row := cell_row_at(zone.position)
		var max_row := cell_row_at(zone.position + zone.size - Vector2(0.01, 0.01))
		for row in range(min_row, max_row + 1):
			for col in range(min_col, max_col + 1):
				var cell := row * cols + col
				if cell < 0 or cell >= _type_index.size():
					continue
				var slot := _type_index[cell]
				var impassable := _type_traversable[slot] == 0 or _slope[cell] > max_traversable_slope
				if not impassable:
					continue
				var soil := soil_id_of_cell(cell)
				_type_index[cell] = type_slot(TerrainCatalog.FALLBACK_ID)
				_slope[cell] = minf(_slope[cell], max_traversable_slope * 0.5)
				if soil == "silt" or soil == "sand":
					_soil_index[cell] = maxi(0, _soil_ids.find("dirt"))
				refresh_maps_of_cell(cell)
				changed += 1
	return changed


## ---------- props ---------------------------------------------------------

## Grow the things standing on the ground and fold their gameplay into the cells they stand in.
##
## This is called after generation and before anything reads the maps, because a prop is not
## decoration: it writes cover, sight-line opacity and obstruction into the cells it occupies, and
## the queries the simulation makes already read those cells.
func build_props(config: GameConfig, biomes: BiomeCatalog, keep_clear: Array[Rect2] = []) -> TerrainProps:
	var source := biomes if biomes != null else (_biomes if _biomes != null else BiomeCatalog.load_from())
	var zones := keep_clear
	if zones.is_empty() and config != null:
		zones = BattleSetup.deployment_zones(config)
	props = TerrainProps.build(self, source, terrain_seed, generation_version, config, zones)
	apply_prop_obstacles()
	return props


## Write every prop's gameplay into the ground it stands on: enough cover to hide behind, enough
## opacity to break a sight line, and - for the kinds that should - an obstruction.
##
## Cover and opacity are taken as maxima rather than added, so a bush inside a wood does not stack to
## an impossible number, and a cell that already blocks a sight line cannot be made *less* blocking by
## something standing in it.
func apply_prop_obstacles() -> void:
	if props == null or props.is_empty():
		return
	for index in props.count():
		var point := props.position_at(index)
		var radius := maxf(props.radius_at(index), cell_size * 0.35)
		var cover := props.cover_at(index)
		var opacity := props.los_at(index)
		var blocks := props.blocks_at(index)
		var min_col := cell_col_at(point - Vector2(radius, radius))
		var max_col := cell_col_at(point + Vector2(radius, radius))
		var min_row := cell_row_at(point - Vector2(radius, radius))
		var max_row := cell_row_at(point + Vector2(radius, radius))
		for row in range(min_row, max_row + 1):
			for col in range(min_col, max_col + 1):
				var cell := row * cols + col
				if cell < 0 or cell >= _type_index.size():
					continue
				if cell_centre(cell).distance_to(point) > radius + cell_size * 0.5:
					continue
				_cover[cell] = clampf(maxf(_cover[cell], cover), 0.0, 0.95)
				_los[cell] = clampf(maxf(_los[cell], opacity), 0.0, 1.0)
				if blocks:
					_obstacle[cell] = _obstacle[cell] | OBSTACLE_PROP
					_traversable[cell] = 0


## Whether a point is clear of every prop that obstructs movement. The traversability map already
## answers this per cell; this is for a caller holding a prop and asking about a place.
func props_block_at(point: Vector2) -> bool:
	if props == null:
		return false
	return (obstacle_bits_at(point) & OBSTACLE_PROP) != 0


## ---------- edits ---------------------------------------------------------

## Force one cell's type. The maps that depend on the type - movement, cover, sight line and
## traversability - are all recomposed for that cell, so the field cannot be left describing ground
## it is not. This is what the tests use to build a controlled battlefield rather than hoping the
## seed produced one.
func set_type_at(point: Vector2, type_id: String) -> bool:
	var index := cell_index_at(point)
	var type_slot_index := _type_ids.find(type_id)
	if index < 0 or type_slot_index < 0:
		return false
	_type_index[index] = type_slot_index
	refresh_maps_of_cell(index)
	return true


## Recompute everything derived from a cell's type and its channels: cover, sight line, traversability,
## obstacle state, and the movement multiplier itself. Generation calls this per cell and so does
## [method set_type_at], which is what stops the two paths from drifting.
func refresh_maps_of_cell(index: int) -> void:
	if index < 0 or index >= _type_index.size():
		return
	var slot := clampi(_type_index[index], 0, maxi(0, _type_traversable.size() - 1))
	if _type_traversable.size() == 0:
		return
	# Cover and opaqueness come from the ground and from what is growing on it. Density is read
	# rather than re-derived: a thicket is a woods cell with vegetation in it, not a new type.
	var vegetation := _vegetation[index] if index < _vegetation.size() else 0.0
	_cover[index] = clampf(maxf(_type_cover[slot], vegetation * 0.35), 0.0, 0.9)
	# Only *thick* growth hides anything. A man standing in knee-high grass is not concealed from the
	# men opposite, and treating every blade of it as opacity made every long sight line blocked: on a
	# field of grass, twenty cells at 0.5 vegetation summed well past [constant LOS_BLOCKED_AT]. What
	# blocks is the type (woods, a cliff) and what is standing in the cell (a tree); the grass only
	# counts once it is over waist high.
	_los[index] = clampf(maxf(_type_los[slot], maxf(0.0, vegetation - LOS_VEGETATION_THRESHOLD) * LOS_VEGETATION_OPACITY), 0.0, 1.0)
	# A prop standing here has already written its own cover and opacity into this cell. Those are
	# maxima rather than a base, so recomposing the ground must not lower them - a tree does not stop
	# hiding a man because the cell under it was repainted.
	if (obstacle_of_cell(index) & OBSTACLE_PROP) != 0:
		_cover[index] = clampf(maxf(_cover[index], maxf(_type_cover[slot], vegetation * 0.35)), 0.0, 0.95)
		_los[index] = clampf(maxf(_los[index], maxf(_type_los[slot], maxf(0.0, vegetation - LOS_VEGETATION_THRESHOLD) * LOS_VEGETATION_OPACITY)), 0.0, 1.0)
	var slope := _slope[index] if index < _slope.size() else 0.0
	var ground_allows := _type_traversable[slot] == 1 and slope <= max_traversable_slope
	# Something standing here that obstructs movement keeps its grip on the cell: a repainted type
	# does not clear the tree that is in the way.
	if (_obstacle[index] & OBSTACLE_PROP) != 0:
		ground_allows = false
	_traversable[index] = 1 if ground_allows else 0
	if _type_traversable[slot] == 0 or slope > max_traversable_slope:
		_obstacle[index] = _obstacle[index] | OBSTACLE_TERRAIN
	else:
		_obstacle[index] = _obstacle[index] & ~OBSTACLE_TERRAIN
	_move[index] = resolve_move_of_cell(index)


## ---------- reporting -----------------------------------------------------

func counts_by_type() -> Dictionary:
	var counts := {}
	for id in _type_ids:
		counts[id] = 0
	for index in _type_index.size():
		var slot := _type_index[index]
		var id := _type_ids[slot] if slot >= 0 and slot < _type_ids.size() else TerrainCatalog.FALLBACK_ID
		counts[id] = int(counts.get(id, 0)) + 1
	return counts


func counts_by_soil() -> Dictionary:
	var counts := {}
	for id in _soil_ids:
		counts[id] = 0
	for index in _soil_index.size():
		var slot := _soil_index[index]
		var id := _soil_ids[slot] if slot >= 0 and slot < _soil_ids.size() else SoilCatalog.FALLBACK_ID
		counts[id] = int(counts.get(id, 0)) + 1
	return counts


func counts_by_variant() -> Dictionary:
	var counts := {}
	for slot in 4:
		counts[slot] = 0
	for index in _type_index.size():
		var slot := variant_of_cell(index)
		counts[slot] = int(counts.get(slot, 0)) + 1
	return counts


## Every cell that is a given type, as cell indices. Used by the tests and the debug overlay.
func cells_of_type(type_id: String) -> Array[int]:
	var out: Array[int] = []
	var wanted := _type_ids.find(type_id)
	if wanted < 0:
		return out
	for index in _type_index.size():
		if _type_index[index] == wanted:
			out.append(index)
	return out


## A compact fingerprint of the whole battlefield. Two terrains with the same signature are identical
## cell for cell, which is what the determinism tests assert. Every channel that carries information
## is folded in, so a change to any one of them is caught rather than assumed.
func signature() -> String:
	var acc := 2166136261
	acc = _mix(acc, terrain_seed)
	acc = _mix(acc, generation_version)
	acc = _mix(acc, cols)
	acc = _mix(acc, rows)
	acc = _mix(acc, int(cell_size * 100.0))
	acc = _mix(acc, _biome_index_of_primary())
	for index in _type_index.size():
		acc = _mix(acc, _type_index[index])
		acc = _mix(acc, _soil_index[index])
		acc = _mix(acc, _obstacle[index])
		acc = _mix(acc, _traversable[index])
		acc = _mix(acc, int(round(_heights[index] * 64.0)))
		acc = _mix(acc, int(round(_move[index] * 256.0)))
		acc = _mix(acc, int(round(_vegetation[index] * 128.0)))
		acc = _mix(acc, int(round(_cover[index] * 128.0)))
		acc = _mix(acc, int(round(_wetness[index] * 128.0)))
		acc = _mix(acc, int(round(_los[index] * 128.0)))
		acc = _mix(acc, int(round(_moisture[index] * 128.0)))
		acc = _mix(acc, int(round(_blend[index] * 64.0)))
		for slot in 4:
			acc = _mix(acc, int(round(_variant_w[index * 4 + slot] * 64.0)))
			acc = _mix(acc, int(round(_overlay_w[index * 4 + slot] * 64.0)))
	return "%08x" % (acc & 0xffffffff)


static func _mix(accumulator: int, value: int) -> int:
	var h := (accumulator ^ (value * 16777619)) & 0x7fffffff
	h = (h ^ (h >> 13)) & 0x7fffffff
	return h


func _biome_index_of_primary() -> int:
	var acc := 0
	for character in biome_id.to_utf8_buffer():
		acc = (acc * 31 + int(character)) & 0x7fffffff
	return acc


func summary() -> String:
	if not is_valid():
		return "terrain: invalid"
	return "terrain seed %d v%d (%s): %dx%d cells of %.1f, %s" % [
		terrain_seed, generation_version, biome_id, cols, rows, cell_size, str(counts_by_type()),
	]


func to_dict() -> Dictionary:
	return {
		"terrain_seed": terrain_seed,
		"generation_version": generation_version,
		"cell_size": cell_size,
		"cols": cols,
		"rows": rows,
		"size": DataUtils.vec2_to(size),
		"biome": biome_id,
		"blend_biome": blend_biome_id,
		"signature": signature(),
		"counts": counts_by_type(),
		"soils": counts_by_soil(),
	}
