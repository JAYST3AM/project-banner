extends Control
## Settlement screen.
##
## Step 2 delivers this as a functional placeholder: the town, who owns it and
## what it is, plus a working Leave. Recruitment, the recruit pool and the party
## roster arrive in Step 3 - the data they need is already in [Settlement].

const WORLD_MAP_KEY := "world_map"

@onready var _body: VBoxContainer = $Center/Panel/Body
@onready var _leave_button: Button = $Center/Panel/Body/LeaveButton

var _settlement: Settlement = null


func _ready() -> void:
	var panel := $Center/Panel as PanelContainer
	panel.add_theme_stylebox_override("panel", UiTheme.panel_style(UiTheme.PANEL_DEEP))
	_leave_button.text = "Leave Settlement"
	_leave_button.pressed.connect(_on_leave)

	if not GameManager.is_campaign_active():
		SceneManager.change_scene("main_menu")
		return

	var state := GameManager.campaign
	var payload := SceneManager.consume_payload()
	var settlement_id := str(payload.get("settlement_id", state.current_settlement_id))
	_settlement = state.settlement(settlement_id)
	if _settlement == null:
		DebugLogger.warn("settlement screen opened for unknown id '%s'" % settlement_id, "Settlement")
		SceneManager.change_scene(WORLD_MAP_KEY)
		return

	# Standing inside a settlement is what makes it "entered".
	state.current_settlement_id = _settlement.id
	_fill(state)
	DebugLogger.info("entered %s" % _settlement.name, "Settlement")


func _fill(state: CampaignState) -> void:
	var owner_text := _settlement.owner_faction_id
	if owner_text.is_empty():
		owner_text = "unclaimed"
	else:
		owner_text = owner_text.replace("_", " ").capitalize()

	var lines: Array[String] = [
		"%s  |  %s" % [_settlement.type_display(), owner_text],
		"Population %d" % _settlement.population,
		"",
		_state_line(state),
		"",
		_settlement.description,
		"",
		"Recruits available: %d" % _settlement.total_recruits_available(),
		"Market: %s" % str(_settlement.market.get("status", "closed")),
		"",
		"Recruitment, the market and the party roster are built in Step 3.",
	]
	_body.get_node("Title").text = _settlement.name
	_body.get_node("Info").text = "\n".join(lines)


func _state_line(state: CampaignState) -> String:
	return "Gold %d    Party %d    %s" % [
		state.player_gold,
		state.player_party.size(),
		state.clock.full_string(),
	]


func _on_leave() -> void:
	SceneManager.change_scene(WORLD_MAP_KEY, {"select_settlement_id": _settlement.id if _settlement != null else ""})
