class_name BattleTacticalOverview
extends Node2D
## Unified formation readability across two tactical zoom levels.
## At middle distance, translucent unit standards and selected footprints
## augment soldier sprites. At full-map zoom, oriented unit blocks replace them.
## Both use one formation snapshot from the actual simulation.
const FRIENDLY := Color("376e84")
const HOSTILE := Color("985348")
const SELECTED := Color("f0cf88")
const LETTERING := Color("e9e6dc")
const INK := Color("111711")
const STRENGTH := Color("9dc0a6")
const LOW_STRENGTH := Color("bb7f64")

var _formations: Array[Dictionary] = []
var _selected: Array[int] = []
var _font_world_size := 3
var _full_map := true


static func strength_fraction(alive: int, started: int) -> float:
	return clampf(float(maxi(0, alive)) / float(maxi(1, started)), 0.0, 1.0)


func set_formations(formations: Array[Dictionary], selected: Array[int],
		font_world_size: int, full_map: bool = true) -> void:
	_formations = formations
	_selected = selected
	_font_world_size = maxi(2, font_world_size)
	_full_map = full_map
	queue_redraw()


func _draw() -> void:
	for body in _formations:
		if int(body.get("alive", 0)) <= 0:
			continue
		var id := int(body.get("id", -1))
		var friendly := int(body.get("side", 1)) == 0
		var chosen := friendly and _selected.has(id)
		var anchor: Vector2 = body.get("anchor", Vector2.ZERO)
		var forward: Vector2 = body.get("forward", Vector2.RIGHT)
		if forward.length_squared() < 0.0001:
			forward = Vector2.RIGHT
		forward = forward.normalized()
		var span := maxf(2.0, float(body.get("half_span", 2.0)))
		var depth := maxf(2.0, float(body.get("half_depth", 2.0)))
		var colour := FRIENDLY if friendly else HOSTILE
		var alive := int(body.get("alive", 0))
		var strength := strength_fraction(alive, int(body.get("started", alive)))
		if _full_map:
			_draw_full_body(anchor, forward, depth, span, colour, chosen, strength,
				str(body.get("type_key", "")))
		else:
			_draw_medium_body(anchor, forward, depth, span, colour, chosen)
		_draw_identity(anchor, maxf(span, depth), colour, chosen,
			str(body.get("name", "Unit")), alive, _full_map)


func _draw_full_body(anchor: Vector2, forward: Vector2, half_depth: float,
		half_span: float, colour: Color, chosen: bool, strength: float,
		type_key: String) -> void:
	draw_set_transform(anchor, forward.angle(), Vector2.ONE)
	var footprint := Rect2(-half_depth, -half_span, half_depth * 2.0, half_span * 2.0)
	draw_rect(footprint, Color(colour.r, colour.g, colour.b, 0.89), true)
	var border := SELECTED if chosen else colour.lightened(0.40)
	draw_rect(footprint, border, false, 0.95 if chosen else 0.50, true)
	# Front-facing command bar: an anchored head line is clearer than a floating arrow.
	draw_line(Vector2(half_depth, -half_span),
		Vector2(half_depth, half_span), border, 0.95, true)
	draw_line(Vector2.ZERO, Vector2(half_depth + 2.0, 0.0),
		border, 0.7, true)
	# Stripe length reports *actual surviving strength*, never a placeholder
	# morale percentage. The bottom edge makes it readable on dense maps.
	var stripe_height := clampf(half_span * 0.19, 0.5, 1.35)
	var total_width := maxf(0.5, half_depth * 2.0 - 0.8)
	draw_rect(Rect2(-half_depth + 0.4, half_span - stripe_height - 0.35,
		total_width, stripe_height), INK, true)
	if strength > 0.0:
		draw_rect(Rect2(-half_depth + 0.4, half_span - stripe_height - 0.35,
			total_width * strength, stripe_height),
			STRENGTH if strength >= 0.45 else LOW_STRENGTH, true)
	# Simple tactical symbol made from lines, not a fantasy unit icon.
	var across := 0.0
	if "archer" in type_key or "bow" in type_key:
		draw_arc(Vector2(across, -0.3), 1.3, -PI * 0.55, PI * 0.55,
			8, LETTERING, 0.5, true)
	elif "spear" in type_key:
		draw_line(Vector2(-1.0, -1.2), Vector2(1.5, 1.2),
			LETTERING, 0.45, true)
		draw_line(Vector2(-1.0, 1.2), Vector2(1.5, -1.2),
			LETTERING, 0.45, true)
	else:
		draw_line(Vector2(-1.0, 0.0), Vector2(1.1, 0.0),
			LETTERING, 0.55, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_medium_body(anchor: Vector2, forward: Vector2, half_depth: float,
		half_span: float, colour: Color, chosen: bool) -> void:
	draw_set_transform(anchor, forward.angle(), Vector2.ONE)
	var footprint := Rect2(-half_depth, -half_span, half_depth * 2.0, half_span * 2.0)
	if chosen:
		draw_rect(footprint, Color(SELECTED.r, SELECTED.g, SELECTED.b, 0.075), true)
		draw_rect(footprint, SELECTED, false, 0.55, true)
		# Dashed? A solid front rank and two short end ticks stay legible with no shimmer.
		draw_line(Vector2(half_depth, -half_span),
			Vector2(half_depth, half_span), SELECTED, 0.9, true)
	else:
		var dim := colour.darkened(0.22)
		draw_line(Vector2(half_depth, -half_span),
			Vector2(half_depth, half_span), Color(dim.r, dim.g, dim.b, 0.60),
			0.45, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_identity(anchor: Vector2, extent: float, colour: Color,
		chosen: bool, name: String, alive: int, full_map: bool) -> void:
	var font_size := _font_world_size
	var text := "%s  %d" % [name, alive]
	var text_width := maxf(12.0, float(text.length()) * float(font_size) * 0.56)
	var badge_size := Vector2(text_width + font_size * 1.0, font_size * 1.6)
	# Keep text horizontal even if a formation is rotated.
	var top := anchor + Vector2(-badge_size.x * 0.5,
		-extent - badge_size.y * (1.55 if not full_map else 1.10))
	var colour_bg := Color(INK.r, INK.g, INK.b, 0.91 if chosen else 0.72)
	draw_rect(Rect2(top, badge_size), colour_bg, true)
	draw_rect(Rect2(top, badge_size), SELECTED if chosen else colour.lightened(0.3),
		false, 0.35, true)
	draw_string(ThemeDB.fallback_font,
		top + Vector2(font_size * 0.5, float(font_size) * 1.19),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, LETTERING)
