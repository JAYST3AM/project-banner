class_name SettlementPanel
extends PanelContainer
## Settlement inspection panel: shows what is at a point on the map and offers
## Travel / Enter. Built in script; emits intent, never mutates state itself.

signal travel_requested(settlement_id: String)
signal enter_requested(settlement_id: String)
signal closed()

var _name_label: Label = null
var _type_label: Label = null
var _facts_label: Label = null
var _description: Label = null
var _travel_button: Button = null
var _enter_button: Button = null

var _settlement_id: String = ""

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
	add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	custom_minimum_size = Vector2(360.0, 0.0)
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	position = Vector2(-372.0, 12.0)
	visible = false
	_build()


func _build() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	var header_row := HBoxContainer.new()
	box.add_child(header_row)
	_name_label = UiTheme.label("", 19, UiTheme.GOLD)
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(_name_label)
	var close_button := UiTheme.button("X")
	close_button.custom_minimum_size = Vector2(30.0, 26.0)
	close_button.pressed.connect(func() -> void: closed.emit())
	header_row.add_child(close_button)

	_type_label = UiTheme.dim_label("")
	box.add_child(_type_label)
	box.add_child(UiTheme.heading_rule())

	_facts_label = UiTheme.label("", 14, UiTheme.TEXT)
	box.add_child(_facts_label)

	_description = UiTheme.label("", 13, UiTheme.DIM)
	_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description.custom_minimum_size = Vector2(330.0, 0.0)
	box.add_child(_description)

	box.add_child(UiTheme.heading_rule())

	_travel_button = UiTheme.button("Travel Here", 150.0)
	_travel_button.pressed.connect(_on_travel)
	box.add_child(_travel_button)

	_enter_button = UiTheme.button("Enter Settlement", 150.0)
	_enter_button.disabled = true
	_enter_button.pressed.connect(_on_enter)
	box.add_child(_enter_button)


## Whether the place on show can be entered. A hamlet or a ruin cannot, and saying so in the panel
## is the difference between a player learning the map and a player concluding the game is broken.
var _enterable: bool = true


func show_settlement(settlement: Settlement) -> void:
	_settlement_id = settlement.id
	_enterable = settlement.is_enterable()
	_name_label.text = settlement.name
	_type_label.text = "%s  |  population %d" % [
		settlement.type_display(),
		settlement.population,
	]
	var owner_text := settlement.owner_faction_id if not settlement.owner_faction_id.is_empty() else "unclaimed"
	var recruit_total := settlement.total_recruits_available()
	var recruit_text := "none" if recruit_total <= 0 else "%d available" % recruit_total
	_facts_label.text = "\n".join([
		"Owner:     %s" % owner_text.replace("_", " ").capitalize(),
		"Recruits:  %s" % recruit_text,
		"Visited:   %s" % ("yes" if settlement.visited else "no"),
		"Entry:     %s" % ("open" if _enterable else "no road in - march there, nothing to enter"),
	])
	_description.text = settlement.description
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
