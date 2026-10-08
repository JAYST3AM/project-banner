class_name BattleDeploymentOverlay
extends Node2D
## Pre-battle placement overlay. It draws only while the commander is
## deploying and never reads or changes simulation rules.
const FRIENDLY := Color("76b5cc")
const HOSTILE := Color("c48670")
const FIELD_EDGE := Color("dbc69a")
const MAX_DEPTH_FRACTION := 0.22
const LINE_TICK := 2.5


## Both scenery exclusion and visible deployment use the *same* world zones.
static func zones(field_size: Vector2, deploy_depth: float,
		deploy_margin: float) -> Array[Rect2]:
	var width := minf(maxf(0.0, field_size.x) * MAX_DEPTH_FRACTION,
		maxf(0.0, deploy_depth + deploy_margin))
	var result: Array[Rect2] = []
	result.append(Rect2(Vector2.ZERO,
		Vector2(width, maxf(0.0, field_size.y))))
	result.append(Rect2(Vector2(maxf(0.0, field_size.x - width), 0.0),
		Vector2(width, maxf(0.0, field_size.y))))
	return result


var _zones: Array[Rect2] = []
var _field_size := Vector2.ZERO


func configure(field_size: Vector2, deploy_depth: float, deploy_margin: float) -> void:
	_field_size = field_size
	_zones = zones(field_size, deploy_depth, deploy_margin)
	queue_redraw()


func _draw() -> void:
	if _zones.size() != 2:
		return
	for side in 2:
		var region := _zones[side]
		if region.size.x < 0.1:
			continue
		var colour := FRIENDLY if side == 0 else HOSTILE
		draw_rect(region, Color(colour.r, colour.g, colour.b, 0.085), true)
		# Exact deploy front: a thin command line with spaced pennants.
		var front := region.end.x if side == 0 else region.position.x
		draw_line(Vector2(front, 0.0), Vector2(front, _field_size.y),
			Color(colour.r, colour.g, colour.b, 0.85), 0.65, true)
		var y := LINE_TICK * 2.0
		while y < _field_size.y - LINE_TICK * 2.0:
			var sign := 1.0 if side == 0 else -1.0
			draw_line(Vector2(front, y),
				Vector2(front - sign * LINE_TICK, y + LINE_TICK * 0.5),
				colour, 0.55, true)
			y += LINE_TICK * 7.0
		# Label behind the line, away from the enemy. Remains part of the
		# field at every zoom level and vanishes once the battle starts.
		var label := "YOUR DEPLOYMENT" if side == 0 else "ENEMY DEPLOYMENT"
		var label_centre := region.get_center()
		draw_string(ThemeDB.fallback_font,
			label_centre + Vector2(-22.0, 0.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 3,
			Color(colour.r, colour.g, colour.b, 0.95))
