extends TestCase
## STEP 5 CRITICAL END-TO-END TEST.
##
## Runs the exact path the milestone demands, through the real scenes, and then
## verifies the consequences on the soldiers themselves:
##
##   Start New Campaign -> Travel to Town -> Recruit 5 Soldiers -> Inspect Roster
##   -> Leave Town -> Encounter Bandits -> Attack -> Fight Battle
##   -> Soldiers Die / Survive -> Survivors Gain XP -> Kills Update
##   -> Gold Reward Applied -> Return to World Map -> Open Roster
##   -> Verify Casualties -> Verify Survivor XP -> Verify Kill Counts
##
## If any major part of this loop fails, Step 5 is not complete.

const SEED := 55501
const RECRUITS := 5


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()

	var campaign: CampaignState = await _start_new_campaign()
	if campaign == null:
		return
	await _travel_to_town(campaign)
	var recruited := await _recruit_soldiers(campaign)
	if recruited.is_empty():
		return
	await _inspect_roster(campaign, recruited)
	await _leave_town()
	var battle := await _encounter_bandits(campaign)
	await _fight_the_battle(battle)
	await _verify_consequences(campaign, recruited, battle)
	SaveManager.delete_all_saves()
	GameManager.end_campaign()
	_complete()


## ---- 1. Start New Campaign ----------------------------------------------

func _start_new_campaign() -> CampaignState:
	section("1. start a new campaign")
	var state := GameManager.new_campaign("Step 5 End to End", SEED)
	not_null(state, "the campaign was created")
	if state == null:
		return null
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	equal(state.settlements.size(), 4, "the world was built")

	var world := await SceneManager.change_scene_and_wait("world_map")
	not_null(world, "the world map loaded")
	equal(state.clock.day, 1, "the campaign starts on day 1")
	equal(state.player_party.size(), 0, "the party starts empty")
	check(state.player_gold > 0, "the party starts with gold")
	DebugLogger.info("--- campaign started with %d gold ---" % state.player_gold, "E2E")
	return state


## ---- 2. Travel to Town --------------------------------------------------

func _travel_to_town(state: CampaignState) -> void:
	section("2. travel to a town")
	var travel := TravelService.new(state, GameManager.config())
	state.world_position = state.settlement("greywatch").position + Vector2(300.0, 0.0)
	state.current_settlement_id = ""
	check(travel.set_destination("greywatch"), "a destination was set")
	check(travel.is_travelling(), "the party is travelling")

	var guard := 0
	while travel.is_travelling() and guard < 500:
		guard += 1
		travel.step(0.25)
	check(travel.is_at_settlement("greywatch"), "the party arrived at Greywatch")
	equal(state.current_settlement_id, "greywatch", "the campaign records where the party is")


## ---- 3. Recruit 5 Soldiers ---------------------------------------------

func _recruit_soldiers(state: CampaignState) -> Array[Soldier]:
	section("3. recruit five soldiers")

	var town := await SceneManager.change_scene_and_wait("settlement", {"settlement_id": "greywatch"})
	not_null(town, "the settlement screen loaded")

	var recruitment := RecruitmentService.build(state, GameManager.config())
	var pool := recruitment.available_at(state.settlement("greywatch"), "peasant_recruit")
	check(pool >= RECRUITS, "the town has at least %d recruits to offer (has %d)" % [RECRUITS, pool])

	# The screen's own handler is the code path a player's click takes.
	town.call("_on_recruit_pressed", "peasant_recruit", RECRUITS)

	var recruited: Array[Soldier] = []
	for soldier in state.party_members(state.player_party):
		recruited.append(soldier)
	equal(recruited.size(), RECRUITS, "%d soldiers were recruited" % RECRUITS)
	equal(state.active_members(state.player_party).size(), RECRUITS, "all of them are fit for duty")
	for soldier in recruited:
		check(not soldier.full_name().is_empty(), "a recruited soldier has a name")
		check(soldier.max_hp > 0, "a recruited soldier has hit points")
		equal(soldier.status, Soldier.STATUS_ACTIVE, "a recruited soldier is active")
		equal(soldier.level, 1, "a recruited soldier starts at level 1")
		equal(soldier.kills, 0, "a recruited soldier has no kills yet")
		check(soldier.history.size() > 0, "a recruited soldier has a beginning in their history")
	var names: Array[String] = []
	for soldier in recruited:
		names.append(soldier.full_name())
	DebugLogger.info("--- recruited: %s ---" % ", ".join(names), "E2E")
	return recruited


