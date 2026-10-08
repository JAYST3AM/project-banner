class_name BattleCommandBar
extends PanelContainer
## Compact, legible battle command bar. This is presentation and input only;
## all command outcomes still run through the battle controller.
signal action_requested(action: String)

const INK := Color("151a16")
const INK_RAISED := Color("292e29")
const EDGE := Color("68705c")
const TEXT := Color("e8e0ce")
const MUTED := Color("b2b6a5")
const GOLD := Color("e4c783")
const ENEMY := Color("d98a77")
const ALLY := Color("8bb5c7")

var _stage: Label
var _forces: Label
var _selection: Label
var _map_button: Button
var _pause_button: Button


static func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = INK
	style.border_color = EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	return style


static func _button_style(selected: bool = false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("48412b") if selected else INK_RAISED
	style.border_color = GOLD if selected else EDGE.darkened(0.1)
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_left = 9.0
	style.content_margin_right = 9.0
	style.content_margin_top = 5.0
	style.content_margin_bottom = 5.0
	return style


static func _label(text: String, size: int, colour: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", colour)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _ready() -> void:
	add_theme_stylebox_override("panel", _panel_style())
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	add_child(column)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	column.add_child(top)
	top.add_child(_label("PROJECT BANNER  /  FIELD COMMAND", 14, GOLD))
	_stage = _label("DEPLOYMENT", 12, TEXT)
	top.add_spacer(false)
	top.add_child(_stage)
	_forces = _label("OUR ARMY  —   ENEMY  —", 12, ALLY)
	top.add_child(_forces)

	var lower := HBoxContainer.new()
	lower.add_theme_constant_override("separation", 9)
	column.add_child(lower)
	_selection = _label("SELECT A FORMATION", 11, MUTED)
	_selection.custom_minimum_size.x = 185.0
	lower.add_child(_selection)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 37.0
	lower.add_child(scroll)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 5)
	scroll.add_child(actions)
	for entry in [
		["H  HOLD", "hold"],
		["U  ENGAGE", "engage"],
		["L  LINE", "line"],
		["C  COLUMN", "column"],
		["O  LOOSE", "loose"],
		["T  MAP", "map"],
		["P  PAUSE", "pause"]
	]:
		var button := Button.new()
		button.text = str(entry[0])
		button.custom_minimum_size = Vector2(94, 32)
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_stylebox_override("normal", _button_style())
		button.add_theme_stylebox_override("hover", _button_style(true))
		button.add_theme_stylebox_override("pressed", _button_style(true))
		button.add_theme_color_override("font_color", TEXT)
		button.add_theme_color_override("font_hover_color", GOLD)
		button.add_theme_font_size_override("font_size", 12)
		button.pressed.connect(_invoke.bind(str(entry[1])))
		actions.add_child(button)
		if entry[1] == "map":
			_map_button = button
		elif entry[1] == "pause":
			_pause_button = button


func set_battle_status(deploying: bool, player_alive: int, enemy_alive: int,
		selected_count: int, map_view: bool, paused: bool) -> void:
	if _stage == null:
		return
	_stage.text = "DEPLOYMENT" if deploying else "BATTLE PAUSED" if paused else "IN BATTLE"
	_stage.add_theme_color_override("font_color", GOLD if deploying else TEXT)
	_forces.text = "OUR ARMY  %d    /    ENEMY  %d" % [player_alive, enemy_alive]
	_selection.text = "%d FORMATION%s SELECTED" % [
		selected_count, "" if selected_count == 1 else "S"] if selected_count > 0 		else "SELECT A FORMATION"
	if _map_button != null:
		_map_button.text = "T  RETURN" if map_view else "T  MAP"
	if _pause_button != null:
		_pause_button.text = "P  RESUME" if paused else "P  PAUSE"


func _invoke(action: String) -> void:
	action_requested.emit(action)
