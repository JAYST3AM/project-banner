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

var simulator: BattleSimulator = null
var context: BattleContext = null

var selected_ids: Array[int] = []

var box_select_active: bool = false
var box_select_rect: Rect2 = Rect2()

var _font: Font = null


func _ready() -> void:
	_font = ThemeDB.fallback_font


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

	# Ground
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_GROUND)
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_GROUND_EDGE, false, 0.4)

	# Centre line and deployment bounds, so the layout is legible before the fight
	var centre := size.x * 0.5
	draw_line(Vector2(centre, 0.0), Vector2(centre, size.y), COLOR_LINE, 0.15)
	draw_dashed_line(Vector2(centre, 0.0), Vector2(centre, size.y), COLOR_LINE.lightened(0.2), 0.1, 1.6)

	for unit in simulator.units:
		if unit.is_alive():
			_draw_unit(unit)
		else:
			_draw_fallen(unit)

	if box_select_active:
		draw_rect(box_select_rect, COLOR_GOLD.darkened(0.2), false, 0.18)
		draw_rect(box_select_rect, Color(COLOR_GOLD.r, COLOR_GOLD.g, COLOR_GOLD.b, 0.12))


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

	if unit.has_move_order:
		draw_dashed_line(position, unit.move_order, COLOR_GOLD.darkened(0.25), 0.16, 1.2)


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
