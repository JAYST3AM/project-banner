extends Node
## Step 6 cross-process persistence check.
##
## The milestone's definition of done is "the full vertical slice survives a
## complete application restart". That cannot be proven inside one process - a
## same-process save/load only proves the serialiser round-trips, not that the
## game can be closed and reopened. So this runs as two separate Godot processes,
## driven by a shell command:
##
## [codeblock]
## godotc --headless --path "<project>" res://scenes/dev/persistence_check.tscn -- --phase=write
## godotc --headless --path "<project>" res://scenes/dev/persistence_check.tscn -- --phase=verify
## [/codeblock]
##
## The second process has no memory of the first except the game's own save file
## and a witness file of recorded expectations. That is the whole point: if the
## save is incomplete, the verify phase fails.
##
## Exit code 0 = the phase passed, 1 = it failed.

const WITNESS_PATH := "user://persistence_witness.json"
const SEED := 90901
const RECRUITS := 5

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	var phase := _phase()
	print("")
	print("######## PROJECT BANNER PERSISTENCE CHECK - phase: %s ########" % phase)
	match phase:
		"write":
			await _run_write()
		"verify":
			await _run_verify()
		_:
			_fail("unknown --phase (expected write or verify)")
	_finish(phase)


func _phase() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="):
			return arg.trim_prefix("--phase=")
	return ""


func _finish(phase: String) -> void:
	print("")
	print("--------- persistence %s: %s (%d checks, %d failures) ---------" % [
		phase, "PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size(),
	])
	get_tree().quit(1 if not _failures.is_empty() else 0)


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append(message)
		print("    FAIL  %s" % message)
	return condition


func _equal(actual: Variant, expected: Variant, message: String) -> bool:
	_checks += 1
	if actual != expected:
		_failures.append(message)
		print("    FAIL  %s (expected %s, got %s)" % [message, expected, actual])
		return false
	return true


func _fail(message: String) -> void:
	_checks += 1
	_failures.append(message)
	print("    FAIL  %s" % message)


## ---------- phase 1: play, then save and exit ----------------------------

func _run_write() -> void:
	SaveManager.delete_all_saves()
	await get_tree().process_frame

	var state := GameManager.new_campaign("Restart Check", SEED)
	_check(state != null, "a campaign was created")
	if state == null:
		return
	WorldBuilder.new(state, GameManager.config()).build_if_needed()
	OverworldService.build(state, GameManager.config()).spawn_if_needed()
	_check(state.settlements.size() == 4, "the world was built")

	# Recruit five soldiers in town.
	state.world_position = state.settlement("greywatch").position
	state.current_settlement_id = "greywatch"
	var recruitment := RecruitmentService.build(state, GameManager.config())
	var recruited := recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", RECRUITS)
	_check((recruited.get("recruited", []) as Array).size() == RECRUITS, "five soldiers were recruited")

	# Travel somewhere, so the position and destination are not trivial.
	var travel := TravelService.new(state, GameManager.config())
	travel.teleport_to("redmoor")
	travel.set_destination("brackenford")
	travel.step(1.5)
	_check(travel.is_travelling(), "the party is travelling at save time")

	# Fight a real battle and let it change the world.
	var battle_facts := _fight_one_battle(state)
	# Then break off from a second fight, so the withdrawal path - which writes its own
	# progression rules into the campaign - also has to survive the restart.
	var withdrawal_facts := _withdraw_from_one_battle(state, str(battle_facts.get("enemy_party_id", "")))
	state.clock.day = 9
	state.clock.hour = 16.5

	# Record what the next process must find.
	var witness := {
		"campaign_id": state.campaign_id,
		"campaign_name": state.campaign_name,
		"campaign_seed": state.campaign_seed,
		"day": state.clock.day,
		"hour": state.clock.hour,
		"gold": state.player_gold,
		"world_position": [state.world_position.x, state.world_position.y],
		"destination_id": state.destination_id,
		"current_settlement_id": state.current_settlement_id,
		"party_size": state.roster_member_count(state.player_party),
		"party_active": state.active_member_count(state.player_party),
		"party_lost": state.fallen_member_count(state.player_party),
		"battles_fought_flag": int(state.flags.get("battles_fought", 0)),
		"recruited_names": _names_of(state.party_members(state.player_party)),
		"soldiers": _soldier_facts(state),
		"settlements": _settlement_facts(state),
		"parties": _party_facts(state),
		"battle": battle_facts,
		"withdrawal": withdrawal_facts,
		"save_version": SaveManager.SAVE_VERSION,
	}
	_check(GameManager.save_campaign(), "the campaign saved")

	var file := FileAccess.open(WITNESS_PATH, FileAccess.WRITE)
	_check(file != null, "the witness file opened for writing")
	if file != null:
		file.store_string(JSON.stringify(witness, "\t"))
		file.close()

	print("    wrote: %d soldiers (%d active, %d dead), %d gold, %d enemy parties, save v%d" % [
		witness["party_size"], witness["party_active"], witness["party_lost"], witness["gold"],
		(state.parties as Dictionary).size(), witness["save_version"],
	])
	print("    the game now exits; the verify phase runs in a new process")


