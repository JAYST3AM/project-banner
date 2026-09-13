extends Control
## Main menu.

@onready var _name_input: LineEdit = $Frame/NameInput
@onready var _seed_input: LineEdit = $Frame/SeedInput
@onready var _new_button: Button = $Frame/NewCampaignButton
@onready var _continue_button: Button = $Frame/ContinueButton
@onready var _quit_button: Button = $Frame/QuitButton
@onready var _status: Label = $Frame/StatusLabel


func _ready() -> void:
	_name_input.text = GameManager.config().get_string("campaign.default_campaign_name", "A New Banner")
	_new_button.pressed.connect(_on_new_campaign)
	_continue_button.pressed.connect(_on_continue)
	_quit_button.pressed.connect(_on_quit)
	_refresh_continue_state()
	_new_button.grab_focus()


## Continue is only offered when a save actually exists and parses.
func _refresh_continue_state() -> void:
	var summary := GameManager.continue_summary()
	var available := not summary.is_empty()
	_continue_button.disabled = not available
	if available:
		_status.text = "Saved campaign: %s - Day %d %s - %d gold - %d soldiers" % [
			summary.get("campaign_name", "?"),
			int(summary.get("day", 1)),
			CampaignClock.new(null).time_string_from_hour(float(summary.get("hour", 8.0))),
			int(summary.get("player_gold", 0)),
			int(summary.get("party_size", 0)),
		]
	else:
		_status.text = "No saved campaign found."


func _on_new_campaign() -> void:
	var seed_value := 0
	var raw_seed := _seed_input.text.strip_edges()
	if not raw_seed.is_empty():
		seed_value = int(raw_seed) if raw_seed.is_valid_int() else RngService.stable_hash(raw_seed)
	GameManager.new_campaign(_name_input.text, seed_value)
	SceneManager.change_scene("world_map")


func _on_continue() -> void:
	if not GameManager.continue_campaign():
		_refresh_continue_state()
		return
	SceneManager.change_scene("world_map")


func _on_quit() -> void:
	DebugLogger.info("quit requested from main menu", "MainMenu")
	get_tree().quit()
