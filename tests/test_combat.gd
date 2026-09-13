extends TestCase
## Step 5 combat mechanics: damage and death in the simulator, the battle result,
## and the resolver that writes consequences back to the campaign.

const SEED := 30333


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_damage_and_death()
	_test_victory_and_walls()
	_test_result_contents()
	_test_resolver_applies_consequences()
	_test_retreat_and_defeat()
	_test_determinism()
	_test_starting_fight_is_a_contest()
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
		state.player_gold = 5000
		var recruitment := RecruitmentService.build(state, GameManager.config())
		recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", recruits)
	return state


## A battle ready to fight, driven by the real services.
func _make_battle(state: CampaignState, party_index: int = 0) -> Dictionary:
	var config := GameManager.config()
	var encounters := EncounterService.build(state, config)
	var world_party := state.parties[str(state.parties.keys()[party_index])] as WorldParty
	state.world_position = world_party.position
	var context := encounters.build_context(world_party, true)
	var units := BattleSetup.build_units_prepared(context, config)
	var simulator := BattleSimulator.new(config, context.battle_seed)
	simulator.add_units(units)
	return {"context": context, "simulator": simulator, "world_party": world_party}


## Runs a battle to completion and returns the result, without touching campaign
## state beyond what the resolver is told to do.
func _fight_to_the_end(bundle: Dictionary, apply: bool) -> BattleResult:
	var simulator: BattleSimulator = bundle["simulator"]
	var context: BattleContext = bundle["context"]
	simulator.start()
	var guard := 0
	while not simulator.is_finished() and guard < 20000:
		guard += 1
		simulator.step(0.05)
	check(simulator.is_finished(), "the battle finished within the step budget")
	var resolver := BattleResolver.build(GameManager.campaign, GameManager.config())
	var result := resolver.build_result(context, simulator, simulator.winner, simulator.elapsed, false)
	if apply:
		resolver.apply(result, context)
	return result


## ---------- tests --------------------------------------------------------

func _test_damage_and_death() -> void:
	section("damage and death")
	var config := GameManager.config()
	var bundle := _make_battle(_fresh_campaign("Damage Test", SEED, 6))
	var simulator: BattleSimulator = bundle["simulator"]
	simulator.start()

	var hits := 0
	var misses := 0
	var deaths := 0
	var guard := 0
	while not simulator.is_finished() and guard < 20000:
		guard += 1
		for event in simulator.step(0.05):
			match str(event.get("type", "")):
				"hit":
					hits += 1
					check(int(event.get("damage", 0)) >= 1, "every landed blow does at least 1 damage")
				"miss":
					misses += 1
				"death":
					deaths += 1

	check(simulator.is_finished(), "the battle ended")
	greater(float(hits), 0.0, "blows were struck")
	greater(float(misses), 0.0, "some blows missed (hit chance is not 100%)")
	greater(float(deaths), 0.0, "somebody died")
	equal(deaths, _dead_count(simulator), "every death event matches a unit that is not alive")

	# Dead units must be out of the fight: no hp, not alive, and never targeted.
	for unit in simulator.units:
		if not unit.alive:
			equal(unit.hp, 0, "a fallen unit is on zero hit points")
			check(not unit.is_alive(), "a fallen unit is not alive")
	for unit in simulator.alive_units():
		check(unit.hp > 0, "a standing unit has hit points left")

	# Kills are attributed to the killer, and the killer is one of ours or theirs.
	var total_kills := 0
	for unit in simulator.units:
		total_kills += unit.kills
	equal(total_kills, deaths, "every death is attributed to exactly one killer")
	for unit in simulator.units:
		if unit.kills > 0:
			greater(float(unit.damage_dealt), 0.0, "a unit with kills dealt damage")

	# Defence must actually reduce damage taken. Measured through the real
	# simulator rather than by calling internals: one attacker, one punching bag,
	# run for a fixed time and compare damage taken.
	var soft_damage := _measure_damage_taken(config, 0)
	var hard_damage := _measure_damage_taken(config, 14)
	greater(float(soft_damage), 0.0, "the unarmoured target was hit")
	less(float(hard_damage), float(soft_damage), "defence reduces the damage taken")


