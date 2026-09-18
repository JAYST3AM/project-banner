class_name WorldTerrain
extends Sprite2D
## The campaign map's ground, as terrain rather than a flat colour.
##
## A field of biome weights is generated from the world seed: one value says how much of the second
## biome a place is, another is its height. The shader mixes two grounds by the first and shades
## them by the second, so where two biomes meet the ground changes over a band rather than at a
## line - and the same weight will drive movement and props when they arrive, so a place cannot
## look like a forest edge and walk like a field.
##
## It is a Sprite2D and not a Control on purpose: the map is a Node2D world under a Camera2D, and a
## Control lives in screen space - the first version of this sat still while the map panned and
## covered the roads and settlements it was supposed to be under.
##
## Nothing here is in the simulation. The field is presentation for now: the campaign's own rules
## still read the settlement and travel data they always did, and this node cannot change one of
## them.

## The field's resolution. Not the screen's: this is how finely the biomes can change, one cell per
## sixteen-odd world units. A test knob, like the two below it.
const FIELD_COLS := 160
const FIELD_ROWS := 112
## How wide a border is, in field cells: the two the owner wanted to test are these two numbers.
## 0 is a hard line; 3 makes the ground change over about fifty world units.
const BLEND_WIDTH_CELLS := 3.0
## How far the border wanders from where the noise put it. A straight blend still reads as a
## straight line, just a soft one; this bends it.
const BORDER_WIGGLE := 0.22
## Texture repeats. Smaller sees the art's detail closer up.
## One repeat of a ground image per this many world units. Sized so the art is seen at roughly its
## own resolution on a normal zoom: tiling it small enough to repeat many times across the map
## minifies a 1254-pixel painting into speckle, which is exactly what the first attempt looked like.
const TILE_UNITS := 800.0

const HEIGHT_OCTAVES := 3
const BIOME_OCTAVES := 4
const CATALOGUE := "res://data/terrain/biomes.json"

var seed_value: int = 0
var generated_ms: float = 0.0


## Builds the field and the material. [param land] is the rectangle on the map the ground covers.
## [param config] is read for nothing yet; it is here because the next thing this needs to know is
## how big a campaign cell is, and taking it now saves changing every caller later.
func setup(p_seed: int, land: Rect2, _config: GameConfig) -> void:
	seed_value = p_seed
	var started := Time.get_ticks_usec()
	var field := _build_field()
	generated_ms = float(Time.get_ticks_usec() - started) / 1000.0
	centered = false
	position = land.position
	# A one-pixel white texture stretched over the rectangle: the shader ignores it and works in
	# world units, so the ground tiles with the map instead of stretching with it.
	texture = _white_pixel()
	scale = land.size
	_build_material(field, land)
	print("world terrain: field %dx%d in %.0f ms | blend %.0f cells, wiggle %.2f | seed %d" % [
		FIELD_COLS, FIELD_ROWS, generated_ms, BLEND_WIDTH_CELLS, BORDER_WIGGLE, seed_value])


## The two grounds this shows. The plains set's four looks stand in for two biomes until the next
## set arrives: Standard and Lush behave as one, Dry and Worn as the other. Both are named in the
## catalogue rather than in this file, so the day the art changes this code does not.
func _ground_paths() -> Array[String]:
	var paths: Array[String] = []
	if FileAccess.file_exists(CATALOGUE):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE))
		if typeof(parsed) == TYPE_DICTIONARY:
			for biome in (parsed as Dictionary).get("biomes", []):
				var grounds: Array = biome.get("grounds", [])
				for entry in grounds:
					var art := str(entry.get("art", ""))
					if not art.is_empty():
						paths.append(art)
	if paths.is_empty():
		push_error("world terrain: no grounds in %s" % CATALOGUE)
	return paths


static func _white_pixel() -> ImageTexture:
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(image)


func _build_material(field: Image, land: Rect2) -> void:
	var paths := _ground_paths()
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/world/world_ground.gdshader")
	material.set_shader_parameter("field_map", ImageTexture.create_from_image(field))
	material.set_shader_parameter("tile_units", TILE_UNITS)
	material.set_shader_parameter("map_origin", land.position)
	material.set_shader_parameter("map_span", land.size)
	material.set_shader_parameter("shade_strength", 0.32)
	# First ground of the first biome, and the dry look of the second as the other side of the
	# blend: the four looks are one biome's art, so this is a test of the blend rather than of two
	# real biomes.
	if paths.size() >= 1:
		material.set_shader_parameter("ground_a", load(paths[0]))
	if paths.size() >= 2:
		material.set_shader_parameter("ground_b", load(paths[min(2, paths.size() - 1)]))
	self.material = material


## R = how much of the second biome is here, G = height. Both from the world seed, both from a
## positional hash rather than a stateful generator, so the same campaign always grows the same
## country and cells can be sampled in any order.
func _build_field() -> Image:
	var image := Image.create_empty(FIELD_COLS, FIELD_ROWS, false, Image.FORMAT_RGB8)
	for row in FIELD_ROWS:
		for col in FIELD_COLS:
			var x := float(col) / float(FIELD_COLS)
			var y := float(row) / float(FIELD_ROWS)
			# The border wanders: the biome is sampled from a point nudged sideways by a slower
			# noise, which is what turns a soft straight edge into a coast.
			var wander := (_fbm(x * 5.4, y * 5.4, 11, 2) - 0.5) * BORDER_WIGGLE
			var biome := _fbm(x * 3.0 + wander, y * 3.0, 1, BIOME_OCTAVES)
			var half := maxf(0.0001, BLEND_WIDTH_CELLS / float(FIELD_COLS) * 3.0)
			var weight := smoothstep(0.5 - half, 0.5 + half, biome)
			var height := _fbm(x * 1.7, y * 1.7, 23, HEIGHT_OCTAVES)
			image.set_pixel(col, row, Color(weight, height, 0.0))
	return image


## Fractal value noise: smoothstep-interpolated lattice values, summed over octaves, all of it
## derived from where the sample is and the campaign's seed.
func _fbm(x: float, y: float, salt: int, octaves: int) -> float:
	var total := 0.0
	var amplitude := 1.0
	var weight_total := 0.0
	var frequency := 1.0
	for octave in octaves:
		total += _value_noise(x * frequency, y * frequency, salt + octave) * amplitude
		weight_total += amplitude
		amplitude *= 0.5
		frequency *= 2.0
	return total / maxf(0.0001, weight_total)


func _value_noise(x: float, y: float, salt: int) -> float:
	var x0 := int(floorf(x))
	var y0 := int(floorf(y))
	var fx := x - floorf(x)
	var fy := y - floorf(y)
	# Smoothstep, so the lattice does not show as diamonds.
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sy := fy * fy * (3.0 - 2.0 * fy)
	var a := _hash01(x0, y0, salt)
	var b := _hash01(x0 + 1, y0, salt)
	var c := _hash01(x0, y0 + 1, salt)
	var d := _hash01(x0 + 1, y0 + 1, salt)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)


## A number in [0, 1) from three integers, the same on every machine and in any order.
func _hash01(x: int, y: int, salt: int) -> float:
	var h := (x * 374761393 + y * 668265263 + salt * 2246822519 + seed_value * 2654435761) % 2147483647
	if h < 0:
		h += 2147483647
	h = (h ^ (h >> 13)) * 1274126177
	h = h % 2147483647
	if h < 0:
		h += 2147483647
	h = h ^ (h >> 16)
	return float(h % 16777216) / 16777216.0
