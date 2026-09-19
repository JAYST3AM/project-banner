class_name WorldHud
extends CanvasLayer
## The world map's heads-up display and action bar.
##
## Built in script rather than in a .tscn so all HUD behaviour (what is shown,
## when a button is enabled, what it emits) lives in one file. The HUD never
## mutates campaign state - it emits a signal and the world map decides.
##
## Dressed in the interface's one language (D-133): the menus' pixel chrome, values in Silkscreen,
## labels in the serif. The stat wording is load-bearing - test_party_semantics reads the party line
## through [method stat_text] - so it is deliberately untouched by the dressing.

signal speed_requested(speed_name: String)
signal enter_settlement_requested(settlement_id: String)
signal travel_requested(settlement_id: String)
signal save_requested()
signal menu_requested()

const STAT_COLUMNS := 4

## The menus' palette, so the HUD and the menu are one game. Same values as main_menu.gd.
const BODY := Color(0.13, 0.15, 0.19)
const LIGHT := Color(0.38, 0.42, 0.48)
const DARK := Color(0.06, 0.07, 0.09)
const OUTLINE := Color(0.02, 0.02, 0.03)
const RAIL_BODY := Color(0.075, 0.088, 0.11)

var _stats: GridContainer = null
var _stat_values: Dictionary = {}
var _title: Label = null
var _subtitle: Label = null
var _hint: Label = null
var _speed_buttons: Dictionary = {}
var _enter_button: Button = null
var _selection: SettlementPanel = null
var _button_styles: Dictionary = {}

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
	_button_styles = PixelStyle.button_styles(BODY, LIGHT, DARK, UiTheme.ACCENT, OUTLINE)

	# --- top-left status panel -------------------------------------------
	var top_bar := PixelStyle.dressed_panel(RAIL_BODY, LIGHT.darkened(0.55), OUTLINE)
	top_bar.position = Vector2(12.0, 12.0)
	add_child(top_bar)

	var top_box := VBoxContainer.new()
	top_box.add_theme_constant_override("separation", 4)
	top_bar.add_child(top_box)

	_title = PixelStyle.pixel_label("", 17, UiTheme.GOLD)
	top_box.add_child(_title)
	_subtitle = PixelStyle.pixel_label("", 9.5, UiTheme.DIM)
	top_box.add_child(_subtitle)
	top_box.add_child(PixelStyle.rule(DARK))

	_stats = GridContainer.new()
	_stats.columns = STAT_COLUMNS
	_stats.add_theme_constant_override("h_separation", 18)
	_stats.add_theme_constant_override("v_separation", 3)
	top_box.add_child(_stats)
	for stat_name in ["Gold", "Party", "Date", "Speed", "Destination", "Position", "At", "Settlements"]:
		_stats.add_child(PixelStyle.body_label(stat_name, 13.5, UiTheme.DIM))
		var value := PixelStyle.pixel_label("-", 10.5, UiTheme.TEXT)
		_stat_values[stat_name] = value
		_stats.add_child(value)

	# --- time controls (top-centre) --------------------------------------
	# The owner: "I want the pause, normal and faster in the top center of the hud, and I want
	# symbols not words." A full-width strip with a centred box keeps the cluster centred whatever
	# the UI scale, and the strip itself ignores the mouse so the map under it still takes clicks.
	var centre_strip := HBoxContainer.new()
	centre_strip.set_anchors_preset(Control.PRESET_TOP_WIDE)
	centre_strip.offset_top = 10.0
	centre_strip.offset_bottom = 64.0
	centre_strip.alignment = BoxContainer.ALIGNMENT_CENTER
	centre_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre_strip)

	var speed_bar := PixelStyle.dressed_panel(RAIL_BODY, LIGHT.darkened(0.55), OUTLINE)
	centre_strip.add_child(speed_bar)
	var speed_box := HBoxContainer.new()
	speed_box.add_theme_constant_override("separation", 6)
	speed_bar.add_child(speed_box)
	for i in CampaignClock.SPEED_NAMES.size():
		var speed_name := CampaignClock.SPEED_NAMES[i]
		var button := _speed_button(speed_name, i)
		speed_box.add_child(button)
		_speed_buttons[speed_name] = button

	# --- actions (bottom-right) ------------------------------------------
	var action_bar := PixelStyle.dressed_panel(RAIL_BODY, LIGHT.darkened(0.55), OUTLINE)
	action_bar.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	action_bar.position = Vector2(-236.0, -158.0)
	add_child(action_bar)

	var action_box := VBoxContainer.new()
	action_box.add_theme_constant_override("separation", 6)
	action_bar.add_child(action_box)
	action_box.add_child(PixelStyle.pixel_label("ACTIONS", 12, UiTheme.ACCENT))

	_enter_button = PixelStyle.text_button("Enter Settlement", _button_styles, 11,
		Vector2(200.0, 34.0), UiTheme.GOLD, UiTheme.DIM)
	_enter_button.disabled = true
	_enter_button.pressed.connect(_on_enter_pressed)
	action_box.add_child(_enter_button)

	var save_button := PixelStyle.text_button("Save Game", _button_styles, 11,
		Vector2(200.0, 34.0), UiTheme.TEXT, UiTheme.DIM)
	save_button.pressed.connect(func() -> void: save_requested.emit())
	action_box.add_child(save_button)

	var menu_button := PixelStyle.text_button("Save & Quit to Menu", _button_styles, 11,
		Vector2(200.0, 34.0), UiTheme.TEXT, UiTheme.DIM)
	menu_button.pressed.connect(func() -> void: menu_requested.emit())
	action_box.add_child(menu_button)

	# --- hint line (bottom-centre) ---------------------------------------
	_hint = PixelStyle.body_label("", 14, UiTheme.DIM, true)
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.position = Vector2(12.0, -30.0)
	_hint.offset_right = -240.0
	# The Settings panel can turn the hint line off (D-137); it is read here at build, so a change
	# lands on the next entry to the map rather than mid-session.
	_hint.visible = GameSettings.show_hints
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

	var active := _state.active_member_count(_state.player_party)
	var max_party := _config.get_int("campaign.max_party_size", 24)
	var lost := _state.fallen_member_count(_state.player_party)
	var party_text := "%d / %d active" % [active, max_party]
	if lost > 0:
		party_text += "   (%d lost)" % lost
	_set_stat("Party", party_text)
	_set_stat("Date", _state.clock.full_string())
	_set_stat("Speed", _state.clock.speed_name())

	var destination := _state.destination_id
	if _state.destination_is_point:
		_set_stat("Destination", "Open ground  (%.1f h)" % _travel.hours_to_reach(_state.destination_point))
	elif destination.is_empty():
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


