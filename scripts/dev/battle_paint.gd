extends Node2D
## The marks a commander makes on the ground: which formations are in his hand, where he has told
## them to go, and the box he is dragging around them.
##
## It is a child of the view root and speaks world coordinates, so the one transform that lays the
## ground down lays these on it: the marks cannot end up beside the field they belong to, and
## panning, turning and zooming do not have to be told about them. Nothing here is drawn in screen
## space, and nothing here exists in the simulation - a mark is a mark.
##
## The arrays are refilled by the battle every frame and the layer redraws itself. Keeping the two
## in one file would have been shorter, but the marks outlive any one battle: the deployment screen,
## the order previews and the selection rings all want the same painter.

## Each entry: [from: Vector2, to: Vector2, colour: Color, width: float, dash: float]. A dash of
## zero draws a solid line; anything else draws dashes of that length in world units.
var lines: Array = []
## Each entry: [rect: Rect2, colour: Color, line_width: float, fill_alpha: float].
var rects: Array = []


func _draw() -> void:
	for entry in lines:
		var from: Vector2 = entry[0]
		var to: Vector2 = entry[1]
		var colour: Color = entry[2]
		var width: float = entry[3]
		var dash: float = entry[4]
		if dash <= 0.0:
			draw_line(from, to, colour, width)
			continue
		# Dashes are measured in world units so an order line stays the same length of dash
		# however far the camera is zoomed in. Drawn as separate segments, because draw_line
		# has no dash pattern of its own and faking one with a shader would be a texture
		# the marks do not need.
		var span := from.distance_to(to)
		if span < 0.001:
			continue
		var dir := (to - from) / span
		var walked := 0.0
		while walked < span:
			var end := minf(walked + dash, span)
			draw_line(from + dir * walked, from + dir * end, colour, width)
			walked = end + dash
	for entry in rects:
		var rect: Rect2 = entry[0]
		var colour: Color = entry[1]
		var width: float = entry[2]
		var fill_alpha: float = entry[3]
		draw_rect(rect, Color(colour.r, colour.g, colour.b, fill_alpha), true)
		if width > 0.0:
			draw_rect(rect, colour, false, width)
