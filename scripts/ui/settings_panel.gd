class_name SettingsPanel
extends PanelContainer
## The Settings screen, shared by the main menu and the Esc menu (D-137).
##
## Cycle rows and one slider. Every change applies and saves the moment it is made - there is no OK
## button, because there is nothing to confirm: the screen behind the panel is already showing the
## answer.
##
## The UI scale is the one setting the panel itself demonstrates: moving the slider rescales the
## panel's own text when the handle is released (`drag_ended`), because a theme that has already
## been built cannot be re-scaled, and the honest model is "the next thing built wears the new
## size". Other screens pick it up as they are opened.
##
## Esc closes this panel and nothing else: it handles the key in `_input`, which runs before any
## `_unhandled_input`, so the Esc menu underneath keeps its own Esc for itself.

signal closed

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.075, 0.088, 0.11)

const PANEL_WIDTH := 560.0

var _window_button: Button = null
var _window_size_button: Button = null
var _scale_slider: HSlider = null
var _scale_value: Label = null
var _vsync_button: Button = null
var _fps_button: Button = null
var _overlay_button: Button = null
var _hints_button: Button = null
var _status: Label = null
var _box: VBoxContainer = null
var _styles: Dictionary = {}


func _init() -> void:
	add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.5), OUTLINE))
	custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	# Centred over whatever opened it, nudged right so it never sits over the menu column's own
	# words, running while the tree may be paused.
	set_anchors_preset(Control.PRESET_CENTER)
	offset_left = -PANEL_WIDTH * 0.5 + 80.0
	offset_right = PANEL_WIDTH * 0.5 + 80.0
	offset_top = -250.0
	offset_bottom = 250.0
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_rebuild()


## Everything in the panel is built here, at the current UI scale, so rebuilding is also how the
## panel shows a scale change.
func _rebuild() -> void:
	if _box != null:
		remove_child(_box)
		_box.queue_free()
	_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	theme = PixelStyle.tooltip_theme(BODY, LIGHT.darkened(0.45), UiTheme.TEXT)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 9)
	add_child(_box)

	_box.add_child(PixelStyle.pixel_label("SETTINGS", 16, UiTheme.GOLD))
	_box.add_child(PixelStyle.rule(DARK))

	_window_button = _setting_row("Window", _cycle_window)
	_window_size_button = _setting_row("Window size", _cycle_window_size,
		"Applies in Windowed mode.")
	_scale_slider = _slider_row()
	_box.add_child(PixelStyle.rule(DARK))
	_vsync_button = _setting_row("VSync", _cycle_vsync)
	_fps_button = _setting_row("Frame cap", _cycle_fps)
	_box.add_child(PixelStyle.rule(DARK))
	_overlay_button = _setting_row("Frame-rate overlay", _cycle_overlay,
		"Shows on start. F1 always toggles it by hand.")
	_hints_button = _setting_row("Map hints", _cycle_hints,
		"The one-line hint under the time controls. Applies on the next entry to the map.")

	_box.add_child(PixelStyle.rule(DARK))

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	_box.add_child(footer)
	_status = PixelStyle.body_label("", 12.5, UiTheme.DIM, true)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_child(_status)
	var close_button := PixelStyle.text_button("Close", _styles, 11, Vector2(110.0, 34.0),
		UiTheme.TEXT, UiTheme.DIM)
	close_button.pressed.connect(close)
	footer.add_child(close_button)

	_refresh()


