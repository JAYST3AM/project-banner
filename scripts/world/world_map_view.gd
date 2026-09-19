class_name WorldMapView
extends Node2D
## Draws the overworld: land, roads, settlements, the player party and (later)
## enemy parties. Pure presentation - it reads campaign state and never mutates it.

const COLOR_BG := Color("0e1218")
const COLOR_LAND := Color("243026")
const COLOR_GRID := Color("2c3a2e")
const COLOR_LAND_EDGE := Color("3a4a3c")
## Earth tones pulled from the ground's own flat-shader palette (worn earth, dry grass, sand), so a
## road reads as ground that has been walked rather than a line drawn over the map - the owner:
## "make the roads look more like terrain". Each tier is a soft trampled margin, a core, and - on a
## proper road - a faint worn centre.
const COLOR_ROAD := Color("8f7a55")
const COLOR_TRACK := Color("7d6c4e")
const COLOR_DIRT := Color("6b5d43")
## The soft margin each road sits in: wide, faint, low-contrast earth. It replaces the old hard
## casing, which read as a UI stroke; this reads as ground that has been trodden.
const COLOR_ROAD_MARGIN := Color(0.30, 0.26, 0.18, 0.38)
const COLOR_TRACK_MARGIN := Color(0.27, 0.24, 0.17, 0.30)
const COLOR_DIRT_MARGIN := Color(0.25, 0.22, 0.16, 0.24)
## The worn centre of a proper road: the strip where feet and cartwheels have taken the grass away.
const COLOR_ROAD_WORN := Color(0.72, 0.64, 0.46, 0.30)
## Timber: a bridge is the one piece of a road that is built rather than worn, so it is drawn as its
## own thing - a dark planked span with a post at each bank.
const COLOR_BRIDGE := Color("6d4f33")
const COLOR_BRIDGE_MARGIN := Color(0.16, 0.12, 0.08, 0.45)
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
## The road network, when one is wired: the view draws the network's own shaped curves (the ones the
## snap and the grid read) and the bridges they carry.
var roads: RoadNetwork = null

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

	if show_costs:
		_draw_cost_grid()
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


## Roads are drawn from RoadPath.between(), shared with the party's walking so the two cannot disagree
## about where a road goes - see scripts/world/road_path.gd.
## Shown when the owner has debug mode open; set by the map from the debug panel.
var show_costs := false
## The campaign priced ground, set by the map once it exists.
var costs: TravelCosts = null


## The travel cost grid, drawn when debug mode is open: "when I hit debug mode it should show the
## point system in the grid." Cells are tinted by what crossing them costs - bright where ground is
## cheap, dim where it is dear - so a route's reasoning is visible rather than inferred. Only the
## cells in view are drawn, by the same rectangle everything else culls against.
func _draw_cost_grid() -> void:
	if costs == null or not costs.is_ready():
		return
	var visible := _visible_world_rect()
	var cell := TravelCosts.CELL
	var first := Vector2i(int(floorf(visible.position.x / cell)), int(floorf(visible.position.y / cell)))
	var last := Vector2i(int(ceilf(visible.end.x / cell)), int(ceilf(visible.end.y / cell)))
	var ceiling := costs.dearest()
	for row in range(maxi(0, first.y), mini(TravelCosts.ROWS, last.y)):
		for column in range(maxi(0, first.x), mini(TravelCosts.COLUMNS, last.x)):
			var price := costs.cost_of(Vector2i(column, row))
			if price == INF:
				continue
			var warmth := clampf(1.0 - price / maxf(0.0001, ceiling * 0.65), 0.0, 1.0)
			var origin := Vector2(column, row) * cell
			draw_rect(Rect2(origin, Vector2(cell, cell)), Color(0.95, 0.55, 0.15, 0.10 + 0.20 * warmth), true)
			if warmth > 0.7:
				draw_rect(Rect2(origin + Vector2(1.0, 1.0), Vector2(cell - 2.0, cell - 2.0)), Color(0.95, 0.62, 0.20, 0.10 + 0.22 * warmth), true)
	if travel != null and not travel.route.is_empty():
		draw_polyline(travel.route, Color(0.65, 0.95, 0.55, 0.9), 2.0, true)


