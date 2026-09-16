class_name BattleView
extends Node2D
## Draws the battlefield and everything standing on it.
##
## Read-only: it renders [BattleUnit] state and never changes it. Selection and
## orders are the controller's job.

const COLOR_GROUND := Color("2b3428")
const COLOR_GROUND_EDGE := Color("465239")
const COLOR_LINE := Color("3a4534")
const COLOR_PLAYER := Color("4fa8e0")
const COLOR_ENEMY := Color("d0603f")
const COLOR_OUTLINE := Color("0b1017")
const COLOR_TEXT := Color("e8eaed")
const COLOR_DIM := Color("93a0ad")
const COLOR_GOLD := Color("e8ce8c")

const UNIT_RADIUS := 1.5

## Formation debugging. Off by default: the overlay exists to make behaviour observable
## while the systems are being built, and it is deliberately separable from the
## simulation so that leaving it on cannot change what happens.
const COLOR_ANCHOR := Color("ffd166")
const COLOR_SLOT := Color("9ad1d4")
const COLOR_FACING := Color("ffe9a8")
## Step 7.8's development overlay: the body a body has decided to fight, the band inside which
## its soldiers may look for opponents of their own, and the soldiers who are allowed to.
const COLOR_ENGAGEMENT := Color("c58cff")
const COLOR_BAND := Color("c58cff", 0.5)
const COLOR_PROMOTED := Color("ff8ad8")

var simulator: BattleSimulator = null
var context: BattleContext = null

## Ground is drawn from the simulation's terrain data, never the other way round.
var show_terrain: bool = true
## The development overlay: anchors, facing, target slots, formation bounds, cohesion.
var show_formation_debug: bool = false
## Whether this view draws the soldiers themselves. Off when a [SoldierField] draws the army
## as one instanced draw instead (Step 7.9's render spike), and off on its own for the
## ground-only baseline the render benchmark measures. Nothing else about the view changes:
## the ground, the overlay, the box selection and the popups are drawn either way.
var show_units: bool = true
## Draw each formation as one box instead of its soldiers as marks. The army at large numbers is
## unreadable as twenty thousand circles - and paying for them - while six boxes say the same thing
## at a glance. The box is the body's own bounds, so it shrinks as the ranks thin, and the soldiers
## behind it are exactly the same individuals either way. [code]PB_BLOCK_VIEW=1[/code] turns it on
## without a code change, which is how the large showcases are watched.
var block_view: bool = OS.get_environment("PB_BLOCK_VIEW") == "1"
## The label above each body - its id, state, cohesion and shape. Split from the geometry
## drawing because at a zoomed-out camera the text is drawn in world units and covers a large
## part of the field: a showcase that wants to see the armies arrange themselves can drop the
## words and keep the marks. On by default, which is what the battle scene has always done.
var show_formation_labels: bool = true

var selected_ids: Array[int] = []

var box_select_active: bool = false
var box_select_rect: Rect2 = Rect2()

## Transient floating text (damage numbers, deaths), aged by _process.
var _popups: Array[Dictionary] = []
const POPUP_LIFETIME := 1.1
## How far a damage number drifts upward, in *screen* pixels - not world units, or the text flies
## across the map on a zoomed-in camera and does not move at all on a zoomed-out one.
const POPUP_RISE_PIXELS := 22.0
## How tall a damage number is drawn, in screen pixels.
const POPUP_TEXT_PIXELS := 15.0
## Arrows in flight, drawn only: the shot being visible rather than resolved. See D-110.
var _arrows: Array[Dictionary] = []
const ARROW_FLIGHT := 0.10
const ARROW_THICKNESS_PIXELS := 2.0
const COLOR_ARROW := Color("efe7cd")

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font


func _process(delta: float) -> void:
	if _popups.is_empty() and _arrows.is_empty():
		return
	var kept: Array[Dictionary] = []
	for popup in _popups:
		popup["age"] = float(popup.get("age", 0.0)) + delta
		if float(popup["age"]) < POPUP_LIFETIME:
			kept.append(popup)
	_popups = kept
	var flying: Array[Dictionary] = []
	for arrow in _arrows:
		arrow["age"] = float(arrow.get("age", 0.0)) + delta
		if float(arrow["age"]) < ARROW_FLIGHT:
			flying.append(arrow)
	_arrows = flying
	queue_redraw()


