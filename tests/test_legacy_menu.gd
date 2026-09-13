extends TestCase
## Step 6.6: the REAL main menu, against the old save format it claims to support.
##
## Step 6.5 fixed [method SaveManager.peek_metadata] and tested the Continue path
## through [method GameManager.continue_campaign]. That left a gap: the tests proved
## the underlying calls worked, but nothing proved the actual menu scene could open a
## legacy save without falling over. The menu is where a player meets the problem, and
## it runs its own code - it reads metadata, decides whether to offer Continue, and
## formats its own status line.
##
## These tests drive the real [code]main_menu.tscn[/code] and read its real state
## through small read-only accessors, so a regression that only shows up in the menu
## is caught by the menu.

const LEGACY_NAME := "A Legacy Campaign"
const MODERN_NAME := "A Modern Campaign"


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	await _test_a_legacy_save_opens_and_continues()
	await _test_the_too_new_warning_still_wins()
	await _test_no_save_means_no_continue()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _fresh_campaign(name: String, seed_value: int) -> CampaignState:
	var state := GameManager.new_campaign(name, seed_value)
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	OverworldService.build(state, GameManager.config()).spawn_if_needed()
	state.player_gold = 9000
	state.settlement("greywatch").recruit_pool["peasant_recruit"] = 40
	var recruitment := RecruitmentService.build(state, GameManager.config())
	recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", 5)
	return state


## Writes a save in the pre-versioning shape the v0 migration exists to handle: no
## save_version field, and player_party stored as a bare array of soldier ids.
## Returns {"members": int, "active": int, "day": int, "gold": int}.
func _write_legacy_save(name: String, seed_value: int, day: int, gold: int) -> Dictionary:
	var state := _fresh_campaign(name, seed_value)
	state.player_gold = gold
	# Lose two, so the roster count and the active count differ - the menu has to
	# report the right one, and a shape-tolerant reader has to find both.
	var killed := 0
	for soldier in state.active_members(state.player_party):
		if killed >= 2:
			break
		soldier.hp = 0
		soldier.status = Soldier.STATUS_DEAD
		killed += 1
	var members := state.roster_member_count(state.player_party)
	var active := state.active_member_count(state.player_party)
	check(GameManager.save_campaign(), "a save was written to rewrite as legacy")

	var path := SaveManager.slot_path()
	var raw := JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary
	raw.erase("save_version")
	raw["campaign_name"] = name
	raw["player_gold"] = gold
	raw["clock"]["day"] = day
	var ids: Array = ((raw.get("player_party", {}) as Dictionary).get("member_ids", []) as Array)
	raw["player_party"] = ids
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(raw, "\t"))
	file.close()
	GameManager.end_campaign()
	return {"members": members, "active": active, "day": day, "gold": gold}


## ---------- 1. the headline case -----------------------------------------

## A player with an old save opens the game. The menu must describe it, offer it, and
## Continue must open it - all through the real scene.
func _test_a_legacy_save_opens_and_continues() -> void:
	section("the real main menu, opening an unversioned legacy save")
	var facts := _write_legacy_save(LEGACY_NAME, 31415, 7, 987)

	check(SaveManager.has_save(), "the legacy save is on disk")
	equal(SaveManager.is_save_too_new(), false, "and is not from a newer build")

	# The real scene, loaded the way the game loads it.
	var menu := await SceneManager.change_scene_and_wait("main_menu")
	not_null(menu, "the main menu scene loaded")
	if menu == null:
		return
	equal(SceneManager.current_key, "main_menu", "the main menu is the current scene")

	# --- it describes the save rather than erroring on it --------------------
	var status := str(menu.call("status_text"))
	check(not status.is_empty(), "the menu shows a status line")
	contains(status, LEGACY_NAME, "naming the legacy campaign")
	contains(status, "%d" % int(facts["gold"]), "with its gold")
	contains(status, "%d" % int(facts["active"]), "and the number of soldiers actually standing")
	check(not status.contains("newer version"),
		"and does not claim it came from a newer build")
	check(not status.contains("No saved campaign"), "nor claims there is no save")
	contains(str(menu.call("offered_campaign_name")), LEGACY_NAME, "the menu offers that campaign by name")

	# --- and the Continue control is genuinely offered -----------------------
	check(bool(menu.call("continue_available")), "Continue is enabled for the legacy save")

	# --- pressing it migrates and opens the campaign -------------------------
	menu.call("press_continue")
	var world := await SceneManager.await_scene("world_map")
	not_null(world, "Continue reached the world map")
	equal(SceneManager.current_key, "world_map", "and the world map is current")

	var campaign := GameManager.campaign
	not_null(campaign, "a campaign is open")
	if campaign == null:
		return
	equal(campaign.campaign_name, LEGACY_NAME, "it is the migrated legacy campaign")
	equal(campaign.player_gold, int(facts["gold"]), "with its gold intact")
	equal(campaign.roster_member_count(campaign.player_party), int(facts["members"]),
		"the whole roster came through the migration")
	equal(campaign.active_member_count(campaign.player_party), int(facts["active"]),
		"and the active force with it")
	equal(campaign.party_members(campaign.player_party).size(), int(facts["members"]),
		"every member is resolvable, casualties included")


## ---------- 2. a save from the future ------------------------------------

## The migration tolerance must not have softened the refusal: a save this build
## cannot read is still refused, and the menu still says why.
func _test_the_too_new_warning_still_wins() -> void:
	section("the menu still refuses a save from a newer build")
	var state := _fresh_campaign(MODERN_NAME, 27182)
	check(GameManager.save_campaign(), "a current-format save was written")

	var path := SaveManager.slot_path()
	var raw := JSON.parse_string(FileAccess.get_file_as_string(path)) as Dictionary
	raw["save_version"] = SaveManager.SAVE_VERSION + 1
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(raw, "\t"))
	file.close()
	GameManager.end_campaign()

	var menu := await SceneManager.change_scene_and_wait("main_menu")
	not_null(menu, "the main menu loaded")
	if menu == null:
		return
	var status := str(menu.call("status_text"))
	contains(status, "newer version", "the menu explains the save is too new")
	check(not bool(menu.call("continue_available")), "and Continue is not offered")
	equal(GameManager.continue_campaign(), false, "the underlying load refuses it too")


## ---------- 3. nothing saved ---------------------------------------------

func _test_no_save_means_no_continue() -> void:
	section("with no save at all, Continue is not offered")
	SaveManager.delete_all_saves()
	var menu := await SceneManager.change_scene_and_wait("main_menu")
	not_null(menu, "the main menu loaded")
	if menu == null:
		return
	check(not bool(menu.call("continue_available")), "Continue is disabled")
	contains(str(menu.call("status_text")), "No saved campaign", "and the menu says so")
	equal(str(menu.call("offered_campaign_name")), "", "no campaign is offered")