## ---- 4. Inspect Roster --------------------------------------------------

func _inspect_roster(state: CampaignState, recruited: Array[Soldier]) -> void:
	section("4. inspect the roster")
	var config := GameManager.config()
	for soldier in recruited:
		# Everything the roster panel shows must be readable before the fight.
		check(soldier.age >= config.get_int("recruitment.min_age", 17), "the roster can show an age")
		greater(float(soldier.xp_to_next(config)), 0.0, "the roster can show experience to the next level")
		check(soldier.morale > 0, "the roster can show morale")
		check(soldier.loyalty > 0, "the roster can show loyalty")
		check(soldier.status_display() == "Active", "the roster can show a status")
	check(state.player_party.size() == RECRUITS, "the roster lists the whole party")


## ---- 5. Leave Town ------------------------------------------------------

func _leave_town() -> void:
	section("5. leave town")
	var world := await SceneManager.change_scene_and_wait("world_map", {"select_settlement_id": "greywatch"})
	not_null(world, "left the town and returned to the world map")
	equal(SceneManager.current_key, "world_map", "the world map is the current scene")


## ---- 6/7. Encounter Bandits and Attack ---------------------------------

func _encounter_bandits(state: CampaignState) -> Dictionary:
	section("6. encounter bandits and attack")
	var overworld := OverworldService.build(state, GameManager.config())
	overworld.spawn_if_needed()
	var encounters := EncounterService.build(state, GameManager.config())

	check(state.parties.size() > 0, "there are parties on the overworld")
	# A sensible player picks the smallest band, so the test does too.
	var world_party: WorldParty = null
	for key in state.parties.keys():
		var candidate := state.parties[key] as WorldParty
		if candidate == null or not candidate.is_available():
			continue
		if world_party == null or state.active_members(state.party_of(candidate)).size() \
				< state.active_members(state.party_of(world_party)).size():
			world_party = candidate
	not_null(world_party, "a hostile party exists to fight")
	if world_party == null:
		return {}

	var enemy_count := encounters.enemy_size(world_party)
	check(enemy_count >= 5, "the bandits number at least five (have %d)" % enemy_count)
	greater(float(encounters.enemy_strength(world_party)), 0.0, "the enemy has a strength figure shown in the prompt")
	greater(float(encounters.player_strength()), 0.0, "the player has a strength figure shown in the prompt")

	# Walk into them, exactly as the world map does each frame.
	state.world_position = world_party.position
	var detected := encounters.detect()
	not_null(detected, "the encounter fired")
	if detected == null:
		return {}

	var context := encounters.build_context(detected, true)
	not_null(context, "the battle context was built")

	# 7. Attack: enter the real battlefield carrying that context.
	var battle_scene := await SceneManager.change_scene_and_wait("battle", {"context": context})
	not_null(battle_scene, "the battlefield loaded")
	equal(SceneManager.current_key, "battle", "the battlefield is the current scene")
	return {"scene": battle_scene, "context": context, "world_party": world_party}


## ---- 8. Fight the Battle -----------------------------------------------

func _fight_the_battle(battle: Dictionary) -> void:
	section("7. fight the battle")
	var scene: Node = battle.get("scene", null)
	if scene == null:
		check(false, "there was no battlefield to fight on")
		return

	var view := _find_by_script(scene, "battle_view.gd")
	not_null(view, "the battlefield has a view")
	var simulator: BattleSimulator = null
	if view != null:
		simulator = view.simulator
	not_null(simulator, "the battlefield has a simulator")
	if simulator == null:
		return

	equal(simulator.side_count(BattleContext.SIDE_PLAYER), RECRUITS, "our whole party is on the field")
	equal(simulator.side_count(BattleContext.SIDE_ENEMY), (battle["context"] as BattleContext).enemy_snapshot.size(),
		"the whole enemy party is on the field")

	# Start Battle through the scene's own handler, then drive its _process the
	# way the engine would. This exercises the real scene code, not a copy of it.
	scene.call("_on_start_battle")
	check(simulator.is_running(), "the battle is under way")

	var guard := 0
	while not simulator.is_finished() and guard < 4000:
		guard += 1
		scene.call("_process", 0.05)
	check(simulator.is_finished(), "the battle reached a conclusion")
	DebugLogger.info("--- battle over: winner %s after %.1fs ---" % [simulator.winner, simulator.elapsed], "E2E")

	# Hand the outcome to the next step so the results screen can be checked against
	# what actually happened on the field.
	battle["winner"] = simulator.winner
	battle["elapsed"] = simulator.elapsed

	await _verify_results_screen(GameManager.campaign, battle)


