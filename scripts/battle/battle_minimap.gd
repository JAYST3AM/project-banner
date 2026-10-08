class_name BattleMinimap
extends Control
## Screen-space battle map. Shows an OPTIONAL terrain image, troop formations and the camera's true
## viewport footprint, and allows camera panning without issuing orders.
##
## Terrain imagery is an input, never a dependency: the caller paints whatever it likes and hands over a
## Texture2D, and a null texture is a first-class state that draws a flat field. This class must not know
## about BattleGroundPainter or any terrain slice - the original did, calling
## BattleGroundPainter._paint_colour() from set_terrain(), which is why that version could only compile in
## the single worktree the painter lived in.
##
## Projection, marker geometry, marker colours and the camera rectangle are pure statics so they can be
## asserted without a renderer; _draw() only composes them.
signal navigate_requested(world: Vector2)

const OUTLINE := Color("a79a75")
const SELECTION := Color("f1d38a")
const PLAYER := Color("79aec0")
const ENEMY := Color("bd7964")
const VIEWPORT := Color("e8e3d1")
const INK := Color("101512")
const FLAT_FIELD := Color("313c2c")
const PAD := 8.0
const TOP := 26.0
## The camera footprint is never drawn smaller than this, so a fully zoomed-in camera stays visible.
const MIN_VIEWPORT_PX := Vector2(1.5, 1.5)
## How far the facing tip sits from the marker's centre, in map pixels rather than world units, so it stays
## visible when a formation's footprint shrinks to nothing.
const FACING_TIP_PX := 3.5

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


static func facing(forward: Vector2) -> Vector2:
	## A formation with no usable facing reads as facing right rather than disappearing.
	var dir := forward
	if dir.length_squared() < 0.00001:
		dir = Vector2.RIGHT
	return dir.normalized()


static func marker_polygon(anchor: Vector2, forward: Vector2, half_depth: float, half_span: float,
		field: Vector2, rect: Rect2) -> PackedVector2Array:
	## The formation's oriented footprint in map space: four corners around the projected anchor, the long
	## axis along the facing, the short axis across it.
	var dir := facing(forward)
	var across := Vector2(-dir.y, dir.x)
	var depth := maxf(1.0, half_depth)
	var span := maxf(1.0, half_span)
	var origin := world_to_map(anchor, field, rect)
	var stretch := Vector2(rect.size.x / maxf(1.0, field.x), rect.size.y / maxf(1.0, field.y))
	var front := dir * depth
	var side := across * span
	var corners := PackedVector2Array([
		origin + Vector2((front.x + side.x) * stretch.x, (front.y + side.y) * stretch.y),
		origin + Vector2((front.x - side.x) * stretch.x, (front.y - side.y) * stretch.y),
		origin - Vector2((front.x + side.x) * stretch.x, (front.y + side.y) * stretch.y),
		origin - Vector2((front.x - side.x) * stretch.x, (front.y - side.y) * stretch.y),
	])
	# A formation sitting on the field's edge projects onto the map's edge, which would let half its
	# footprint spill over the panel. Clamp the corners so every marker stays inside the map rectangle.
	for corner in corners.size():
		corners[corner] = Vector2(clampf(corners[corner].x, rect.position.x, rect.end.x),
			clampf(corners[corner].y, rect.position.y, rect.end.y))
	return corners


static func facing_tip(anchor: Vector2, forward: Vector2, field: Vector2, rect: Rect2) -> Vector2:
	return world_to_map(anchor, field, rect) + facing(forward) * FACING_TIP_PX


static func marker_ink(friendly: bool) -> Color:
	return PLAYER if friendly else ENEMY


static func marker_outline(friendly: bool, chosen: bool) -> Color:
	return SELECTION if chosen else marker_ink(friendly).lightened(0.35)


static func marker_tip_colour(friendly: bool, chosen: bool) -> Color:
	return SELECTION if chosen else marker_ink(friendly).lightened(0.45)


static func viewport_rect(camera_centre: Vector2, camera_span: Vector2, field: Vector2,
		rect: Rect2) -> Rect2:
	## The camera's real footprint, so both a pan and a zoom move it - unlike a fixed crosshair.
	var low := world_to_map(camera_centre - camera_span * 0.5, field, rect)
	var high := world_to_map(camera_centre + camera_span * 0.5, field, rect)
	return Rect2(low, (high - low).max(MIN_VIEWPORT_PX))


func _map_rect() -> Rect2:
	return Rect2(Vector2(PAD, TOP), Vector2(maxf(1.0, size.x - PAD * 2.0),
		maxf(1.0, size.y - TOP - PAD)))


func set_terrain_texture(texture: Texture2D, world_size: Vector2) -> void:
	## Optional imagery. Pass null to clear it and keep the flat field: the world size is still recorded, so
	## formations and the camera rectangle keep projecting correctly with no image at all.
	_terrain_texture = texture
	_world_size = Vector2(maxf(1.0, world_size.x), maxf(1.0, world_size.y))
	queue_redraw()


func has_terrain_texture() -> bool:
	return _terrain_texture != null


func set_battle_state(formations: Array[Dictionary], selected: Array[int],
		camera_centre: Vector2, camera_span: Vector2) -> void:
	_formations = formations
	_selection = selected
	_camera_centre = camera_centre
	_camera_span = camera_span
	queue_redraw()


## Lightweight per-frame camera motion. Formation snapshots and terrain imagery are
## updated only on simulation ticks or actual UI changes.
func set_camera(camera_centre: Vector2, camera_span: Vector2) -> void:
	if _camera_centre.is_equal_approx(camera_centre) and _camera_span.is_equal_approx(camera_span):
		return
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
	draw_rect(map, FLAT_FIELD, true)
	if _terrain_texture != null:
		draw_texture_rect(_terrain_texture, map, false, Color.WHITE)
	draw_rect(map, OUTLINE.darkened(0.3), false, 1.0)
	# Actual formations, not schematic markers: their oriented footprints in map coordinates.
	for formation in _formations:
		if int(formation.get("alive", 0)) <= 0:
			continue
		var id := int(formation.get("id", -1))
		var anchor: Vector2 = formation.get("anchor", Vector2.ZERO)
		var forward: Vector2 = formation.get("forward", Vector2.RIGHT)
		var friendly := int(formation.get("side", 1)) == 0
		var chosen := friendly and _selection.has(id)
		var polygon := marker_polygon(anchor, forward, float(formation.get("half_depth", 2.0)),
			float(formation.get("half_span", 2.0)), _world_size, map)
		var ink := marker_ink(friendly)
		draw_colored_polygon(polygon, Color(ink.r, ink.g, ink.b, 0.9))
		var edge := marker_outline(friendly, chosen)
		for corner in 4:
			draw_line(polygon[corner], polygon[(corner + 1) % 4], edge, 2.0 if chosen else 1.0, true)
		draw_circle(facing_tip(anchor, forward, _world_size, map), 1.3,
			marker_tip_colour(friendly, chosen))
	var footprint := viewport_rect(_camera_centre, _camera_span, _world_size, map)
	draw_rect(footprint, Color(0.94, 0.9, 0.76, 0.055), true)
	draw_rect(footprint, VIEWPORT, false, 1.25)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				# A drag counts only if it STARTED on the map. A press on the panel's header or border that
				# slides over the map must not pan the camera, so the drag flag is decided at the press.
				_dragging = _map_rect().has_point(button.position)
				if _dragging:
					navigate_requested.emit(map_to_world(button.position, _world_size, _map_rect()))
					accept_event()
			else:
				_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		navigate_requested.emit(map_to_world(motion.position, _world_size, _map_rect()))
		accept_event()
