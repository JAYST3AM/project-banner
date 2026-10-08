class_name BattleGroundPainter
extends RefCounted
## Art-free, deterministic tactical ground fallback. This deliberately reads the
## authoritative terrain's types/soils/wetness/vegetation/heights; it never changes
## pathing, collision, battle RNG or a single terrain cell. Replace it with
## TerrainGround's authored atlases as soon as a biome has suitable art.
##
## A texel is a small coherent brushmark, NOT a grid-cell-wide block. Tight palette
## and short horizontal/diagonal clusters avoid the former debug-map appearance.
const TARGET_WIDTH := 1024
const MAX_TEXELS_PER_CELL := 6


static func _mix_id(col: int, row: int, seed_value: int) -> int:
	return ((col * 73856093) ^ (row * 19349663) ^ (seed_value * 83492791)) & 0x7fffffff


static func _soil_colour(soil: String, fallback: Color) -> Color:
	match soil:
		"grass":
			return Color("68704a")
		"dirt":
			return Color("7b6547")
		"silt":
			return Color("796e54")
		"sand":
			return Color("867655")
		"rock":
			return Color("73716a")
		"gravel":
			return Color("7a7665")
		"mudflat":
			return Color("514a38")
		_:
			return fallback


static func _paint_colour(terrain: BattlefieldTerrain, index: int,
		col: int, row: int, low: float, span: float) -> Color:
	var base := terrain.colour_of_cell(index)
	var tint := _soil_colour(terrain.soil_id_of_cell(index), base)
	base = base.lerp(tint, 0.35)
	var vegetation := clampf(terrain.vegetation_of_cell(index), 0.0, 1.0)
	var wetness := clampf(terrain.wetness_of_cell(index), 0.0, 1.0)
	if vegetation > 0.3:
		base = base.lerp(Color("475a39"), vegetation * 0.14)
	if wetness > 0.25:
		base = base.darkened((wetness - 0.25) * 0.18)
	var here := terrain.height_of_cell(index)
	var left := terrain.height_of_cell(row * terrain.cols + maxi(0, col - 1))
	var above := terrain.height_of_cell(maxi(0, row - 1) * terrain.cols + col)
	var illumination := clampf((here - (left + above) * 0.5) * 0.085, -0.14, 0.14)
	var altitude := clampf((here - low) / span, 0.0, 1.0)
	var shade := illumination + (altitude - 0.5) * 0.13
	return base.lightened(shade) if shade >= 0.0 else base.darkened(-shade)


static func bake(terrain: BattlefieldTerrain) -> Image:
	if terrain == null or not terrain.is_valid():
		return null
	var cols := maxi(1, terrain.cols)
	var rows := maxi(1, terrain.rows)
	var per_cell := clampi(TARGET_WIDTH / maxi(cols, rows), 1, MAX_TEXELS_PER_CELL)
	var image := Image.create_empty(cols * per_cell, rows * per_cell,
		false, Image.FORMAT_RGBA8)
	var low := terrain.min_height()
	var span := maxf(0.001, terrain.max_height() - low)
	for cy in rows:
		for cx in cols:
			var index := cy * cols + cx
			var base := _paint_colour(terrain, index, cx, cy, low, span)
			var kind := terrain.type_id_of_cell(index)
			var detail := _mix_id(cx, cy, terrain.terrain_seed)
			var veg := terrain.vegetation_of_cell(index)
			# The three values repeat over groups of pixels, making strokes and
			# worn patches instead of visual static or arbitrary coloured flecks.
			var shadow := base.darkened(0.095)
			var light := base.lightened(0.11)
			for py in per_cell:
				for px in per_cell:
					var x := cx * per_cell + px
					var y := cy * per_cell + py
					var colour := base
					var brush := (detail + (px / 2) * 17 + (py / 2) * 29) % 17
					if brush <= 2:
						colour = shadow
					elif brush >= 15:
						colour = light
					# Horizontal grass tufts, broken scree, and slow water ripples:
					# the texture motif follows the actual terrain type.
					if kind == "water":
						if py % 4 == 1 and (px + detail) % 5 < 3:
							colour = light
					elif kind == "rough" or kind == "cliff":
						if (px + py + detail) % 6 == 0:
							colour = shadow
					elif kind == "woods":
						if (px + detail) % 5 < 2 and py % 3 == 0:
							colour = shadow
					elif veg > 0.35 and (detail % 4) == 0:
						if py % 4 == 1 and px % 5 < 3:
							colour = light
					image.set_pixel(x, y, colour)
	return image
