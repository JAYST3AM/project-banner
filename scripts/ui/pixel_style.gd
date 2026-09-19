class_name PixelStyle
extends RefCounted
## Pixel-art furniture for the interface, drawn a pixel at a time and scaled as pixels.
##
## The world is painted and the interface was flat: two different games stapled together. These are
## the two pieces a screen needs to look like it belongs to that world without pretending to be a
## painting - a button and a panel - and both are the same idiom: a small image on an integer grid,
## handed to the interface as a nine-patch, so the border stays exactly as many pixels wide however
## large the thing it is drawn around grows.
##
## The one rule that makes it read as pixel art rather than as a blurry button: nearest filtering.
## Every node that draws one of these must set its texture filter to nearest, or the GPU will
## politely smooth the whole point of it away.

const BUTTON_PIXELS := 16
## How much of each edge is a corner. Five of sixteen leaves six pixels to stretch.
const BUTTON_MARGIN := 5
const PANEL_PIXELS := 16
const PANEL_MARGIN := 4
const FONT_PATH := "res://assets/fonts/Silkscreen-Regular.ttf"
## Body text is set in a real serif, not the pixel face. The owner, looking at the first mock:
## "descriptions need to not be everywhere, you kind of throw text everywhere but can be helpful
## just maybe a hover tool tip maybe?" Silkscreen carries headers, buttons, prices and numeric
## values; anything read as a sentence is set here, because a 5x7 pixel font turns a paragraph
## into a maze.
const BODY_FONT_PATH := "res://assets/fonts/EBGaramond-Regular.ttf"
const BODY_FONT_ITALIC_PATH := "res://assets/fonts/EBGaramond-Italic.ttf"

## What every interface size in this file is multiplied by, set from GameSettings when the player
## moves the UI scale slider (D-137 follow-up). A static, because screens read it while they build:
## a theme that already exists cannot be re-scaled, so the honest model is "the next screen built
## wears the new size". Everything below rounds, so a pixel font never lands on a half size.
static var ui_scale := 1.0


## A base size, scaled. Public so screens with their own label helpers (the menus) can pass their
## sizes through the same arithmetic.
static func scaled(base: int) -> int:
	return maxi(6, int(round(float(base) * ui_scale)))


static func scaled_vec(base: Vector2) -> Vector2:
	return Vector2(roundf(base.x * ui_scale), roundf(base.y * ui_scale))


## A button: a one-pixel outline, a two-pixel bevel that catches the light on the top and left, and
## a flat body. The bevel is the whole illusion - swap it and the same shape reads as pressed.
static func button_style(body: Color, light: Color, dark: Color, outline: Color,
		bevel_in := false) -> StyleBoxTexture:
	var image := Image.create_empty(BUTTON_PIXELS, BUTTON_PIXELS, false, Image.FORMAT_RGBA8)
	var last := BUTTON_PIXELS - 1
	for y in BUTTON_PIXELS:
		for x in BUTTON_PIXELS:
			var colour := body
			if x == 0 or y == 0 or x == last or y == last:
				colour = outline
			elif x <= 2 or y <= 2:
				colour = dark if bevel_in else light
			elif x >= last - 2 or y >= last - 2:
				colour = light if bevel_in else dark
			image.set_pixel(x, y, colour)
	return _nine_patch(image, BUTTON_MARGIN)


## A panel: the same language with a quieter edge, for anything that is not a thing you press.
static func panel_style(body: Color, edge: Color, outline: Color) -> StyleBoxTexture:
	var image := Image.create_empty(PANEL_PIXELS, PANEL_PIXELS, false, Image.FORMAT_RGBA8)
	var last := PANEL_PIXELS - 1
	for y in PANEL_PIXELS:
		for x in PANEL_PIXELS:
			var colour := body
			if x == 0 or y == 0 or x == last or y == last:
				colour = outline
			elif x == 1 or y == 1 or x == last - 1 or y == last - 1:
				colour = edge
			image.set_pixel(x, y, colour)
	return _nine_patch(image, PANEL_MARGIN)


static func _nine_patch(image: Image, margin: int) -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.texture = ImageTexture.create_from_image(image)
	box.texture_margin_left = float(margin)
	box.texture_margin_right = float(margin)
	box.texture_margin_top = float(margin)
	box.texture_margin_bottom = float(margin)
	box.content_margin_left = roundf(14.0 * ui_scale)
	box.content_margin_right = roundf(14.0 * ui_scale)
	box.content_margin_top = roundf(8.0 * ui_scale)
	box.content_margin_bottom = roundf(8.0 * ui_scale)
	return box


## The four states of a button, in the order Godot wants them: normal, hover, pressed, disabled.
## One palette, four moods, and the accent is spent on the only state that is answering the mouse.
static func button_styles(body: Color, light: Color, dark: Color, accent: Color,
		outline: Color) -> Dictionary:
	return {
		"normal": button_style(body, light, dark, outline),
		"hover": button_style(body.lightened(0.10), accent, dark, accent),
		"pressed": button_style(body.darkened(0.12), light, dark, outline, true),
		"disabled": button_style(body.darkened(0.5), light.darkened(0.6), dark.darkened(0.4),
			outline.darkened(0.35)),
	}


