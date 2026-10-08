class_name BattleScenery
extends Node2D
## Batched medieval scenery driven by the exact deterministic TerrainProps
## catalogue used by the rest of the game. Art is preferred whenever imported.
## In the absence of art, small original pixel-art silhouettes keep the field
## visually legible; they are explicitly fallbacks, not final production assets.
##
## Visual-only in the current GPU battle: it does not introduce simulation
## obstacles until GPU pathing has its own terrain/prop collision integration.
const MAX_INSTANCES_PER_BATCH := 4000
const FALLBACK_IMAGE_SIZE := Vector2i(32, 40)
const SHADOW := Color("161d18", 0.42)
const WOOD_DARK := Color("312c27")
const WOOD := Color("665039")
const WOOD_LIGHT := Color("8b7652")
const LEAF_DARK := Color("263a2d")
const LEAF_MID := Color("3b5638")
const LEAF_LIGHT := Color("71805a")
const STONE_DARK := Color("393d3c")
const STONE := Color("6a6b61")
const STONE_LIGHT := Color("939081")
const DRY := Color("aa9b62")

var built_count := 0
var fallback_count := 0
var authored_count := 0
var _batch_count := 0


## Basic deterministic sprite, original raster clusters on a transparent canvas.
## Authored PNGs from the biome catalogue automatically replace this texture.
static func fallback_image(kind: String) -> Image:
	var image := Image.create_empty(FALLBACK_IMAGE_SIZE.x, FALLBACK_IMAGE_SIZE.y,
		false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	_ellipse(image, Vector2i(16, 36), Vector2i(11, 2), SHADOW)
	match kind:
		"tree", "cactus":
			_rect(image, Rect2i(13, 20, 6, 16), WOOD_DARK)
			_rect(image, Rect2i(14, 20, 3, 15), WOOD)
			if kind == "cactus":
				_rect(image, Rect2i(13, 8, 7, 25), LEAF_DARK)
				_rect(image, Rect2i(14, 7, 5, 24), LEAF_MID)
				_rect(image, Rect2i(8, 17, 8, 5), LEAF_MID)
				_rect(image, Rect2i(19, 20, 7, 5), LEAF_MID)
			else:
				_ellipse(image, Vector2i(16, 15), Vector2i(13, 13), LEAF_DARK)
				_ellipse(image, Vector2i(12, 12), Vector2i(9, 9), LEAF_MID)
				_ellipse(image, Vector2i(20, 16), Vector2i(8, 8), LEAF_MID)
				_ellipse(image, Vector2i(10, 10), Vector2i(4, 3), LEAF_LIGHT)
				_ellipse(image, Vector2i(22, 13), Vector2i(3, 3), LEAF_LIGHT)
		"bush", "crop", "reed":
			for index in 7:
				var x := 5 + index * 3
				_rect(image, Rect2i(x, 23 - (index % 3) * 3,
					2, 13 + (index % 3) * 3), LEAF_DARK)
				_rect(image, Rect2i(x, 21 - (index % 3) * 3,
					1, 11), LEAF_LIGHT if index % 2 == 0 else LEAF_MID)
			if kind == "bush":
				_ellipse(image, Vector2i(15, 27), Vector2i(13, 8), LEAF_DARK)
				_ellipse(image, Vector2i(13, 24), Vector2i(10, 6), LEAF_MID)
			if kind == "crop":
				for index in 5:
					_rect(image, Rect2i(7 + index * 4, 19 - index % 3, 2, 5), DRY)
		"rock", "debris":
			_ellipse(image, Vector2i(16, 29), Vector2i(13, 7), STONE_DARK)
			_ellipse(image, Vector2i(14, 27), Vector2i(11, 5), STONE)
			_rect(image, Rect2i(9, 23, 9, 2), STONE_LIGHT)
			if kind == "debris":
				_rect(image, Rect2i(3, 34, 5, 2), STONE)
				_rect(image, Rect2i(25, 32, 3, 3), STONE_DARK)
		"stump", "log":
			if kind == "log":
				_rect(image, Rect2i(4, 27, 23, 7), WOOD_DARK)
				_rect(image, Rect2i(5, 27, 20, 4), WOOD)
				_ellipse(image, Vector2i(26, 30), Vector2i(3, 4), WOOD_LIGHT)
			else:
				_rect(image, Rect2i(11, 25, 11, 10), WOOD_DARK)
				_rect(image, Rect2i(12, 26, 8, 8), WOOD)
				_ellipse(image, Vector2i(16, 26), Vector2i(5, 2), WOOD_LIGHT)
		"fence":
			for x in [4, 15, 26]:
				_rect(image, Rect2i(x, 21, 3, 14), WOOD_DARK)
				_rect(image, Rect2i(x, 21, 2, 12), WOOD_LIGHT)
			_rect(image, Rect2i(4, 25, 24, 3), WOOD)
			_rect(image, Rect2i(4, 30, 24, 2), WOOD_DARK)
		"ruin":
			_rect(image, Rect2i(7, 16, 8, 19), STONE_DARK)
			_rect(image, Rect2i(17, 23, 10, 12), STONE_DARK)
			_rect(image, Rect2i(8, 18, 6, 5), STONE)
			_rect(image, Rect2i(18, 24, 8, 4), STONE)
			for x in [8, 18]:
				_rect(image, Rect2i(x, 30, 7, 1), STONE_LIGHT)
		"hay":
			_ellipse(image, Vector2i(16, 30), Vector2i(13, 6), WOOD)
			_ellipse(image, Vector2i(15, 28), Vector2i(12, 5), DRY)
			_rect(image, Rect2i(9, 27, 17, 2), WOOD_LIGHT)
		_:
			_ellipse(image, Vector2i(16, 30), Vector2i(10, 5), STONE)
	return image


static func _rect(image: Image, rect: Rect2i, ink: Color) -> void:
	var x0 := maxi(0, rect.position.x)
	var y0 := maxi(0, rect.position.y)
	var x1 := mini(image.get_width(), rect.end.x)
	var y1 := mini(image.get_height(), rect.end.y)
	for y in range(y0, y1):
		for x in range(x0, x1):
			image.set_pixel(x, y, ink)


static func _ellipse(image: Image, centre: Vector2i, radius: Vector2i,
		ink: Color) -> void:
	var rx := maxi(1, radius.x)
	var ry := maxi(1, radius.y)
	for y in range(maxi(0, centre.y - ry), mini(image.get_height(), centre.y + ry + 1)):
		for x in range(maxi(0, centre.x - rx), mini(image.get_width(), centre.x + rx + 1)):
			var dx := float(x - centre.x) / float(rx)
			var dy := float(y - centre.y) / float(ry)
			if dx * dx + dy * dy <= 1.0:
				image.set_pixel(x, y, ink)


## Returns the number of visible props, whether art is present or missing.
func build(props: TerrainProps) -> int:
	for child in get_children():
		child.queue_free()
	built_count = 0
	fallback_count = 0
	authored_count = 0
	_batch_count = 0
	if props == null or props.is_empty():
		return 0

	# One GPU batch per texture. Missing assets use one cached generated
	# silhouette per kind; never thousands of individual Sprite2D nodes.
	var by_texture: Dictionary = {}
	var textures: Dictionary = {}
	for index in props.count():
		var path := props.art_at(index)
		var kind := props.kind_id_at(index)
		var texture_key := path if not path.is_empty() and ResourceLoader.exists(path) 			else "__fallback_" + kind
		if not textures.has(texture_key):
			var texture: Texture2D = null
			if not texture_key.begins_with("__fallback_"):
				texture = load(texture_key) as Texture2D
			if texture == null:
				texture_key = "__fallback_" + kind
				if not textures.has(texture_key):
					texture = ImageTexture.create_from_image(fallback_image(kind))
					textures[texture_key] = texture
			else:
				textures[texture_key] = texture
		if not by_texture.has(texture_key):
			by_texture[texture_key] = []
		(by_texture[texture_key] as Array).append(index)

	# Large fields may have thousands of one kind. Split into bounded batches
	# rather than silently dropping scenery after the first 4,000 instances.
	for key in by_texture.keys():
		var texture: Texture2D = textures.get(key)
		if texture == null:
			continue
		var indices: Array = by_texture[key]
		if indices.is_empty():
			continue
		var first := 0
		while first < indices.size():
			var count := mini(MAX_INSTANCES_PER_BATCH, indices.size() - first)
			var instance := MultiMeshInstance2D.new()
			instance.texture = texture
			instance.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			instance.z_index = -4
			var mesh := QuadMesh.new()
			mesh.size = Vector2.ONE
			var batch := MultiMesh.new()
			batch.mesh = mesh
			batch.transform_format = MultiMesh.TRANSFORM_2D
			batch.use_colors = true
			batch.instance_count = count
			batch.visible_instance_count = count
			for slot in count:
				var index := int(indices[first + slot])
				var kind := props.kind_id_at(index)
				var bounds := texture.get_size()
				var height := maxf(1.0, props.scale_at(index) * 2.1)
				if kind == "crop" or kind == "debris" or kind == "reed":
					height *= 0.70
				var width := height * float(bounds.x) / maxf(1.0, float(bounds.y))
				var transform := Transform2D(
					Vector2(width, 0.0), Vector2(0.0, height),
					props.position_at(index) - Vector2(0.0, height * 0.5))
				batch.set_instance_transform_2d(slot, transform)
				var variation := 0.91 + float((index * 17 + kind.length() * 11) % 13) / 130.0
				batch.set_instance_color(slot,
					Color(variation, variation, variation, 1.0))
			instance.multimesh = batch
			add_child(instance)
			_batch_count += 1
			built_count += count
			if str(key).begins_with("__fallback_"):
				fallback_count += count
			else:
				authored_count += count
			first += count
	return built_count