## Total damage an attacker with attack 10 deals to a target with the given
## defence over a fixed 20 seconds of simulated fighting.
func _measure_damage_taken(config: GameConfig, defence: int) -> int:
	var attacker := BattleUnit.from_snapshot({
		"soldier_id": "t_attacker", "name": "Attacker", "unit_type_id": "x", "unit_name": "X",
		"level": 1, "max_hp": 100000, "hp": 100000, "attack": 10, "defence": 0,
		"move_speed": 5.0, "attack_range": 1.5, "attack_cooldown": 0.2, "ranged": false,
	}, BattleContext.SIDE_PLAYER, 0)
	var target := BattleUnit.from_snapshot({
		"soldier_id": "t_target", "name": "Target", "unit_type_id": "x", "unit_name": "X",
		"level": 1, "max_hp": 100000, "hp": 100000, "attack": 0, "defence": defence,
		"move_speed": 0.0, "attack_range": 1.0, "attack_cooldown": 1.0, "ranged": false,
	}, BattleContext.SIDE_ENEMY, 1)
	var simulator := BattleSimulator.new(config, 4242)
	simulator.add_units([attacker, target])
	attacker.position = Vector2(10.0, 10.0)
	target.position = Vector2(11.0, 10.0)
	simulator.start()
	for i in 200:
		simulator.step(0.1)
	return target.damage_taken


func _dead_count(simulator: BattleSimulator) -> int:
	var count := 0
	for unit in simulator.units:
		if not unit.alive:
			count += 1
	return count


func _test_victory_and_walls() -> void:
	section("victory conditions")
	var config := GameManager.config()

	# Regression guard: a melee unit must be able to reach past the distance the
	# separation pass holds units apart, or it can never land a blow. This exact
	# mismatch - attack_range 1.0 against a separation minimum of 1.35 - made
	# melee combat completely inert while archers still shot people dead.
	var minimum_gap := config.get_float("battle.separation_radius", 1.5) * BattleSimulator.SEPARATION_FACTOR
	var units := UnitCatalog.load_from()
	for definition in units.all():
		if definition.ranged:
			continue
		greater(definition.attack_range, minimum_gap,
			"%s can reach past the separation distance (range %.1f, gap %.2f)" % [
				definition.id, definition.attack_range, minimum_gap])

	# And a melee-only fight must actually produce damage.
	var melee_damage := _measure_damage_taken(config, 0)
	greater(float(melee_damage), 0.0, "two melee units in contact inflict damage on each other")

	# One side wiped out ends the battle and names the other the winner.
	var state := _fresh_campaign("Victory Test", SEED + 1, 4)
	var bundle := _make_battle(state)
	var simulator: BattleSimulator = bundle["simulator"]
	simulator.start()
	for unit in simulator.units:
		if unit.side == BattleContext.SIDE_ENEMY:
			unit.take_damage(9999, -1)
	simulator.step(0.05)
	check(simulator.is_finished(), "wiping out one side ends the battle")
	equal(simulator.winner, BattleContext.SIDE_PLAYER, "the surviving side wins")

	# The timeout produces a draw rather than an endless fight.
	var dragged := BattleSimulator.new(config, 99)
	dragged.max_duration = 0.5
	var stuck_units := BattleSetup.build_units_prepared(bundle["context"], config)
	for unit in stuck_units:
		unit.attack = 0
	dragged.add_units(stuck_units)
	dragged.start()
	for i in 20:
		dragged.step(0.1)
	check(dragged.is_finished(), "the battle ends when it runs out of time")
	equal(dragged.winner, "", "a battle that times out has no winner")


func _test_determinism() -> void:
	section("determinism")
	var state_a := _fresh_campaign("Determinism A", SEED + 6, 5)
	var state_b := _fresh_campaign("Determinism B", SEED + 6, 5)
	var bundle_a := _make_battle(state_a)
	var bundle_b := _make_battle(state_b)

	var result_a := _fight_to_the_end(bundle_a, false)
	var result_b := _fight_to_the_end(bundle_b, false)

	equal(result_a.winner, result_b.winner, "the same seed fights the same battle")
	equal(result_a.player_dead.size(), result_b.player_dead.size(), "the same losses")
	equal(result_a.enemy_dead.size(), result_b.enemy_dead.size(), "the same enemy losses")
	equal(result_a.gold_total(), result_b.gold_total(), "the same spoils")
	var names_a: Array = []
	var names_b: Array = []
	for entry in result_a.player_dead:
		names_a.append(str(entry.get("name", "")))
	for entry in result_b.player_dead:
		names_b.append(str(entry.get("name", "")))
	equal(names_a, names_b, "the same people died")