## ---- 8. The results screen ----------------------------------------------

## The results screen must have received the REAL [BattleResult].
##
## This step previously called change_scene_and_wait("battle_results") after the
## battle scene had already transitioned there itself. That queued a second
## transition carrying no payload, which replaced the first - so the screen fell back
## to "No battle result was passed to this screen" while the test happily confirmed
## that the scene existed. Waiting for the transition instead of causing it, and then
## reading what the screen is actually displaying, is what makes these assertions
## mean anything.
func _verify_results_screen(state: CampaignState, battle: Dictionary) -> void:
	section("8. the results screen received the real battle result")

	var results := await SceneManager.await_scene("battle_results")
	not_null(results, "the results screen loaded on its own")
	if results == null:
		return
	equal(SceneManager.current_key, "battle_results", "the results screen is the current scene")

	var shown: BattleResult = results.call("displayed_result")
	not_null(shown, "the results screen is holding a BattleResult")
	if shown == null:
		return

	var text := str(results.call("displayed_text"))
	check(not text.contains("No battle result"),
		"the screen is not showing the empty fallback")

	var context := battle.get("context") as BattleContext
	var summary := BattleResolver.build(state, GameManager.config()).last_battle_summary()
	var field_winner := str(battle.get("winner", ""))

	equal(shown.battle_id, context.battle_id, "it is the battle that was just fought")
	equal(shown.winner, field_winner, "it reports the outcome the simulator reached")

	# Compared against a fresh result rather than a hardcoded string, so a change to
	# the wording cannot silently desynchronise this test from the screen.
	var expected := BattleResult.new()
	expected.winner = field_winner
	equal(shown.title(), expected.title(), "the title matches the outcome")
	contains(text, shown.title(), "the title is actually rendered on screen")

	equal(shown.player_survivors.size(), int(summary.get("player_survivors", -1)),
		"the survivor count matches the campaign record")
	equal(shown.player_dead.size(), int(summary.get("player_dead", -1)),
		"the casualty count matches the campaign record")
	equal(shown.player_dead.size() + shown.player_survivors.size(), shown.player_total,
		"every soldier is accounted for as either dead or alive")
	equal(shown.player_total, RECRUITS, "all %d recruits were on the field" % RECRUITS)
	equal(shown.xp_awarded, int(summary.get("xp", -1)), "the XP total matches the campaign record")
	equal(shown.gold_total(), int(summary.get("gold", -1)), "the gold total matches the campaign record")
	equal(shown.enemy_dead.size(), int(summary.get("enemy_dead", -1)),
		"the enemy casualty count matches the campaign record")

	# The screen must be showing the fight's real details, not just its headline.
	for entry in shown.player_dead:
		contains(text, str(entry.get("name", "")), "%s is named among the losses" % entry.get("name", "?"))
	for entry in shown.player_survivors:
		contains(text, str(entry.get("name", "")), "%s is named among the survivors" % entry.get("name", "?"))
	if shown.gold_total() > 0:
		contains(text, "%d gold" % shown.gold_total(), "the gold won is rendered on screen")

	# And what the screen claims about each soldier must match what the campaign did.
	for entry in shown.player_survivors:
		var soldier := state.soldier(str(entry.get("soldier_id", "")))
		not_null(soldier, "every survivor named on the screen exists in the campaign")
		if soldier == null:
			continue
		equal(soldier.kills, int(entry.get("kills", -1)),
			"%s's kills on screen match the campaign" % soldier.full_name())
		equal(soldier.hp, int(entry.get("hp", -1)),
			"%s's hit points on screen match the campaign" % soldier.full_name())

	DebugLogger.info("--- results screen verified against the campaign record ---", "E2E")

	# Continue is the screen's own action: press it and follow it back.
	results.call("continue_to_world_map")
	var world := await SceneManager.await_scene("world_map")
	not_null(world, "pressing Continue returned to the world map")


## ---- 9-15. Verify the consequences --------------------------------------