func _draw_roads() -> void:
	var visible := _visible_world_rect()
	for index in state.roads.size():
		var raw: Variant = state.roads[index]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var road := raw as Dictionary
		var a := state.settlement(str(road.get("a", "")))
		var b := state.settlement(str(road.get("b", "")))
		if a == null or b == null:
			continue
		# A road is drawn if its own box touches the view. Rect2.expand() builds it from the two ends,
		# which for a road that bends is a cheap approximation of its extent and always a safe one.
		var bound := Rect2(a.position, Vector2.ZERO).expand(b.position)
		if not visible.intersects(bound):
			continue
		var tier := str(road.get("kind", "road"))
		if tier == "none":
			continue
		# The network's own shaped curve - the one the snap, the grid and the walking read - so what
		# is drawn and what is walked cannot drift apart; a fresh shape only when no network is wired.
		var path: PackedVector2Array = PackedVector2Array()
		var bridges: Array = []
		if roads != null:
			path = roads.link_curve(index)
			bridges = roads.bridge_spans(index)
		if path.size() < 2:
			path = RoadPath.between(a.position, b.position)
			bridges = []
		var core := COLOR_ROAD
		var margin := COLOR_ROAD_MARGIN
		var width := 4.6
		match tier:
			"dirt":
				core = COLOR_DIRT
				margin = COLOR_DIRT_MARGIN
				width = 1.8
			"track":
				core = COLOR_TRACK
				margin = COLOR_TRACK_MARGIN
				width = 3.2
		# Ground that has been walked: the trampled margin, then the core - timber where the curve
		# crosses water - and, on a proper road, the worn centre.
		draw_polyline(path, margin, width + 5.0, true)
		_draw_road_core(path, core, width, bridges)
		if tier == "road":
			_draw_road_strip(path, COLOR_ROAD_WORN, 2.0, bridges)


## The core line, split around any bridge spans: dry ground in the tier's own colour, water in
## timber with a post at each bank.
func _draw_road_core(path: PackedVector2Array, core: Color, width: float, bridges: Array) -> void:
	var from := 0
	for bridge in bridges:
		var start := maxi(int(bridge.x) - 1, 0)
		var stop := mini(int(bridge.y) + 1, path.size() - 1)
		if start > from:
			draw_polyline(path.slice(from, start + 1), core, width, true)
		var planks := path.slice(start, stop + 1)
		if planks.size() >= 2:
			draw_polyline(planks, COLOR_BRIDGE_MARGIN, width + 3.4, true)
			draw_polyline(planks, COLOR_BRIDGE, width + 1.0, true)
			var across := (planks[planks.size() - 1] - planks[0]).orthogonal().normalized()
			draw_line(planks[0] - across * 3.4, planks[0] + across * 3.4, COLOR_BRIDGE, 1.8)
			draw_line(planks[planks.size() - 1] - across * 3.4,
				planks[planks.size() - 1] + across * 3.4, COLOR_BRIDGE, 1.8)
		from = stop
	if from < path.size() - 1:
		draw_polyline(path.slice(from, path.size()), core, width, true)


## A thin strip along the dry stretches only - the worn centre of a road, which a bridge does not
## have: a road does not wear its own planks.
func _draw_road_strip(path: PackedVector2Array, color: Color, width: float, bridges: Array) -> void:
	var from := 0
	for bridge in bridges:
		var start := maxi(int(bridge.x) - 1, 0)
		var stop := mini(int(bridge.y) + 1, path.size() - 1)
		if start > from:
			draw_polyline(path.slice(from, start + 1), color, width, true)
		from = stop
	if from < path.size() - 1:
		draw_polyline(path.slice(from, path.size()), color, width, true)


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
	# Between the last simulation step and the next one, not on a step boundary: the world moves thirty
	# times a second and the screen draws three hundred and sixty, so drawing the step position alone
	# makes the party hop the same distance at the same interval. Interpolating costs one lerp and is
	# the difference between a marker that glides and a marker that stutters.
	var position := state.previous_world_position.lerp(state.world_position, clampf(state.render_alpha, 0.0, 1.0))
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