## A length in world units that draws as [param pixels] on screen, whatever the camera is doing.
## Damage numbers and arrow shafts are screen furniture - they belong to the player's eye, not to the
## battlefield - so they are sized in pixels and converted here at draw time. The damage text used to
## be a flat 26 world units, which at a battle camera's zoom is a number four hundred pixels tall.
func _screen_constant(pixels: float) -> float:
	var zoom := maxf(0.001, get_canvas_transform().get_scale().x)
	return pixels / zoom


## Consume a frame of simulator events and turn them into visual feedback.
func add_events(events: Array[Dictionary]) -> void:
	for event in events:
		match str(event.get("type", "")):
			"hit":
				var ranged := bool(event.get("ranged", false))
				if ranged:
					_launch_arrow(int(event.get("attacker", -1)), event.get("position", Vector2.ZERO))
				_popups.append({
					"text": "-%d" % int(event.get("damage", 0)),
					"position": event.get("position", Vector2.ZERO),
					# A ranged number lands when its arrow does, so a hit does not read a tenth of a
					# second before the shaft that caused it. See D-110.
					"age": -ARROW_FLIGHT if ranged else 0.0,
					"color": COLOR_GOLD if ranged else Color("ffd9d0"),
				})
			"miss":
				# A miss is only visible at all if the shot is: an arrow that flies and finds nothing.
				if simulator == null:
					continue
				var shooter: BattleUnit = simulator.find_unit(int(event.get("attacker", -1)))
				if shooter != null and shooter.ranged:
					_launch_arrow(shooter.id, event.get("position", Vector2.ZERO))
			"death":
				_popups.append({
					"text": "%s down" % str(event.get("unit_name", "")),
					"position": event.get("position", Vector2.ZERO),
					"age": 0.0,
					"color": COLOR_ENEMY.lightened(0.25),
				})


## A cosmetic arrow from a shooter to where the shot went. The damage is already decided: this draws
## the shot being visible rather than resolving it, so the simulation's timing, determinism and every
## test that pins them are untouched. An arrow that misses is drawn too - that is the only way a
## player can tell a volley from a formation that has stopped shooting.
func _launch_arrow(attacker_id: int, to: Vector2) -> void:
	if simulator == null:
		return
	var shooter: BattleUnit = simulator.find_unit(attacker_id)
	if shooter == null:
		return
	_arrows.append({"from": shooter.position, "to": to, "age": 0.0})


## Arrows currently in flight. Exposed for tests: the arrows are the only part of a ranged attack a
## player can see, so the wiring from event to drawing is worth an assertion.
func arrows_in_flight() -> int:
	return _arrows.size()


func _draw_arrows() -> void:
	var thickness := _screen_constant(ARROW_THICKNESS_PIXELS)
	for arrow in _arrows:
		var t := clampf(float(arrow.get("age", 0.0)) / ARROW_FLIGHT, 0.0, 1.0)
		var from: Vector2 = arrow.get("from", Vector2.ZERO)
		var to: Vector2 = arrow.get("to", Vector2.ZERO)
		var head := from.lerp(to, t)
		# A short shaft behind the head, so a shot in flight reads as a shot rather than a dot.
		var shaft := head - (to - from).normalized() * (thickness * 4.0)
		draw_line(shaft, head, COLOR_ARROW, thickness)


func bind(p_simulator: BattleSimulator, p_context: BattleContext) -> void:
	simulator = p_simulator
	context = p_context
	queue_redraw()


func unit_color(unit: BattleUnit) -> Color:
	return COLOR_PLAYER if unit.side == BattleContext.SIDE_PLAYER else COLOR_ENEMY