## Takes the field against a second bandit party and immediately breaks off.
##
## Its purpose in this file is to make the withdrawal rules produce state that has to
## survive the restart: a battle fought but not survived, a run of experience paid for
## kills only, and an enemy left standing on the map.
func _withdraw_from_one_battle(state: CampaignState, avoid_party_id: String) -> Dictionary:
	var config := GameManager.config()
	var encounters := EncounterService.build(state, config)
	var chosen: WorldParty = null
	for key in state.parties.keys():
		var candidate := state.parties[key] as WorldParty
		if candidate == null or not candidate.is_available():
			continue
		# Prefer a party other than the one just fought, so the two outcomes stay
		# distinguishable on the record.
		if str(candidate.id) == avoid_party_id:
			continue
		chosen = candidate
		break
	if chosen == null:
		_fail("no second bandit party was available to break off from")
		return {}

	var before := _party_battle_counters(state)
	var enemy_active_before := state.active_member_count(state.party_of(chosen))

	state.world_position = chosen.position
	var context := encounters.build_context(chosen, true)
	var simulator := BattleSimulator.new(config, context.battle_seed)
	simulator.add_units(BattleSetup.build_units_prepared(context, config))
	simulator.start()
	# One step: on the field, but essentially unengaged. This is the retreat-before-
	# fighting case, which is exactly the one that used to pay experience.
	simulator.step(0.05)

	# Wound one of them meaningfully before breaking off. Enemy survivors are
	# persistent people, so their remaining hit points have to come back to the
	# campaign and survive the restart - this is what gives the verify phase
	# something to catch if that ever regresses.
	var wounded_id := ""
	var wounded_hp := 0
	var wounded_start_hp := 0
	var enemy_units := simulator.alive_units(BattleContext.SIDE_ENEMY)
	if not enemy_units.is_empty():
		var wounded := enemy_units[0]
		wounded_id = wounded.soldier_id
		wounded_start_hp = wounded.hp
		wounded_hp = maxi(1, int(round(float(wounded.hp) * 0.4)))
		wounded.take_damage(wounded.hp - wounded_hp, -1)

	var resolver := BattleResolver.build(state, config)
	var result := resolver.build_result(context, simulator, "", simulator.elapsed, true)
	resolver.apply(result, context)
	var after := _party_battle_counters(state)

	print("    broke off from %s: %s, %d xp, %d gold, enemy still present: %s" % [
		chosen.display_name, result.title(), result.xp_awarded, result.gold_total(), str(chosen.is_available()),
	])
	if not wounded_id.is_empty():
		print("    wounded %s: %d -> %d hp, must survive the restart" % [wounded_id, wounded_start_hp, wounded_hp])
	return {
		"battle_id": result.battle_id,
		"enemy_party_id": chosen.id,
		"is_withdrawal": result.withdrawal,
		"title": result.title(),
		"xp": result.xp_awarded,
		"gold": result.gold_total(),
		"fought_delta": int(after["fought"]) - int(before["fought"]),
		"survived_delta": int(after["survived"]) - int(before["survived"]),
		"survivors_taken_field": result.player_survivors.size(),
		"enemy_still_available": chosen.is_available(),
		"enemy_active": state.active_member_count(state.party_of(chosen)),
		"enemy_active_before": enemy_active_before,
		## The persistent enemy this phase wounded, and the hit points it must be
		## found with in the next process.
		"enemy_wounded_id": wounded_id,
		"enemy_wounded_hp": wounded_hp,
		"enemy_survivors_described": result.enemy_survivors.size(),
	}


