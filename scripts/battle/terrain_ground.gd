class_name TerrainGround
extends Sprite2D
## The battlefield's ground as a picture: the biome's variants, its overlays and the looks its types
## need, drawn by one shader from the maps the field bakes.
##
## [b]It draws what the field says.[/b] Three images come out of the terrain - the variant weights
## with the height, the overlay coverages, and where water, rock and mud are - and the shader mixes
## textures by them. Nothing here decides what the ground is; that decision was made in the
## generator, and the same channels feed the simulation and the debug overlay.
##
## [b]It is a Sprite2D and not a Control[/b], for the reason the campaign map learned the hard way: a
## Control lives in screen space and would sit still while the battlefield beneath it moved. It is
## anchored at the field's top-left corner ([code]centered = false[/code]) and scaled to the field's
## size, so one texture covers exactly the ground it describes.
##
## [b]A missing atlas is not a crash.[/b] A biome with no art yet leaves this node invisible and the
## view falls back to its flat per-cell bake, so adding a country is still a data change.

## How many sub-variants an atlas holds. Four, always: fewer than four is padded by repeating, so the
## shader can index atlas slots without asking how many there are.
const ATLAS_SLOTS := 4

var terrain: BattlefieldTerrain = null
var biomes: BiomeCatalog = null
## The signature of the field this picture was built from, so it is rebuilt when the ground changes
## and not when the camera moves.
var built_for: String = ""

var _material: ShaderMaterial = null


## Point this node at a field. Safe to call every frame: the picture is rebuilt only when the field's
## signature changes.
func show_field(p_field: BattlefieldTerrain, p_biomes: BiomeCatalog, p_config: GameConfig = null) -> bool:
	terrain = p_field
	if p_biomes != null:
		biomes = p_biomes
	if biomes == null:
		biomes = BiomeCatalog.load_from()
	if terrain == null or not terrain.is_valid():
		visible = false
		return false
	var art := biomes.variant_art(terrain.biome_id, 0)
	if art.is_empty() or not ResourceLoader.exists(art[0]):
		visible = false
		built_for = ""
		return false
	if built_for == terrain.signature() and _material != null:
		visible = true
		return true
	_build(p_config)
	built_for = terrain.signature()
	visible = true
	return true


## Whether this biome has ground art at all. Asked before the node is shown, so a caller knows which
## way the ground is about to be drawn.
static func has_art(terrain: BattlefieldTerrain, p_biomes: BiomeCatalog) -> bool:
	if terrain == null or p_biomes == null:
		return false
	var art := p_biomes.variant_art(terrain.biome_id, 0)
	if art.is_empty():
		return false
	return ResourceLoader.exists(art[0])


func _build(config: GameConfig) -> void:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = load("res://shaders/battle/ground.gdshader")
		material = _material
	centered = false
	position = Vector2.ZERO
	texture = _white_pixel()
	scale = terrain.size
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	var ppu := terrain.visual_pixels_per_unit(config)
	_material.set_shader_parameter("ground_map", ImageTexture.create_from_image(terrain.build_ground_map(ppu)))
	_material.set_shader_parameter("overlay_map", ImageTexture.create_from_image(terrain.build_overlay_map(ppu)))
	_material.set_shader_parameter("type_map", ImageTexture.create_from_image(terrain.build_type_map(ppu)))
	_material.set_shader_parameter("map_span", terrain.size)

	# The biome's four variants, atlas by atlas. A variant with no art falls back to the first one
	# that has any, so one missing file cannot leave a quadrant of the ground undrawn.
	var fallback := PackedStringArray()
	for index in 4:
		var paths := biomes.variant_art(terrain.biome_id, index)
		if paths.is_empty():
			if fallback.is_empty():
				continue
			paths = []
			for path in fallback:
				paths.append(path)
		elif fallback.is_empty():
			fallback = PackedStringArray(paths)
		var atlas := _atlas(paths)
		if atlas == null and not fallback.is_empty():
			atlas = _atlas(Array(fallback))
		if atlas != null:
			_material.set_shader_parameter(_variant_parameter(index), atlas)

	for index in 4:
		var overlay := biomes.overlay_id(terrain.biome_id, index)
		var art := _overlay_art(overlay)
		if art.is_empty():
			continue
		var texture := _first_texture(art)
		if texture != null:
			_material.set_shader_parameter("overlay_%d" % (index + 1), texture)

	_material.set_shader_parameter("type_water", _atlas(_type_art("water")))
	_material.set_shader_parameter("type_rock", _first_texture(_type_art("cliff")))
	_material.set_shader_parameter("type_mud", _first_texture(_type_art("mud")))

	_material.set_shader_parameter("tile_units", _tile_units("variant_scale", 4.0))
	_material.set_shader_parameter("overlay_units", _tile_units("overlay_scale", 3.0))
	_material.set_shader_parameter("type_units", 3.0)
	_material.set_shader_parameter("shade_strength", 0.3)