## Balance guard: the fight a brand-new party picks is a contest, not a foregone
## conclusion.
##
## Five freshly recruited peasants are pitted against the weakest bandit band the
## world spawns (what a careful player would choose) and against the strongest
## (what happens if they are careless). Both ends are measured across many
## campaign seeds and reported.
##
## This is deliberately a *range* assertion. A vertical slice where the opening
## fight is always lost teaches the player nothing and hides broken combat maths;
## one where it is always won hides it too. If this fails, the numbers in
## data/units/unit_types.json or data/encounters/bandit_parties.json have drifted
## out of the band the design intends.
func _test_starting_fight_is_a_contest() -> void:
	section("the opening fight is a contest")
	var weakest := _run_opening_fights(true, 24)
	var strongest := _run_opening_fights(false, 24)

	print("      opening fight vs the WEAKEST band: %d/%d won, %d enemy casualties" % [
		int(weakest["wins"]), int(weakest["trials"]), int(weakest["enemy_casualties"]),
	])
	print("      opening fight vs the STRONGEST band: %d/%d won, %d enemy casualties" % [
		int(strongest["wins"]), int(strongest["trials"]), int(strongest["enemy_casualties"]),
	])

	equal(int(weakest["trials"]), 24, "every weakest-band trial produced an outcome")
	greater(weakest["wins"], 0.0, "a fresh five-soldier party can beat the weakest band")
	check(weakest["wins"] >= int(weakest["trials"]) * 0.25,
		"beating the weakest band is a realistic plan, not a coin-flip against the player (%d/%d)" % [
			int(weakest["wins"]), int(weakest["trials"]),
		])
	greater(weakest["enemy_casualties"], 0.0, "the opening fight inflicts enemy casualties")

	greater(strongest["enemy_casualties"], 0.0, "even the strongest band takes losses")
	less(strongest["wins"], float(strongest["trials"]),
		"the strongest band is genuinely dangerous to a fresh party (%d/%d won)" % [
			int(strongest["wins"]), int(strongest["trials"]),
		])


## Runs the opening fight across seeds, always against the smallest (or largest)
## bandit band. Returns {"wins", "losses", "draws", "trials", "enemy_casualties"}.
func _run_opening_fights(smallest: bool, trials: int) -> Dictionary:
	var wins := 0
	var losses := 0
	var draws := 0
	var completed := 0
	var enemy_casualties := 0
	var config := GameManager.config()
	var encounters := EncounterService.build(GameManager.campaign, config)

	for trial in trials:
		var state := _fresh_campaign("Balance %s %d" % ["small" if smallest else "large", trial],
			SEED + 100 + trial, 5)
		var chosen: WorldParty = null
		var chosen_size := 0
		for key in state.parties.keys():
			var candidate := state.parties[key] as WorldParty
			if candidate == null or not candidate.is_available():
				continue
			var size := state.active_members(state.party_of(candidate)).size()
			if chosen == null \
					or (smallest and size < chosen_size) \
					or (not smallest and size > chosen_size):
				chosen = candidate
				chosen_size = size
		if chosen == null:
			continue

		encounters.state = state
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
		completed += 1
		enemy_casualties += result.enemy_dead.size()
		match result.winner:
			BattleResult.WINNER_PLAYER:
				wins += 1
			BattleResult.WINNER_ENEMY:
				losses += 1
			_:
				draws += 1

	encounters.state = GameManager.campaign
	return {
		"wins": wins,
		"losses": losses,
		"draws": draws,
		"trials": completed,
		"enemy_casualties": enemy_casualties,
	}


