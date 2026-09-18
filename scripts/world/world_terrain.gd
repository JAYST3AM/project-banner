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

## How wide a border is, in field cells: the two the owner wanted to test are these two numbers.
## 0 is a hard line; 6 was the width that suited the painted grounds. With the tiles the ground
## changes character in 64-pixel steps, and a band one tile wide read as a tile edge rather than a
## blend, so it is 10 now - about a hundred and fifty world units of change.
const BLEND_WIDTH_CELLS := 24.0
## How much of a look a place can be. Kept below one on purpose: a tile that is entirely Dry next
## to a tile that is entirely Lush is a border, however wide the band between them, and the owner's
## note on the first showing was that the change between the two was too drastic. Capped, Standard
## always takes the remainder, so the ground reads as one country with a dry district in it. This is
## the first number to turn if the looks ever feel too far apart again.
const LOOK_STRENGTH := 0.75
## Texture repeats. Smaller sees the art's detail closer up.
## One repeat of a ground image per this many world units. Smaller means more tiles and the art's
## detail closer up, which is what the owner asked for - and it only works with mipmaps under the
## samplers, or a 1254-pixel painting shrunk to a quarter of that aliases into coloured speckle. Sized so the art is seen at roughly its
## own resolution. 260 was tried with the painted grounds, then 160 and 100; the owner asked for
## more tiles each time, which is this number going down. With the tileset the number is different in
## own resolution. 260 was tried with the painted grounds, then 160 and 100; the owner asked for
## more tiles each time and liked it, and 100 is where the paintings sat when he said so. When his
## pixel plains land, they are 1024 px and want a repeat nearer 256. The trade-off to watch: a smaller repeat shows the same
## art spread over less ground, so if the ground ever reads soft rather than detailed, the fix is a
## finer art set rather than an even smaller repeat.
## How far apart the field's samples are. The biomes change over hundreds of units, not tens, so
## sampling twice the world's cell size costs a quarter of the build time and loses nothing visible -
## on a 4096-unit world that is 256x256 cells in about a fifth of a second.
const FIELD_STEP := WorldChunks.CELL_SIZE * 2.0

const TILE_UNITS := 64.0

const CATALOGUE := "res://data/terrain/biomes.json"

var seed_value: int = 0
var generated_ms: float = 0.0


## Builds the field and the material. [param land] is the rectangle on the map the ground covers.
## [param config] is read for nothing yet; it is here because the next thing this needs to know is
## how big a campaign cell is, and taking it now saves changing every caller later.
func setup(p_seed: int, land: Rect2, _config: GameConfig) -> void:
	seed_value = p_seed
	var started := Time.get_ticks_usec()
	var field := _build_field(land)
	generated_ms = float(Time.get_ticks_usec() - started) / 1000.0
	centered = false
	position = land.position
	# A one-pixel white texture stretched over the rectangle: the shader ignores it and works in
	# world units, so the ground tiles with the map instead of stretching with it.
	texture = _white_pixel()
	scale = land.size
	_build_material(field, land)
	print("world terrain: 16 grounds, field %dx%d cells of %d units in %.0f ms | blend %.0f cells, look %.2f | seed %d" % [
		field.get_width(), field.get_height(), int(WorldChunks.CELL_SIZE), generated_ms, BLEND_WIDTH_CELLS, LOOK_STRENGTH, seed_value])


static func _white_pixel() -> ImageTexture:
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(image)


func _build_material(field: Image, land: Rect2) -> void:
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/world/world_ground.gdshader")
	material.set_shader_parameter("field_map", ImageTexture.create_from_image(field))
	material.set_shader_parameter("tile_units", TILE_UNITS)
	# The two grounds that were missing. Loaded the same way the looks are, so replacing them with the
	# owner's own art later is a file swap rather than a change here.
	material.set_shader_parameter("ground_water", load("res://assets/terrain/water/water.png"))
	material.set_shader_parameter("ground_sand", load("res://assets/terrain/sand/sand.png"))
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
## R = Lush, G = Dry, B = Worn, A = height, over the rectangle the map covers.
##
## Sampled from [WorldChunks] - the same data the settlements are proposed from and the simulation
## will read. This used to be a private copy of the field: the map's own noise, with its own
## frequencies and its own idea of where the hills were, which is exactly the arrangement in which a
## place can look like one thing and behave like another. One source of truth, at the world's own cell
## size.
func _build_field(land: Rect2) -> Image:
	var cols := int(ceil(land.size.x / FIELD_STEP)) + 1
	var rows := int(ceil(land.size.y / FIELD_STEP)) + 1
	var image := Image.create_empty(cols, rows, false, Image.FORMAT_RGBA8)
	var world := WorldChunks.build(seed_value)
	var half := maxf(0.0001, BLEND_WIDTH_CELLS / float(maxi(cols, rows)) * 3.0)
	for row in rows:
		for col in cols:
			var point := land.position + Vector2(float(col), float(row)) * FIELD_STEP
			var here := world.sample(point)
			var moisture := smoothstep(0.5 - half, 0.5 + half, float(here["moisture"]))
			var wear := smoothstep(0.5 - half, 0.5 + half, float(here["wear"]))
			var region := smoothstep(0.42 - half, 0.58 + half, float(here["region"]))
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
			image.set_pixel(col, row, Color(lush, dry, worn, float(here["height"])))
	return image



