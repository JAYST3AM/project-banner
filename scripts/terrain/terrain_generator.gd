class_name TerrainGenerator
extends RefCounted
## Grows a battlefield's channels from a seed, a size and a biome.
##
## The generator is the only place that knows how a field is *made*; [BattlefieldTerrain] is the only
## place that knows how it is *read*. Everything here is a pure function of (seed, size, biome,
## generation_version): every random number comes from a hashed lattice coordinate rather than from a
## generator's state, so cells can be visited in any order, two runs agree exactly, and generating a
## battlefield cannot disturb any other random stream in the game.
##
## [b]Shape before noise.[/b] A battlefield is built from landforms - rolling ground, hills, ridges,
## valleys, basins, scarps, riverbeds, clearings - and only then dressed with restrained small-scale
## variation. Noise alone produces ground no formation can use. The landforms are what make a hilltop
## worth taking and a riverbed worth avoiding.
##
## [b]Everything comes from data.[/b] No biome is named anywhere in this file. Every frequency,
## threshold and density is read from [BiomeCatalog] or from [code]terrain.*[/code] in the game
## config, so a new country is a block in [code]data/terrain/biomes.json[/code].
##
## [b]Blending.[/b] When a field names a second biome, the two are mixed across a band rather than
## meeting at a line: the cell's blend weight interpolates the parameters that shape ground
## (elevation, moisture, wetness, vegetation, detail) and the choice of soil, so the border is a
## gradient in behaviour as well as in looks. The landforms themselves belong to the field's own
## biome - a hill is a hill whichever country it is in.

## One salt per field, so every field is its own stream without anything having to be stored.
const SALT_BASE := 1101
const SALT_DETAIL := 2203
const SALT_MOISTURE := 3307
const SALT_WEAR := 4409
const SALT_REGION := 5501
const SALT_FEATURE := 6607
const SALT_CLUSTER := 7703
const SALT_ROCK := 8807
const SALT_SOIL := 9901
const SALT_BLEND := 10301

## How many lattice sites a field spans at minimum, so a very small battlefield still gets features.
const MIN_LATTICE := 3
## The most of each landform one field may carry. Densities place features; a cap stops a biome from
## carving a battlefield into islands - two rivers across a hundred-unit field is a puzzle rather
## than a battle, and no amount of tuning makes four of them better.
const FEATURE_CAPS := {
	"hills": 24,
	"ridges": 12,
	"valleys": 12,
	"basins": 10,
	"cliffs": 3,
	"riverbeds": 2,
	"clearings": 5,
}
## How wide a river's bed is, in cells, and how much of the field its channel runs across.
const RIVER_BED_CELLS := 2.2
const RIVER_RUN_FACTOR := 1.5