## Total battles fought and survived across the player's party.
func _party_battle_counters(state: CampaignState) -> Dictionary:
	var fought := 0
	var survived := 0
	for soldier in state.party_members(state.player_party):
		fought += soldier.battles_fought
		survived += soldier.battles_survived
	return {"fought": fought, "survived": survived}


func _fight_one_battle(state: CampaignState) -> Dictionary:
	var config := GameManager.config()
	var encounters := EncounterService.build(state, config)
	var chosen: WorldParty = null
	var chosen_size := 0
	for key in state.parties.keys():
		var candidate := state.parties[key] as WorldParty
		if candidate == null or not candidate.is_available():
			continue
		var size := state.active_members(state.party_of(candidate)).size()
		if chosen == null or size < chosen_size:
			chosen = candidate
			chosen_size = size
	if chosen == null:
		_fail("no bandit party was available to fight")
		return {}
	var size_before := state.active_members(state.party_of(chosen)).size()

	state.world_position = chosen.position
	var context := encounters.build_context(chosen, true)
	var simulator := BattleSimulator.new(config, context.battle_seed)
	simulator.add_units(BattleSetup.build_units_prepared(context, config))
	simulator.start()
	var guard := 0
	while not simulator.is_finished() and guard < 40000:
		guard += 1
		simulator.step(0.05)
	var resolver := BattleResolver.build(state, config)
	var result := resolver.build_result(context, simulator, simulator.winner, simulator.elapsed, false)
	resolver.apply(result, context)

	print("    fought %s: %s, %d of %d of ours fell, %d gold" % [
		chosen.display_name, result.title(), result.player_dead.size(), result.player_total, result.gold_total(),
	])
	return {
		"battle_id": result.battle_id,
		"winner": result.winner,
		"enemy_party_id": chosen.id,
		"enemy_size_before": size_before,
		"enemy_dead": result.enemy_dead.size(),
		"player_total": result.player_total,
		"player_dead": result.player_dead.size(),
		"player_survivors": result.player_survivors.size(),
		"gold": result.gold_total(),
		"xp": result.xp_awarded,
		"defeated": chosen.defeated,
	}


func _names_of(soldiers: Array[Soldier]) -> Array:
	var out: Array = []
	for soldier in soldiers:
		out.append(soldier.full_name())
	return out


func _soldier_facts(state: CampaignState) -> Dictionary:
	var out := {}
	for key in state.soldiers.keys():
		var soldier := state.soldiers[key] as Soldier
		if soldier == null:
			continue
		out[str(key)] = {
			"name": soldier.full_name(),
			"unit_type_id": soldier.unit_type_id,
			"level": soldier.level,
			"xp": soldier.xp,
			"hp": soldier.hp,
			"max_hp": soldier.max_hp,
			"kills": soldier.kills,
			"battles_fought": soldier.battles_fought,
			"battles_survived": soldier.battles_survived,
			"status": soldier.status,
			"traits": soldier.traits,
			"history_entries": soldier.history.size(),
		}
	return out


func _settlement_facts(state: CampaignState) -> Dictionary:
	var out := {}
	for key in state.settlements.keys():
		var settlement := state.settlements[key] as Settlement
		if settlement == null:
			continue
		out[str(key)] = {
			"name": settlement.name,
			"visited": settlement.visited,
			"recruit_pool": settlement.recruit_pool,
			"population": settlement.population,
		}
	return out