func _draw() -> void:
	if simulator == null:
		return
	var size := simulator.field_size

	# Ground. Terrain is data first, so this draws what the simulation is already
	# walking on rather than deciding anything about it.
	if show_terrain and simulator.terrain != null:
		_draw_terrain()
	else:
		draw_rect(Rect2(Vector2.ZERO, size), COLOR_GROUND)
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_GROUND_EDGE, false, 0.4)

	# Centre line and deployment bounds, so the layout is legible before the fight
	var centre := size.x * 0.5
	draw_line(Vector2(centre, 0.0), Vector2(centre, size.y), COLOR_LINE, 0.15)

	if show_formation_debug:
		_draw_formations()

	if show_units:
		var level := drawing_level()
		if UnitScale.is_single(level):
			for unit in simulator.units:
				if unit.is_alive():
					_draw_unit(unit)
				else:
					_draw_fallen(unit)
		else:
			_draw_groups(level)

	_draw_arrows()

	if show_formation_debug and show_formation_labels:
		_draw_formation_labels()
	if box_select_active:
		draw_rect(box_select_rect, COLOR_GOLD.darkened(0.2), false, 0.18)
		draw_rect(box_select_rect, Color(COLOR_GOLD.r, COLOR_GOLD.g, COLOR_GOLD.b, 0.12))

	_draw_popups()


## The army as its groups: one box per century, cohort or legion, in the side's colour. The box is
## where that group's living soldiers stand, so it contracts as the ranks thin and the ground shows
## through it. Twenty thousand individual marks at this scale is a texture, not a picture; the
## soldiers behind the boxes are exactly the same individuals either way.
func _draw_groups(level: int) -> void:
	var step := UnitScale.size_of(level)
	if step <= 1:
		return
	var alive := {}
	for unit in simulator.units:
		if unit.is_alive():
			alive[unit.id] = unit
	for formation in simulator.formations:
		var colour := COLOR_PLAYER if formation.side == BattleContext.SIDE_PLAYER else COLOR_ENEMY
		var groups := {}
		var order: Array[int] = []
		for i in formation.unit_ids.size():
			var unit: BattleUnit = alive.get(formation.unit_ids[i])
			if unit == null:
				continue
			var index := i / step
			if groups.has(index):
				var box: Array = groups[index]
				box[0] = box[0].min(unit.position)
				box[1] = box[1].max(unit.position)
			else:
				groups[index] = [unit.position, unit.position]
				order.append(index)
		for index in order:
			var box: Array = groups[index]
			var rect := Rect2(box[0], box[1] - box[0]).grow(1.1)
			draw_rect(rect, colour)
			draw_rect(rect, colour.darkened(0.45), false, 0.7)


## The grouping this camera is drawn at. Close in, the soldiers; further out, first the century they
## fight as, then the cohort, then the legion. [code]PB_BLOCK_VIEW=1[/code] refuses to draw
## individuals at any zoom, which is how the large showcases are watched.
func drawing_level() -> int:
	var level := UnitScale.level_for_zoom(get_canvas_transform().get_scale().x)
	if block_view and UnitScale.is_single(level):
		return UnitScale.Level.CENTURY
	return level


## The ground, baked once into a texture with one pixel per terrain cell and drawn in a single call.
## The old per-cell rectangles were fine on a field of a few hundred cells and ruinous on one grown
## to fit twenty thousand men: fifty thousand draw calls a frame is the whole frame budget, spent on
## ground that never changes. A stale bake is caught by the terrain's own identity.
var _ground: ImageTexture = null
var _ground_source: int = 0


## Draw the ground. Baked once, drawn in one call, and rebaked only if the terrain is replaced.
func _draw_terrain() -> void:
	var terrain := simulator.terrain
	if terrain == null:
		return
	if _ground == null or _ground_source != terrain.get_instance_id():
		_ground = _bake_ground(terrain)
		_ground_source = terrain.get_instance_id() if _ground != null else 0
	if _ground != null:
		draw_texture_rect(_ground, Rect2(Vector2.ZERO, terrain.size), false)


