class_name SpeedGlyph
extends Control
## One of the three time controls, drawn as pixels rather than typed as a character: the pixel font
## has no media symbols, and hand-placed rectangles stay crisp at every UI scale - which is the
## whole point of the owner's ask ("I want symbols not words").
##
## The symbol carries the state: dim ink when its speed is not the current one, gold when it is.

enum Symbol { PAUSE, PLAY, FAST }

## One glyph-pixel, before the UI scale multiplies it.
const UNIT := 2.5

var symbol := Symbol.PAUSE
var ink := Color.WHITE:
	set(value):
		ink = value
		queue_redraw()


func _init(glyph := Symbol.PAUSE) -> void:
	symbol = glyph
	# The button under this is what takes the mouse; the symbol is only a face.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _draw() -> void:
	var u: float = UNIT * PixelStyle.ui_scale
	var mid := size * 0.5
	match symbol:
		Symbol.PAUSE:
			draw_rect(Rect2(mid.x - u * 4.0, mid.y - u * 3.5, u * 3.0, u * 7.0), ink, true)
			draw_rect(Rect2(mid.x + u * 1.0, mid.y - u * 3.5, u * 3.0, u * 7.0), ink, true)
		Symbol.PLAY:
			_draw_arrow(mid - Vector2(u * 2.0, u * 4.0), u, 1)
		Symbol.FAST:
			_draw_arrow(mid - Vector2(u * 4.5, u * 4.0), u, 2)


## A stepped right-pointing arrow: eight one-unit rows, so the diagonal is drawn in pixels rather
## than smoothed. A second copy follows the first for "faster".
func _draw_arrow(origin: Vector2, u: float, count: int) -> void:
	var widths := [1, 2, 3, 4, 4, 3, 2, 1]
	for copy in count:
		var base := origin + Vector2(float(copy) * u * 5.0, 0.0)
		for row in widths.size():
			draw_rect(Rect2(base.x, base.y + float(row) * u, float(widths[row]) * u, u), ink, true)
