class_name WorldMapView
extends Node2D
## Draws the overworld: land, roads, settlements, the player party and (later)
## enemy parties. Pure presentation - it reads campaign state and never mutates it.

const COLOR_BG := Color("0e1218")
const COLOR_LAND := Color("243026")
const COLOR_GRID := Color("2c3a2e")
const COLOR_LAND_EDGE := Color("3a4a3c")
## Brightened when the terrain arrived. The old values were picked to read against a flat dark
## slab, and against painted ground a brown road on brown earth is simply not there.
const COLOR_ROAD := Color("9a8452")
const COLOR_TRACK := Color("6a5f49")
## The dark edge under a road. Casing is what makes a line legible over whatever it crosses - it is
## the trick contour maps have always used, and the reason the roads vanished without it.
const COLOR_CASING := Color(0.02, 0.03, 0.04, 0.55)
const COLOR_TOWN := Color("e8ce8c")
const COLOR_VILLAGE := Color("b99a5e")
const COLOR_WILDERNESS := Color("7f8a6a")
## A fort is steel and a castle is gold: the shape already says which is which, and the colour says it
## again to anyone who cannot tell a square from a turret at a glance.
const COLOR_FORT := Color("9fb0c0")
const COLOR_CASTLE := Color("e8ce8c")
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
## Set while the terrain layer is drawing the ground. The flat fill and the grid were written for a
## map with no artwork - the grid says so itself - and painting them over real ground would be
## drawing the placeholder on top of the thing it stood in for.
var ground_art := false


func _ready() -> void:
	_font = ThemeDB.fallback_font
	z_index = -10


func bind(p_state: CampaignState, p_config: GameConfig, p_travel: TravelService) -> void:
	state = p_state
	config = p_config
	travel = p_travel
	queue_redraw()


## The rectangle the land occupies. Public because the terrain layer sits exactly here, and two
## copies of this arithmetic would eventually disagree.
func land_rect() -> Rect2:
	# The world, not the campaign's old map rectangle. The simulation walks WorldChunks: a party was
	# found at y 4060 on ground the map did not draw, which is how the world's own settlements ended up
	# outside the slab everything else was laid out on.
	return Rect2(Vector2.ZERO, Vector2(WorldChunks.WORLD_SIZE, WorldChunks.WORLD_SIZE))


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
		Settlement.TYPE_FORT:
			return COLOR_FORT
		Settlement.TYPE_CASTLE:
			return COLOR_CASTLE
		_:
			return COLOR_TOWN


func _draw() -> void:
	var size := map_size()

	# Backdrop, and the land beneath the terrain: both are skipped once the terrain layer is
	# drawing, because a backdrop painted by a node at z zero covers a ground node at z minus one.
	if not ground_art:
		draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	var land := land_rect()
	if not ground_art:
		draw_rect(land, COLOR_LAND)
		_draw_grid(land)
	draw_rect(land, COLOR_LAND_EDGE, false, 2.0)

	if state == null:
		return

	_draw_roads()
	_draw_travel_line()
	_draw_settlements()
	_draw_world_parties()
	_draw_player_party()


## Purely a sense-of-scale aid while the map has no artwork.
func _draw_grid(land: Rect2) -> void:
	var step := 100.0
	var x := land.position.x
	while x <= land.end.x:
		draw_line(Vector2(x, land.position.y), Vector2(x, land.end.y), COLOR_GRID, 1.0)
		x += step
	var y := land.position.y
	while y <= land.end.y:
		draw_line(Vector2(land.position.x, y), Vector2(land.end.x, y), COLOR_GRID, 1.0)
		y += step


## A road's path, in place of the straight line it used to be - the owner asked for "realistic bends
## and windes" and a map of straight spokes between towns reads as a diagram, not a country.
##
## Deterministic, and that matters: the bend is a hash of the two endpoints alone, so the same campaign
## always bends the same road the same way, a save reloads to the roads it had, and nothing has to be
## stored. The shape is one long arc - a road going around whatever is in the way - with smaller
## wiggles at two faster rates, because a single arc reads as a curve and three together read as a road.
func _road_path(a: Vector2, b: Vector2) -> PackedVector2Array:
	var span := a.distance_to(b)
	var path := PackedVector2Array([a, b])
	if span < 24.0:
		return path
	var side := Vector2(b.y - a.y, a.x - b.x).normalized()
	var bend := _bend_of(a, b)
	# Forty-eight points, drawn antialiased: fourteen straight hops between wiggles is what "sharp
	# angles" was - the curve was there, the corners were the segments.
	var steps := 48
	path = PackedVector2Array()
	for i in steps + 1:
		var t := float(i) / float(steps)
		# A window that is zero at both ends, and this is the fix for roads that "don't actually connect
		# to some towns": the wiggles used to carry a phase offset, so at t=0 and t=1 they were still
		# displaced sideways and the road ended a few units short of the settlement it was joining. With
		# every term multiplied by sin(t * PI), the offset is exactly zero at both towns.
		var window := sin(t * PI)
		var offset := window * bend * span * 0.15
		offset += sin(t * PI * 3.0 + bend * 5.0) * span * 0.032 * window
		offset += sin(t * PI * 5.0 + bend * 11.0) * span * 0.010 * window
		path.append(a.lerp(b, t) + side * offset)
	return path


## Which way, and how hard, this particular road bends. A hash of the two ends, so it is a property of
## the road rather than of the frame it is drawn in.
func _bend_of(a: Vector2, b: Vector2) -> float:
	var raw := sin(a.x * 12.9898 + a.y * 78.233 + b.x * 37.719 + b.y * 94.673) * 43758.5453
	return (raw - floorf(raw)) * 2.0 - 1.0


