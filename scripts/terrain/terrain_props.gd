class_name TerrainProps
extends RefCounted
## The things standing on the ground: trees, bushes, rocks, logs, stumps, fences, ruins, crops, hay,
## debris, reeds, cactus.
##
## [b]Props are terrain, not decoration.[/b] A prop is generated from the same seed as the ground,
## obeys the same rules (no trees on a cliff face, no reeds in a desert), and writes its own gameplay
## into the cells it stands in - cover, sight-line opacity, obstruction. Nothing here draws; the
## renderer reads this and the simulation reads the terrain, and the two cannot disagree because both
## come from the same cells.
##
## [b]Clustered, not sprinkled.[/b] Woods come in woods. Every kind in
## [code]data/terrain/biomes.json[/code] carries a cluster size and radius, so props are placed as
## groups around a site rather than independently per cell - which is the difference between a
## thicket and confetti, and it is also the difference between a place a formation can pass and one
## it cannot.
##
## [b]Deterministic.[/b] Every draw comes from a hash of the seed and the site's own coordinates, so
## the same seed grows the same trees in the same places, in any order, on any machine.

## Where a cluster's members are allowed to fall, relative to the cluster's own radius.
const JITTER_MIN := 0.35
## How far apart cluster sites are, in cells. The lattice is what spreads props over a field of any
## size without a count that has to be tuned per size.
const SITE_SPACING_CELLS := 6.0

var seed_value: int = 0
var generation_version: int = 1
var built_ms: float = 0.0

## Per-prop data, row-major over the props in this field. Packed arrays, no objects: a field with
## several thousand props is still a few hundred kilobytes and no allocations.
var _x: PackedFloat32Array = PackedFloat32Array()
var _y: PackedFloat32Array = PackedFloat32Array()
var _rotation: PackedFloat32Array = PackedFloat32Array()
var _scale: PackedFloat32Array = PackedFloat32Array()
var _cover: PackedFloat32Array = PackedFloat32Array()
var _los: PackedFloat32Array = PackedFloat32Array()
var _radius: PackedFloat32Array = PackedFloat32Array()
var _kind_slot: PackedInt32Array = PackedInt32Array()
var _art_slot: PackedInt32Array = PackedInt32Array()
var _blocks: PackedInt32Array = PackedInt32Array()

## The kinds this field actually grew, in first-seen order: the renderer needs one batch per kind
## rather than one per prop.
var _kinds: Array[String] = []
var _kind_records: Array[Dictionary] = []
## Candidates a rule refused, by rule. A count rather than a comment: "the props are too sparse" and
## "the slope rule is refusing most of them" are different problems with the same symptom.
var refusals: Dictionary = {}
var clusters: int = 0


## Grow the props for a field.
##
## [param keep_clear] is ground nothing may stand on - the deployment zones, chiefly. A battlefield
## whose wooded corner is where an army has to form up is a battlefield that cannot be fought, so the
## exclusion is passed in rather than guessed at.
static func build(
	field: BattlefieldTerrain,
	biomes: BiomeCatalog,
	p_seed: int,
	version: int,
	config: GameConfig,
	keep_clear: Array[Rect2] = []
) -> TerrainProps:
	var props := TerrainProps.new()
	props._grow(field, biomes, p_seed, version, config, keep_clear)
	return props


func _grow(
	field: BattlefieldTerrain,
	biomes: BiomeCatalog,
	p_seed: int,
	version: int,
	config: GameConfig,
	clear_zones: Array[Rect2]
) -> void:
	seed_value = p_seed
	generation_version = version
	var started := Time.get_ticks_usec()
	if field == null or not field.is_valid() or biomes == null:
		built_ms = 0.0
		return
	var density_scale := clampf(config.get_float("terrain.prop_density_scale", 1.0), 0.0, 4.0)
	var cells := float(field.cell_count())
	var primary := field.biome_id
	var secondary := field.blend_biome_id
	var entries := _entries(biomes, primary, secondary)
	if entries.is_empty() or density_scale <= 0.0:
		built_ms = float(Time.get_ticks_usec() - started) / 1000.0
		return

	for entry in entries:
		var record := entry as Dictionary
		var kind_id := str(record.get("kind", ""))
		var definition := biomes.prop_kind(kind_id)
		if definition.is_empty():
			continue
		var density := float(record.get("density", 0.0)) * density_scale
		if density <= 0.0:
			continue
		var min_weight := clampf(float(record.get("min_weight", 0.0)), 0.0, 1.0)
		var max_slope := maxf(0.01, float(record.get("max_slope", 1.0)))
		var allow_wet := bool(record.get("allow_wet", false))
		var weight := clampf(float(record.get("weight", 1.0)), 0.0, 1.0)
		var side := 1 if bool(record.get("blended", false)) else 0
		# Expected props from a density per hundred tiles, at the field's own size. A bigger field
		# gets more props rather than the same ones spread thinner.
		var expected := density * cells / 100.0 * weight
		if expected < 0.5:
			continue
		_grow_kind(field, biomes, kind_id, definition, expected, min_weight, max_slope, allow_wet,
			clear_zones, side)
	built_ms = float(Time.get_ticks_usec() - started) / 1000.0


