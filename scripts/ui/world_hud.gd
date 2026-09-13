class_name WorldHud
extends CanvasLayer
## The world map's heads-up display and action bar.
##
## Built in script rather than in a .tscn so all HUD behaviour (what is shown,
## when a button is enabled, what it emits) lives in one file. The HUD never
## mutates campaign state - it emits a signal and the world map decides.

signal speed_requested(speed_name: String)
signal enter_settlement_requested(settlement_id: String)
signal travel_requested(settlement_id: String)
signal save_requested()
signal menu_requested()

const STAT_COLUMNS := 4

var _stats: GridContainer = null
var _stat_values: Dictionary = {}
var _title: Label = null
var _subtitle: Label = null
var _hint: Label = null
var _speed_buttons: Dictionary = {}
var _enter_button: Button = null
var _selection: SettlementPanel = null

var _state: CampaignState = null
var _travel: TravelService = null
var _config: GameConfig = null
var _shown_settlement_id: String = ""


func _ready() -> void:
	layer = 10
	_build()


func setup(state: CampaignState, config: GameConfig, travel: TravelService) -> void:
	_state = state
	_config = config
	_travel = travel
	_selection.bind(state, config, travel)
	refresh()


func _build() -> void:
	# --- top-left status panel -------------------------------------------
	var top_bar := PanelContainer.new()
	top_bar.add_theme_stylebox_override("panel", UiTheme.panel_style())
	top_bar.position = Vector2(12.0, 12.0)
	add_child(top_bar)

	var top_box := VBoxContainer.new()
	top_box.add_theme_constant_override("separation", 4)
	top_bar.add_child(top_box)

	_title = UiTheme.label("", 20, UiTheme.GOLD)
	top_box.add_child(_title)
	_subtitle = UiTheme.dim_label("")
	top_box.add_child(_subtitle)
	top_box.add_child(UiTheme.heading_rule())

	_stats = GridContainer.new()
	_stats.columns = STAT_COLUMNS
	_stats.add_theme_constant_override("h_separation", 18)
	_stats.add_theme_constant_override("v_separation", 2)
	top_box.add_child(_stats)
	for stat_name in ["Gold", "Party", "Date", "Speed", "Destination", "Position", "At", "Settlements"]:
		_stats.add_child(UiTheme.dim_label(stat_name))
		var value := UiTheme.value_label("-")
		_stat_values[stat_name] = value
		_stats.add_child(value)

	# --- speed controls (bottom-left) ------------------------------------
	var speed_bar := PanelContainer.new()
	speed_bar.add_theme_stylebox_override("panel", UiTheme.panel_style())
	speed_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	speed_bar.position = Vector2(12.0, -62.0)
	add_child(speed_bar)

	var speed_box := HBoxContainer.new()
	speed_box.add_theme_constant_override("separation", 6)
	speed_bar.add_child(speed_box)
	speed_box.add_child(UiTheme.dim_label("Time"))
	for speed_name in CampaignClock.SPEED_NAMES:
		var button := UiTheme.button(speed_name, 74.0)
		button.toggle_mode = true
		button.pressed.connect(_on_speed_pressed.bind(speed_name))
		speed_box.add_child(button)
		_speed_buttons[speed_name] = button

	# --- actions (bottom-right) ------------------------------------------
	var action_bar := PanelContainer.new()
	action_bar.add_theme_stylebox_override("panel", UiTheme.panel_style())
	action_bar.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	action_bar.position = Vector2(-232.0, -146.0)
	add_child(action_bar)

	var action_box := VBoxContainer.new()
	action_box.add_theme_constant_override("separation", 6)
	action_bar.add_child(action_box)
	action_box.add_child(UiTheme.header("Actions", 14))

	_enter_button = UiTheme.button("Enter Settlement", 196.0)
	_enter_button.disabled = true
	_enter_button.pressed.connect(_on_enter_pressed)
	action_box.add_child(_enter_button)

	var save_button := UiTheme.button("Save Game", 196.0)
	save_button.pressed.connect(func() -> void: save_requested.emit())
	action_box.add_child(save_button)

	var menu_button := UiTheme.button("Save & Quit to Menu", 196.0)
	menu_button.pressed.connect(func() -> void: menu_requested.emit())
	action_box.add_child(menu_button)

	# --- hint line (bottom-centre) ---------------------------------------
	_hint = UiTheme.label("", 14, UiTheme.DIM)
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.position = Vector2(12.0, -30.0)
	_hint.offset_right = -240.0
	add_child(_hint)

	# --- settlement inspection panel (top-right) -------------------------
	_selection = SettlementPanel.new()
	_selection.travel_requested.connect(func(id: String) -> void: travel_requested.emit(id))
	_selection.enter_requested.connect(func(id: String) -> void: enter_settlement_requested.emit(id))
	_selection.closed.connect(func() -> void: _selection.hide_panel())
	add_child(_selection)


## ---------- public API ---------------------------------------------------

func show_settlement(settlement: Settlement) -> void:
	_shown_settlement_id = settlement.id
	_selection.show_settlement(settlement)
	if _state != null:
		_selection.set_arrival_state(_travel.is_at_settlement(settlement.id))


func hide_settlement() -> void:
	_shown_settlement_id = ""
	_selection.hide_panel()


func shown_settlement_id() -> String:
	return _shown_settlement_id


func set_hint(text: String) -> void:
	_hint.text = text


func speed_buttons() -> Dictionary:
	return _speed_buttons


func refresh() -> void:
	if _state == null:
		return
	_title.text = _state.campaign_name
	_subtitle.text = "World seed %d  |  %s" % [_state.campaign_seed, _state.player_party.display_name]
	_set_stat("Gold", "%d" % _state.player_gold)

	var party_size := _state.player_party.size()
	var max_party := _config.get_int("campaign.max_party_size", 24)
	_set_stat("Party", "%d / %d" % [party_size, max_party])
	_set_stat("Date", _state.clock.full_string())
	_set_stat("Speed", _state.clock.speed_name())

	var destination := _state.destination_id
	if destination.is_empty():
		_set_stat("Destination", "None")
	else:
		var target := _state.settlement(destination)
		var name := target.name if target != null else destination
		var hours := _travel.hours_to_reach(target.position) if target != null else 0.0
		_set_stat("Destination", "%s  (%.1f h)" % [name, hours])

	_set_stat("Position", "%.0f, %.0f" % [_state.world_position.x, _state.world_position.y])
	var here := _travel.current_settlement()
	_set_stat("At", here.name if here != null else "Open country")
	_set_stat("Settlements", "%d" % _state.settlements.size())

	for speed_name in _speed_buttons.keys():
		var button := _speed_buttons[speed_name] as Button
		button.button_pressed = (_state.clock.speed_name() == speed_name)

	if here != null and _travel.is_within_settlement(here):
		_enter_button.text = "Enter %s" % here.name
		_enter_button.disabled = false
	else:
		_enter_button.text = "Enter Settlement"
		_enter_button.disabled = true

	if not _selection.visible:
		return
	_selection.set_arrival_state(_travel.is_at_settlement(_shown_settlement_id))


func _set_stat(stat_name: String, text: String) -> void:
	var value: Label = _stat_values.get(stat_name, null)
	if value != null:
		value.text = text


func _on_speed_pressed(speed_name: String) -> void:
	speed_requested.emit(speed_name)


func _on_enter_pressed() -> void:
	if _travel == null:
		return
	var here := _travel.current_settlement()
	if here != null:
		enter_settlement_requested.emit(here.id)