## The text currently shown for one statistic, or "" if there is no such statistic.
##
## Read-only accessor for the tests: it lets the party-capacity wording be asserted
## directly rather than inferred from a screenshot, and it cannot change what the HUD
## displays.
func stat_text(stat_name: String) -> String:
	var value: Label = _stat_values.get(stat_name, null)
	return value.text if value != null else ""


func _on_speed_pressed(speed_name: String) -> void:
	speed_requested.emit(speed_name)


## One time control: a square button whose face is a drawn symbol, with the word kept to the tooltip
## (D-133: words explain on hover; the face stays an interface). The glyph turns gold when its speed
## is the current one, whether the click or [method refresh] set it.
func _speed_button(speed_name: String, index: int) -> Button:
	var button := PixelStyle.text_button("", _button_styles, 11, Vector2(52.0, 36.0),
		UiTheme.TEXT, UiTheme.DIM)
	button.toggle_mode = true
	# No focus ring: with three icon buttons, a keyboard focus outline reads as a second selection.
	# The gold glyph is the one and only "this is the current speed" signal.
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = speed_name
	# The theme rides on the button: this HUD is a CanvasLayer, which has no theme of its own, and
	# the tooltip is the only thing here that needs one.
	button.theme = PixelStyle.tooltip_theme(RAIL_BODY, LIGHT.darkened(0.45), UiTheme.TEXT)
	button.pressed.connect(_on_speed_pressed.bind(speed_name))
	var glyph := SpeedGlyph.new(index)
	glyph.ink = UiTheme.DIM
	button.add_child(glyph)
	button.toggled.connect(func(on: bool) -> void:
		glyph.ink = UiTheme.GOLD if on else UiTheme.DIM)
	return button


func _on_enter_pressed() -> void:
	if _travel == null:
		return
	var here := _travel.current_settlement()
	if here != null:
		enter_settlement_requested.emit(here.id)