## Build [param field]'s channels. Called by [method BattlefieldTerrain._build].
static func build(
	field: BattlefieldTerrain,
	config: GameConfig,
	types: TerrainCatalog,
	biomes: BiomeCatalog,
	soils: SoilCatalog,
	version: int
) -> void:
	var cols := field.cols
	var rows := field.rows
	var total := cols * rows
	if total <= 0:
		return
	var seed_value := field.terrain_seed
	var cell := field.cell_size
	var primary := field.biome_id
	var secondary := field.blend_biome_id

	# ---------- knobs -----------------------------------------------------
	var elevation_amplitude := config.get_float("terrain.elevation_amplitude", 5.0)
	var detail_amplitude := config.get_float("terrain.detail_amplitude", 0.5)
	var cliff_slope := maxf(0.2, config.get_float("terrain.cliff_slope", 0.9))
	var rough_slope := maxf(0.02, config.get_float("terrain.rough_slope", 0.3))
	var woods_vegetation := config.get_float("terrain.woods_vegetation", 0.5)
	var mud_wetness := config.get_float("terrain.mud_wetness", 0.6)
	var high_fraction := clampf(config.get_float("terrain.high_ground_fraction", 0.8), 0.5, 0.99)
	var water_fraction := clampf(config.get_float("terrain.water_fraction", 0.05), 0.0, 0.4)
	var water_enabled := config.get_bool("terrain.water", true)
	var cliffs_enabled := config.get_bool("terrain.cliffs", true)
	var variant_strength := clampf(config.get_float("terrain.variant_strength", 0.75), 0.0, 1.0)
	var rock_vegetation := config.get_float("terrain.rock_vegetation", 0.45)

	# ---------- the blended parameters, read once -------------------------
	var el_a := _params(biomes, primary)
	var el_b := _params(biomes, secondary, el_a)
	var veg_a := _vege(biomes, primary)
	var veg_b := _vege(biomes, secondary, veg_a)
	var detail_a := biomes.number(primary, "detail", 0.16) if biomes != null else 0.16
	var detail_b := biomes.number(secondary, "detail", detail_a) if biomes != null else detail_a
	var moisture_a := biomes.number(primary, "moisture", 0.45) if biomes != null else 0.45
	var moisture_b := biomes.number(secondary, "moisture", moisture_a) if biomes != null else moisture_a
	var wetness_a := biomes.number(primary, "wetness", 0.06) if biomes != null else 0.06
	var wetness_b := biomes.number(secondary, "wetness", wetness_a) if biomes != null else wetness_a
	var soil_pick := _soil_picker(biomes, soils, primary)
	var soil_pick_b := _soil_picker(biomes, soils, secondary)
	var overlay_sources := _overlay_sources(biomes, primary)
	var overlay_sources_b := _overlay_sources(biomes, secondary)

	# ---------- pass 1: the base relief and the fields it grew ------------
	var heights := PackedFloat32Array()
	heights.resize(total)
	var blend := PackedFloat32Array()
	blend.resize(total)
	var moisture := PackedFloat32Array()
	moisture.resize(total)
	var wear := PackedFloat32Array()
	wear.resize(total)
	var region := PackedFloat32Array()
	region.resize(total)
	var cluster := PackedFloat32Array()
	cluster.resize(total)
	var rockiness := PackedFloat32Array()
	rockiness.resize(total)

	var has_blend := not secondary.is_empty() and field.blend_width_cells > 0.0
	var blend_width := maxf(1.0, field.blend_width_cells)
	for row in rows:
		var v := (float(row) + 0.5) / float(rows)
		for col in cols:
			var index := row * cols + col
			var u := (float(col) + 0.5) / float(cols)
			var mix := 0.0
			if has_blend:
				# A band, not a line: the second country arrives across a width the field names.
				var raw := _fbm(seed_value, SALT_BLEND, u, v, 3, 2.0, version)
				var edge := 0.5 + (u - 0.5) * 0.35
				var half := blend_width / float(maxi(cols, rows)) * 2.0
				mix = smoothstep(edge - half, edge + half, raw)
			blend[index] = mix
			var base_height := lerpf(el_a.x, el_b.x, mix)
			var amplitude := lerpf(el_a.y, el_b.y, mix) * elevation_amplitude
			var roughness := lerpf(el_a.z, el_b.z, mix)
			var bias := lerpf(el_a.w, el_b.w, mix)
			var relief := (_fbm(seed_value, SALT_BASE, u, v, 3, 1.6, version) - 0.5) * roughness
			heights[index] = (base_height - 0.5 + bias * 0.4) * amplitude * 0.4 + relief * amplitude
			moisture[index] = clampf(lerpf(moisture_a, moisture_b, mix) * 0.55
				+ _fbm(seed_value, SALT_MOISTURE, u, v, 2, 2.4, version) * 0.45, 0.0, 1.0)
			wear[index] = _fbm(seed_value, SALT_WEAR, u, v, 2, 3.1, version)
			region[index] = _fbm(seed_value, SALT_REGION, u, v, 2, 1.4, version)
			# Clustered rather than uniform: trees come in woods, not sprinkled one by one. The two
			# smoothstep edges are what make a clump read as a clump at any field size.
			cluster[index] = smoothstep(0.42, 0.78, _fbm(seed_value, SALT_CLUSTER, u, v, 2, 4.2, version))
			rockiness[index] = smoothstep(0.58, 0.88, _fbm(seed_value, SALT_ROCK, u, v, 2, 3.6, version))

	# ---------- pass 2: the landforms -------------------------------------
	_place_features(heights, cols, rows, seed_value, version, biomes, primary, elevation_amplitude)

	# ---------- pass 3: the restrained detail -----------------------------
	for row in rows:
		var v2 := (float(row) + 0.5) / float(rows)
		for col in cols:
			var index2 := row * cols + col
			var u2 := (float(col) + 0.5) / float(cols)
			var detail := (_fbm(seed_value, SALT_DETAIL, u2, v2, 3, 7.0, version) - 0.5) * 2.0
			heights[index2] += detail * detail_amplitude * lerpf(detail_a, detail_b, blend[index2])

	# ---------- pass 4: slope, and the height range -----------------------
	var slope := PackedFloat32Array()
	slope.resize(total)
	var lowest := INF
	var tallest := -INF
	for row in rows:
		for col in cols:
			var index3 := row * cols + col
			var h := heights[index3]
			lowest = minf(lowest, h)
			tallest = maxf(tallest, h)
			var left := heights[index3 - 1] if col > 0 else h
			var right := heights[index3 + 1] if col < cols - 1 else h
			var up := heights[index3 - cols] if row > 0 else h
			var down := heights[index3 + cols] if row < rows - 1 else h
			var dx := (right - left) / (2.0 * cell)
			var dy := (down - up) / (2.0 * cell)
			slope[index3] = sqrt(dx * dx + dy * dy)
	var span := maxf(0.001, tallest - lowest)
	var water_level := lowest + span * water_fraction
	var high_level := lowest + span * high_fraction
	var low_band := water_level + span * 0.12

	# ---------- pass 5: the channels, per cell ----------------------------
	var soil_index := PackedInt32Array()
	soil_index.resize(total)
	var type_index := PackedInt32Array()
	type_index.resize(total)
	var vegetation := PackedFloat32Array()
	vegetation.resize(total)
	var wetness := PackedFloat32Array()
	wetness.resize(total)
	var variant_w := PackedFloat32Array()
	variant_w.resize(total * 4)
	var overlay_w := PackedFloat32Array()
	overlay_w.resize(total * 4)

	var water_slot := types.index_of(field.water_type_id)
	var cliff_slot := types.index_of(field.cliff_type_id)
	var mud_slot := types.index_of(field.mud_type_id)
	var woods_slot := types.index_of(field.woods_type_id)
	var high_slot := types.index_of(field.high_type_id)
	var rough_slot := types.index_of(field.rough_type_id)
	var open_slot := types.index_of(TerrainCatalog.FALLBACK_ID)

	for row in rows:
		for col in cols:
			var index4 := row * cols + col
			var mix2 := blend[index4]
			var here_slope := slope[index4]
			var here_height := heights[index4]
			var here_moisture := clampf(moisture[index4], 0.0, 1.0)
			var here_wear := clampf(wear[index4], 0.0, 1.0)
			var here_region := clampf(region[index4], 0.0, 1.0)

			# Water first: the lowest ground is the riverbed, and the ground beside it is wet.
			var wet := lerpf(wetness_a, wetness_b, mix2)
			if here_height <= low_band:
				wet = maxf(wet, clampf(1.0 - (here_height - water_level) / maxf(0.001, low_band - water_level), 0.0, 1.0))
			wetness[index4] = clampf(wet * 0.75 + here_moisture * 0.25, 0.0, 1.0)

			# Vegetation: what the biome grows, thinned by slope and crowded out by water.
			var base_veg := lerpf(veg_a.x, veg_b.x, mix2)
			var tree_density := lerpf(veg_a.y, veg_b.y, mix2)
			var slope_thinning := clampf(1.0 - here_slope * 1.6, 0.15, 1.0)
			vegetation[index4] = clampf(base_veg + tree_density * cluster[index4] * slope_thinning
				- wetness[index4] * 0.25, 0.0, 1.0)

			# Soil: what the ground is made of, chosen by how wet the cell is.
			var pick := _pick_soil(soil_pick, soil_pick_b, mix2, here_moisture, seed_value, index4)
			if water_enabled and here_height <= water_level:
				pick = soils.index_of("silt")
			elif here_slope >= cliff_slope:
				pick = soils.index_of("rock")
			soil_index[index4] = maxi(0, pick)

			# Type: the rule the ground follows. Order matters - the strictest ground wins.
			var slot := open_slot
			if water_enabled and here_height <= water_level:
				slot = water_slot
			elif cliffs_enabled and here_slope >= cliff_slope:
				slot = cliff_slot
			elif vegetation[index4] >= woods_vegetation:
				slot = woods_slot
			elif wetness[index4] >= mud_wetness and here_height <= low_band:
				slot = mud_slot
			elif here_height >= high_level:
				slot = high_slot
			elif here_slope >= rough_slope or rockiness[index4] >= rock_vegetation:
				slot = rough_slot
			type_index[index4] = maxi(0, slot)

			# Variants: the country's looks, weighted by the field that grew them. Slot 0 is the
			# country's default ground and takes whatever is left; 1 is the worn ground, 2 the dry
			# ground and 3 the unmanaged one. Those four readings are the same on every biome, which
			# is the contract that lets one weight formula serve all of them.
			var dry := clampf((0.55 - here_moisture) * 2.0, 0.0, 1.0)
			var unmanaged := clampf((1.0 - here_wear) * here_region, 0.0, 1.0)
			var w1 := 0.30
			var w2 := dry * 0.8 * variant_strength
			var w3 := unmanaged * 0.7 * variant_strength
			var sum := w1 + w2 + w3
			if sum > 1.0:
				var scale := 1.0 / sum
				w1 *= scale
				w2 *= scale
				w3 *= scale
			variant_w[index4 * 4 + 0] = maxf(0.0, 1.0 - (w1 + w2 + w3))
			variant_w[index4 * 4 + 1] = w1
			variant_w[index4 * 4 + 2] = w2
			variant_w[index4 * 4 + 3] = w3

			# Overlays: detail regions, driven by masks rather than by speckle. Each biome names
			# which field each overlay reads, so a new overlay is a row in the JSON.
			for overlay_index in 4:
				var coverage_a := _overlay_coverage(str(overlay_sources[overlay_index]), here_wear,
					here_moisture, here_slope, wetness[index4], cliff_slope,
					overlay_strength(biomes, primary, overlay_index))
				var coverage_b := _overlay_coverage(str(overlay_sources_b[overlay_index]), here_wear,
					here_moisture, here_slope, wetness[index4], cliff_slope,
					overlay_strength(biomes, secondary, overlay_index))
				overlay_w[index4 * 4 + overlay_index] = clampf(lerpf(coverage_a, coverage_b, mix2), 0.0, 1.0)

	# ---------- pass 6: into the field ------------------------------------
	field._heights = heights
	field._slope = slope
	field._blend = blend
	field._moisture = moisture
	field._vegetation = vegetation
	field._wetness = wetness
	field._soil_index = soil_index
	field._type_index = type_index
	field._variant_w = variant_w
	field._overlay_w = overlay_w
	for index5 in total:
		field._obstacle[index5] = BattlefieldTerrain.OBSTACLE_NONE
		field.refresh_maps_of_cell(index5)


