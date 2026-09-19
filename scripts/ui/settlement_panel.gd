class_name SettlementPanel
extends PanelContainer
## Settlement inspection panel: shows what is at a point on the map and offers
## Travel / Enter. Built in script; emits intent, never mutates state itself.
##
## Dressed in the interface's one language (D-133): pixel chrome, values in Silkscreen, labels in
## the serif, and the town's flavour text on hover rather than printed into the panel.

signal travel_requested(settlement_id: String)
signal enter_requested(settlement_id: String)
signal closed()

const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.085, 0.10, 0.125)

var _name_label: Label = null
var _type_label: Label = null
var _owner_value: Label = null
var _recruits_value: Label = null
var _visited_value: Label = null
var _entry_value: Label = null
var _travel_button: Button = null
var _enter_button: Button = null

var _settlement_id: String = ""
var _button_styles: Dictionary = {}

var _state: CampaignState = null
var _config: GameConfig = null
var _travel: TravelService = null


## The panel is handed the live campaign objects once, rather than reading
## globals on every refresh.
func bind(p_state: CampaignState, p_config: GameConfig, p_travel: TravelService) -> void:
	_state = p_state
	_config = p_config
	_travel = p_travel


func _init() -> void:
	add_theme_stylebox_override("panel",
		PixelStyle.panel_style(RAIL_BODY, LIGHT.darkened(0.55), OUTLINE))
	custom_minimum_size = Vector2(372.0, 0.0)
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	position = Vector2(-384.0, 12.0)
	visible = false
	_build()


func _build() -> void:
	_button_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)
	theme = PixelStyle.tooltip_theme(BODY.darkened(0.15), LIGHT.darkened(0.45), UiTheme.TEXT)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	add_child(box)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	box.add_child(header_row)
	_name_label = PixelStyle.pixel_label("", 16, UiTheme.GOLD)
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_row.add_child(_name_label)
	var close_button := PixelStyle.text_button("X", _button_styles, 11, Vector2(30.0, 26.0),
		UiTheme.DIM, UiTheme.DIM.darkened(0.3))
	close_button.pressed.connect(func() -> void: closed.emit())
	header_row.add_child(close_button)

	_type_label = PixelStyle.pixel_label("", 10, UiTheme.DIM)
	box.add_child(_type_label)
	box.add_child(PixelStyle.rule(DARK))

	_owner_value = PixelStyle.pixel_label("", 10.5)
	box.add_child(PixelStyle.stat_row("Owner", _owner_value, 13.5))
	_recruits_value = PixelStyle.pixel_label("", 10.5)
	box.add_child(PixelStyle.stat_row("Recruits", _recruits_value, 13.5))
	_visited_value = PixelStyle.pixel_label("", 10.5)
	box.add_child(PixelStyle.stat_row("Visited", _visited_value, 13.5))

	# The entry note is a sentence when it is bad news ("no road in - march there..."), so it is set
	# in the serif and allowed to wrap; the value rows above stay one line each.
	_entry_value = PixelStyle.body_label("", 12.5, UiTheme.DIM, true)
	_entry_value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_entry_value.custom_minimum_size = Vector2(330.0, 0.0)
	box.add_child(_entry_value)

	box.add_child(PixelStyle.rule(DARK))

	_travel_button = PixelStyle.text_button("Travel Here", _button_styles, 11, Vector2(150.0, 34.0),
		UiTheme.TEXT, UiTheme.DIM)
	_travel_button.pressed.connect(_on_travel)
	box.add_child(_travel_button)

	_enter_button = PixelStyle.text_button("Enter Settlement", _button_styles, 11,
		Vector2(150.0, 34.0), UiTheme.GOLD, UiTheme.DIM)
	_enter_button.disabled = true
	_enter_button.pressed.connect(_on_enter)
	box.add_child(_enter_button)


## Whether the place on show can be entered. A hamlet or a ruin cannot, and saying so in the panel
## is the difference between a player learning the map and a player concluding the game is broken.
var _enterable: bool = true


func show_settlement(settlement: Settlement) -> void:
	_settlement_id = settlement.id
	_enterable = settlement.is_enterable()
	_name_label.text = settlement.name.to_upper()
	_name_label.tooltip_text = settlement.description
	_type_label.text = "%s | POP %d" % [settlement.type_display().to_upper(), settlement.population]
	var owner_text := settlement.owner_faction_id if not settlement.owner_faction_id.is_empty() else "unclaimed"
	_owner_value.text = owner_text.replace("_", " ").to_upper()
	var recruit_total := settlement.total_recruits_available()
	_recruits_value.text = "NONE" if recruit_total <= 0 else "%d" % recruit_total
	_visited_value.text = "YES" if settlement.visited else "NO"
	_entry_value.text = "" if _enterable else "No road in - march there, nothing to enter."
	visible = true


## Travel button state depends on where the party currently is, and the enter button also depends on
## whether there is anything to enter.
func set_arrival_state(is_here: bool) -> void:
	_travel_button.disabled = is_here
	_travel_button.text = "You are here" if is_here else "Travel Here"
	if not _enterable:
		_enter_button.disabled = true
		_enter_button.text = "No entry here"
		return
	_enter_button.disabled = not is_here
	_enter_button.text = "Enter" if is_here else "Enter (march there first)"


func hide_panel() -> void:
	_settlement_id = ""
	visible = false


func settlement_id() -> String:
	return _settlement_id


func _on_travel() -> void:
	if not _settlement_id.is_empty():
		travel_requested.emit(_settlement_id)


func _on_enter() -> void:
	if not _settlement_id.is_empty():
		enter_requested.emit(_settlement_id)
