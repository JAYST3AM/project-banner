class_name UiTheme
extends RefCounted
## Shared colours and control factories for code-built UI.
##
## Prototype screens build their contents in script (which keeps HUD logic in one
## readable place and out of hand-edited .tscn files); this class is what stops
## every screen inventing its own shade of grey.

const BG := Color("10141a")
const PANEL := Color("1a1f27")
const PANEL_DEEP := Color("141922")
const BORDER := Color("39424f")
const TEXT := Color("e8eaed")
const DIM := Color("93a0ad")
const ACCENT := Color("e8823c")
const GOLD := Color("e8ce8c")
const GOOD := Color("7fc97f")
const BAD := Color("e06c6c")
const PLAYER := Color("4fa8e0")


static func panel_style(background: Color = PANEL) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	return style


static func label(text: String, size: int = 15, color: Color = TEXT) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	return node


static func header(text: String, size: int = 18) -> Label:
	return label(text.to_upper(), size, ACCENT)


static func dim_label(text: String = "") -> Label:
	return label(text, 13, DIM)


static func value_label(text: String = "") -> Label:
	return label(text, 15, TEXT)


static func button(text: String, min_width: float = 0.0) -> Button:
	var node := Button.new()
	node.text = text
	node.add_theme_font_size_override("font_size", 14)
	if min_width > 0.0:
		node.custom_minimum_size = Vector2(min_width, 32.0)
	return node


static func hseparator() -> HSeparator:
	return HSeparator.new()


static func heading_rule() -> ColorRect:
	var rect := ColorRect.new()
	rect.color = BORDER
	rect.custom_minimum_size = Vector2(0.0, 1.0)
	return rect