## One pixel per cell, shaded by elevation the same way the per-cell rectangles were, and read back
## with nearest filtering so the ground keeps its blocky grain instead of blurring into a gradient.
func _bake_ground(terrain: BattlefieldTerrain) -> ImageTexture:
	var cols := maxi(1, terrain.cols)
	var rows := maxi(1, terrain.rows)
	var image := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	var tallest := maxf(0.001, terrain.max_height())
	for y in rows:
		for x in cols:
			var index := y * cols + x
			var colour := terrain.colour_of_cell(index)
			# A little elevation shading so the shape of the ground reads at a glance
			# without needing a legend.
			var relief := terrain.height_of_cell(index) / tallest
			if relief > 0.5:
				colour = colour.lightened((relief - 0.5) * 0.55)
			else:
				colour = colour.darkened((0.5 - relief) * 0.45)
			image.set_pixel(x, y, colour)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	return ImageTexture.create_from_image(image)


## The development overlay: where each body means to be, which way it is turned, the
## places it has handed out, and how well it is holding them.
##
## This is the picture that will matter most once a shield wall's value depends on its
## gaps - a formation's shape is much easier to believe when you can see it separately
## from the men standing in it.
func _draw_formations() -> void:
	if simulator == null:
		return
	for formation in simulator.formations:
		draw_rect(formation.bounds(), COLOR_SLOT.darkened(0.3), false, 0.18)
		for index in formation.slots.size():
			var owner_id := formation.unit_ids[index] if index < formation.unit_ids.size() else -1
			var occupied := false
			if owner_id >= 0:
				var unit := simulator.find_unit(owner_id)
				occupied = unit != null and unit.is_alive()
			draw_circle(formation.slot_at(index), 0.55, COLOR_SLOT if occupied else COLOR_SLOT.darkened(0.6))

	# Anchors and facing arrows on top, so they are never hidden by a slot marker.
	for formation in simulator.formations:
		var forward := formation.forward()
		draw_line(formation.anchor, formation.anchor + forward * 5.0, COLOR_FACING, 0.4)
		draw_circle(formation.anchor, 0.9, COLOR_ANCHOR)
		draw_line(
			formation.anchor - formation.right_vector() * (formation.frontage() * 0.5),
			formation.anchor + formation.right_vector() * (formation.frontage() * 0.5),
			COLOR_ANCHOR.darkened(0.35), 0.22
		)

	# Step 7.8's formation-driven engagement, drawn where it can be seen: which body each body
	# has decided to fight, the band its soldiers are allowed to look for their own opponents in,
	# and which soldiers are looking. Development only, and behind the same switch as the rest of
	# the overlay - it answers "why is that man not fighting" by showing the band he is outside
	# of. See D-105.
	for formation in simulator.formations:
		var target: BattleFormation = simulator.formation(formation.target_formation_id)
		if target == null or target.living_count <= 0:
			continue
		draw_line(formation.centre, target.centre, COLOR_ENGAGEMENT.darkened(0.35), 0.25)
		draw_circle(target.centre, 1.1, COLOR_ENGAGEMENT.darkened(0.2), false, 0.5)
		var band := formation.contact_band
		if band > 0.0:
			draw_rect(target.bounds().grow(band), COLOR_BAND, false, 0.16)
	for unit in simulator.units:
		if not unit.is_alive() or not unit.fdr_promoted:
			continue
		draw_circle(unit.position, UNIT_RADIUS + 0.7, COLOR_PROMOTED, false, 0.3)