## One settings row: the name in the serif, the current choice on a pixel button that cycles it.
func _setting_row(title: String, handler: Callable, tooltip := "") -> Button:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_box.add_child(row)
	var label := PixelStyle.body_label(title, 14, UiTheme.TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var button := PixelStyle.text_button("", _styles, 11, Vector2(200.0, 34.0),
		UiTheme.GOLD, UiTheme.DIM)
	button.pressed.connect(handler)
	row.add_child(button)
	if not tooltip.is_empty():
		label.tooltip_text = tooltip
		button.tooltip_text = tooltip
	return button


## The UI scale row: a dressed slider and the figure it currently stands at.
func _slider_row() -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_box.add_child(row)
	var label := PixelStyle.body_label("UI scale", 14, UiTheme.TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.tooltip_text = "Sizes the interface text and buttons. The panel itself redraws when you let go."
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = GameSettings.UI_SCALE_MIN
	slider.max_value = GameSettings.UI_SCALE_MAX
	slider.step = GameSettings.UI_SCALE_STEP
	slider.value = GameSettings.ui_scale
	slider.custom_minimum_size = Vector2(200.0, 28.0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.tooltip_text = label.tooltip_text
	_dress_slider(slider)
	slider.value_changed.connect(_on_scale_changed)
	slider.drag_ended.connect(_on_scale_released)
	row.add_child(slider)

	_scale_value = PixelStyle.pixel_label("%d%%" % int(round(GameSettings.ui_scale * 100.0)), 11,
		UiTheme.GOLD)
	_scale_value.custom_minimum_size = Vector2(56.0, 0.0)
	_scale_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_scale_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_scale_value)
	return slider


## A slider in the game's furniture: a dark trough, the accent as the filled part, and a solid
## grabber - two small textures, painted in code, because the interface ships no slider artwork.
func _dress_slider(slider: HSlider) -> void:
	var trough := StyleBoxFlat.new()
	trough.bg_color = DARK
	trough.border_color = LIGHT.darkened(0.5)
	trough.set_border_width_all(1)
	trough.content_margin_top = 8.0
	trough.content_margin_bottom = 8.0
	slider.add_theme_stylebox_override("slider", trough)
	var filled := StyleBoxFlat.new()
	filled.bg_color = UiTheme.ACCENT.darkened(0.2)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_stylebox_override("grabber_area_highlight", filled)
	slider.add_theme_icon_override("grabber", _block_texture(12, 26, UiTheme.GOLD))
	slider.add_theme_icon_override("grabber_highlight", _block_texture(12, 26, UiTheme.ACCENT))
	slider.add_theme_icon_override("grabber_pressed", _block_texture(12, 26, UiTheme.ACCENT))


func _block_texture(width: int, height: int, colour: Color) -> ImageTexture:
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	image.fill(colour)
	return ImageTexture.create_from_image(image)


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func open() -> void:
	# Rebuild on the way in: the scale may have changed under the panel's feet since last time, and
	# this is also what makes a scale change visible where it is made.
	_rebuild()
	visible = true
	_status.text = "Changes apply at once, and are remembered."
	_window_button.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


## ---------- the handlers: step or set, apply, save, reprint -----------------

func _cycle_window() -> void:
	GameSettings.window_index = GameSettings.next_index(GameSettings.window_index,
		GameSettings.WINDOW_LABELS.size())
	_apply_and_report()

func _cycle_window_size() -> void:
	GameSettings.window_size_index = GameSettings.next_index(GameSettings.window_size_index,
		GameSettings.WINDOW_SIZE_LABELS.size())
	_apply_and_report()

func _cycle_vsync() -> void:
	GameSettings.vsync_index = GameSettings.next_index(GameSettings.vsync_index,
		GameSettings.VSYNC_LABELS.size())
	_apply_and_report()

func _cycle_fps() -> void:
	GameSettings.fps_index = GameSettings.next_index(GameSettings.fps_index,
		GameSettings.FPS_LABELS.size())
	_apply_and_report()

func _cycle_overlay() -> void:
	GameSettings.show_perf_overlay = not GameSettings.show_perf_overlay
	_apply_and_report()

func _cycle_hints() -> void:
	GameSettings.show_hints = not GameSettings.show_hints
	_apply_and_report()


## While the handle moves: keep the service, the pixels and the file in step, but do not rebuild -
## rebuilding mid-drag would delete the slider being dragged.
func _on_scale_changed(value: float) -> void:
	GameSettings.ui_scale = value
	PixelStyle.ui_scale = value
	GameSettings.save_settings()
	_scale_value.text = "%d%%" % int(round(value * 100.0))


## On release: rebuild, which is how the panel shows the change it just made.
func _on_scale_released(_changed: bool) -> void:
	_rebuild()
	visible = true
	_status.text = "Applied: UI scale %d%%." % int(round(GameSettings.ui_scale * 100.0))


func _apply_and_report() -> void:
	GameSettings.apply()
	GameSettings.save_settings()
	_refresh()
	_status.text = "Applied: %s, window %s, ui %d%%, vsync %s, cap %s." % [
		GameSettings.WINDOW_LABELS[GameSettings.window_index],
		GameSettings.WINDOW_SIZE_LABELS[GameSettings.window_size_index],
		int(round(GameSettings.ui_scale * 100.0)),
		GameSettings.VSYNC_LABELS[GameSettings.vsync_index],
		GameSettings.FPS_LABELS[GameSettings.fps_index],
	]


func _refresh() -> void:
	_window_button.text = "%s  >" % GameSettings.WINDOW_LABELS[GameSettings.window_index]
	_window_size_button.text = "%s  >" % GameSettings.WINDOW_SIZE_LABELS[GameSettings.window_size_index]
	_vsync_button.text = "%s  >" % GameSettings.VSYNC_LABELS[GameSettings.vsync_index]
	_fps_button.text = "%s  >" % GameSettings.FPS_LABELS[GameSettings.fps_index]
	_overlay_button.text = "%s  >" % ("On" if GameSettings.show_perf_overlay else "Off")
	_hints_button.text = "%s  >" % ("On" if GameSettings.show_hints else "Off")
