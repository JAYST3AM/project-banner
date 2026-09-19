class_name WorldFlat
extends Node2D

## Flat-colour ground, used when the catalogue has no art.
##
## Same field, same inputs, no textures: the owner asked for "just make them colors based on the
## terrain they are" while the art is sorted in another session, and this is that - a map that reads,
## instead of a white rectangle. It deliberately touches none of WorldTerrain's files.

const SHADER := "res://shaders/world/world_flat.gdshader"
## How far apart the ground's samples are. Sixteen units meant 66,000 field samples at 33 microseconds
## each - 2.2 seconds of a load the owner is watching. At 32 it is 16,600 samples and half a second, and
## nothing visible changes: this is the resolution of the *blend weights*, not of the colouring, and the
## shader interpolates between them anyway.
const FIELD_STEP := 32.0
const LOOK_STRENGTH := 0.75

## How worn the ground inside a settlement's clearing is - the place where feet, carts and smoke
## work the land hardest. Blended into the natural weights across the clearing's band.
const CLEARING_WORN := 0.55
## Bump when the field's content changes shape: a cached field from an older version is rebuilt
## rather than reused. The settlement clearings arrived after the first caches were written.
const GROUND_VERSION := 2

var _sprite: Sprite2D
## The blended field image this ground was built from, kept so the campaign can cache it: it is a
## pure function of the seed and the land rectangle (D-132).
var field_image: Image = null


func setup(seed_value: int, land: Rect2, _config: GameConfig, on_progress: Callable = Callable(), cached: Image = null, settlements: Array = []) -> void:  ## async: yields frames
	var started := Time.get_ticks_msec()
	var cols := int(ceil(land.size.x / FIELD_STEP)) + 1
	var rows := int(ceil(land.size.y / FIELD_STEP)) + 1
	var image: Image = null
	if cached != null and cached.get_width() == cols and cached.get_height() == rows \
			and int(cached.get_meta("ground_version", 0)) >= GROUND_VERSION:
		# The field is a pure function of the seed and the land, so a cached one is the same picture
		# - and rebuilding it was half a second of every town visit, spent behind a map that had
		# nothing to draw yet (D-132).
		image = cached
	else:
		image = Image.create_empty(cols, rows, false, Image.FORMAT_RGBA8)
		var world := WorldChunks.build(seed_value)
		var clearings := SettlementSprites.clearing_index(settlements, world)
		for row in rows:
			# Yield every few rows. Building this on the main thread without yielding froze the loading
			# screen for the length of the build - the owner: "still stops out for no reason". Half a second
			# of a bar that cannot repaint is indistinguishable from a hang, and the fix is to let the frame
			# through rather than to make the work faster.
			if row % 16 == 0 and get_tree() != null:
				await get_tree().process_frame
			if on_progress.is_valid():
				on_progress.call(float(row) / float(maxi(1, rows)))
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
				# Settlement clearings: the land a town stands on is built for it - flattened to
				# the town's own height and worn by feet - so the structure stands on a plot
				# rather than on whatever slope the noise left. Past the clearing the country
				# takes back over, blended the same banded way the looks blend.
				var height := float(here["height"])
				for clearing in SettlementSprites.clearings_at(clearings, point):
					var distance := point.distance_to(clearing["position"])
					if distance >= float(clearing["outer"]):
						continue
					var k := 1.0 - smoothstep(float(clearing["inner"]), float(clearing["outer"]), distance)
					height = lerpf(height, float(clearing["height"]), k)
					lush *= 1.0 - k
					dry *= 1.0 - k
					worn = maxf(worn, CLEARING_WORN * k)
				var used := lush + dry + worn
				if used > 1.0:
					var overflow := 1.0 / used
					lush *= overflow
					dry *= overflow
					worn *= overflow
				image.set_pixel(col, row, Color(lush, dry, worn, height))
		image.set_meta("ground_version", GROUND_VERSION)
		if on_progress.is_valid():
			on_progress.call(1.0)
	field_image = image

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
	_sprite.centered = false
	_sprite.texture = ImageTexture.create_from_image(pixel)
	_sprite.position = land.position
	_sprite.scale = land.size
	_sprite.material = material
	add_child(_sprite)
	print("world flat: %dx%d cells in %.0f ms, %s" % [
		cols, rows, float(Time.get_ticks_msec() - started),
		"cached field" if image == cached else "colours only",
	])