func _verify_consequences(state: CampaignState, recruited: Array[Soldier], battle: Dictionary) -> void:
	section("9. back on the world map")
	# The results screen already drove this transition - see _verify_results_screen.
	equal(SceneManager.current_key, "world_map", "the world map is current, reached via Continue")
	var world := SceneManager.current_scene
	not_null(world, "the world map is loaded")
	check(GameManager.campaign == state, "the same campaign came back")

	var summary := BattleResolver.build(state, GameManager.config()).last_battle_summary()
	check(not summary.is_empty(), "the battle was recorded in the campaign")
	if summary.is_empty():
		return
	var winner := str(summary.get("winner", ""))
	var dead_names: Array = summary.get("dead_names", [])
	var survivor_names: Array = summary.get("survivor_names", [])
	DebugLogger.info("--- outcome: %s, %d dead, %d survived, %d gold, %d xp ---" % [
		winner, dead_names.size(), survivor_names.size(),
		int(summary.get("gold", 0)), int(summary.get("xp", 0)),
	], "E2E")

	# 9. Soldiers died / survived, and the record agrees with the field.
	var fallen: Array[Soldier] = []
	var survivors: Array[Soldier] = []
	for soldier in recruited:
		var record := state.soldier(soldier.id)
		not_null(record, "every recruited soldier is still on the books")
		if record == null:
			continue
		if record.status == Soldier.STATUS_DEAD:
			fallen.append(record)
		else:
			survivors.append(record)

	equal(fallen.size(), dead_names.size(), "the number of dead soldiers matches the battle record")
	equal(survivors.size(), survivor_names.size(), "the number of survivors matches the battle record")
	equal(fallen.size() + survivors.size(), RECRUITS, "everyone is either dead or alive")
	DebugLogger.info("--- roster after the fight: %d dead, %d alive ---" % [fallen.size(), survivors.size()], "E2E")

	for soldier in fallen:
		equal(soldier.hp, 0, "%s fell with no hit points left" % soldier.full_name())
		check(soldier.battles_fought >= 1, "%s's battle was recorded" % soldier.full_name())
		equal(soldier.battles_survived, 0, "%s did not survive the battle" % soldier.full_name())
		check(soldier.history.size() > 1, "%s has an ending in their history" % soldier.full_name())

	# 10. Survivors gained XP.
	for soldier in survivors:
		greater(float(soldier.xp), 0.0, "%s earned experience" % soldier.full_name())
		equal(soldier.battles_fought, 1, "%s fought one battle" % soldier.full_name())
		equal(soldier.battles_survived, 1, "%s survived one battle" % soldier.full_name())
		check(soldier.hp > 0, "%s has hit points left" % soldier.full_name())
		check(soldier.hp <= soldier.max_hp, "%s is not above full health" % soldier.full_name())

	# 11. Kills updated. Total kills in the campaign must equal the enemy losses.
	var total_kills := 0
	for soldier in recruited:
		var record := state.soldier(soldier.id)
		if record != null:
			total_kills += record.kills
	equal(total_kills, int(summary.get("enemy_dead", 0)),
		"the party's kill count equals the enemies put down")

	# 12. Gold reward applied.
	var earned := int(summary.get("gold", 0))
	var expected_gold := 0
	if winner == BattleResult.WINNER_PLAYER:
		greater(float(earned), 0.0, "a victory paid gold")
		expected_gold = earned
	else:
		equal(earned, 0, "nothing was paid for a battle that was not won")
	equal(int(state.flags.get("total_battle_gold", 0)), expected_gold,
		"the campaign's total battle earnings match the record")

	# 13-15. Re-open the roster and confirm it tells the same story.
	section("9. re-open the roster")
	var town := await SceneManager.change_scene_and_wait("settlement", {"settlement_id": "greywatch"})
	not_null(town, "the town screen re-opened")
	var listed := state.party_members(state.player_party)
	equal(listed.size(), RECRUITS, "the roster still lists every recruited soldier, casualties included")

	var dead_listed := 0
	for soldier in listed:
		soldier.status_display()  # the roster renders a status for every row
		if soldier.status == Soldier.STATUS_DEAD:
			dead_listed += 1
	equal(dead_listed, fallen.size(), "the roster shows exactly the soldiers who died")

	# The enemy party must reflect the outcome on the map.
	var world_party: WorldParty = battle.get("world_party", null)
	if world_party != null:
		if winner == BattleResult.WINNER_PLAYER:
			check(world_party.defeated, "the beaten bandits are gone from the world map")
		else:
			check(world_party.is_available(), "the bandits that held the field are still on the map")

	await SceneManager.change_scene_and_wait("world_map")
	await SceneManager.change_scene_and_wait("main_menu")


## Finds a node in a loaded scene whose script file matches.
func _find_by_script(root: Node, script_file: String) -> Node:
	var script := root.get_script() as GDScript
	if script != null and script.resource_path.get_file() == script_file:
		return root
	for child in root.get_children():
		var found := _find_by_script(child, script_file)
		if found != null:
			return found
	return null