func _grow_kind(
	field: BattlefieldTerrain,
	biomes: BiomeCatalog,
	kind_id: String,
	definition: Dictionary,
	expected: float,
	min_weight: float,
	max_slope: float,
	allow_wet: bool,
	clear_zones: Array[Rect2],
	side: int
) -> void:
	var cluster_block: Variant = definition.get("cluster", {})
	var cluster := cluster_block as Dictionary if typeof(cluster_block) == TYPE_DICTIONARY else {}
	var count_range := cluster.get("count", [2, 5]) as Array
	var minimum_members := maxi(1, int(count_range[0]) if count_range.size() > 0 else 2)
	var maximum_members := maxi(minimum_members, int(count_range[1]) if count_range.size() > 1 else 5)
	var average_members := float(minimum_members + maximum_members) * 0.5
	var cluster_radius := maxf(1.0, float(cluster.get("radius", 8.0)))
	var base_scale := maxf(0.05, float(definition.get("scale", 2.0)))
	var base_cover := clampf(float(definition.get("cover", 0.0)), 0.0, 1.0)
	var base_los := clampf(float(definition.get("los_blocking", 0.0)), 0.0, 1.0)
	var base_radius := maxf(0.0, float(definition.get("obstacle_radius", 0.0)))
	var blocks := bool(definition.get("blocks_movement", false))
	var art := _art_paths(definition)

	# A lattice of candidate sites rather than uniform sampling: props arrive as groups wherever the
	# ground suits them, and a forest edge reads as an edge.
	var sites_x := maxi(1, int(ceilf(field.size.x / (SITE_SPACING_CELLS * field.cell_size))))
	var sites_y := maxi(1, int(ceilf(field.size.y / (SITE_SPACING_CELLS * field.cell_size))))
	var wanted := int(roundf(expected / average_members))
	var per_site := float(wanted) / float(sites_x * sites_y)
	var salt := _salt_of(kind_id)
	for site_y in sites_y:
		for site_x in sites_x:
			var roll := TerrainGenerator.hash01(seed_value, salt, site_x, site_y)
			if roll >= per_site:
				continue
			clusters += 1
			var centre := Vector2(
				(float(site_x) + 0.15 + TerrainGenerator.hash01(seed_value, salt + 11, site_x, site_y) * 0.7)
					* SITE_SPACING_CELLS * field.cell_size,
				(float(site_y) + 0.15 + TerrainGenerator.hash01(seed_value, salt + 23, site_x, site_y) * 0.7)
					* SITE_SPACING_CELLS * field.cell_size
			)
			var members := minimum_members + int(
				TerrainGenerator.hash01(seed_value, salt + 37, site_x, site_y) * float(maximum_members - minimum_members + 1)
			)
			for member in mini(members, maximum_members):
				var angle := TerrainGenerator.hash01(seed_value, salt + 41, site_x * 13 + member, site_y) * TAU
				var reach := sqrt(TerrainGenerator.hash01(seed_value, salt + 53, site_x, site_y * 17 + member)) * cluster_radius
				var point := centre + Vector2(cos(angle), sin(angle)) * reach
				_place(field, biomes, kind_id, definition, point, base_scale, base_cover, base_los,
					base_radius, blocks, art, min_weight, max_slope, allow_wet, clear_zones,
					site_x * 31 + member, site_y * 17 + member, salt, side)


