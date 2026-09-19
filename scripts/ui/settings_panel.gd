class_name SettingsPanel
extends PanelContainer
## The Settings screen, shared by the main menu and the Esc menu (D-137).
##
## Three rows, each a cycle button: click to step through the values, applied and saved the moment
## it changes. There is no OK button, because there is nothing to confirm - the screen behind the
## panel is already showing the answer.
##
## Esc closes this panel and nothing else: it handles the key in `_input`, which runs before any
## `_unhandled_input`, so the Esc menu underneath keeps its own Esc for itself.

signal closed

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.075, 0.088, 0.11)

const PANEL_SIZE := Vector2(520.0, 0.0)

var _window_button: Button = null
var _vsync_button: Button = null
var _fps_button: Button = null
var _status: Label = null
var _styles: Dictionary = {}


func _init() -> void:
	add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.5), OUTLINE))
	custom_minimum_size = PANEL_SIZE
	# Centred over whatever opened it, nudged right so it never sits over the menu column's own
	# words, running while the tree may be paused.
	set_anchors_preset(Control.PRESET_CENTER)
	offset_left = -PANEL_SIZE.x * 0.5 + 80.0
	offset_right = PANEL_SIZE.x * 0.5 + 80.0
	offset_top = -160.0
	offset_bottom = 160.0
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()


func _build() -> void:
	_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	theme = PixelStyle.tooltip_theme(BODY, LIGHT.darkened(0.45), UiTheme.TEXT)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	add_child(box)

	box.add_child(PixelStyle.pixel_label("SETTINGS", 16, UiTheme.GOLD))
	box.add_child(PixelStyle.rule(DARK))

	_window_button = _setting_row(box, "Window", _cycle_window)
	_vsync_button = _setting_row(box, "VSync", _cycle_vsync)
	_fps_button = _setting_row(box, "Frame cap", _cycle_fps)

	box.add_child(PixelStyle.rule(DARK))

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	box.add_child(footer)
	_status = PixelStyle.body_label("", 12.5, UiTheme.DIM, true)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_status)
	var close_button := PixelStyle.text_button("Close", _styles, 11, Vector2(110.0, 34.0),
		UiTheme.TEXT, UiTheme.DIM)
	close_button.pressed.connect(close)
	footer.add_child(close_button)

	_refresh()


## One settings row: the name in the serif, the current choice on a pixel button that cycles it.
func _setting_row(box: VBoxContainer, title: String, handler: Callable) -> Button:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var label := PixelStyle.body_label(title, 14, UiTheme.TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var button := PixelStyle.text_button("", _styles, 11, Vector2(200.0, 34.0),
		UiTheme.GOLD, UiTheme.DIM)
	button.pressed.connect(handler)
	row.add_child(button)
	return button


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func open() -> void:
	_refresh()
	visible = true
	_status.text = "Changes apply at once, and are remembered."
	_window_button.grab_focus()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


## The three handlers: step the table, apply, save, reprint. Nothing else lives in this panel.
func _cycle_window() -> void:
	GameSettings.window_index = GameSettings.next_index(GameSettings.window_index,
		GameSettings.WINDOW_LABELS.size())
	_apply_and_report()

func _cycle_vsync() -> void:
	GameSettings.vsync_index = GameSettings.next_index(GameSettings.vsync_index,
		GameSettings.VSYNC_LABELS.size())
	_apply_and_report()

func _cycle_fps() -> void:
	GameSettings.fps_index = GameSettings.next_index(GameSettings.fps_index,
		GameSettings.FPS_LABELS.size())
	_apply_and_report()


func _apply_and_report() -> void:
	GameSettings.apply()
	GameSettings.save_settings()
	_refresh()
	_status.text = "Applied: %s, vsync %s, cap %s." % [
		GameSettings.WINDOW_LABELS[GameSettings.window_index],
		GameSettings.VSYNC_LABELS[GameSettings.vsync_index],
		GameSettings.FPS_LABELS[GameSettings.fps_index],
	]


func _refresh() -> void:
	_window_button.text = "%s  >" % GameSettings.WINDOW_LABELS[GameSettings.window_index]
	_vsync_button.text = "%s  >" % GameSettings.VSYNC_LABELS[GameSettings.vsync_index]
	_fps_button.text = "%s  >" % GameSettings.FPS_LABELS[GameSettings.fps_index]