## ---------- landforms ------------------------------------------------------

## Place the landform features on a jittered lattice and add them to the height field.
##
## A lattice rather than a count, so the same biome means the same thing on a 100x60 field and on a
## 633x380 one: "hills 0.3" is three hills in ten lattice cells at every size, and the lattice is
## spaced by [code]features.spacing[/code] cells. Each family hashes its own stream, so adding
## ridges to a biome cannot move a single hill.
static func _place_features(
	heights: PackedFloat32Array,
	cols: int,
	rows: int,
	seed_value: int,
	version: int,
	biomes: BiomeCatalog,
	biome_id: String,
	elevation_amplitude: float
) -> void:
	var features := biomes.features_block(biome_id)
	if features.is_empty():
		return
	var spacing := maxf(3.0, float(features.get("spacing", 7.0)))
	var scale := maxf(0.25, biomes.number(biome_id, "feature_scale", 1.0, "elevation"))
	var lattice_cols := maxi(MIN_LATTICE, int(ceilf(float(cols) / spacing)))
	var lattice_rows := maxi(MIN_LATTICE, int(ceilf(float(rows) / spacing)))
	var base_radius := maxf(1.5, spacing * 0.55 * scale)
	var amplitude := elevation_amplitude * maxf(0.2, biomes.number(biome_id, "amplitude", 1.0, "elevation"))
	var placed := {}

	var families: Array[String] = ["hills", "ridges", "valleys", "basins", "cliffs", "riverbeds", "clearings"]
	for family_index in families.size():
		var family := families[family_index]
		var chance := clampf(float(features.get(family, 0.0)), 0.0, 1.0)
		if chance <= 0.0:
			continue
		var cap := int(FEATURE_CAPS.get(family, 99))
		var count := 0
		var family_salt := SALT_FEATURE + family_index * 977
		for ly in lattice_rows:
			for lx in lattice_cols:
				if count >= cap:
					break
				if _hash01(seed_value, family_salt + version, lx, ly) >= chance:
					continue
				count += 1
				var jitter_x := _hash01(seed_value, family_salt + 17, lx, ly)
				var jitter_y := _hash01(seed_value, family_salt + 29, lx, ly)
				var spread := 0.55 + _hash01(seed_value, family_salt + 41, lx, ly) * 0.75
				var size := base_radius * spread
				var angle := _hash01(seed_value, family_salt + 67, lx, ly) * TAU
				var strength := (0.45 + _hash01(seed_value, family_salt + 79, lx, ly) * 0.85) * amplitude
				var centre := Vector2(
					(float(lx) + jitter_x) / float(lattice_cols) * float(cols),
					(float(ly) + jitter_y) / float(lattice_rows) * float(rows)
				)
				match family:
					"hills":
						_apply_blob(heights, cols, rows, centre, size, strength * 0.75, 1.0, angle, 1.0, 1.0)
					"ridges":
						_apply_blob(heights, cols, rows, centre, size * 2.2, strength * 0.6, 0.32, angle, 1.4, 1.0)
					"valleys":
						_apply_blob(heights, cols, rows, centre, size * 1.8, strength * 0.55, 0.4, angle, 1.3, -1.0)
					"basins":
						_apply_blob(heights, cols, rows, centre, size * 1.4, strength * 0.4, 1.0, angle, 0.8, -1.0)
					"cliffs":
						_apply_scarp(heights, cols, rows, centre, angle, size * 3.2,
							maxf(1.0, size * 0.35), strength * 0.8)
					"riverbeds":
						_carve_river(heights, cols, rows, centre, angle,
							float(maxi(cols, rows)) * RIVER_RUN_FACTOR, RIVER_BED_CELLS,
							strength * 0.6, seed_value, lx, ly, family_salt)
					"clearings":
						_flatten_clearing(heights, cols, rows, centre, size * 1.6, 0.7)
		placed[family] = count


