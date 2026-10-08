class_name BattleUnitDock
extends PanelContainer
## Persistent formation cards. Clicking and box selection share the same selected body IDs.
signal body_chosen(body_id: int, additive: bool)

var _row: HBoxContainer = null
var _buttons: Dictionary = {}


func _ready() -> void:
	add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 6)
	scroll.add_child(_row)


func update_bodies(bodies: Array[Dictionary], selected: Array[int]) -> void:
	if _row == null:
		return
	for body in bodies:
		if int(body.get("side", 1)) != 0:
			continue
		var id := int(body.get("id", -1))
		if id < 0:
			continue
		var button: Button = _buttons.get(id)
		if button == null:
			button = Button.new()
			button.toggle_mode = true
			button.custom_minimum_size = Vector2(108.0, 58.0)
			button.tooltip_text = "Select formation (Shift-click to add or remove)"
			button.pressed.connect(_choose.bind(id))
			_row.add_child(button)
			_buttons[id] = button
		var alive := int(body.get("alive", 0))
		var started := maxi(1, int(body.get("started", alive)))
		button.text = "%s   %d/%d\n%s" % [
			str(body.get("name", "Unit")), alive, started, str(body.get("shape", "line")).capitalize()]
		button.disabled = alive <= 0
		button.set_pressed_no_signal(selected.has(id))
		button.add_theme_color_override("font_color", Color("f1d89b") if selected.has(id) else Color("e8eaed"))


func _choose(id: int) -> void:
	body_chosen.emit(id, Input.is_key_pressed(KEY_SHIFT))