func _test_result_contents() -> void:
	section("battle result")
	var state := _fresh_campaign("Result Test", SEED + 2, 6)
	var bundle := _make_battle(state)
	var context: BattleContext = bundle["context"]
	var simulator: BattleSimulator = bundle["simulator"]
	var party_size := state.active_members(state.player_party).size()
	equal(party_size, 6, "six soldiers were recruited for the test")

	# Force a clean player victory so the reward path is deterministic.
	simulator.start()
	for unit in simulator.units:
		if unit.side == BattleContext.SIDE_ENEMY:
			unit.take_damage(9999, -1)
	simulator.step(0.05)

	var resolver := BattleResolver.build(state, GameManager.config())
	var result := resolver.build_result(context, simulator, simulator.winner, simulator.elapsed, false)

	equal(result.winner, BattleResult.WINNER_PLAYER, "the player won")
	check(result.player_won(), "player_won() agrees")
	equal(result.title(), "VICTORY", "the title reads VICTORY")
	equal(result.enemy_display_name, context.enemy_display_name, "the enemy is named")
	equal(result.player_total, party_size, "the player's whole party was counted")
	equal(result.enemy_total, context.enemy_snapshot.size(), "the enemy's whole party was counted")
	equal(result.enemy_dead.size(), result.enemy_total, "every enemy was put down")
	equal(result.player_dead.size(), 0, "nobody on our side fell")
	equal(result.player_survivors.size(), party_size, "every one of ours survived")

	var config := GameManager.config()
	var expected_xp := config.get_int("xp.participation", 10)
	expected_xp += config.get_int("xp.survived_battle", 15)
	expected_xp += config.get_int("xp.victory", 25)
	for entry in result.player_survivors:
		equal(int(entry.get("xp_gained", 0)), expected_xp,
			"a kill-less victory survivor earns participation + survival + victory")
		check(not str(entry.get("soldier_id", "")).is_empty(), "the survivor keeps an id")
		check(not str(entry.get("name", "")).is_empty(), "the survivor has a name")

	greater(float(result.gold_total()), 0.0, "a victory pays gold")
	greater(float(result.gold_from_enemies), 0.0, "gold comes from the fallen")
	equal(result.gold_from_victory, config.get_int("rewards.victory_gold_bonus", 25), "the victory bonus is paid")
	greater(float(result.xp_awarded), 0.0, "experience was awarded")
	contains(result.headline(), "defeated", "the headline reports the enemy count")

	# Result must survive being handed around.
	var round_tripped := BattleResult.from_dict(result.to_dict())
	equal(round_tripped.winner, result.winner, "the result round-trips")
	equal(round_tripped.player_survivors.size(), result.player_survivors.size(), "survivors survive the round trip")
	equal(round_tripped.gold_total(), result.gold_total(), "gold survives the round trip")


func _test_resolver_applies_consequences() -> void:
	section("resolver applies consequences")
	var state := _fresh_campaign("Apply Test", SEED + 3, 6)
	var bundle := _make_battle(state)
	var context: BattleContext = bundle["context"]

	# Snapshot everything the battle is supposed to change.
	var gold_before := state.player_gold
	var before := {}
	for soldier in state.active_members(state.player_party):
		before[soldier.id] = {
			"xp": soldier.xp, "level": soldier.level, "kills": soldier.kills,
			"battles": soldier.battles_fought, "survived": soldier.battles_survived,
			"history": soldier.history.size(), "hp": soldier.hp,
		}

	# Kill two of our own so casualties are exercised, and wipe out the enemy so
	# the outcome is a player victory - the assertions below depend on both.
	var our_ids := state.player_party.member_ids.duplicate()
	var doomed := [our_ids[0], our_ids[1]]
	for unit in (bundle["simulator"] as BattleSimulator).units:
		if unit.soldier_id in doomed:
			unit.take_damage(9999, -1)
		elif unit.side == BattleContext.SIDE_ENEMY:
			unit.take_damage(9999, -1)

	var result := _fight_to_the_end(bundle, true)

	equal(result.winner, BattleResult.WINNER_PLAYER, "the player held the field")
	equal(result.player_dead.size(), 2, "two of ours fell")
	equal(state.player_gold, gold_before + result.gold_total(), "gold changed by exactly the spoils")

	for soldier_id in our_ids:
		var soldier := state.soldier(soldier_id)
		not_null(soldier, "the soldier still exists")
		if soldier == null:
			continue
		var prior: Dictionary = before[soldier_id]
		equal(soldier.battles_fought, int(prior["battles"]) + 1, "%s has one more battle fought" % soldier.full_name())
		if soldier_id in doomed:
			equal(soldier.status, Soldier.STATUS_DEAD, "%s is recorded dead" % soldier.full_name())
			equal(soldier.hp, 0, "%s is on zero hit points" % soldier.full_name())
			equal(soldier.battles_survived, int(prior["survived"]), "the fallen do not count a survival")
			check(soldier.history.size() > int(prior["history"]), "%s has a death recorded in their history" % soldier.full_name())
			var last_entry: Dictionary = soldier.history[soldier.history.size() - 1]
			equal(str(last_entry.get("type", "")), "death", "the last history entry is a death")
			check(not str(last_entry.get("text", "")).is_empty(), "the death entry says something")
		else:
			equal(soldier.status, Soldier.STATUS_ACTIVE, "%s is still active" % soldier.full_name())
			equal(soldier.battles_survived, int(prior["survived"]) + 1, "%s counts a survival" % soldier.full_name())
			greater(float(soldier.xp), float(prior["xp"]), "%s earned experience" % soldier.full_name())
			greater(float(soldier.hp), 0.0, "%s came out with hit points left" % soldier.full_name())
			check(soldier.history.size() > int(prior["history"]), "%s has the fight recorded" % soldier.full_name())

	# Dead soldiers must not be fielded again.
	var active_after := state.active_members(state.player_party)
	equal(active_after.size(), 4, "only the four survivors are fielded")
	for soldier in active_after:
		check(not (soldier.id in doomed), "a fallen soldier is not in the active list")

	# The beaten party must leave the map.
	var world_party: WorldParty = bundle["world_party"]
	check(world_party.defeated, "the beaten party is marked defeated")
	var enemies_left := 0
	var enemy_party := state.party_of(world_party)
	if enemy_party != null:
		enemies_left = state.active_members(enemy_party).size()
	equal(enemies_left, 0, "every enemy soldier is recorded dead")

	# The campaign must remember the fight.
	var summary := BattleResolver.build(state, GameManager.config()).last_battle_summary()
	check(not summary.is_empty(), "the battle was written to the campaign's chronicle")
	if not summary.is_empty():
		equal(str(summary.get("winner", "")), BattleResult.WINNER_PLAYER, "the chronicle records the winner")
		equal(int(summary.get("gold", 0)), result.gold_total(), "the chronicle records the gold")
		equal(int(summary.get("player_dead", 0)), 2, "the chronicle records our losses")
		equal((summary.get("dead_names", []) as Array).size(), 2, "the chronicle names the fallen")
	# A resolved battle must survive a save/load with the casualties intact.
	check(GameManager.save_campaign(), "the campaign saves after the battle")
	var restored := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, GameManager.config())
	not_null(restored, "the campaign reloads")
	if restored != null:
		var dead_after_load := 0
		for soldier_id in our_ids:
			var soldier := restored.soldier(soldier_id)
			if soldier != null and soldier.status == Soldier.STATUS_DEAD:
				dead_after_load += 1
		equal(dead_after_load, 2, "the casualties survive a save and load")
		check(not restored.world_party(str(bundle["world_party"].id)).is_available(),
			"the destroyed party stays destroyed after a load")


