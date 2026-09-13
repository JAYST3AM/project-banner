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

var simulator: BattleSimulator = null
var context: BattleContext = null

## Ground is drawn from the simulation's terrain data, never the other way round.
var show_terrain: bool = true
## The development overlay: anchors, facing, target slots, formation bounds, cohesion.
var show_formation_debug: bool = false

var selected_ids: Array[int] = []

var box_select_active: bool = false
var box_select_rect: Rect2 = Rect2()

## Transient floating text (damage numbers, deaths), aged by _process.
var _popups: Array[Dictionary] = []
const POPUP_LIFETIME := 1.1
const POPUP_RISE := 2.6

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font


func _process(delta: float) -> void:
	if _popups.is_empty():
		return
	var kept: Array[Dictionary] = []
	for popup in _popups:
		popup["age"] = float(popup.get("age", 0.0)) + delta
		if float(popup["age"]) < POPUP_LIFETIME:
			kept.append(popup)
	_popups = kept
	queue_redraw()


## Consume a frame of simulator events and turn them into visual feedback.
func add_events(events: Array[Dictionary]) -> void:
	for event in events:
		match str(event.get("type", "")):
			"hit":
				_popups.append({
					"text": "-%d" % int(event.get("damage", 0)),
					"position": event.get("position", Vector2.ZERO),
					"age": 0.0,
					"color": COLOR_GOLD if bool(event.get("ranged", false)) else Color("ffd9d0"),
				})
			"death":
				_popups.append({
					"text": "%s down" % str(event.get("unit_name", "")),
					"position": event.get("position", Vector2.ZERO),
					"age": 0.0,
					"color": COLOR_ENEMY.lightened(0.25),
				})


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

	for unit in simulator.units:
		if unit.is_alive():
			_draw_unit(unit)
		else:
			_draw_fallen(unit)

	if show_formation_debug:
		_draw_formation_labels()

	if box_select_active:
		draw_rect(box_select_rect, COLOR_GOLD.darkened(0.2), false, 0.18)
		draw_rect(box_select_rect, Color(COLOR_GOLD.r, COLOR_GOLD.g, COLOR_GOLD.b, 0.12))

	_draw_popups()


## One rectangle per terrain cell, shaded by elevation. Coarse on purpose - the cell
## size is the simulation's, not a pixel's - and cheap, because the cells are few.
func _draw_terrain() -> void:
	var terrain := simulator.terrain
	var tallest := maxf(0.001, terrain.max_height())
	for index in terrain.cell_count():
		var colour := terrain.colour_of_cell(index)
		# A little elevation shading so the shape of the ground reads at a glance
		# without needing a legend.
		var relief := terrain.height_of_cell(index) / tallest
		if relief > 0.5:
			colour = colour.lightened((relief - 0.5) * 0.55)
		else:
			colour = colour.darkened((0.5 - relief) * 0.45)
		draw_rect(terrain.cell_rect(index), colour)


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
		var life := float(popup.get("age", 0.0)) / POPUP_LIFETIME
		var colour: Color = popup.get("color", COLOR_TEXT)
		colour.a = clampf(1.0 - life, 0.0, 1.0)
		var size := 26
		var text := str(popup.get("text", ""))
		var position: Vector2 = popup.get("position", Vector2.ZERO)
		position.y -= life * POPUP_RISE
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