## World units per repeat, from the biome's own terrain block. Read through the catalogue so a biome
## can tile its ground tighter or looser without touching the shader.
func _tile_units(key: String, fallback: float) -> float:
	if biomes == null:
		return fallback
	var record := biomes.terrain_block(terrain.biome_id)
	var value: Variant = record.get(key, null)
	if value == null:
		return fallback
	return maxf(0.5, float(value))


func _variant_parameter(index: int) -> String:
	return "variant_%s" % ["a", "b", "c", "d"][clampi(index, 0, 3)]


func _overlay_art(overlay_id: String) -> Array[String]:
	if overlay_id.is_empty() or biomes == null:
		return []
	var out: Array[String] = []
	for entry in biomes.overlays(terrain.biome_id):
		var record := entry as Dictionary
		if str(record.get("id", "")) != overlay_id:
			continue
		var raw: Variant = record.get("art", [])
		if typeof(raw) == TYPE_ARRAY:
			for path in raw as Array:
				out.append(str(path))
	return out


## The art for a type look (water, rock, mud), from the shared table rather than from a biome.
func _type_art(type_id: String) -> Array[String]:
	var out: Array[String] = []
	if biomes == null:
		return out
	var record: Variant = biomes.type_look(type_id)
	if typeof(record) != TYPE_DICTIONARY:
		return out
	var raw: Variant = (record as Dictionary).get("art", [])
	if typeof(raw) == TYPE_ARRAY:
		for path in raw as Array:
			out.append(str(path))
	return out


## Four sub-variants side by side in one texture, padded by repeating when a variant has fewer.
##
## One atlas rather than four textures because the shader has to pick a sub-variant per repeat, and a
## pick that is a UV offset costs nothing while a pick between four samplers costs a branch - and
## because a texture unit is a resource the shader is running out of.
func _atlas(paths: Array) -> ImageTexture:
	var images: Array[Image] = []
	for path in paths:
		var texture := _first_texture([str(path)])
		if texture != null:
			images.append(texture.get_image())
	if images.is_empty():
		return null
	var tile := images[0].get_width()
	var height := images[0].get_height()
	var sheet := Image.create_empty(tile * ATLAS_SLOTS, height, false, Image.FORMAT_RGBA8)
	for slot in ATLAS_SLOTS:
		var source := images[slot % images.size()]
		sheet.blit_rect(source, Rect2i(0, 0, tile, height), Vector2i(slot * tile, 0))
	return ImageTexture.create_from_image(sheet)


func _first_texture(paths: Array) -> Texture2D:
	for path in paths:
		var text := str(path)
		if text.is_empty() or not ResourceLoader.exists(text):
			continue
		var texture := load(text) as Texture2D
		if texture != null:
			return texture
	return null


static func _white_pixel() -> ImageTexture:
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(image)
