class_name WorldFlat
extends Node2D

## Flat-colour ground, used when the catalogue has no art.
##
## Same field, same inputs, no textures: the owner asked for "just make them colors based on the
## terrain they are" while the art is sorted in another session, and this is that - a map that reads,
## instead of a white rectangle. It deliberately touches none of WorldTerrain's files.

const SHADER := "res://shaders/world/world_flat.gdshader"
const FIELD_STEP := 16.0
const LOOK_STRENGTH := 0.75

var _sprite: Sprite2D


func setup(seed_value: int, land: Rect2, _config: GameConfig) -> void:
	var started := Time.get_ticks_msec()
	var cols := int(ceil(land.size.x / FIELD_STEP)) + 1
	var rows := int(ceil(land.size.y / FIELD_STEP)) + 1
	var image := Image.create_empty(cols, rows, false, Image.FORMAT_RGBA8)
	var world := WorldChunks.build(seed_value)
	for row in rows:
		for col in cols:
			var point := land.position + Vector2(float(col), float(row)) * FIELD_STEP
			var here: Dictionary = world.sample(point)
			var moisture := float(here["moisture"])
			var wear := float(here["wear"])
			var region := float(here["region"])
			var worn := wear * 0.85
			var plain := 1.0 - worn
			var lush := plain * moisture * region * LOOK_STRENGTH
			var dry := plain * (1.0 - moisture) * region * LOOK_STRENGTH
			worn *= LOOK_STRENGTH
			var used := lush + dry + worn
			if used > 1.0:
				var overflow := 1.0 / used
				lush *= overflow
				dry *= overflow
				worn *= overflow
			image.set_pixel(col, row, Color(lush, dry, worn, float(here["height"])))

	var shader: Shader = load(SHADER)
	if shader == null:
		push_error("world flat: no shader at %s" % SHADER)
		return
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("field_map", ImageTexture.create_from_image(image))
	material.set_shader_parameter("map_origin", land.position)
	material.set_shader_parameter("map_span", land.size)

	# One white pixel stretched over the land is the quad, exactly as the painted ground does it.
	var pixel := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	pixel.set_pixel(0, 0, Color.WHITE)
	_sprite = Sprite2D.new()
	_sprite.centred = false
	_sprite.texture = ImageTexture.create_from_image(pixel)
	_sprite.position = land.position
	_sprite.scale = land.size
	_sprite.material = material
	add_child(_sprite)
	print("world flat: %dx%d cells in %.0f ms, colours only" % [cols, rows, float(Time.get_ticks_msec() - started)])
