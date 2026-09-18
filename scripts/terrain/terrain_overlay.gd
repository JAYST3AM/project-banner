class_name TerrainOverlay
extends RefCounted
## The debug view of the ground: every channel the field carries, drawn as a picture.
##
## A battlefield is data before it is anything else, and data is hard to argue with until you can see
## it. This turns one channel at a time into an image - one pixel per cell - with a legend that says
## what the colours mean, so "the woods are in the wrong place" becomes a question about a number
## rather than about a picture.
##
## It lives here rather than in a renderer because both renderers want it: the battle scene draws it
## over its own ground, and the terrain lab draws it on its own.
##
## [b]This is a tool.[/b] Nothing in the game reads it, nothing it draws feeds back into the field,
## and every colour in it is chosen to be legible rather than attractive.

## What each overlay shows. The order is the order the battle's key cycles them in.
enum Mode {
	OFF,
	TYPE,
	HEIGHT,
	SLOPE,
	MOVEMENT,
	TRAVERSABLE,
	SOIL,
	WETNESS,
	VEGETATION,
	COVER,
	SIGHT_LINES,
	OBSTACLES,
	BIOME,
	VARIANT,
	OVERLAY_COVERAGE,
	PROPS,
}

const MODE_NAMES := [
	"off",
	"ground type",
	"height",
	"slope",
	"movement cost",
	"traversability",
	"soil",
	"wetness",
	"vegetation",
	"cover",
	"sight lines",
	"obstacles",
	"biome",
	"ground variant",
	"detail overlays",
	"props",
]

## Ground nothing can cross is drawn in the same red in every mode that has a notion of passing.
const BLOCKED := Color("c03a2f")
const PASSABLE := Color("2f7d4f")


static func mode_count() -> int:
	return MODE_NAMES.size()


static func label(mode: int) -> String:
	return str(MODE_NAMES[clampi(mode, 0, MODE_NAMES.size() - 1)])


static func next_mode(mode: int) -> int:
	return (clampi(mode, 0, MODE_NAMES.size() - 1) + 1) % MODE_NAMES.size()


static func mode_from_name(name: String) -> int:
	var wanted := name.strip_edges().to_lower()
	for index in MODE_NAMES.size():
		if str(MODE_NAMES[index]) == wanted:
			return index
	# Also accept the enum-style names, so a command line can say `--overlay=SLOPE`.
	for key in Mode.keys():
		if str(key).to_lower() == wanted:
			return int(Mode[key])
	return Mode.OFF


## One image, one pixel per cell, in the channel the mode names.
##
## Baked rather than drawn per cell for the same reason the ground is: a field ten times this size is
## fifty thousand rectangles a frame, and this is a picture that only changes when the mode or the
## terrain does.
static func bake(terrain: BattlefieldTerrain, mode: int) -> Image:
	if terrain == null or not terrain.is_valid():
		return null
	var cols := maxi(1, terrain.cols)
	var rows := maxi(1, terrain.rows)
	var image := Image.create_empty(cols, rows, false, Image.FORMAT_RGBA8)
	if mode == Mode.OFF:
		return image
	var tallest := maxf(0.001, terrain.max_height())
	var lowest := terrain.min_height()
	var span := maxf(0.001, tallest - lowest)
	var catalog := TerrainCatalog.load_from()
	var soils := SoilCatalog.load_from()
	var biomes := BiomeCatalog.load_from()
	for row in rows:
		for col in cols:
			var index := row * cols + col
			image.set_pixel(col, row, _colour_of(terrain, index, mode, catalog, soils, biomes, lowest, span))
	return image


