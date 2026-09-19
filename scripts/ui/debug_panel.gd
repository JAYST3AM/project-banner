class_name DebugPanel
extends PanelContainer
## Development/debug panel (toggle with F1).
##
## Entirely opt-in: [method is_available] gates it behind
## [code]debug.enabled[/code] in the config and, when
## [code]debug.debug_build_only[/code] is set, behind running from source.
## Shipping a build without it is a config edit, not a code change.
##
## Every action emits a signal; the world map performs it. That keeps the panel
## unable to corrupt campaign state on its own, and keeps the actions testable.

signal teleport_requested(settlement_id: String)
signal gold_requested(amount: int)
signal speed_requested(speed_name: String)
signal state_requested()

var _config: GameConfig = null
var _state: CampaignState = null
var _travel: TravelService = null

var _readout: Label = null
var _teleport_box: VBoxContainer = null


func _init() -> void:
	add_theme_stylebox_override("panel", UiTheme.panel_style(Color("151a24")))
	custom_minimum_size = Vector2(286.0, 0.0)
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(12.0, 190.0)
	visible = false
	_build()


func _build() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	add_child(box)

	box.add_child(UiTheme.header("Debug  (F1)", 15))
	box.add_child(UiTheme.heading_rule())

	_readout = UiTheme.label("", 12, UiTheme.DIM)
	box.add_child(_readout)

	box.add_child(UiTheme.heading_rule())
	box.add_child(UiTheme.dim_label("Teleport"))
	_teleport_box = VBoxContainer.new()
	_teleport_box.add_theme_constant_override("separation", 3)
	box.add_child(_teleport_box)

	box.add_child(UiTheme.heading_rule())
	box.add_child(UiTheme.dim_label("Gold"))
	var gold_row := HBoxContainer.new()
	gold_row.add_theme_constant_override("separation", 4)
	box.add_child(gold_row)
	for amount in [100, 1000]:
		var button := UiTheme.button("+%d" % amount, 82.0)
		button.pressed.connect(func() -> void: gold_requested.emit(amount))
		gold_row.add_child(button)

	box.add_child(UiTheme.heading_rule())
	box.add_child(UiTheme.dim_label("Game speed"))
	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 4)
	box.add_child(speed_row)
	for speed_name in CampaignClock.SPEED_NAMES:
		var button := UiTheme.button(speed_name.substr(0, 4), 60.0)
		button.pressed.connect(func() -> void: speed_requested.emit(speed_name))
		speed_row.add_child(button)


## Whether the panel may be used at all in this build.
func is_available() -> bool:
	if _config == null:
		return false
	if not _config.get_bool("debug.enabled", false):
		return false
	if _config.get_bool("debug.debug_build_only", true) and not OS.is_debug_build():
		return false
	return true


func setup(state: CampaignState, config: GameConfig, travel: TravelService) -> void:
	_state = state
	_config = config
	_travel = travel
	_rebuild_teleports()
	refresh()
	if not is_available():
		visible = false


func toggle() -> void:
	if not is_available():
		return
	visible = not visible
	if visible:
		refresh()


func _rebuild_teleports() -> void:
	for child in _teleport_box.get_children():
		child.queue_free()
	if _state == null:
		return
	for key in _state.settlements.keys():
		var settlement := _state.settlements[key] as Settlement
		if settlement == null:
			continue
		var button := UiTheme.button("Go to %s" % settlement.name, 240.0)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(func() -> void: teleport_requested.emit(settlement.id))
		_teleport_box.add_child(button)


func refresh() -> void:
	if _state == null or not visible:
		return
	var here := _travel.current_settlement() if _travel != null else null
	var lines: Array[String] = [
		"coords      %.0f, %.0f" % [_state.world_position.x, _state.world_position.y],
		"destination %s" % _state.destination_name(),
		"at          %s" % (here.name if here != null else "-"),
		"time        %s" % _state.clock.full_string(),
		"speed       %s" % _state.clock.speed_name(),
		"party       %d active / %d roster" % [
			_state.active_member_count(_state.player_party), _state.roster_member_count(_state.player_party),
		],
		"soldiers    %d total" % _state.soldiers.size(),
		"settlements %d" % _state.settlements.size(),
		"seed        %d" % _state.campaign_seed,
	]
	if _travel != null:
		# The pace a player actually walks at, not the bare number: the ground's own factor is
		# included, so a road reads x1.40 and open field x1.00 and the boot is visible - the owner,
		# watching a road: "I don't see a speed increase on the roads".
		var factor := _travel.ground_factor()
		lines.append("pace        %.0f u/h  (ground x%.2f)" % [
			_travel.speed_units_per_game_hour() * factor, factor,
		])
	_readout.text = "\n".join(lines)
