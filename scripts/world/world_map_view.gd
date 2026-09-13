class_name WorldMapView
extends Node2D
## Draws the overworld: land, roads, settlements, the player party and (later)
## enemy parties. Pure presentation - it reads campaign state and never mutates it.

const COLOR_BG := Color("0e1218")
const COLOR_LAND := Color("243026")
const COLOR_GRID := Color("2c3a2e")
const COLOR_LAND_EDGE := Color("3a4a3c")
const COLOR_ROAD := Color("6b5b3e")
const COLOR_TRACK := Color("4a4133")
const COLOR_TOWN := Color("e8ce8c")
const COLOR_VILLAGE := Color("b99a5e")
const COLOR_WILDERNESS := Color("7f8a6a")
const COLOR_SELECTED := Color("ffd479")
const COLOR_HOVERED := Color("c9d4de")
const COLOR_PLAYER := Color("4fa8e0")
const COLOR_ENEMY := Color("d0603f")
const COLOR_PARTY_OUTLINE := Color("0b1017")

var state: CampaignState = null
var config: GameConfig = null
var travel: TravelService = null

var selected_id: String = ""
var hovered_id: String = ""

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font
	z_index = -10


func bind(p_state: CampaignState, p_config: GameConfig, p_travel: TravelService) -> void:
	state = p_state
	config = p_config
	travel = p_travel
	queue_redraw()


func map_size() -> Vector2:
	if config == null:
		return Vector2(1600.0, 900.0)
	return Vector2(
		config.get_float("world.map_width", 1600.0),
		config.get_float("world.map_height", 900.0)
	)


func interact_radius() -> float:
	if config == null:
		return 30.0
	return config.get_float("world.settlement_interact_radius", 30.0)


func label_font_size() -> int:
	if config == null:
		return 15
	return config.get_int("world.label_font_size", 15)


## Nearest selectable settlement to a world-space point, or null.
func settlement_at(point: Vector2) -> Settlement:
	if state == null:
		return null
	var best: Settlement = null
	var best_distance := interact_radius()
	for key in state.settlements.keys():
		var settlement := state.settlements[key] as Settlement
		if settlement == null:
			continue
		var distance := point.distance_to(settlement.position)
		if distance <= best_distance:
			best_distance = distance
			best = settlement
	return best


func settlement_color(settlement: Settlement) -> Color:
	match settlement.type:
		Settlement.TYPE_VILLAGE:
			return COLOR_VILLAGE
		Settlement.TYPE_WILDERNESS:
			return COLOR_WILDERNESS
		_:
			return COLOR_TOWN


func _draw() -> void:
	var size := map_size()

	# Backdrop
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	var land := Rect2(Vector2(24.0, 24.0), size - Vector2(48.0, 48.0))
	draw_rect(land, COLOR_LAND)
	draw_rect(land, COLOR_LAND_EDGE, false, 2.0)

	# Grid: purely a sense-of-scale aid while the map has no artwork.
	var step := 100.0
	var x := land.position.x
	while x <= land.end.x:
		draw_line(Vector2(x, land.position.y), Vector2(x, land.end.y), COLOR_GRID, 1.0)
		x += step
	var y := land.position.y
	while y <= land.end.y:
		draw_line(Vector2(land.position.x, y), Vector2(land.end.x, y), COLOR_GRID, 1.0)
		y += step

	if state == null:
		return

	_draw_roads()
	_draw_travel_line()
	_draw_settlements()
	_draw_world_parties()
	_draw_player_party()


func _draw_roads() -> void:
	for road in state.roads:
		var a := state.settlement(str(road.get("a", "")))
		var b := state.settlement(str(road.get("b", "")))
		if a == null or b == null:
			continue
		var kind := str(road.get("kind", "road"))
		var color := COLOR_ROAD if kind == "road" else COLOR_TRACK
		var width := 5.0 if kind == "road" else 3.0
		draw_line(a.position, b.position, color, width)
		if kind == "road":
			draw_line(a.position, b.position, color.lightened(0.18), 1.0)


func _draw_travel_line() -> void:
	if not travel.is_travelling():
		return
	var target := travel.destination()
	if target == null:
		return
	draw_dashed_line(state.world_position, target.position, COLOR_PLAYER.darkened(0.1), 2.0, 10.0)


func _draw_settlements() -> void:
	var font_size := label_font_size()
	for key in state.settlements.keys():
		var settlement := state.settlements[key] as Settlement
		if settlement == null:
			continue
		var color := settlement_color(settlement)
		var radius := 11.0 if settlement.type == Settlement.TYPE_TOWN else 8.0

		# Marker: filled disc plus a ring, so it reads on both dark and light land.
		draw_circle(settlement.position, radius + 2.0, COLOR_PARTY_OUTLINE)
		draw_circle(settlement.position, radius, color)
		draw_arc(settlement.position, radius + 4.0, 0.0, TAU, 32, color.darkened(0.35), 2.0)

		if settlement.visited:
			draw_arc(settlement.position, radius + 8.0, 0.0, TAU, 32, COLOR_HOVERED.darkened(0.3), 1.0)

		if settlement.id == selected_id:
			draw_arc(settlement.position, radius + 12.0, 0.0, TAU, 48, COLOR_SELECTED, 3.0)
		elif settlement.id == hovered_id:
			draw_arc(settlement.position, radius + 12.0, 0.0, TAU, 48, COLOR_HOVERED, 2.0)

		_draw_label(settlement.name, settlement.position + Vector2(0.0, -radius - 20.0), color, font_size)


func _draw_player_party() -> void:
	var position := state.world_position
	draw_circle(position, 12.0, COLOR_PARTY_OUTLINE)
	draw_circle(position, 9.0, COLOR_PLAYER)
	draw_arc(position, 14.0, 0.0, TAU, 32, COLOR_PLAYER.lightened(0.25), 2.0)
	if state.player_party != null and not state.player_party.display_name.is_empty():
		_draw_label(state.player_party.display_name, position + Vector2(0.0, 30.0), COLOR_PLAYER, label_font_size() - 2)


## Hostile and neutral parties sharing the map with the player. Hostile ones get
## a threat ring that reaches as far as they will chase from, so "am I about to be
## jumped?" is answerable at a glance.
func _draw_world_parties() -> void:
	if state == null:
		return
	var font_size := label_font_size() - 2
	for key in state.parties.keys():
		var world_party := state.parties[key] as WorldParty
		if world_party == null or not world_party.is_available():
			continue
		var party := state.party_of(world_party)
		var soldiers := party.size() if party != null else 0
		var color := COLOR_ENEMY if world_party.kind == Party.KIND_BANDIT else COLOR_HOVERED
		var position := world_party.position

		draw_circle(position, 11.0, COLOR_PARTY_OUTLINE)
		# A diamond, so parties never read as settlements or as the player.
		var points := PackedVector2Array([
			position + Vector2(0.0, -9.0),
			position + Vector2(9.0, 0.0),
			position + Vector2(0.0, 9.0),
			position + Vector2(-9.0, 0.0),
		])
		draw_colored_polygon(points, color)

		var label := "%s (%d)" % [world_party.display_name, soldiers]
		_draw_label(label, position + Vector2(0.0, 26.0), color.lightened(0.15), font_size)


## Centred text with a hard shadow so labels stay readable over any backdrop.
func _draw_label(text: String, position: Vector2, color: Color, font_size: int) -> void:
	if _font == null:
		return
	var text_size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var origin := position - Vector2(text_size.x * 0.5, 0.0)
	draw_string(_font, origin + Vector2(1.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.0, 0.0, 0.0, 0.75))
	draw_string(_font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