static func _colour_of(
	terrain: BattlefieldTerrain,
	index: int,
	mode: int,
	catalog: TerrainCatalog,
	soils: SoilCatalog,
	biomes: BiomeCatalog,
	lowest: float,
	span: float
) -> Color:
	match mode:
		Mode.TYPE:
			return catalog.colour(terrain.type_id_of_cell(index))
		Mode.HEIGHT:
			return _ramp((terrain.height_of_cell(index) - lowest) / span, Color("243447"), Color("e8d9a0"))
		Mode.SLOPE:
			return _ramp(clampf(terrain.slope_of_cell(index) / 1.2, 0.0, 1.0), Color("12281c"), Color("ff5a3c"))
		Mode.MOVEMENT:
			return _ramp(1.0 - terrain.move_multiplier_of_cell(index), Color("2f7d4f"), Color("c03a24"))
		Mode.TRAVERSABLE:
			if not terrain.is_cell_traversable(index):
				return BLOCKED
			return PASSABLE if terrain.type_id_of_cell(index) == "open" else Color("4f8f5f")
		Mode.SOIL:
			return soils.colour(terrain.soil_id_of_cell(index))
		Mode.WETNESS:
			return _ramp(terrain.wetness_of_cell(index), Color("c9b273"), Color("2f6fa8"))
		Mode.VEGETATION:
			return _ramp(terrain.vegetation_of_cell(index), Color("2a2a20"), Color("61c05a"))
		Mode.COVER:
			return _ramp(terrain.cover_of_cell(index), Color("1d1d1d"), Color("f0f0f0"))
		Mode.SIGHT_LINES:
			return _ramp(terrain.los_of_cell(index), Color("101014"), Color("c58cff"))
		Mode.OBSTACLES:
			var bits := terrain.obstacle_of_cell(index)
			if (bits & BattlefieldTerrain.OBSTACLE_PROP) != 0:
				return Color("ff8a3c")
			if (bits & BattlefieldTerrain.OBSTACLE_TERRAIN) != 0:
				return BLOCKED
			return Color("20261f")
		Mode.BIOME:
			var primary := biomes.variant_colour(terrain.biome_id, 0)
			if terrain.blend_biome_id.is_empty():
				return primary
			return primary.lerp(biomes.variant_colour(terrain.blend_biome_id, 0), terrain.blend_of_cell(index))
		Mode.VARIANT:
			return biomes.variant_colour(terrain.biome_id, terrain.variant_of_cell(index))
		Mode.OVERLAY_COVERAGE:
			# Four overlays in one picture: red, green, blue and white, so a cell wearing more than
			# one is visibly wearing more than one.
			return Color(
				terrain.overlay_weight_of_cell(index, 0),
				terrain.overlay_weight_of_cell(index, 1),
				terrain.overlay_weight_of_cell(index, 2),
				terrain.overlay_weight_of_cell(index, 3)
			)
		Mode.PROPS:
			# The ground under the props, dark enough that the props themselves read on top of it.
			return Color("1a2018") if terrain.is_cell_traversable(index) else BLOCKED.darkened(0.4)
	return Color(0.0, 0.0, 0.0, 0.0)


static func _ramp(value: float, from: Color, to: Color) -> Color:
	return from.lerp(to, clampf(value, 0.0, 1.0))


## What the colours in this mode mean, as one line. A legend is the difference between a picture and
## a measurement.
static func legend(terrain: BattlefieldTerrain, mode: int) -> String:
	if terrain == null or mode == Mode.OFF:
		return ""
	match mode:
		Mode.TYPE:
			var parts := PackedStringArray()
			var catalog := TerrainCatalog.load_from()
			for id in catalog.order:
				parts.append("%s %s" % [id, catalog.colour(id).to_html(false)])
			return "ground type: %s" % ", ".join(parts)
		Mode.HEIGHT:
			return "height: dark %.1f to light %.1f, range %.1f" % [
				terrain.min_height(), terrain.max_height(), terrain.max_height() - terrain.min_height()]
		Mode.SLOPE:
			return "slope: green flat to red 1.2 rise per unit run (45 degrees is 1.0)"
		Mode.MOVEMENT:
			return "movement cost: green free to red stopped. mean %.2f" % [_mean(terrain, Mode.MOVEMENT)]
		Mode.TRAVERSABLE:
			return "traversability: green passable, red not. %.0f%% of the field passes" % [
				100.0 * _share_traversable(terrain)]
		Mode.SOIL:
			return "soil: %s" % str(terrain.counts_by_soil())
		Mode.WETNESS:
			return "wetness: dry ochre to wet blue. mean %.2f" % [_mean(terrain, Mode.WETNESS)]
		Mode.VEGETATION:
			return "vegetation: bare to thick. mean %.2f" % [_mean(terrain, Mode.VEGETATION)]
		Mode.COVER:
			return "cover: none to full. mean %.2f" % [_mean(terrain, Mode.COVER)]
		Mode.SIGHT_LINES:
			return "sight lines: clear to opaque (a wood is 0.7, a cliff 1.0)"
		Mode.OBSTACLES:
			return "obstacles: orange is something standing, red is the ground itself"
		Mode.BIOME:
			return "biome: %s%s" % [terrain.biome_id,
				"" if terrain.blend_biome_id.is_empty() else " blended with %s" % terrain.blend_biome_id]
		Mode.VARIANT:
			return "ground variant: %s" % str(terrain.counts_by_variant())
		Mode.OVERLAY_COVERAGE:
			return "detail overlays: red, green, blue, white - one channel each"
		Mode.PROPS:
			if terrain.props == null:
				return "props: none grown for this field"
			return "props: %d, by kind %s" % [terrain.props.count(), str(terrain.props.counts_by_kind())]
	return ""


static func _mean(terrain: BattlefieldTerrain, mode: int) -> float:
	var total := 0.0
	var cells := maxi(1, terrain.cell_count())
	for index in terrain.cell_count():
		match mode:
			Mode.MOVEMENT:
				total += terrain.move_multiplier_of_cell(index)
			Mode.WETNESS:
				total += terrain.wetness_of_cell(index)
			Mode.VEGETATION:
				total += terrain.vegetation_of_cell(index)
			Mode.COVER:
				total += terrain.cover_of_cell(index)
	return total / float(cells)


static func _share_traversable(terrain: BattlefieldTerrain) -> float:
	var open := 0
	for index in terrain.cell_count():
		if terrain.is_cell_traversable(index):
			open += 1
	return float(open) / maxf(1.0, float(terrain.cell_count()))