## A rounded, irregular blob: a hill, a ridge, a valley or a basin depending on the arguments.
##
## The wobble is what stops them looking like noise: `sin(3*theta)` gives every landform a lobed
## outline, so a hillside has shoulders instead of being a smooth dome.
static func _apply_blob(
	heights: PackedFloat32Array,
	cols: int,
	rows: int,
	centre: Vector2,
	radius: float,
	height: float,
	stretch: float,
	angle: float,
	falloff_power: float,
	sign: float
) -> void:
	var cos_a := cos(angle)
	var sin_a := sin(angle)
	var reach := radius * maxf(1.0, 1.0 / maxf(0.05, stretch)) + 2.0
	var min_x := maxi(0, int(floorf(centre.x - reach)))
	var max_x := mini(cols - 1, int(ceilf(centre.x + reach)))
	var min_y := maxi(0, int(floorf(centre.y - reach)))
	var max_y := mini(rows - 1, int(ceilf(centre.y + reach)))
	for row in range(min_y, max_y + 1):
		for col in range(min_x, max_x + 1):
			var dx := float(col) + 0.5 - centre.x
			var dy := float(row) + 0.5 - centre.y
			var along := dx * cos_a + dy * sin_a
			var across := -dx * sin_a + dy * cos_a
			var distance := sqrt(along * along + (across * across) / maxf(0.01, stretch * stretch))
			if distance >= radius:
				continue
			var theta := atan2(dy, dx)
			var wobble := 1.0 - 0.22 * sin(theta * 3.0 + angle * 1.7)
			var t := clampf(distance / maxf(0.001, radius * wobble), 0.0, 1.0)
			var weight := pow(clampf(0.5 + 0.5 * cos(PI * t), 0.0, 1.0), falloff_power)
			heights[row * cols + col] += sign * height * weight