func _draw_roads() -> void:
	var visible := _visible_world_rect()
	for road in state.roads:
		var a := state.settlement(str(road.get("a", "")))
		var b := state.settlement(str(road.get("b", "")))
		if a == null or b == null:
			continue
		# A road is drawn if its own box touches the view. Rect2.expand() builds it from the two ends,
		# which for a road that bends is a cheap approximation of its extent and always a safe one.
		var span := Rect2(a.position, Vector2.ZERO).expand(b.position)
		if not visible.intersects(span):
			continue
		var kind := str(road.get("kind", "road"))
		var color := COLOR_ROAD if kind == "road" else COLOR_TRACK
		var width := 5.0 if kind == "road" else 3.0
		var path := _road_path(a.position, b.position)
		draw_polyline(path, COLOR_CASING, width + 3.0, true)
		draw_polyline(path, color, width, true)
		if kind == "road":
			draw_polyline(path, color.lightened(0.3), 1.0, true)


func _draw_travel_line() -> void:
	if not travel.is_travelling():
		return
	var target := travel.destination()
	if target == null:
		return
	draw_dashed_line(state.world_position, target.position, COLOR_PLAYER.darkened(0.1), 2.0, 10.0)


## The slice of the world the camera can actually see, plus a margin so a label does not pop in and
## out at the edge. The owner's rule, from the world design: anything not in vision is data, not
## drawing. At ninety settlements and a 1600-unit view that is about ten drawn instead of ninety.
func _visible_world_rect() -> Rect2:
	var screen := get_viewport_rect().grow(240.0)
	return get_global_transform_with_canvas().affine_inverse() * screen


func _draw_settlements() -> void:
	var font_size := label_font_size()
	var visible := _visible_world_rect()
	for key in state.settlements.keys():
		var settlement := state.settlements[key] as Settlement
		if settlement == null:
			continue
		if not visible.has_point(settlement.position):
			continue
		var color := settlement_color(settlement)
		var radius := _settlement_radius(settlement.type)

		# The marker says what the place is in three ways at once - shape, size and colour - because
		# the map has to be readable at a glance and a player should not have to read a label to know
		# whether the thing ahead is somewhere to trade or somewhere to be shot at.
		#
		#   village  small disc
		#   town     large disc
		#   fort     square, steel
		#   castle   square with four corner towers, gold
		#
		# Placeholders, and the owner asked for placeholders: real icons are art, and art comes after
		# the systems it describes.
		match settlement.type:
			Settlement.TYPE_FORT:
				_draw_square_marker(settlement.position, radius, color, false)
			Settlement.TYPE_CASTLE:
				_draw_square_marker(settlement.position, radius, color, true)
			_:
				draw_circle(settlement.position, radius + 2.0, COLOR_PARTY_OUTLINE)
				draw_circle(settlement.position, radius, color)
				draw_arc(settlement.position, radius + 4.0, 0.0, TAU, 32, color.darkened(0.35), 2.0)
				# A town wears a mark inside the disc. Size alone was not enough: at map zoom a village
				# and a town were the same shape at slightly different scales, and a marker that needs
				# the label read to be understood is not doing its job.
				if settlement.type == Settlement.TYPE_TOWN:
					draw_circle(settlement.position, radius * 0.4, COLOR_BG)

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
		var soldiers := state.active_member_count(party)
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
## How big a settlement's marker is. Size is the first thing the eye reads, so a town is visibly
## more than a village before anything else about it registers.
static func _settlement_radius(type: String) -> float:
	match type:
		Settlement.TYPE_TOWN:
			return 11.0
		Settlement.TYPE_CASTLE:
			return 12.0
		Settlement.TYPE_FORT:
			return 10.0
		_:
			return 8.0


## A walled settlement: a filled square with a dark edge, and for a castle a turret at each corner -
## four small squares, offset off the corners, which is the oldest shorthand there is for "this one is
## fortified harder than that one".
func _draw_square_marker(centre: Vector2, half: float, color: Color, towers: bool) -> void:
	var body := Rect2(centre - Vector2(half, half), Vector2(half, half) * 2.0)
	draw_rect(body.grow(2.0), COLOR_PARTY_OUTLINE, true)
	draw_rect(body, color, true)
	draw_rect(body, color.darkened(0.35), false, 2.0)
	if not towers:
		return
	var turret := half * 0.42
	var offsets: Array[Vector2] = [
		Vector2(-half, -half), Vector2(half, -half), Vector2(-half, half), Vector2(half, half),
	]
	for offset in offsets:
		var at := centre + offset
		var square := Rect2(at - Vector2(turret, turret), Vector2(turret, turret) * 2.0)
		draw_rect(square.grow(1.5), COLOR_PARTY_OUTLINE, true)
		draw_rect(square, color, true)


func _draw_label(text: String, position: Vector2, color: Color, font_size: int) -> void:
	if _font == null:
		return
	var text_size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var origin := position - Vector2(text_size.x * 0.5, 0.0)
	# An eight-way outline rather than one drop shadow. A single offset shadow leaves the letters'
	# other edges sitting directly on whatever colour happens to be under them, which over painted
	# ground is the difference between a label and a smudge.
	var outline := Color(0.02, 0.03, 0.04, 0.9)
	var offsets: Array[Vector2] = [
		Vector2(-1.5, 0.0), Vector2(1.5, 0.0), Vector2(0.0, -1.5), Vector2(0.0, 1.5),
		Vector2(-1.1, -1.1), Vector2(1.1, -1.1), Vector2(-1.1, 1.1), Vector2(1.1, 1.1),
	]
	for offset in offsets:
		draw_string(_font, origin + offset, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, outline)
	draw_string(_font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
