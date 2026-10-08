class_name BattleMinimap
extends Control
## Screen-space battle map. Shows terrain, troop formations and the camera's
## true viewport footprint, and allows camera panning without issuing orders.
signal navigate_requested(world: Vector2)

const OUTLINE := Color("a79a75")
const SELECTION := Color("f1d38a")
const PLAYER := Color("79aec0")
const ENEMY := Color("bd7964")
const VIEWPORT := Color("e8e3d1")
const INK := Color("101512")
const PAD := 8.0
const TOP := 26.0

var _terrain_texture: Texture2D = null
var _world_size := Vector2.ONE
var _formations: Array[Dictionary] = []
var _selection: Array[int] = []
var _camera_centre := Vector2.ZERO
var _camera_span := Vector2.ONE
var _dragging := false


## Pure projection: testable without a Control, atlas, camera or GPU.
static func world_to_map(world: Vector2, field: Vector2, rect: Rect2) -> Vector2:
	return rect.position + Vector2(
		clampf(world.x / maxf(1.0, field.x), 0.0, 1.0) * rect.size.x,
		clampf(world.y / maxf(1.0, field.y), 0.0, 1.0) * rect.size.y)


static func map_to_world(point: Vector2, field: Vector2, rect: Rect2) -> Vector2:
	return Vector2(
		clampf((point.x - rect.position.x) / maxf(1.0, rect.size.x), 0.0, 1.0) * field.x,
		clampf((point.y - rect.position.y) / maxf(1.0, rect.size.y), 0.0, 1.0) * field.y)


func _map_rect() -> Rect2:
	return Rect2(Vector2(PAD, TOP), Vector2(maxf(1.0, size.x - PAD * 2.0),
		maxf(1.0, size.y - TOP - PAD)))


func set_terrain(terrain: BattlefieldTerrain) -> void:
	if terrain == null or not terrain.is_valid():
		return
	_world_size = terrain.size
	var image := Image.create_empty(maxi(1, terrain.cols), maxi(1, terrain.rows),
		false, Image.FORMAT_RGBA8)
	var low := terrain.min_height()
	var span := maxf(0.001, terrain.max_height() - low)
	for y in terrain.rows:
		for x in terrain.cols:
			var i := y * terrain.cols + x
			image.set_pixel(x, y, BattleGroundPainter._paint_colour(
				terrain, i, x, y, low, span))
	_terrain_texture = ImageTexture.create_from_image(image)
	queue_redraw()


func set_battle_state(formations: Array[Dictionary], selected: Array[int],
		camera_centre: Vector2, camera_span: Vector2) -> void:
	_formations = formations
	_selection = selected
	_camera_centre = camera_centre
	_camera_span = camera_span
	queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(225.0, 157.0)


func _draw() -> void:
	var bounds := Rect2(Vector2.ZERO, size)
	draw_rect(bounds, INK, true)
	draw_rect(bounds, OUTLINE, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(PAD, 17),
		"TACTICAL MAP   /   CLICK TO PAN",
		HORIZONTAL_ALIGNMENT_LEFT, size.x - PAD * 2.0, 11, OUTLINE)
	var map := _map_rect()
	draw_rect(map, Color("313c2c"), true)
	if _terrain_texture != null:
		draw_texture_rect(_terrain_texture, map, false, Color.WHITE)
	draw_rect(map, OUTLINE.darkened(0.3), false, 1.0)
	# Actual formations, not schematic markers: draw their oriented footprints
	# in map coordinates, with minimum marker width for smaller army bodies.
	var stretch := Vector2(map.size.x / maxf(1.0, _world_size.x),
		map.size.y / maxf(1.0, _world_size.y))
	for formation in _formations:
		if int(formation.get("alive", 0)) <= 0:
			continue
		var id := int(formation.get("id", -1))
		var anchor: Vector2 = formation.get("anchor", Vector2.ZERO)
		var forward: Vector2 = formation.get("forward", Vector2.RIGHT)
		if forward.length_squared() < 0.00001:
			forward = Vector2.RIGHT
		forward = forward.normalized()
		var across := Vector2(-forward.y, forward.x)
		var half_depth := maxf(1.0, float(formation.get("half_depth", 2.0)))
		var half_span := maxf(1.0, float(formation.get("half_span", 2.0)))
		var origin := world_to_map(anchor, _world_size, map)
		var front := forward * half_depth
		var side := across * half_span
		var polygon := PackedVector2Array([
			origin + Vector2((front.x + side.x) * stretch.x, (front.y + side.y) * stretch.y),
			origin + Vector2((front.x - side.x) * stretch.x, (front.y - side.y) * stretch.y),
			origin - Vector2((front.x + side.x) * stretch.x, (front.y + side.y) * stretch.y),
			origin - Vector2((front.x - side.x) * stretch.x, (front.y - side.y) * stretch.y),
		])
		var friendly := int(formation.get("side", 1)) == 0
		var chosen := friendly and _selection.has(id)
		var ink := PLAYER if friendly else ENEMY
		draw_colored_polygon(polygon, Color(ink.r, ink.g, ink.b, 0.9))
		for corner in 4:
			draw_line(polygon[corner], polygon[(corner + 1) % 4],
				SELECTION if chosen else ink.lightened(0.35),
				2.0 if chosen else 1.0, true)
		# Facing tip remains visible even when the footprint is very small.
		draw_circle(origin + Vector2(forward.x * 3.5, forward.y * 3.5), 1.3,
			SELECTION if chosen else ink.lightened(0.45))
	# Visible battle camera footprint. Unlike a static minimap crosshair this
	# changes with both pan and zoom, including full-map tactical overview.
	var view_min := world_to_map(_camera_centre - _camera_span * 0.5, _world_size, map)
	var view_max := world_to_map(_camera_centre + _camera_span * 0.5, _world_size, map)
	var camera_rect := Rect2(view_min, (view_max - view_min).max(Vector2(1.5, 1.5)))
	draw_rect(camera_rect, Color(0.94, 0.9, 0.76, 0.055), true)
	draw_rect(camera_rect, VIEWPORT, false, 1.25)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
			if _dragging and _map_rect().has_point(button.position):
				navigate_requested.emit(map_to_world(button.position, _world_size, _map_rect()))
				accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		navigate_requested.emit(map_to_world(motion.position, _world_size, _map_rect()))
		accept_event()
