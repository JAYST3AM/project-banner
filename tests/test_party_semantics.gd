extends TestCase
## Step 6.5 remediation: roster membership versus active force.
##
## A party deliberately keeps its dead for the historical record. That means two
## different numbers describe the same party, and using the wrong one is a bug that
## hides itself: a band that has lost three quarters of its strength would still march
## at the pace of a full company and still show as full, while the recruitment screen -
## which counts only the living - offers replacements the player thinks they have no
## room for.
##
## The rule: [b]Party.size() is the historical record; active_member_count() is the
## force.[/b] Travel pace, party capacity, encounter strength and every "how strong is
## this party" display use the force.

const SEED := 70770


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_dead_do_not_slow_the_column()
	await _test_hud_and_capacity_agree()
	_test_dead_remain_on_the_record()
	_test_metadata_reports_both_numbers()
	SaveManager.delete_all_saves()
	GameManager.end_campaign()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _fresh_campaign(name: String, seed_value: int, recruits: int) -> CampaignState:
	var state := GameManager.new_campaign(name, seed_value)
	var builder := WorldBuilder.new(state, GameManager.config())
	builder.build_if_needed()
	var overworld := OverworldService.build(state, GameManager.config())
	overworld.spawn_if_needed()
	if recruits > 0:
		state.player_gold = 9000
		# Top the pool up first: this suite fixes its own numbers rather than
		# depending on how many recruits the content file happens to offer.
		state.settlement("greywatch").recruit_pool["peasant_recruit"] = 40
		var recruitment := RecruitmentService.build(state, GameManager.config())
		recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", recruits)
	return state


## Kills the first [count] living members outright, the way a battle would.
func _kill_members(state: CampaignState, count: int) -> Array[Soldier]:
	var killed: Array[Soldier] = []
	for soldier in state.active_members(state.player_party):
		if killed.size() >= count:
			break
		soldier.hp = 0
		soldier.status = Soldier.STATUS_DEAD
		soldier.record_history(state.clock.day, "death", "Killed at Greywatch.")
		killed.append(soldier)
	return killed


## The HUD redraws on a 0.1s timer rather than every frame, so waiting a single frame
## is not enough for a change to appear in it. Drive the scene's own _process with a
## delta larger than that interval - the same code path the engine uses over time.
func _let_hud_redraw(world: Node) -> void:
	world.call("_process", 0.2)
	await _tick()


func _find_by_script(root: Node, script_file: String) -> Node:
	var script := root.get_script() as GDScript
	if script != null and script.resource_path.get_file() == script_file:
		return root
	for child in root.get_children():
		var found := _find_by_script(child, script_file)
		if found != null:
			return found
	return null


## ---------- 1. travel pace ----------------------------------------------

func _test_dead_do_not_slow_the_column() -> void:
	section("travel: the dead do not slow the living")
	var config := GameManager.config()
	var state := _fresh_campaign("Pace Test", SEED, 10)
	var travel := TravelService.new(state, config)

	var roster := state.roster_member_count(state.player_party)
	equal(roster, 10, "ten soldiers are on the roster")
	equal(state.active_member_count(state.player_party), 10, "and all ten are standing")

	var full_pace := travel.speed_multiplier()

	# Lose six of them.
	_kill_members(state, 6)
	equal(state.roster_member_count(state.player_party), 10, "the roster still holds ten - the dead are kept")
	equal(state.active_member_count(state.player_party), 4, "but only four remain on their feet")
	equal(state.fallen_member_count(state.player_party), 6, "six have fallen")

	var reduced_pace := travel.speed_multiplier()
	greater(reduced_pace, full_pace,
		"the column travels faster once the dead stop being counted as baggage")

	# The pace must match the active force exactly, not the roster.
	var penalty := config.get_float("travel.party_size_speed_penalty", 0.012)
	var floor_fraction := config.get_float("travel.min_speed_fraction", 0.55)
	var expected := maxf(floor_fraction, 1.0 - (4.0 * penalty))
	approx(reduced_pace, expected, 0.0001, "the pace is computed from four soldiers, not ten")

	# The decisive comparison: same active force, different number of graves.
	var like_for_like := _fresh_campaign("Pace Comparison", SEED + 1, 4)
	var comparison := TravelService.new(like_for_like, config)
	equal(like_for_like.active_member_count(like_for_like.player_party), 4,
		"the comparison party is also four strong")
	approx(comparison.speed_multiplier(), reduced_pace, 0.0001,
		"a party of four with six graves marches exactly like a party of four with none")

	# And survivors still count: losing more must be faster still.
	_kill_members(state, 2)
	equal(state.active_member_count(state.player_party), 2, "two remain")
	greater(travel.speed_multiplier(), reduced_pace,
		"the living still affect the pace - it is not simply ignoring the party")


## ---------- 2. the HUD and the recruit cap -------------------------------