func _place(
	field: BattlefieldTerrain,
	biomes: BiomeCatalog,
	kind_id: String,
	definition: Dictionary,
	point: Vector2,
	base_scale: float,
	base_cover: float,
	base_los: float,
	base_radius: float,
	blocks: bool,
	art: Array[String],
	min_weight: float,
	max_slope: float,
	allow_wet: bool,
	clear_zones: Array[Rect2],
	hash_x: int,
	hash_y: int,
	salt: int,
	side: int
) -> void:
	if not field.inside(point):
		_count_refusal("outside the field")
		return
	var index := field.cell_index_at(point)
	if index < 0:
		_count_refusal("outside the field")
		return
	# Only things that *obstruct* keep clear of where an army is drawn up. A bush or a stand of
	# reeds underfoot is battlefield furniture; a boulder wall across the deployment is a battle that
	# cannot be fought. The zone is the deployment's own numbers, so the two cannot drift apart.
	if blocks:
		for zone in clear_zones:
			if zone.has_point(point):
				_count_refusal("obstructing, in a keep-clear zone")
				return
	var type_id := field.type_id_of_cell(index)
	# How much of this cell belongs to the country the prop grew in. On a blended field the two
	# countries' props do not overlap in the middle of a wood that is only half theirs - which is
	# what makes a transition band read as a band rather than as both places at once.
	var biome_weight := 1.0
	if not field.blend_biome_id.is_empty():
		biome_weight = field.blend_of_cell(index) if side == 1 else 1.0 - field.blend_of_cell(index)
	if biome_weight < min_weight:
		_count_refusal("below its biome weight")
		return
	if field.slope_of_cell(index) > max_slope:
		_count_refusal("ground too steep")
		return
	if type_id == "water" and not allow_wet:
		_count_refusal("standing in water")
		return
	if type_id == "cliff":
		_count_refusal("on a cliff face")
		return
	var variation := 0.85 + TerrainGenerator.hash01(seed_value, salt + 61, hash_x, hash_y) * 0.3
	var art_index := 0
	if not art.is_empty():
		art_index = int(TerrainGenerator.hash01(seed_value, salt + 71, hash_x, hash_y) * float(art.size()))
		art_index = clampi(art_index, 0, art.size() - 1)
	_x.append(point.x)
	_y.append(point.y)
	_rotation.append(TerrainGenerator.hash01(seed_value, salt + 83, hash_x, hash_y) * TAU)
	_scale.append(base_scale * variation)
	# Cover and sight-line opacity scale with how big the thing actually grew: a sapling does not
	# hide a man.
	var size_factor := clampf((0.6 + variation * 0.55) / 1.0, 0.5, 1.4)
	_cover.append(clampf(base_cover * size_factor, 0.0, 0.95))
	_los.append(clampf(base_los * size_factor, 0.0, 1.0))
	_radius.append(base_radius * variation)
	_kind_slot.append(_register_kind(kind_id, definition))
	_art_slot.append(art_index)
	_blocks.append(1 if blocks else 0)


## Which of a biome's prop entries apply, with the weight each carries when two biomes are blended.
static func _entries(biomes: BiomeCatalog, primary: String, secondary: String) -> Array:
	var out: Array = []
	for entry in biomes.props(primary):
		var record := (entry as Dictionary).duplicate()
		record["weight"] = 1.0
		out.append(record)
	if secondary.is_empty():
		return out
	# A blended field grows both countries' props, each only where that country is.
	for entry in biomes.props(secondary):
		var record := (entry as Dictionary).duplicate()
		record["weight"] = 1.0
		record["blended"] = true
		out.append(record)
	return out


## The kind's art files, in catalogue order. An empty list is legal: the kind then draws as nothing
## and still stands in the world, which is what lets a biome be configured before its art exists.
static func _art_paths(definition: Dictionary) -> Array[String]:
	var raw: Variant = definition.get("art", [])
	var out: Array[String] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry in raw as Array:
		out.append(str(entry))
	return out


static func _salt_of(kind_id: String) -> int:
	var total := 0
	for character in kind_id.to_utf8_buffer():
		total = (total * 31 + int(character)) % 100000
	return 4000 + total


func _register_kind(kind_id: String, definition: Dictionary) -> int:
	var found := _kinds.find(kind_id)
	if found >= 0:
		return found
	_kinds.append(kind_id)
	_kind_records.append(definition)
	return _kinds.size() - 1


func _count_refusal(reason: String) -> void:
	refusals[reason] = int(refusals.get(reason, 0)) + 1


## ---------- reading -------------------------------------------------------

func count() -> int:
	return _x.size()


func is_empty() -> bool:
	return _x.is_empty()


