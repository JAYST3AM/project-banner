class_name EncounterDialog
extends PanelContainer
## The "you have met someone" prompt: who they are, how strong both sides look,
## and the choice to fight or back off.
##
## The world is paused while this is open - that is the world map's job, not the
## dialog's. This only reports intent.

signal attack_requested()
signal retreat_requested()

var _title: Label = null
var _body: Label = null
var _warning: Label = null
var _attack_button: Button = null
var _retreat_button: Button = null


func _init() -> void:
	add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(460.0, 0.0)
	offset_left = -230.0
	offset_top = -150.0
	offset_right = 230.0
	offset_bottom = 150.0
	visible = false
	_build()


func _build() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	_title = UiTheme.label("", 26, UiTheme.BAD)
	box.add_child(_title)
	box.add_child(UiTheme.heading_rule())

	_body = UiTheme.label("", 15, UiTheme.TEXT)
	box.add_child(_body)

	_warning = UiTheme.label("", 13, UiTheme.GOLD)
	_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning.custom_minimum_size = Vector2(430.0, 46.0)
	box.add_child(_warning)
	box.add_child(UiTheme.heading_rule())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	_attack_button = UiTheme.button("Attack", 200.0)
	_attack_button.custom_minimum_size = Vector2(205.0, 40.0)
	_attack_button.pressed.connect(func() -> void: attack_requested.emit())
	row.add_child(_attack_button)

	_retreat_button = UiTheme.button("Retreat", 200.0)
	_retreat_button.custom_minimum_size = Vector2(205.0, 40.0)
	_retreat_button.pressed.connect(func() -> void: retreat_requested.emit())
	row.add_child(_retreat_button)


## [param enemy_strength] / [param player_strength] come from the campaign's own
## strength calculation, so the numbers match what the world map shows.
func show_encounter(party_name: String, enemy_strength: int, enemy_count: int, player_strength: int, player_count: int) -> void:
	_title.text = party_name.to_upper()
	_body.text = "\n".join([
		"Enemy strength:  %d   (%d soldiers)" % [enemy_strength, enemy_count],
		"Your strength:   %d   (%d soldiers)" % [player_strength, player_count],
	])
	if player_count <= 0:
		_warning.text = "You have no soldiers to fight with. Retreat while you still can."
		_attack_button.disabled = true
	elif enemy_strength > player_strength * 1.35:
		_warning.text = "They look far stronger than your party. Attacking is a gamble."
		_attack_button.disabled = false
	elif enemy_strength < player_strength * 0.75:
		_warning.text = "They look weaker than your party."
		_attack_button.disabled = false
	else:
		_warning.text = "The two forces look evenly matched."
		_attack_button.disabled = false
	visible = true
	_attack_button.grab_focus()


func hide_dialog() -> void:
	visible = false
