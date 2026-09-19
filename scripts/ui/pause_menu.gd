class_name PauseMenu
extends Control
## The Esc menu.
##
## The same language as the front screen - a painted valley, a pixel-art column of buttons on the
## quiet side of it - with different words, because a menu you reach from inside a campaign has a
## different question to answer. Nothing here is a new pattern: it dresses itself with [PixelStyle]
## and hands its three decisions back to the screen that owns the campaign, so saving and leaving
## happen through exactly the code paths the on-screen Actions panel already uses.
##
## It pauses the tree while it is open. That is the honest pause: the campaign's clock runs on
## process, so stopping process stops the world - and this menu keeps working because it is set to
## run while everything else is stopped.

const BACKGROUND_PATH := "res://assets/ui/pause_menu_bg.png"
const COLUMN_WIDTH := 372.0
const BUTTON_WIDTH := 240.0
const TITLE_SIZE := 42
const BUTTON_SIZE := 15
const BUTTON_HEIGHT := 46.0
const SMALL_SIZE := 12

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const SCRIM := Color(0.03, 0.04, 0.06, 0.88)

## Asked for by the screen that owns the campaign. Saving and leaving are its business, not this
## menu's: it says what the player chose and gets out of the way.
signal save_requested
signal menu_requested
signal quit_requested

var _font: Font = null
var _settings: SettingsPanel = null
var _resume_button: Button = null
var _status: Label = null
var _column: VBoxContainer = null
var _styles: Dictionary = {}


func _ready() -> void:
	visible = false
	# Runs while the tree is paused, which is the whole point of it.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Anchors *and* offsets. Under a CanvasLayer there is no parent rect for anchors alone to work
	# out, so a preset that only sets anchors leaves this screen zero pixels wide: the background
	# texture loaded and was never drawn, while the buttons showed, because a button carries its own
	# minimum size and a picture does not. Measured: node (0.0, 0.0), texture (1672.0, 941.0).
	_fill_viewport()
	get_viewport().size_changed.connect(_fill_viewport)
	_font = PixelStyle.pixel_font()
	var styles := PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	_build(styles)
	# A committed UI-scale change rebuilds the column at the new size (D-137 follow-up).
	GameSettings.ui_scale_committed.connect(_rebuild_column)


func _fill_viewport() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _build(styles: Dictionary) -> void:
	var picture := TextureRect.new()
	picture.name = "Background"
	if ResourceLoader.exists(BACKGROUND_PATH):
		picture.texture = load(BACKGROUND_PATH)
	picture.set_anchors_preset(Control.PRESET_FULL_RECT)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	# Named and checked out loud: a background that silently does not appear is indistinguishable
	# from one that was never asked for, and the owner's report was exactly that.
	picture.ready.connect(func() -> void:
		DebugLogger.info("pause menu: background %s, node %s, texture %s" % [
			"loaded" if picture.texture != null else "MISSING at " + BACKGROUND_PATH,
			str(picture.size),
			str(picture.texture.get_size()) if picture.texture != null else "none"], "PauseMenu"))
	if picture.texture != null:
		add_child(picture)

	var fade := Gradient.new()
	fade.colors = PackedColorArray([SCRIM, SCRIM, Color(SCRIM.r, SCRIM.g, SCRIM.b, 0.5), Color(0, 0, 0, 0)])
	fade.offsets = PackedFloat32Array([0.0, 0.3, 0.55, 0.8])
	var gradient := GradientTexture2D.new()
	gradient.gradient = fade
	gradient.fill_from = Vector2(0.0, 0.5)
	gradient.fill_to = Vector2(1.0, 0.5)
	gradient.width = 256
	gradient.height = 4
	var scrim := TextureRect.new()
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim.stretch_mode = TextureRect.STRETCH_SCALE
	scrim.texture = gradient
	add_child(scrim)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 68)
	margin.add_theme_constant_override("margin_right", 24)
	add_child(margin)
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 8)
	column.custom_minimum_size = Vector2(COLUMN_WIDTH, 0)
	column.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	margin.add_child(column)
	_column = column
	_styles = styles
	_fill_column()

	# The shared settings panel (D-137), centred over the column. It takes its own Esc, so opening
	# it from here never closes the pause menu with it.
	_settings = SettingsPanel.new()
	add_child(_settings)


func _fill_column() -> void:
	_column.add_child(_label("PAUSED", TITLE_SIZE, UiTheme.GOLD))
	_column.add_child(_label("The world waits.", SMALL_SIZE, Color(0.72, 0.74, 0.78)))
	_column.add_child(_gap(18))

	_resume_button = _button("Resume", _styles)
	_resume_button.pressed.connect(close)
	_column.add_child(_resume_button)
	var save_button := _button("Save Game", _styles)
	save_button.pressed.connect(_on_save)
	_column.add_child(save_button)
	var settings_button := _button("Settings", _styles)
	settings_button.pressed.connect(_on_settings)
	_column.add_child(settings_button)
	var menu_button := _button("Save & Quit to Menu", _styles)
	menu_button.pressed.connect(_on_menu)
	_column.add_child(menu_button)
	var quit_button := _button("Quit to Desktop", _styles)
	quit_button.pressed.connect(_on_quit)
	_column.add_child(quit_button)
	_column.add_child(_gap(10))

	_status = _label("Esc resumes.", SMALL_SIZE, Color(0.66, 0.68, 0.72))
	_column.add_child(_status)


## Build the column again at the current scale (D-137 follow-up). The settings panel is a sibling of
## the column, so it keeps its place and its open state while the column's own words re-set around
## it.
func _rebuild_column() -> void:
	if _column == null:
		return
	var status_text := _status.text if _status != null else "Esc resumes."
	for child in _column.get_children():
		_column.remove_child(child)
		child.queue_free()
	_fill_column()
	_status.text = status_text


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


## Whether the world is currently stopped for this menu.
func is_open() -> bool:
	return visible


func open() -> void:
	if visible:
		return
	visible = true
	get_tree().paused = true
	if _resume_button != null:
		_resume_button.grab_focus()
	DebugLogger.info("pause menu opened", "PauseMenu")


func close() -> void:
	if not visible:
		return
	visible = false
	get_tree().paused = false
	DebugLogger.info("pause menu closed", "PauseMenu")


## A line for the player, used for the one thing that can go wrong in here: a save that failed.
func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func _on_save() -> void:
	save_requested.emit()


func _on_settings() -> void:
	if _settings != null:
		_settings.open()


## Leaving the campaign unpauses first: a paused tree would follow the new scene into the menu and
## freeze it, which is how a quit-to-menu turns into a hang.
func _on_menu() -> void:
	get_tree().paused = false
	menu_requested.emit()


func _on_quit() -> void:
	get_tree().paused = false
	quit_requested.emit()


# ---------------------------------------------------------------------------------------------

func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", PixelStyle.scaled(size))
	label.add_theme_color_override("font_color", colour)
	return label


func _gap(height: int) -> Control:
	var space := Control.new()
	space.custom_minimum_size = Vector2(0, float(PixelStyle.scaled(height)))
	return space


func _button(text: String, styles: Dictionary) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = PixelStyle.scaled_vec(Vector2(BUTTON_WIDTH, BUTTON_HEIGHT))
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	PixelStyle.dress_button(button, styles, _font, BUTTON_SIZE, UiTheme.TEXT,
		Color(0.45, 0.47, 0.51))
	return button