func _test_hud_and_capacity_agree() -> void:
	section("HUD: party capacity is stated in terms of the active force")
	var state := _fresh_campaign("HUD Test", SEED + 2, 8)
	var config := GameManager.config()
	var recruitment := RecruitmentService.build(state, config)

	var world := await SceneManager.change_scene_and_wait("world_map")
	not_null(world, "the world map loaded")
	if world == null:
		return
	var hud := _find_by_script(world, "world_hud.gd")
	not_null(hud, "the world map has a HUD")
	if hud == null:
		return

	await _let_hud_redraw(world)
	var cap := recruitment.max_party_size()
	var full_text: String = hud.stat_text("Party")
	contains(full_text, "active", "the HUD says the count is of the active force")
	contains(full_text, "%d / %d active" % [8, cap], "and shows eight of a possible %d" % cap)

	# Lose half. The HUD must show the force, not the roster.
	_kill_members(state, 4)
	await _let_hud_redraw(world)
	var reduced_text: String = hud.stat_text("Party")
	contains(reduced_text, "%d / %d active" % [4, cap], "the HUD drops to four active")
	check(not reduced_text.begins_with("8 /"), "the HUD no longer reports the roster count as the force")
	contains(reduced_text, "4 lost", "and it says how many have been lost")

	# The recruit cap counts the living, so the two now agree.
	equal(recruitment.party_capacity_remaining(), cap - 4,
		"recruitment capacity is measured against the active force")
	equal(recruitment.party_capacity_remaining(),
		cap - state.active_member_count(state.player_party),
		"and matches the number of living soldiers exactly")

	# A party with graves in it must not appear full.
	check(recruitment.party_capacity_remaining() > 0,
		"a party of four with four dead is not full, whatever the roster says")

	# Refill and confirm the HUD tracks the living all the way back up.
	state.player_gold = 9000
	recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", 4)
	await _let_hud_redraw(world)
	contains(hud.stat_text("Party"), "%d / %d active" % [8, cap],
		"the HUD returns to eight active after replacements are recruited")
	equal(recruitment.party_capacity_remaining(), cap - 8, "and the cap is consumed by the living")

	await SceneManager.change_scene_and_wait("main_menu")


## ---------- 3. the record survives ---------------------------------------

func _test_dead_remain_on_the_record() -> void:
	section("history: the dead stay in the roster")
	var state := _fresh_campaign("Record Test", SEED + 3, 6)
	var names_before: Array[String] = []
	for soldier in state.party_members(state.player_party):
		names_before.append(soldier.full_name())
	equal(names_before.size(), 6, "six soldiers were recruited")

	var fallen := _kill_members(state, 2)
	equal(fallen.size(), 2, "two of them fell")

	var listed := state.party_members(state.player_party)
	equal(listed.size(), 6, "the roster still lists all six - casualties are not deleted")
	equal(state.roster_member_count(state.player_party), 6, "the roster count is unchanged")
	equal(state.fallen_members(state.player_party).size(), 2, "two are recorded as fallen")
	equal(state.active_members(state.player_party).size(), 4, "four remain active")

	# Each of the fallen is still individually inspectable.
	for soldier in fallen:
		var record := state.soldier(soldier.id)
		not_null(record, "%s is still on the books" % soldier.full_name())
		equal(record.status, Soldier.STATUS_DEAD, "%s is marked dead" % soldier.full_name())
		equal(record.hp, 0, "%s has no hit points" % soldier.full_name())
		check(record.history.size() > 0, "%s's history is intact" % soldier.full_name())
		check(names_before.has(record.full_name()), "%s kept their name" % record.full_name())

	# And the whole thing survives a save/load round trip.
	var before_names: Array[String] = []
	for soldier in state.party_members(state.player_party):
		before_names.append(soldier.full_name())
	check(SaveManager.save_campaign(state), "the campaign saved")
	var reloaded := SaveManager.load_campaign()
	not_null(reloaded, "the campaign loaded again")
	if reloaded == null:
		return
	equal(reloaded.roster_member_count(reloaded.player_party), 6, "the roster survived the round trip")
	equal(reloaded.active_member_count(reloaded.player_party), 4, "the active force survived too")
	equal(reloaded.fallen_member_count(reloaded.player_party), 2, "so did the casualties")
	var after_names: Array[String] = []
	for soldier in reloaded.party_members(reloaded.player_party):
		after_names.append(soldier.full_name())
	equal(after_names, before_names, "in the same order, with the same names")


## ---------- 4. the main-menu summary -------------------------------------

func _test_metadata_reports_both_numbers() -> void:
	section("save metadata: the menu shows the force, not the roster")
	var state := _fresh_campaign("Metadata Test", SEED + 4, 7)
	_kill_members(state, 3)
	check(SaveManager.save_campaign(state), "the campaign saved")

	var summary := SaveManager.peek_metadata()
	not_null(summary, "the menu can describe the save")
	equal(summary.get("party_size"), 7, "the roster size is reported")
	equal(summary.get("party_active"), 4, "the active force is reported separately")
	equal(summary.get("party_lost"), 3, "and the casualties are reported")
	equal(int(summary.get("party_active", -1)), state.active_member_count(state.player_party),
		"the metadata agrees with the campaign about the active force")
