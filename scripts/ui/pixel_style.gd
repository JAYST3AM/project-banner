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
	box.content_margin_left = 14.0
	box.content_margin_right = 14.0
	box.content_margin_top = 8.0
	box.content_margin_bottom = 8.0
	return box


## The four states of a button, in the order Godot wants them: normal, hover, pressed, disabled.
## One palette, four moods, and the accent is spent on the only state that is answering the mouse.
static func button_styles(body: Color, light: Color, dark: Color, accent: Color,
		outline: Color) -> Dictionary:
	return {
		"normal": button_style(body, light, dark, outline),
		"hover": button_style(body.lightened(0.10), accent, dark, accent),
		"pressed": button_style(body.darkened(0.12), light, dark, outline, true),
		"disabled": button_style(body.darkened(0.35), light.darkened(0.4), dark.darkened(0.3),
			outline.darkened(0.2)),
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
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_color_override("font_color", text_colour)
	button.add_theme_color_override("font_hover_color", text_colour)
	button.add_theme_color_override("font_pressed_color", text_colour)
	button.add_theme_color_override("font_focus_color", text_colour)
	button.add_theme_color_override("font_disabled_color", dim_colour)


static func pixel_font() -> Font:
	if ResourceLoader.exists(FONT_PATH):
		return load(FONT_PATH) as Font
	return null
