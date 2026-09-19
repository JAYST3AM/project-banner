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
## Traders (D-139): a warm wagon gold, distinct from the enemy red at a glance.
const COLOR_CARAVAN := Color("d9b96a")
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
## How far the baked contact shadow spills below the wall foot, as a fraction of the sprite's map
## width. The baker (scripts/bake_structure_shadow.py in the asset factory) pads the canvas by
## int(1.25 * 0.115 * texture_width) + 4, which scales to a fixed 0.1475 of the sprite's drawn width
## once the texture is sized to the map - the number here tracks that pad. The sprite is drawn this
## much lower than a plain bottom anchor so the wall foot meets the ground, and the soil nubs sit on
## the same base line.
const SPILL_BELOW_BASE := 0.1475
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
	var best_distance := INF
	for key in state.settlements.keys():
		var settlement := state.settlements[key] as Settlement
		if settlement == null:
			continue
		# The pick follows the art: a settlement that stands 160 units wide is selectable across
		# its footprint, not only inside the old marker's radius.
		var reach := maxf(interact_radius(), SettlementSprites.map_width(settlement.type) * 0.5)
		var distance := point.distance_to(settlement.position)
		if distance <= reach and distance < best_distance:
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

		# The art from here on (2026-09-19): the accepted structure sprites stand where the
		# placeholder discs and squares did. The sprite itself now says what the place is - a
		# longhouse reads as a village, a moated keep as a coastal castle - while size, colour,
		# the rings and the label still carry what the map needs at a glance. Wilderness keeps
		# its disc: there is no sprite for a place that is not settled.
		var sprite_height := 0.0
		var base := radius
		if settlement.type != Settlement.TYPE_WILDERNESS:
			var texture := SettlementSprites.texture_for(settlement)
			var width := SettlementSprites.map_width(settlement.type)
			var size := Vector2(width, width * float(texture.get_height()) / float(texture.get_width()))
			sprite_height = size.y
			base = width * 0.5
			# Planted (2026-09-19): the contact shadow is baked into the sprite itself, so it blends
			# over whatever ground the terrain draws beneath, and the clearing around the town is
			# carved into the terrain field (SettlementSprites.clearing_index). Nothing is drawn
			# between the two - the double-shadow read was the first version's tell.
			# The sprite anchors on its BASE, not its bottom edge (2026-09-19): the baked contact
			# shadow spills below the wall foot, so a bottom-edge anchor leaves the building
			# hovering a shadow's height above the very spot the clearing is centred on (the owner:
			# "still too high"). Drawing it SPILL_BELOW_BASE lower puts the wall foot, the contact
			# band and the middle of the dirt patch on one point.
			var spill := width * SPILL_BELOW_BASE
			var patch := width * 0.62
			var phase := float(settlement.id.hash() % 628) / 100.0
			draw_set_transform(settlement.position, 0.0, Vector2(1.0, 0.5))
			var rings := [
				{"r": patch, "a": 0.30},
				{"r": patch * 0.82, "a": 0.26},
				{"r": patch * 0.6, "a": 0.22},
			]
			for ring_index in rings.size():
				# Each ring wobbles on its own phase (the first version shared one, and the shared
				# pattern read as a scalloped, gear-like edge).
				var ring: Dictionary = rings[ring_index]
				var points := PackedVector2Array()
				for i in 24:
					var angle := TAU * float(i) / 24.0
					var wobble := 1.0 + 0.10 * sin(3.0 * angle + phase + float(ring_index) * 1.9) \
							+ 0.05 * sin(5.0 * angle + phase * 1.7 + float(ring_index) * 0.8)
					points.append(Vector2(cos(angle), sin(angle)) * float(ring["r"]) * wobble)
				draw_colored_polygon(points, Color(0.30, 0.25, 0.17, float(ring["a"])))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			# Two satellite smudges - fixed offsets, differing per town - so the edge is never a
			# clean contour.
			var wob_x := patch * (0.55 + 0.25 * sin(phase * 2.1))
			var wob_y := patch * (0.10 + 0.22 * cos(phase * 1.3))
			draw_circle(settlement.position + Vector2(wob_x, wob_y), patch * 0.2, Color(0.30, 0.25, 0.17, 0.22))
			draw_circle(settlement.position + Vector2(-wob_x, wob_y * 1.4), patch * 0.16, Color(0.30, 0.25, 0.17, 0.18))
			# And the first road that leaves it ends in the earth, not at a line: a faint spur of
			# the same ground bridges the two.
			for road_any in state.roads:
				if typeof(road_any) != TYPE_DICTIONARY:
					continue
				var road := road_any as Dictionary
				var other: Settlement = null
				if str(road.get("a", "")) == settlement.id:
					other = state.settlement(str(road.get("b", "")))
				elif str(road.get("b", "")) == settlement.id:
					other = state.settlement(str(road.get("a", "")))
				if other == null:
					continue
				var direction := (other.position - settlement.position).normalized()
				for step in 4:
					draw_circle(settlement.position + direction * patch * (1.05 + 0.30 * float(step)),
							patch * (0.24 - 0.04 * float(step)), Color(0.30, 0.25, 0.17, 0.18))
				break
			draw_texture_rect(texture, Rect2(settlement.position - Vector2(size.x * 0.5, size.y - spill), size), false)
			# Soil nubs over the base line (2026-09-19): the keyer crops the sprite to its last
			# opaque row, so the wall foot meets the ground at a knife edge - and a knife edge is
			# what makes a structure float even with a shadow under it (the owner: "just fyi it
			# looks like they are floating"). A scatter of earth blobs over that edge buries the
			# foot in the same soil the clearing makes. Deterministic from the same phase as the
			# patch, or the scatter would crawl between frames.
			var base_y := settlement.position.y
			# Varied size, spacing, opacity and a few crumbs above the line: evenly sized nubs on
			# even spacing read as a string of beads, which is worse than the knife edge was.
			for i in 12:
				var t := (float(i) + 0.5) / 12.0 + sin(float(i) * 7.3 + phase) * 0.022
				var nub := 0.5 + 0.5 * sin(phase * 3.0 + float(i) * 2.1)
				var crumb := 0.5 + 0.5 * sin(phase * 5.7 + float(i) * 3.7)
				var nx := settlement.position.x + (t - 0.5) * width * 0.92
				var ny := base_y + (nub - 0.4) * 9.0
				draw_circle(Vector2(nx, ny), 1.7 + 3.6 * crumb, Color(0.26, 0.21, 0.14, 0.45 + 0.3 * nub))
				if crumb > 0.72:
					draw_circle(Vector2(nx + 5.0, ny - 4.0), 1.6 + 1.2 * nub, Color(0.26, 0.21, 0.14, 0.4))
		else:
			draw_circle(settlement.position, radius + 2.0, COLOR_PARTY_OUTLINE)
			draw_circle(settlement.position, radius, color)
			draw_arc(settlement.position, radius + 4.0, 0.0, TAU, 32, color.darkened(0.35), 2.0)

		# The rings follow the art: at this scale a ring drawn at the old marker radius would ring
		# the town's doorway rather than the town.
		var ring := maxf(radius, base * 0.62)
		if settlement.visited:
			draw_arc(settlement.position, ring + 8.0, 0.0, TAU, 32, COLOR_HOVERED.darkened(0.3), 1.0)

		if settlement.id == selected_id:
			draw_arc(settlement.position, ring + 12.0, 0.0, TAU, 48, COLOR_SELECTED, 3.0)
		elif settlement.id == hovered_id:
			draw_arc(settlement.position, ring + 12.0, 0.0, TAU, 48, COLOR_HOVERED, 2.0)

		var label_lift := sprite_height if sprite_height > 0.0 else radius
		_draw_label(settlement.name, Vector2(settlement.position.x, settlement.position.y - label_lift - 20.0), color, font_size)


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
		var color := COLOR_HOVERED
		if world_party.kind == Party.KIND_BANDIT:
			color = COLOR_ENEMY
		elif world_party.kind == Party.KIND_CARAVAN:
			color = COLOR_CARAVAN
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

		# Guards are real soldiers now (D-139), so every party on the map counts its spears.
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