func position_at(index: int) -> Vector2:
	if index < 0 or index >= _x.size():
		return Vector2.ZERO
	return Vector2(_x[index], _y[index])


func rotation_at(index: int) -> float:
	return _rotation[index] if index >= 0 and index < _rotation.size() else 0.0


func scale_at(index: int) -> float:
	return _scale[index] if index >= 0 and index < _scale.size() else 1.0


func cover_at(index: int) -> float:
	return _cover[index] if index >= 0 and index < _cover.size() else 0.0


func los_at(index: int) -> float:
	return _los[index] if index >= 0 and index < _los.size() else 0.0


func radius_at(index: int) -> float:
	return _radius[index] if index >= 0 and index < _radius.size() else 0.0


func blocks_at(index: int) -> bool:
	return _blocks[index] == 1 if index >= 0 and index < _blocks.size() else false


func kind_id_at(index: int) -> String:
	if index < 0 or index >= _kind_slot.size():
		return ""
	var slot := _kind_slot[index]
	return _kinds[slot] if slot >= 0 and slot < _kinds.size() else ""


func kind_record_at(index: int) -> Dictionary:
	if index < 0 or index >= _kind_slot.size():
		return {}
	var slot := _kind_slot[index]
	return _kind_records[slot] if slot >= 0 and slot < _kind_records.size() else {}


func art_at(index: int) -> String:
	if index < 0 or index >= _art_slot.size():
		return ""
	var art := _art_paths(kind_record_at(index))
	var slot := _art_slot[index]
	return art[slot] if slot >= 0 and slot < art.size() else ""


## The kinds this field grew, in the order they were first placed.
func kinds() -> Array[String]:
	return _kinds.duplicate()


func definition_of(kind_id: String) -> Dictionary:
	var found := _kinds.find(kind_id)
	return _kind_records[found] if found >= 0 else {}


## Every prop of one kind. The renderer wants one batch per kind, and this is how it gets one.
func indices_of_kind(kind_id: String) -> Array[int]:
	var out: Array[int] = []
	var wanted := _kinds.find(kind_id)
	if wanted < 0:
		return out
	for index in _kind_slot.size():
		if _kind_slot[index] == wanted:
			out.append(index)
	return out


func counts_by_kind() -> Dictionary:
	var counts := {}
	for index in _kind_slot.size():
		var id := kind_id_at(index)
		counts[id] = int(counts.get(id, 0)) + 1
	return counts


## The art files this field needs, one entry per file, with the props that use each.
##
## Keyed by path rather than by kind because a kind may carry several art files and the renderer
## batches by texture: two kinds sharing one texture should cost one batch, not two.
func art_batches() -> Dictionary:
	var batches := {}
	for index in _kind_slot.size():
		var path := art_at(index)
		if path.is_empty():
			continue
		if not batches.has(path):
			batches[path] = []
		(batches[path] as Array).append(index)
	return batches


## How many props stand within a radius of a point. Reads every prop, so it is a tool rather than a
## query - a per-soldier caller wants [method BattlefieldTerrain.cover_at] instead, which reads the
## cell the prop already wrote to.
func count_within(point: Vector2, radius: float) -> int:
	var total := 0
	var squared := radius * radius
	for index in _x.size():
		if Vector2(_x[index], _y[index]).distance_squared_to(point) <= squared:
			total += 1
	return total


## A fingerprint of every prop: position, kind, art, scale. Two fields with the same signature grew
## the same woods.
func signature() -> String:
	var accumulator := 2166136261
	for index in _x.size():
		accumulator = BattlefieldTerrain._mix(accumulator, int(round(_x[index] * 64.0)))
		accumulator = BattlefieldTerrain._mix(accumulator, int(round(_y[index] * 64.0)))
		accumulator = BattlefieldTerrain._mix(accumulator, int(round(_scale[index] * 64.0)))
		accumulator = BattlefieldTerrain._mix(accumulator, _kind_slot[index])
		accumulator = BattlefieldTerrain._mix(accumulator, _art_slot[index])
	return "%08x" % (accumulator & 0xffffffff)


func summary() -> String:
	return "props seed %d: %d over %d clusters of %d kinds, %.1f ms" % [
		seed_value, count(), clusters, _kinds.size(), built_ms,
	]


func to_dict() -> Dictionary:
	return {
		"seed": seed_value,
		"count": count(),
		"clusters": clusters,
		"kinds": counts_by_kind(),
		"signature": signature(),
	}
