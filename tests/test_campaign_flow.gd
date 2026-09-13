extends TestCase
## Campaign lifecycle: creation, transitions that must not destroy the session,
## and a save/continue cycle that must restore it.


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	await _test_new_campaign()
	await _test_scene_transitions_keep_one_session()
	await _test_continue_restores_the_campaign()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()


func _test_new_campaign() -> void:
	section("new campaign")
	var state := GameManager.new_campaign("Test Campaign", 777)
	not_null(state, "new_campaign returns state")
	check(GameManager.is_campaign_active(), "campaign is active after creation")
	equal(state.campaign_name, "Test Campaign", "campaign name stored")
	equal(state.campaign_seed, 777, "campaign seed stored")
	check(not state.campaign_id.is_empty(), "campaign id generated")
	equal(state.player_gold, 250, "starting gold applied from config")
	equal(state.player_party.member_ids.size(), 0, "new campaign starts with an empty party")
	equal(state.player_party.kind, Party.KIND_PLAYER, "player party has the player kind")
	equal(state.clock.day, 1, "campaign starts on day 1")
	approx(state.clock.hour, 8.0, 0.001, "campaign starts at 08:00")
	equal(state.clock.speed_name(), "Normal", "campaign starts at normal speed")
	equal(state.settlements.size(), 0, "no settlements before the world is built (Step 2)")

	# A second campaign must fully replace the first, leaving nothing behind.
	var replacement := GameManager.new_campaign("Second Campaign", 888)
	not_equal(replacement.campaign_id, state.campaign_id, "a new campaign gets a new id")
	equal(replacement.soldiers.size(), 0, "a new campaign starts with no soldiers")


func _test_scene_transitions_keep_one_session() -> void:
	section("scene transitions")
	var campaign_before := GameManager.campaign
	not_null(campaign_before, "a campaign is active before transitioning")

	var world := await SceneManager.change_scene_and_wait("world_map")
	not_null(world, "world map scene loaded")
	equal(SceneManager.current_key, "world_map", "SceneManager reports world_map")
	check(GameManager.campaign == campaign_before,
		"the same CampaignState object survives the transition to the world map")

	var menu := await SceneManager.change_scene_and_wait("main_menu")
	not_null(menu, "main menu scene loaded")
	equal(SceneManager.current_key, "main_menu", "SceneManager reports main_menu")
	check(GameManager.campaign == campaign_before,
		"the same CampaignState object survives the transition back to the menu")

	# Autoloads must exist exactly once no matter how many transitions happened.
	var root := runner.get_tree().root
	for autoload_name in ["GameManager", "SceneManager", "SaveManager", "GameData", "DebugLogger"]:
		var count := 0
		for child in root.get_children():
			if child.name == autoload_name:
				count += 1
		equal(count, 1, "exactly one '%s' singleton exists after transitions" % autoload_name)


func _test_continue_restores_the_campaign() -> void:
	section("continue")
	var state := GameManager.campaign
	not_null(state, "campaign is active before the save test")

	# Give it something distinctive to persist.
	var soldier := Soldier.new()
	soldier.first_name = "Rowan"
	soldier.surname = "Ashdown"
	soldier.unit_type_id = "peasant_recruit"
	soldier.max_hp = 30
	soldier.hp = 30
	state.register_soldier(soldier)
	state.player_party.add_member(soldier.id)
	state.player_gold = 333
	state.world_position = Vector2(250, 400)
	state.clock.day = 5

	check(GameManager.save_campaign(), "campaign saves")
	check(GameManager.has_continue(), "continue is offered once a save exists")

	# Simulate a full application restart: drop the live campaign entirely.
	var expected_id := state.campaign_id
	GameManager.end_campaign()
	check(not GameManager.is_campaign_active(), "campaign cleared to simulate a restart")

	check(GameManager.continue_campaign(), "continue loads the save")
	check(GameManager.is_campaign_active(), "campaign is active again")
	var restored := GameManager.campaign
	not_null(restored, "restored campaign exists")
	if restored == null:
		return
	equal(restored.campaign_id, expected_id, "the same campaign id came back")
	equal(restored.campaign_name, "Second Campaign", "campaign name came back")
	equal(restored.player_gold, 333, "gold came back")
	equal(restored.clock.day, 5, "day came back")
	approx(restored.world_position.x, 250.0, 0.001, "world x came back")
	equal(restored.player_party.member_ids.size(), 1, "party membership came back")
	var restored_soldier := restored.soldier(soldier.id)
	not_null(restored_soldier, "the soldier came back")
	if restored_soldier != null:
		equal(restored_soldier.full_name(), "Rowan Ashdown", "soldier identity came back")