## The whole set applied to one button, so a caller says "this is a button" once.
static func dress_button(button: Button, styles: Dictionary, font: Font, font_size: int,
		text_colour: Color, dim_colour: Color) -> void:
	button.add_theme_stylebox_override("normal", styles["normal"])
	button.add_theme_stylebox_override("hover", styles["hover"])
	button.add_theme_stylebox_override("pressed", styles["pressed"])
	button.add_theme_stylebox_override("disabled", styles["disabled"])
	button.add_theme_stylebox_override("focus", styles["hover"])
	if font != null:
		button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", scaled(font_size))
	button.add_theme_color_override("font_color", text_colour)
	button.add_theme_color_override("font_hover_color", text_colour)
	button.add_theme_color_override("font_pressed_color", text_colour)
	button.add_theme_color_override("font_focus_color", text_colour)
	button.add_theme_color_override("font_disabled_color", dim_colour)


static func body_font(italic := false) -> Font:
	var path := BODY_FONT_ITALIC_PATH if italic else BODY_FONT_PATH
	if ResourceLoader.exists(path):
		return load(path) as Font
	return null


## A label set in the serif: names, sentences, records.
static func body_label(text: String, size: int = 14, colour: Color = Color.WHITE,
		italic := false) -> Label:
	var node := Label.new()
	node.text = text
	var font := body_font(italic)
	if font != null:
		node.add_theme_font_override("font", font)
	node.add_theme_font_size_override("font_size", scaled(size))
	node.add_theme_color_override("font_color", colour)
	return node


## A label set in the interface's own voice: headers, buttons, prices, stat values. Numbers in
## Silkscreen scan better than numbers in a serif, which is the whole reason the pixel face stays.
static func pixel_label(text: String, size: int = 10, colour: Color = Color.WHITE) -> Label:
	var node := Label.new()
	node.text = text
	var font := pixel_font()
	if font != null:
		node.add_theme_font_override("font", font)
	node.add_theme_font_size_override("font_size", scaled(size))
	node.add_theme_color_override("font_color", colour)
	return node


## A stat chip: a small boxed value - "HP 28", "ATK 6". Five chips in a row answer the five
## questions a recruit card asks faster than a sentence does.
static func chip(label_text: String, value_text: String, body: Color, edge: Color,
		label_colour: Color, value_colour: Color) -> Control:
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = body
	style.border_color = edge
	style.set_border_width_all(1)
	style.set_corner_radius_all(0)
	style.content_margin_left = 6.0
	style.content_margin_right = 6.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	box.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	box.add_child(row)
	if not label_text.is_empty():
		row.add_child(pixel_label(label_text.to_upper(), 9, label_colour))
	if not value_text.is_empty():
		row.add_child(pixel_label(value_text, 10, value_colour))
	return box


## One row of chips, from pairs: [["HP", "28"], ["ATK", "6"], ...].
static func chip_row(entries: Array, body: Color, edge: Color, label_colour: Color,
		value_colour: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	for entry in entries:
		var pair: Array = entry
		row.add_child(chip(str(pair[0]), str(pair[1]), body, edge, label_colour, value_colour))
	return row


## A divider in the pixel language: two pixels of shade, not a hairline.
static func rule(colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = colour
	rect.custom_minimum_size = Vector2(0.0, maxf(2.0, roundf(2.0 * ui_scale)))
	return rect


## Tooltips carry what the lean layout leaves out, so they have to look like the game: one theme
## set on a screen's root styles every tooltip inside it, popover included.
static func tooltip_theme(body: Color, edge: Color, text_colour: Color) -> Theme:
	var theme := Theme.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = body
	panel.border_color = edge
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(0)
	panel.content_margin_left = 10.0
	panel.content_margin_right = 10.0
	panel.content_margin_top = 8.0
	panel.content_margin_bottom = 8.0
	theme.set_stylebox("panel", "TooltipPanel", panel)
	var font := body_font()
	if font != null:
		theme.set_font("font", "TooltipLabel", font)
	theme.set_font_size("font_size", "TooltipLabel", scaled(14))
	theme.set_color("font_color", "TooltipLabel", text_colour)
	return theme


## A panel in the pixel furniture, in one call.
static func dressed_panel(body: Color, edge: Color, outline: Color,
		min_size := Vector2.ZERO) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style(body, edge, outline))
	panel.custom_minimum_size = min_size
	return panel


## A button in the pixel furniture, in one call: dress it and size it, nothing else.
static func text_button(text: String, styles: Dictionary, font_size: int, min_size: Vector2,
		text_colour: Color, dim_colour: Color) -> Button:
	var node := Button.new()
	node.text = text
	dress_button(node, styles, pixel_font(), font_size, text_colour, dim_colour)
	node.custom_minimum_size = scaled_vec(min_size)
	return node


## label left (serif, dim, taking the slack), value right (usually Silkscreen): the shape every
## stat line in the interface shares, so the numbers line up down the panel edge.
static func stat_row(label_text: String, value: Label, label_size := 14,
		label_colour := Color(0.58, 0.63, 0.68)) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := body_label(label_text, label_size, label_colour)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	row.add_child(value)
	return row


static func pixel_font() -> Font:
	if ResourceLoader.exists(FONT_PATH):
		return load(FONT_PATH) as Font
	return null
