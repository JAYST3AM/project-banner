class_name EncounterDialog
extends PanelContainer
## The "you have met someone" prompt: who they are, how strong both sides look,
## and the choice to fight or back off.
##
## The world is paused while this is open - that is the world map's job, not the
## dialog's. This only reports intent. Dressed in the interface's one language (D-133).

signal attack_requested()
signal retreat_requested()

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.075, 0.088, 0.11)

var _title: Label = null
var _enemy_value: Label = null
var _player_value: Label = null
var _warning: Label = null
var _attack_button: Button = null
var _retreat_button: Button = null


func _init() -> void:
	add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.5), OUTLINE))
	set_anchors_preset(Control.PRESET_CENTER)
	custom_minimum_size = Vector2(480.0, 0.0)
	offset_left = -240.0
	offset_top = -160.0
	offset_right = 240.0
	offset_bottom = 160.0
	visible = false
	_build()


func _build() -> void:
	var styles := PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	theme = PixelStyle.tooltip_theme(BODY, LIGHT.darkened(0.45), UiTheme.TEXT)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	add_child(box)

	_title = PixelStyle.pixel_label("", 20, UiTheme.BAD)
	box.add_child(_title)
	box.add_child(PixelStyle.rule(DARK))

	_enemy_value = PixelStyle.pixel_label("", 11, UiTheme.TEXT)
	box.add_child(PixelStyle.stat_row("Enemy strength", _enemy_value, 14))
	_player_value = PixelStyle.pixel_label("", 11, UiTheme.TEXT)
	box.add_child(PixelStyle.stat_row("Your strength", _player_value, 14))

	_warning = PixelStyle.body_label("", 14, UiTheme.GOLD, true)
	_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning.custom_minimum_size = Vector2(440.0, 44.0)
	box.add_child(_warning)
	box.add_child(PixelStyle.rule(DARK))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	_attack_button = PixelStyle.text_button("Attack", styles, 12, Vector2(216.0, 42.0),
		UiTheme.GOLD, UiTheme.DIM)
	_attack_button.pressed.connect(func() -> void: attack_requested.emit())
	row.add_child(_attack_button)

	_retreat_button = PixelStyle.text_button("Retreat", styles, 12, Vector2(216.0, 42.0),
		UiTheme.TEXT, UiTheme.DIM)
	_retreat_button.pressed.connect(func() -> void: retreat_requested.emit())
	row.add_child(_retreat_button)


## [param enemy_strength] / [param player_strength] come from the campaign's own
## strength calculation, so the numbers match what the world map shows.
func show_encounter(party_name: String, enemy_strength: int, enemy_count: int, player_strength: int, player_count: int) -> void:
	_title.text = party_name.to_upper()
	_enemy_value.text = "%d (%d soldiers)" % [enemy_strength, enemy_count]
	_player_value.text = "%d (%d soldiers)" % [player_strength, player_count]
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