## A scarp: ground on one side of a line stands above the other, with a steep face between.
##
## This is what a cliff is in this system - the slope on the face is what makes those cells cliff
## ground, so a cliff is a consequence of the land rather than a shape painted onto it. The face is
## narrow on purpose: a wide one would be a hill.
static func _apply_scarp(
	heights: PackedFloat32Array,
	cols: int,
	rows: int,
	centre: Vector2,
	angle: float,
	length: float,
	width: float,
	height: float
) -> void:
	var cos_a := cos(angle)
	var sin_a := sin(angle)
	var normal := Vector2(-sin_a, cos_a)
	for row in rows:
		for col in cols:
			var dx := float(col) + 0.5 - centre.x
			var dy := float(row) + 0.5 - centre.y
			var along := dx * cos_a + dy * sin_a
			if absf(along) > length:
				continue
			var distance := dx * normal.x + dy * normal.y
			var fade := clampf(1.0 - absf(along) / maxf(1.0, length), 0.0, 1.0)
			heights[row * cols + col] += height * (smoothstep(-width, width, distance) - 0.5) * (0.35 + 0.65 * fade)


## A river: a wandering channel across the field, with a bed and banks that fall away from it.
##
## Carved rather than stamped as a rectangle, so its width and direction are the river's own, and the
## ground beside it is merely low - which is what lets the bank be silt and the bed be water without
## anything naming either.
static func _carve_river(
	heights: PackedFloat32Array,
	cols: int,
	rows: int,
	start: Vector2,
	angle: float,
	run_length: float,
	bed_cells: float,
	depth: float,
	seed_value: int,
	lx: int,
	ly: int,
	salt: int
) -> void:
	var direction := Vector2(cos(angle), sin(angle))
	var normal := Vector2(-direction.y, direction.x)
	var steps := maxi(12, int(run_length))
	var wander := 0.0
	var previous := start - direction * run_length * 0.5
	for step in range(steps + 1):
		var t := float(step) / float(steps)
		wander += (_hash01(seed_value, salt + 101, lx * 31 + step, ly * 17 + step) - 0.5) * 1.4
		var point := start - direction * run_length * 0.5 + direction * (t * run_length) + normal * wander
		_stamp_channel(heights, cols, rows, previous, point, bed_cells, depth)
		previous = point


