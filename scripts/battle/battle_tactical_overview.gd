class_name BattleTacticalOverview
extends Node2D
## View-only tactical map: one accurately rotated footprint per formation.
## The battle simulation and its positions never change when this is visible.

const FRIENDLY := Color("356b89")
const HOSTILE := Color("975045")
const SELECTED := Color("f0d18b")

var _formations: Array[Dictionary] = []
var _selected: Array[int] = []
var _font_world_size: int = 3


func set_formations(formations: Array[Dictionary], selected: Array[int], font_world_size: int) -> void:
	_formations = formations
	_selected = selected
	_font_world_size = maxi(2, font_world_size)
	queue_redraw()


func _draw() -> void:
	for body in _formations:
		if int(body.get("alive", 0)) <= 0:
			continue
		var body_id := int(body.get("id", -1))
		var friendly := int(body.get("side", 1)) == 0
		var anchor: Vector2 = body.get("anchor", Vector2.ZERO)
		var forward: Vector2 = body.get("forward", Vector2.RIGHT)
		if forward.length_squared() < 0.0001:
			forward = Vector2.RIGHT
		forward = forward.normalized()
		var half_depth := maxf(2.0, float(body.get("half_depth", 2.0)))
		var half_span := maxf(2.0, float(body.get("half_span", 2.0)))
		var chosen := friendly and _selected.has(body_id)
		var base := FRIENDLY if friendly else HOSTILE
		var border := SELECTED if chosen else base.lightened(0.40)
		var shape := Rect2(-half_depth, -half_span, half_depth * 2.0, half_span * 2.0)
		draw_set_transform(anchor, forward.angle(), Vector2.ONE)
		draw_rect(shape, Color(base.r, base.g, base.b, 0.85), true)
		draw_rect(shape, border, false, 0.85 if chosen else 0.40, true)
		# The direction marker follows the actual formation facing, not the camera.
		draw_line(Vector2.ZERO, Vector2(half_depth + 2.0, 0.0), border, 0.6, true)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		var label := "%s  %d" % [str(body.get("name", "")), int(body.get("alive", 0))]
		var label_pos := anchor + Vector2(-float(label.length()) * float(_font_world_size) * 0.25,
			-float(_font_world_size) * 0.35)
		draw_string(ThemeDB.fallback_font, label_pos, label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, _font_world_size, Color.WHITE)