func _draw_formation_labels() -> void:
	if _font == null:
		return
	for formation in simulator.formations:
		var text := "%s  %s  coh %.0f%%  %dfx%dr" % [
			formation.id, formation.state_name(), formation.cohesion * 100.0,
			formation.file_count, formation.rank_count]
		draw_string(_font, formation.anchor + Vector2(-6.0, -6.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, COLOR_FACING)


func _draw_popups() -> void:
	if _font == null:
		return
	for popup in _popups:
		var age := float(popup.get("age", 0.0))
		# A negative age is a number waiting for its arrow to land.
		if age < 0.0:
			continue
		var life := age / POPUP_LIFETIME
		var colour: Color = popup.get("color", COLOR_TEXT)
		colour.a = clampf(1.0 - life, 0.0, 1.0)
		var size := int(clampf(_screen_constant(POPUP_TEXT_PIXELS), 3.0, 64.0))
		var text := str(popup.get("text", ""))
		var position: Vector2 = popup.get("position", Vector2.ZERO)
		position.y -= life * _screen_constant(POPUP_RISE_PIXELS)
		var measured := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		draw_string(_font, position - Vector2(measured.x * 0.5, 0.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, colour)


func _draw_unit(unit: BattleUnit) -> void:
	var color := unit_color(unit)
	var position := unit.position

	draw_circle(position, UNIT_RADIUS + 0.45, COLOR_OUTLINE)
	draw_circle(position, UNIT_RADIUS, color)

	# Facing pip: a short line showing which way the unit is turned.
	if unit.facing.length() > 0.01:
		draw_line(position, position + unit.facing * (UNIT_RADIUS + 0.7), color.lightened(0.5), 0.28)

	# Health bar above the unit.
	var bar_width := UNIT_RADIUS * 2.4
	var bar_height := 0.42
	var bar_origin := position + Vector2(-bar_width * 0.5, -UNIT_RADIUS - 1.25)
	draw_rect(Rect2(bar_origin, Vector2(bar_width, bar_height)), Color(0.0, 0.0, 0.0, 0.65))
	var ratio := unit.hp_ratio()
	var fill := COLOR_PLAYER if ratio > 0.35 else COLOR_ENEMY
	draw_rect(Rect2(bar_origin, Vector2(bar_width * ratio, bar_height)), fill.lightened(0.1))

	# Ranged units are marked with a ring so the two lines read apart at a glance.
	if unit.ranged:
		draw_arc(position, UNIT_RADIUS + 1.0, 0.0, TAU, 20, color.lightened(0.35), 0.22)

	if selected_ids.has(unit.id):
		draw_arc(position, UNIT_RADIUS + 1.9, 0.0, TAU, 28, COLOR_GOLD, 0.34)

	if unit.has_orders():
		draw_dashed_line(position, _order_target(unit), COLOR_GOLD.darkened(0.25), 0.16, 1.2)


## Where a unit's order line should point: an attack target if it has one,
## otherwise its move waypoint. Only meaningful when [method BattleUnit.has_orders]
## is true.
func _order_target(unit: BattleUnit) -> Vector2:
	if unit.attack_order_target_id >= 0 and simulator != null:
		var hunted := simulator.find_unit(unit.attack_order_target_id)
		if hunted != null and hunted.is_alive():
			return hunted.position
	return unit.move_order


func _draw_fallen(unit: BattleUnit) -> void:
	var color := unit_color(unit).darkened(0.55)
	draw_line(
		unit.position + Vector2(-UNIT_RADIUS, -UNIT_RADIUS * 0.5),
		unit.position + Vector2(UNIT_RADIUS, UNIT_RADIUS * 0.5),
		color, 0.35
	)
	draw_line(
		unit.position + Vector2(UNIT_RADIUS, -UNIT_RADIUS * 0.5),
		unit.position + Vector2(-UNIT_RADIUS, UNIT_RADIUS * 0.5),
		color, 0.35
	)


## Screen-space click to a unit id, or -1. Uses a generous radius so a unit is
## easy to hit at any zoom.
func unit_at(world_point: Vector2, pick_radius: float = 2.4) -> int:
	if simulator == null:
		return -1
	var best := -1
	var best_distance := pick_radius
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		var distance := world_point.distance_to(unit.position)
		if distance <= best_distance:
			best_distance = distance
			best = unit.id
	return best


## Every alive unit inside a rectangle (box selection).
func units_in_rect(rect: Rect2) -> Array[int]:
	var out: Array[int] = []
	if simulator == null:
		return out
	for unit in simulator.units:
		if unit.is_alive() and rect.has_point(unit.position):
			out.append(unit.id)
	return out