static func _stamp_channel(
	heights: PackedFloat32Array,
	cols: int,
	rows: int,
	from: Vector2,
	to: Vector2,
	width: float,
	depth: float
) -> void:
	var min_x := maxi(0, int(floorf(minf(from.x, to.x) - width - 1.0)))
	var max_x := mini(cols - 1, int(ceilf(maxf(from.x, to.x) + width + 1.0)))
	var min_y := maxi(0, int(floorf(minf(from.y, to.y) - width - 1.0)))
	var max_y := mini(rows - 1, int(ceilf(maxf(from.y, to.y) + width + 1.0)))
	var segment := to - from
	var length_squared := maxf(0.0001, segment.length_squared())
	for row in range(min_y, max_y + 1):
		for col in range(min_x, max_x + 1):
			var point := Vector2(float(col) + 0.5, float(row) + 0.5)
			var t := clampf((point - from).dot(segment) / length_squared, 0.0, 1.0)
			var closest := from + segment * t
			var distance := point.distance_to(closest)
			if distance > width:
				continue
			var profile := 1.0 - (distance / width) * (distance / width)
			heights[row * cols + col] -= depth * profile


## A clearing: ground levelled toward the mean of what is already there, so formations have somewhere
## to deploy. Noise alone leaves nowhere flat, and a battlefield with nowhere flat is not a
## battlefield.
static func _flatten_clearing(
	heights: PackedFloat32Array,
	cols: int,
	rows: int,
	centre: Vector2,
	radius: float,
	strength: float
) -> void:
	var min_x := maxi(0, int(floorf(centre.x - radius)))
	var max_x := mini(cols - 1, int(ceilf(centre.x + radius)))
	var min_y := maxi(0, int(floorf(centre.y - radius)))
	var max_y := mini(rows - 1, int(ceilf(centre.y + radius)))
	var total := 0.0
	var count := 0
	for row in range(min_y, max_y + 1):
		for col in range(min_x, max_x + 1):
			total += heights[row * cols + col]
			count += 1
	if count == 0:
		return
	var level := total / float(count)
	for row in range(min_y, max_y + 1):
		for col in range(min_x, max_x + 1):
			var distance := Vector2(float(col) + 0.5, float(row) + 0.5).distance_to(centre)
			if distance > radius:
				continue
			var t := clampf(distance / radius, 0.0, 1.0)
			var weight := clampf(strength * (0.5 + 0.5 * cos(PI * t)), 0.0, 1.0)
			var index := row * cols + col
			heights[index] = lerpf(heights[index], level, weight)


