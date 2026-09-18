class_name WorldTerrain
extends Sprite2D
## The campaign map's ground, as terrain rather than a flat colour.
##
## A field is generated from the world seed holding three weights - how much Lush, Dry and Worn a
## place is, with Standard as the remainder - and a height. The shader blends four *looks* by those
## weights and, inside each look, picks one of four *sub-variants* per texture repeat from a hash of
## where the repeat is. Sixteen grounds, all of them in use.
##
## Where two looks meet the ground changes over a band rather than at a line - which is what meshing
## means here - and the same field will drive movement and props when they arrive, so a place cannot
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
## 0 is a hard line; 6 makes the ground change over about ninety world units, which after the first
## showing turned out to be the width that reads as a gradient rather than as a mottle.
const BLEND_WIDTH_CELLS := 6.0
## How much of a look a place can be. Kept below one on purpose: a tile that is entirely Dry next
## to a tile that is entirely Lush is a border, however wide the band between them, and the owner's
## note on the first showing was that the change between the two was too drastic. Capped, Standard
## always takes the remainder, so the ground reads as one country with a dry district in it. This is
## the first number to turn if the looks ever feel too far apart again.
const LOOK_STRENGTH := 0.75
## How far the border wanders from where the noise put it. A straight blend still reads as a
## straight line, just a soft one; this bends it.
const BORDER_WIGGLE := 0.22
## Texture repeats. Smaller sees the art's detail closer up.
## One repeat of a ground image per this many world units. Smaller means more tiles and the art's
## detail closer up, which is what the owner asked for - and it only works with mipmaps under the
## samplers, or a 1254-pixel painting shrunk to a quarter of that aliases into coloured speckle. Sized so the art is seen at roughly its
## own resolution on a normal zoom. 260 was tried first, then 160; the owner looked at both and
## asked for more tiles each time, which is this number going down. The trade-off to watch: a smaller repeat shows the same
## art spread over less ground, so if the ground ever reads soft rather than detailed, the fix is a
## finer art set rather than an even smaller repeat.
const TILE_UNITS := 100.0

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
	print("world terrain: 16 grounds, field %dx%d in %.0f ms | blend %.0f cells, look %.2f, wiggle %.2f | seed %d" % [
		FIELD_COLS, FIELD_ROWS, generated_ms, BLEND_WIDTH_CELLS, LOOK_STRENGTH, BORDER_WIGGLE, seed_value])


static func _white_pixel() -> ImageTexture:
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(image)


func _build_material(field: Image, land: Rect2) -> void:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/world/world_ground.gdshader")
	material.set_shader_parameter("field_map", ImageTexture.create_from_image(field))
	material.set_shader_parameter("tile_units", TILE_UNITS)
	material.set_shader_parameter("map_origin", land.position)
	material.set_shader_parameter("map_span", land.size)
	material.set_shader_parameter("shade_strength", 0.32)
	for look in _looks():
		var base := "look_%s" % str(look.get("shader", "")).strip_edges()
		var variants: Array = look.get("variants", [])
		for index in variants.size():
			# look_lush, look_lush_2, look_lush_3, look_lush_4: the first variant keeps the bare
			# name, so the art maps onto the shader by position with no lookup table in between.
			var parameter := base if index == 0 else "%s_%d" % [base, index + 1]
			material.set_shader_parameter(parameter, load(str(variants[index])))
	self.material = material


## The four looks as the catalogue lists them: a name, a shader key and four variants each. The
## catalogue owns the naming, so renaming the art or adding a fifth variant does not touch this
## file.
func _looks() -> Array:
	var looks: Array = []
	if FileAccess.file_exists(CATALOGUE):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOGUE))
		if typeof(parsed) == TYPE_DICTIONARY:
			for biome in (parsed as Dictionary).get("biomes", []):
				for entry in biome.get("grounds", []):
					looks.append(entry)
	if looks.size() != 4:
		push_error("world terrain: expected four looks in %s, found %d" % [CATALOGUE, looks.size()])
	return looks


## R = Lush, G = Dry, B = Worn, A = height. All four from the world seed, all from a positional
## hash rather than a stateful generator, so the same campaign always grows the same country and
## cells can be sampled in any order.
##
## Which look a place gets is decided the way the design says: moisture decides Lush against Dry,
## wear decides where the ground has been used hard enough to go Worn, and a very slow region field
## says how much character the land has at all - where it is low, the plain Standard look shows
## through. Every value is softened over BLEND_WIDTH_CELLS before it becomes a weight, and that
## band is what the looks mesh across.
func _build_field() -> Image:
	var image := Image.create_empty(FIELD_COLS, FIELD_ROWS, false, Image.FORMAT_RGBA8)
	var half := maxf(0.0001, BLEND_WIDTH_CELLS / float(FIELD_COLS) * 3.0)
	for row in FIELD_ROWS:
		for col in FIELD_COLS:
			var x := float(col) / float(FIELD_COLS)
			var y := float(row) / float(FIELD_ROWS)
			# The borders wander: each field is sampled from a point nudged sideways by a slower
			# noise, which is what turns a soft straight edge into a coast.
			var wander := (_fbm(x * 5.4, y * 5.4, 11, 2) - 0.5) * BORDER_WIGGLE
			var moisture := smoothstep(0.5 - half, 0.5 + half, _fbm(x * 4.5 + wander, y * 4.5, 1, BIOME_OCTAVES))
			var wear := smoothstep(0.5 - half, 0.5 + half, _fbm(x * 6.5 + wander, y * 6.5, 17, 3))
			var region := smoothstep(0.42 - half, 0.58 + half, _fbm(x * 2.0, y * 2.0, 29, 2))
			var worn := wear * 0.85
			var plain := 1.0 - worn
			var lush := plain * moisture * region * LOOK_STRENGTH
			var dry := plain * (1.0 - moisture) * region * LOOK_STRENGTH
			worn *= LOOK_STRENGTH
			# The shader derives Standard as whatever is left over, so this only stops the three
			# stored weights summing past one and letting the fourth look show through as a hole.
			var used := lush + dry + worn
			if used > 1.0:
				var overflow := 1.0 / used
				lush *= overflow
				dry *= overflow
				worn *= overflow
			var height := _fbm(x * 1.7, y * 1.7, 23, HEIGHT_OCTAVES)
			image.set_pixel(col, row, Color(lush, dry, worn, height))
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
