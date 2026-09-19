extends Node2D
## Throwaway: what the pipeline draws, measured. One soldier and one health bar, written with the
## same maths the compute battlefield uses (UnitSpriteWriter + gpu_crowd's bar placement), in a
## neutral scene, then both are measured out of the rendered image and compared with the model.
## Run windowed: godotc --resolution 1600x900 res://scenes/dev/sprite_orientation.tscn

const BAR_WIDTH := 2.2
const BAR_HEIGHT := 0.5
const DISC_RADIUS := 1.1
const SPRITE_FOOT_LIFT := 0.85
const SPRITE_BAR_MARGIN := 0.15
const ZOOM := 32.0

var _camera: Camera2D = null


func _ready() -> void:
	var art := UnitArt.load_if_present()
	if art == null:
		print("no art")
		get_tree().quit()
		return
	var sprite_mm := UnitArt.build_batch(art.texture(), 2)
	var node := MultiMeshInstance2D.new()
	node.texture = art.texture()
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var material := ShaderMaterial.new()
	material.shader = load(UnitArt.SHADER_PATH) as Shader
	node.material = material
	node.multimesh = sprite_mm
	add_child(node)
	var layout := UnitArt.measure_layout(sprite_mm, true)
	var offsets := UnitArt.offsets_from(layout)
	var stride := int(layout.get("stride", 0))
	var writer := UnitSpriteWriter.new()
	writer.setup(art, [UnitArt.CHARACTER_PLAYER, UnitArt.CHARACTER_ENEMY], 30.0, offsets, stride,
		SPRITE_FOOT_LIFT)
	writer.reserve(2)
	var buffer := PackedFloat32Array()
	buffer.resize(stride)
	writer.write(buffer, 0, 0, Vector2.ZERO, 0, true, false, -1, -1, 0, false, 0)
	sprite_mm.instance_count = 1
	sprite_mm.buffer = buffer
	sprite_mm.visible_instance_count = 1

	# The bar, written the way gpu_crowd writes it: a plain white quad, sized BAR_WIDTH x
	# BAR_HEIGHT, its top-left at the picture point lifted by the radius and the bar lift.
	var bar_mm := MultiMesh.new()
	bar_mm.transform_format = MultiMesh.TRANSFORM_2D
	bar_mm.use_colors = true
	bar_mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	bar_mm.mesh = quad
	bar_mm.instance_count = 2
	var bar_node := MultiMeshInstance2D.new()
	bar_node.multimesh = bar_mm
	bar_node.z_index = 1
	add_child(bar_node)
	var bar_layout := UnitArt.measure_layout(bar_mm, true)
	var bar_offsets := UnitArt.offsets_from(bar_layout)
	var bar_stride := int(bar_layout.get("stride", 0))
	var head := writer.sprite_head()
	var lift := head + BAR_HEIGHT - DISC_RADIUS - SPRITE_FOOT_LIFT + SPRITE_BAR_MARGIN
	var bar_top_left := Vector2(-BAR_WIDTH * 0.5, -DISC_RADIUS - lift)
	var bar_buffer := PackedFloat32Array()
	bar_buffer.resize(bar_stride)
	bar_buffer[bar_offsets[0]] = BAR_WIDTH
	bar_buffer[bar_offsets[1]] = BAR_HEIGHT
	bar_buffer[bar_offsets[2]] = bar_top_left.x + BAR_WIDTH * 0.5
	bar_buffer[bar_offsets[3]] = bar_top_left.y + BAR_HEIGHT * 0.5
	bar_buffer[bar_offsets[4]] = 1.0
	bar_buffer[bar_offsets[4] + 1] = 0.2
	bar_buffer[bar_offsets[4] + 2] = 0.1
	bar_buffer[bar_offsets[4] + 3] = 1.0
	bar_mm.instance_count = 1
	bar_mm.buffer = bar_buffer
	bar_mm.visible_instance_count = 1

	print("head (world units) = ", head, "  cell = ", art.cell_size(UnitArt.CHARACTER_PLAYER),
		"  units/px = ", art.units_per_pixel())
	print("bar lift = ", lift, "   bar top-left = ", bar_top_left,
		"  bar bottom = ", bar_top_left.y + BAR_HEIGHT)
	print("model: sprite box top = ", SPRITE_FOOT_LIFT - art.cell_size(UnitArt.CHARACTER_PLAYER).y
		* art.units_per_pixel(), "  head top = ", SPRITE_FOOT_LIFT - head,
		"  model gap (bar bottom - head top) = ", bar_top_left.y + BAR_HEIGHT
		- (SPRITE_FOOT_LIFT - head))

	_camera = Camera2D.new()
	_camera.zoom = Vector2(ZOOM, ZOOM)
	_camera.position = Vector2(0.0, -2.5)
	add_child(_camera)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	var path := "F:/VSC Projects/pb-bench/unit_sprites_shots/pipeline_orientation.png"
	image.save_png(path)
	print("saved ", path)

	# Measure both back out of the image: screen pixels to picture units through the camera.
	var centre := Vector2(get_viewport().get_visible_rect().size) * 0.5
	var sprite_top := 1.0e9
	var sprite_bottom := -1.0e9
	var bar_bottom := -1.0e9
	var bar_top := 1.0e9
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			var world_y := (Vector2(x, y) - centre) / ZOOM + _camera.position
			var is_bar := c.r > 0.85 and c.g < 0.4 and c.b < 0.35
			if is_bar:
				bar_top = minf(bar_top, world_y.y)
				bar_bottom = maxf(bar_bottom, world_y.y)
			elif c.r + c.g + c.b > 0.25 and absf(c.r - c.g) + absf(c.g - c.b) > 0.06:
				# Anything coloured that is not the bar and not the plain background.
				sprite_top = minf(sprite_top, world_y.y)
				sprite_bottom = maxf(sprite_bottom, world_y.y)
	print("measured from the picture: sprite top y = %.2f, sprite bottom y = %.2f, height = %.2f"
		% [sprite_top, sprite_bottom, sprite_bottom - sprite_top])
	print("measured bar: top y = %.2f, bottom y = %.2f" % [bar_top, bar_bottom])
	print("measured gap from bar bottom up to sprite top = %.2f units   (bar bottom %.2f - sprite top %.2f)"
		% [bar_bottom - sprite_top, bar_bottom, sprite_top])
	get_tree().quit()