## ---------- data-driven tables --------------------------------------------

## A biome's elevation character as (base, amplitude, roughness, bias). The fallback is the primary
## biome's own values, so a blended field that names no second country changes nothing.
static func _params(biomes: BiomeCatalog, biome_id: String, fallback: Vector4 = Vector4(0.45, 1.0, 0.3, 0.0)) -> Vector4:
	if biomes == null or biome_id.is_empty():
		return fallback
	return Vector4(
		biomes.number(biome_id, "base", fallback.x, "elevation"),
		biomes.number(biome_id, "amplitude", fallback.y, "elevation"),
		biomes.number(biome_id, "roughness", fallback.z, "elevation"),
		biomes.number(biome_id, "bias", fallback.w, "elevation")
	)


## A biome's vegetation as (base density, tree density).
static func _vege(biomes: BiomeCatalog, biome_id: String, fallback: Vector2 = Vector2(0.2, 0.04)) -> Vector2:
	if biomes == null or biome_id.is_empty():
		return fallback
	return Vector2(
		biomes.number(biome_id, "base", fallback.x, "vegetation"),
		biomes.number(biome_id, "trees", fallback.y, "vegetation")
	)


## A biome's soils as indices, weights, and how wet each of them is.
##
## The moistures are read once here rather than per cell: a soil's wetness is a property of the soil,
## and asking the catalogue for it inside the cell loop was the difference between a generator that
## takes milliseconds and one that takes a second.
static func _soil_picker(biomes: BiomeCatalog, soils: SoilCatalog, biome_id: String) -> Dictionary:
	var ids: Array[int] = []
	var weights := PackedFloat32Array()
	var moistures := PackedFloat32Array()
	if biomes != null and not biome_id.is_empty():
		for entry in biomes.soils(biome_id):
			var record := entry as Dictionary
			var id := str(record.get("id", ""))
			if not soils.has(id):
				continue
			ids.append(soils.index_of(id))
			weights.append(maxf(0.0, float(record.get("weight", 1.0))))
			moistures.append(soils.moisture(id))
	if ids.is_empty():
		var fallback := soils.index_of(SoilCatalog.FALLBACK_ID)
		ids.append(fallback)
		weights.append(1.0)
		moistures.append(soils.moisture(SoilCatalog.FALLBACK_ID))
	return {"ids": ids, "weights": weights, "moistures": moistures}


## Choose a soil: the biome's weights, pulled toward the soils that match how wet this cell is.
##
## Deterministic and order-independent. The per-cell hash only rolls the dice between soils that
## scored differently, so the same cell always gets the same soil without a generator's state.
static func _pick_soil(
	picker: Dictionary,
	picker_b: Dictionary,
	mix: float,
	moisture: float,
	seed_value: int,
	index: int
) -> int:
	var chosen_a := _pick_from(picker, moisture, seed_value, index)
	if mix <= 0.0:
		return chosen_a
	var chosen_b := _pick_from(picker_b, moisture, seed_value, index + 7919)
	return chosen_b if _hash01(seed_value, SALT_SOIL + 5, index, 3) < mix else chosen_a