func _test_retreat_and_defeat() -> void:
	section("retreat and defeat")
	var state := _fresh_campaign("Retreat Test", SEED + 4, 4)
	var bundle := _make_battle(state)
	var context: BattleContext = bundle["context"]
	var simulator: BattleSimulator = bundle["simulator"]

	simulator.start()
	simulator.step(0.05)
	var resolver := BattleResolver.build(state, GameManager.config())
	var retreated := resolver.build_result(context, simulator, "", 3.0, true)
	equal(retreated.winner, BattleResult.WINNER_RETREAT, "a retreat is its own outcome")
	equal(retreated.title(), "WITHDREW", "the title reads WITHDREW")
	equal(retreated.gold_total(), 0, "a withdrawal pays nothing")

	var gold_before := state.player_gold
	resolver.apply(retreated, context)
	equal(state.player_gold, gold_before, "withdrawing changes no gold")
	for soldier in state.active_members(state.player_party):
		greater(float(soldier.hp), 0.0, "nobody was killed by withdrawing")
	equal(state.player_party.size(), 4, "the party is intact after a withdrawal")

	# A defeat: the player's side is wiped out, the enemy holds the field.
	var lost := _fresh_campaign("Defeat Test", SEED + 5, 3)
	var lost_bundle := _make_battle(lost)
	var lost_context: BattleContext = lost_bundle["context"]
	var lost_simulator: BattleSimulator = lost_bundle["simulator"]
	lost_simulator.start()
	for unit in lost_simulator.units:
		if unit.side == BattleContext.SIDE_PLAYER:
			unit.take_damage(9999, -1)
	lost_simulator.step(0.05)
	equal(lost_simulator.winner, BattleContext.SIDE_ENEMY, "wiping out the player makes the enemy the winner")

	var gold_before_loss := lost.player_gold
	var lost_resolver := BattleResolver.build(lost, GameManager.config())
	var defeat := lost_resolver.build_result(lost_context, lost_simulator, lost_simulator.winner, lost_simulator.elapsed, false)
	equal(defeat.winner, BattleResult.WINNER_ENEMY, "the result records a defeat")
	equal(defeat.title(), "DEFEAT", "the title reads DEFEAT")
	check(defeat.party_wiped(), "the party was wiped out")
	equal(defeat.gold_total(), 0, "a defeat pays nothing")
	check(defeat.headline().contains("broken"), "the defeat headline says the party was broken")
	lost_resolver.apply(defeat, lost_context)
	equal(lost.player_gold, gold_before_loss, "a defeat changes no gold")
	check(not (lost_bundle["world_party"] as WorldParty).defeated, "the victorious bandits remain on the map")
