extends Node
## GameManager (autoload).
##
## Creates, owns and destroys the active [CampaignState]. It is intentionally the
## *only* long-lived holder of campaign data: scenes come and go, the campaign
## does not. Anything that needs campaign data asks GameManager for it.

signal campaign_started(state: CampaignState)
signal campaign_loaded(state: CampaignState)
signal campaign_cleared()

var campaign: CampaignState = null


func is_campaign_active() -> bool:
	return campaign != null


func config() -> GameConfig:
	if GameData.config == null:
		GameData.reload()
	return GameData.config


## Creates a brand-new campaign. [param seed_value] of 0 means "pick one".
func new_campaign(campaign_name: String = "", seed_value: int = 0) -> CampaignState:
	var cfg := config()
	var final_name := campaign_name.strip_edges()
	if final_name.is_empty():
		final_name = cfg.get_string("campaign.default_campaign_name", "A New Banner")
	if seed_value == 0:
		seed_value = randi()

	campaign = CampaignState.create(cfg, final_name, seed_value)
	campaign.campaign_id = generate_campaign_id()
	campaign.created_at = Time.get_datetime_string_from_system(false, true)

	DebugLogger.info("new campaign '%s' (seed %d, id %s)" % [
		campaign.campaign_name, campaign.campaign_seed, campaign.campaign_id,
	], "GameManager")
	campaign_started.emit(campaign)
	return campaign


func generate_campaign_id() -> String:
	var stamp := Time.get_datetime_string_from_system(false, true)
	stamp = stamp.replace("-", "").replace(":", "").replace("T", "").replace(" ", "")
	return "camp_%s_%04d" % [stamp, randi() % 10000]


## Loads the most recent save. Returns false (and leaves [member campaign] alone)
## when there is nothing usable to load.
func continue_campaign(slot: int = SaveManager.SLOT_DEFAULT) -> bool:
	if not SaveManager.has_save(slot):
		DebugLogger.info("continue: no save in slot %d" % slot, "GameManager")
		return false
	var loaded := SaveManager.load_campaign(slot, config())
	if loaded == null:
		return false
	campaign = loaded
	campaign_loaded.emit(campaign)
	return true


## Ends the active campaign and returns to whatever the caller moved to.
func end_campaign() -> void:
	if campaign != null:
		DebugLogger.info("campaign '%s' ended" % campaign.campaign_name, "GameManager")
	campaign = null
	campaign_cleared.emit()


func save_campaign(slot: int = SaveManager.SLOT_DEFAULT) -> bool:
	if campaign == null:
		DebugLogger.warn("save requested with no active campaign", "GameManager")
		return false
	return SaveManager.save_campaign(campaign, slot)


func has_continue() -> bool:
	return SaveManager.has_save(SaveManager.SLOT_DEFAULT)


func continue_summary() -> Dictionary:
	return SaveManager.peek_metadata(SaveManager.SLOT_DEFAULT)