static func _pick_from(picker: Dictionary, moisture: float, seed_value: int, index: int) -> int:
	var ids := picker["ids"] as Array[int]
	if ids.is_empty():
		return 0
	var weights := picker["weights"] as PackedFloat32Array
	var moistures := picker["moistures"] as PackedFloat32Array
	var scores := PackedFloat32Array()
	scores.resize(ids.size())
	var total := 0.0
	for i in ids.size():
		# A soil that is exactly as wet as the cell scores highest, which is what makes sand appear
		# on dry ground and mud in hollows without a rule naming either.
		var match := 1.0 - absf(moistures[i] - moisture)
		var score := weights[i] * maxf(0.05, match * match)
		scores[i] = score
		total += score
	if total <= 0.0:
		return ids[0]
	var roll := _hash01(seed_value, SALT_SOIL, index, 11) * total
	var running := 0.0
	for i in ids.size():
		running += scores[i]
		if roll <= running:
			return ids[i]
	return ids[ids.size() - 1]


## Which field each of a biome's four overlays reads. Missing slots read "none" and stay at zero.
static func _overlay_sources(biomes: BiomeCatalog, biome_id: String) -> Array[String]:
	var out: Array[String] = []
	if biomes != null and not biome_id.is_empty():
		for entry in biomes.overlays(biome_id):
			var record := entry as Dictionary
			out.append(str(record.get("source", "none")))
	while out.size() < 4:
		out.append("none")
	return out


static func overlay_strength(biomes: BiomeCatalog, biome_id: String, slot: int) -> float:
	if biomes == null or biome_id.is_empty():
		return 0.0
	var list := biomes.overlays(biome_id)
	if slot < 0 or slot >= list.size():
		return 0.0
	return clampf(float((list[slot] as Dictionary).get("strength", 0.7)), 0.0, 1.0)


## How much of an overlay a cell wears, from the field its biome named.
static func _overlay_coverage(
	source: String,
	wear: float,
	moisture: float,
	slope: float,
	wetness: float,
	cliff_slope: float,
	strength: float
) -> float:
	if source == "none" or strength <= 0.0:
		return 0.0
	var value := 0.0
	match source:
		"wear":
			value = smoothstep(0.55, 0.9, wear)
		"dryness":
			value = smoothstep(0.5, 0.15, moisture)
		"moisture":
			value = smoothstep(0.55, 0.9, moisture)
		"slope":
			value = smoothstep(0.08, cliff_slope * 0.85, slope)
		"wetness":
			value = smoothstep(0.5, 0.9, wetness)
	return clampf(value * strength, 0.0, 1.0)


## ---------- noise ---------------------------------------------------------

## Fractal value noise over the field's own 0..1 coordinates. Wrapped at the lattice period, so the
## field's left edge and right edge agree and a feature never runs off into a discontinuity.
static func _fbm(seed_value: int, salt: int, u: float, v: float, octaves: int, frequency: float, version: int) -> float:
	var total := 0.0
	var weight := 0.0
	var amplitude := 1.0
	var f := frequency
	for octave in octaves:
		var period := maxi(2, int(roundf(f)))
		total += _value_noise(seed_value, salt + octave * 131 + version, u * f, v * f, period) * amplitude
		weight += amplitude
		amplitude *= 0.5
		f *= 2.0
	return total / maxf(0.001, weight)


static func _value_noise(seed_value: int, salt: int, x: float, y: float, period: int) -> float:
	var x0 := int(floorf(x))
	var y0 := int(floorf(y))
	var fx := x - floorf(x)
	var fy := y - floorf(y)
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sy := fy * fy * (3.0 - 2.0 * fy)
	var a := _hash01(seed_value, salt, posmod(x0, period), posmod(y0, period))
	var b := _hash01(seed_value, salt, posmod(x0 + 1, period), posmod(y0, period))
	var c := _hash01(seed_value, salt, posmod(x0, period), posmod(y0 + 1, period))
	var d := _hash01(seed_value, salt, posmod(x0 + 1, period), posmod(y0 + 1, period))
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)


## A number in [0, 1) from four integers. Integer arithmetic only, so it is exact, fast, and gives
## the same answer on every machine and in any order - which is the whole reason the generator has no
## state of its own.
static func _hash01(seed_value: int, salt: int, x: int, y: int) -> float:
	var h := (x * 374761393 + y * 668265263 + salt * 2246822519 + seed_value * 2654435761) % 2147483647
	if h < 0:
		h += 2147483647
	h = (h ^ (h >> 13)) * 1274126177
	h = h % 2147483647
	if h < 0:
		h += 2147483647
	h = h ^ (h >> 16)
	return float(h % 16777216) / 16777216.0
