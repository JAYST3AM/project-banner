extends Node2D
## World map - Step 1 placeholder.
##
## Step 1 only has to prove that a campaign can be created and that the session
## survives a scene transition. The real overworld (travel, settlements,
## encounters, HUD, debug panel) lands in Step 2.

@onready var _label: Label = $UI/Panel/Label
@onready var _menu_button: Button = $UI/BackButton


func _ready() -> void:
	_menu_button.pressed.connect(_on_back_to_menu)

	if not GameManager.is_campaign_active():
		_label.text = "No active campaign.\nStart one from the main menu."
		return

	var campaign := GameManager.campaign
	_label.text = "\n".join([
		"WORLD MAP (placeholder - Step 2 builds this out)",
		"",
		"Campaign:      %s" % campaign.campaign_name,
		"Campaign ID:   %s" % campaign.campaign_id,
		"Seed:          %d" % campaign.campaign_seed,
		"Date:          %s" % campaign.clock.full_string(),
		"Gold:          %d" % campaign.player_gold,
		"Party:         %s (%d soldiers)" % [
			campaign.player_party.display_name, campaign.player_party.size(),
		],
		"Position:      %.0f, %.0f" % [campaign.world_position.x, campaign.world_position.y],
		"Settlements:   %d" % campaign.settlements.size(),
	])
	DebugLogger.info("world map ready (campaign '%s')" % campaign.campaign_name, "WorldMap")


func _on_back_to_menu() -> void:
	# Step 1 exposes "save and quit to menu" so the save round-trip is testable
	# by hand before the dedicated save UI exists.
	if GameManager.is_campaign_active():
		GameManager.save_campaign()
	SceneManager.change_scene("main_menu")