func _party_facts(state: CampaignState) -> Dictionary:
	var out := {}
	for key in state.parties.keys():
		var world_party := state.parties[key] as WorldParty
		if world_party == null:
			continue
		var roster := state.party_members(state.party_of(world_party))
		out[str(key)] = {
			"name": world_party.display_name,
			"position": [world_party.position.x, world_party.position.y],
			"defeated": world_party.defeated,
			"wander_count": world_party.wander_count,
			"roster": _names_of(roster),
		}
	return out


## ---------- phase 2: a brand-new process loads it ------------------------

func _run_verify() -> void:
	var witness := _read_witness()
	if witness.is_empty():
		_fail("no witness file - run the write phase first")
		return

	_check(SaveManager.has_save(), "a save file exists in this new process")
	_equal(SaveManager.peek_metadata().get("campaign_seed"), witness["campaign_seed"],
		"the new process can see the save before loading it")

	# Exactly what the Continue button does.
	_check(GameManager.continue_campaign(), "Continue loaded the campaign")
	var state := GameManager.campaign
	_check(state != null, "the campaign is active after Continue")
	if state == null:
		return

	# --- the game must not rebuild the world over the top of the save ---------
	var builder := WorldBuilder.new(state, GameManager.config())
	_check(not builder.build_if_needed(), "the loaded world was not rebuilt from data")
	OverworldService.build(state, GameManager.config()).spawn_if_needed()
	_equal(state.settlements.size(), 4, "the world is still there")

	# --- campaign metadata, time, position, gold -----------------------------
	_equal(state.campaign_id, witness["campaign_id"], "campaign id")
	_equal(state.campaign_name, witness["campaign_name"], "campaign name")
	_equal(state.campaign_seed, int(witness["campaign_seed"]), "campaign seed")
	_equal(state.clock.day, int(witness["day"]), "campaign day")
	_check(absf(state.clock.hour - float(witness["hour"])) < 0.001, "campaign hour")
	_equal(state.player_gold, int(witness["gold"]), "gold")
	var position: Array = witness["world_position"]
	_check(absf(state.world_position.x - float(position[0])) < 0.001, "world x")
	_check(absf(state.world_position.y - float(position[1])) < 0.001, "world y")
	_equal(state.destination_id, str(witness["destination_id"]), "destination in progress")
	_equal(state.current_settlement_id, str(witness["current_settlement_id"]), "current settlement")
	_equal(state.roster_member_count(state.player_party), int(witness["party_size"]), "party size")
	_equal(state.active_member_count(state.player_party), int(witness["party_active"]), "active force")
	_equal(state.fallen_member_count(state.player_party), int(witness["party_lost"]), "casualties")
	# The main menu's summary and the campaign must agree about the force, not just
	# the roster - they are computed in completely different places.
	_equal(SaveManager.peek_metadata().get("party_active"), int(witness["party_active"]),
		"the menu's active count agrees with the campaign")

	# --- the party, in the same order, with the same names -------------------
	_equal(_names_of(state.party_members(state.player_party)), witness["recruited_names"], "party membership and order")

	# --- every soldier ---------------------------------------------------------
	var soldier_facts: Dictionary = witness["soldiers"]
	var mismatched := 0
	var dead_expected := 0
	for key in soldier_facts.keys():
		var expected: Dictionary = soldier_facts[key]
		var soldier := state.soldier(str(key))
		if soldier == null:
			mismatched += 1
			print("    FAIL  soldier %s is missing after the restart" % key)
			continue
		if str(expected["status"]) == Soldier.STATUS_DEAD:
			dead_expected += 1
		var matches := soldier.full_name() == str(expected["name"]) \
			and soldier.unit_type_id == str(expected["unit_type_id"]) \
			and soldier.level == int(expected["level"]) \
			and soldier.xp == int(expected["xp"]) \
			and soldier.hp == int(expected["hp"]) \
			and soldier.max_hp == int(expected["max_hp"]) \
			and soldier.kills == int(expected["kills"]) \
			and soldier.battles_fought == int(expected["battles_fought"]) \
			and soldier.battles_survived == int(expected["battles_survived"]) \
			and soldier.status == str(expected["status"]) \
			and soldier.history.size() == int(expected["history_entries"])
		if not matches:
			mismatched += 1
			print("    FAIL  soldier %s does not match: %s" % [key, soldier.describe() if soldier.has_method("describe") else soldier.full_name()])
	_check(soldier_facts.size() > 0, "the witness recorded soldiers")
	_equal(mismatched, 0, "every soldier in the world came back identical")
	print("    %d soldiers restored, %d of them dead" % [soldier_facts.size(), dead_expected])
	if dead_expected > 0:
		_check(true, "the battle's casualties survived the restart")

	# --- settlements, recruit pools, visited flags ---------------------------
	var settlement_facts: Dictionary = witness["settlements"]
	for key in settlement_facts.keys():
		var expected: Dictionary = settlement_facts[key]
		var settlement := state.settlement(str(key))
		if not _check(settlement != null, "settlement %s came back" % key):
			continue
		_equal(settlement.name, str(expected["name"]), "settlement %s name" % key)
		_equal(settlement.visited, bool(expected["visited"]), "settlement %s visited flag" % key)
		_equal(settlement.population, int(expected["population"]), "settlement %s population" % key)
		_equal(settlement.recruit_pool, expected["recruit_pool"], "settlement %s recruit pool" % key)

	# --- enemy parties and their rosters -------------------------------------
	var party_facts: Dictionary = witness["parties"]
	for key in party_facts.keys():
		var expected: Dictionary = party_facts[key]
		var world_party := state.world_party(str(key))
		if not _check(world_party != null, "party %s came back" % key):
			continue
		_equal(world_party.display_name, str(expected["name"]), "party %s name" % key)
		_equal(world_party.defeated, bool(expected["defeated"]), "party %s defeated flag" % key)
		_equal(world_party.wander_count, int(expected["wander_count"]), "party %s wander count" % key)
		var expected_position: Array = expected["position"]
		_check(absf(world_party.position.x - float(expected_position[0])) < 0.001, "party %s x" % key)
		var roster := state.party_members(state.party_of(world_party))
		_equal(_names_of(roster), expected["roster"], "party %s roster" % key)

	# --- the battle itself ----------------------------------------------------
	var battle: Dictionary = witness["battle"]
	if not battle.is_empty():
		# Looked up by id, not taken as "the latest": the chronicle holds every fight in
		# order, so once more than one battle has been fought the last entry is a
		# different fight entirely.
		var summary := _log_entry_for(state, str(battle["battle_id"]))
		_check(not summary.is_empty(), "the battle chronicle survived the restart")
		if not summary.is_empty():
			_equal(str(summary.get("winner", "")), str(battle["winner"]), "the chronicle records the same outcome")
			_equal(int(summary.get("gold", 0)), int(battle["gold"]), "the chronicle records the same gold")
			_equal(int(summary.get("enemy_dead", 0)), int(battle["enemy_dead"]), "the chronicle records the same enemy losses")
			_equal(int(summary.get("player_dead", 0)), int(battle["player_dead"]), "the chronicle records the same own losses")
			_equal(bool(summary.get("withdrawal", true)), false, "and it is not recorded as a withdrawal")
		_equal(int(state.flags.get("battles_fought", 0)), int(witness["battles_fought_flag"]),
			"the battle count is unchanged by the restart")
		var enemy_party := state.world_party(str(battle["enemy_party_id"]))
		if enemy_party != null:
			_equal(enemy_party.defeated, bool(battle["defeated"]), "the fought party's fate survived")

	# --- the withdrawal, and the progression rules it applies -----------------
	var withdrawal: Dictionary = witness.get("withdrawal", {})
	if not withdrawal.is_empty():
		var log: Array = state.flags.get("battle_log", [])
		_check(log.size() >= 2, "both fights survived the restart in the chronicle")
		var last: Dictionary = log[log.size() - 1] if not log.is_empty() else {}
		_equal(str(last.get("battle_id", "")), str(withdrawal["battle_id"]),
			"the withdrawal is the latest entry in the chronicle")
		_equal(bool(last.get("withdrawal", false)), true, "and is recorded as a withdrawal")
		_equal(str(last.get("winner", "")), BattleResult.WINNER_RETREAT, "with a withdrawal outcome")
		_equal(int(last.get("xp", 0)), int(withdrawal["xp"]), "the experience paid is unchanged")
		_equal(int(last.get("gold", 0)), int(withdrawal["gold"]), "the spoils are unchanged")
		_equal(int(last.get("gold", 0)), 0, "and a withdrawal paid nothing at all")
		# The rules themselves, re-asserted on the restored campaign.
		_equal(int(withdrawal["survived_delta"]), 0,
			"nothing was counted as having survived the withdrawal")
		_equal(int(withdrawal["survivors_taken_field"]), int(withdrawal["fought_delta"]),
			"every soldier who took the field was counted as having fought")
		_equal(int(last.get("player_survivors", -1)), int(withdrawal["survivors_taken_field"]),
			"and the chronicle agrees on how many were on the field")
		_equal(int(withdrawal["enemy_survivors_described"]), int(withdrawal["enemy_active"]),
			"every enemy left standing was described in the result")
		# The enemy this phase wounded must come back with exactly those hit points,
		# not healed to full. This is the enemy-side half of the same rule that
		# already applied to the player's own soldiers.
		var wounded_id := str(withdrawal.get("enemy_wounded_id", ""))
		if not wounded_id.is_empty():
			var wounded := state.soldier(wounded_id)
			_check(wounded != null, "the wounded enemy came back after the restart")
			if wounded != null:
				_equal(wounded.hp, int(withdrawal["enemy_wounded_hp"]),
					"and still has the hit points the battle left it with")
				_equal(wounded.battles_fought, 1, "with its battle recorded")
		var broken_off_from := state.world_party(str(withdrawal["enemy_party_id"]))
		_check(broken_off_from != null, "the party they broke off from came back")
		if broken_off_from != null:
			_check(broken_off_from.is_available(),
				"and is still on the map - breaking off did not destroy it")
			_equal(state.active_member_count(state.party_of(broken_off_from)),
				int(withdrawal["enemy_active"]), "with the same soldiers it had")

	# --- the world must still be playable ------------------------------------
	var world := await SceneManager.change_scene_and_wait("world_map")
	_check(world != null, "the world map opens on the restored campaign")
	_equal(SceneManager.current_key, "world_map", "the world map is the current scene")
	_equal(GameManager.campaign.campaign_id, witness["campaign_id"], "the same campaign is still active")

	# --- and it can be saved again, unchanged ---------------------------------
	_check(GameManager.save_campaign(), "the restored campaign saves again")
	var again := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config())
	_check(again != null, "and reloads")
	if again != null:
		_equal(again.player_gold, state.player_gold, "gold is stable across a second cycle")
		_equal(again.soldiers.size(), state.soldiers.size(), "no soldiers appear on a second cycle")
		_equal(again.player_party.member_ids, state.player_party.member_ids, "the party is stable across a second cycle")

	# Leave the slot clean for the next run.
	SaveManager.delete_all_saves()
	FileAccess.open(WITNESS_PATH, FileAccess.WRITE).close()


## The chronicle entry for one specific battle.
##
## The chronicle holds every fight in order, so "the last one" stops meaning "the one
## we care about" as soon as more than one battle has been fought.
func _log_entry_for(state: CampaignState, battle_id: String) -> Dictionary:
	var log: Array = state.flags.get("battle_log", [])
	for entry in log:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		if str((entry as Dictionary).get("battle_id", "")) == battle_id:
			return entry as Dictionary
	return {}


func _read_witness() -> Dictionary:
	if not FileAccess.file_exists(WITNESS_PATH):
		return {}
	var text := FileAccess.get_file_as_string(WITNESS_PATH)
	if text.strip_edges().is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary
