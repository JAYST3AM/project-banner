extends TestCase
## Step 6.5 remediation: the four battle outcomes, and the withdrawal rule.
##
## The exploit these guard against: walk onto a battlefield, press Retreat straight
## away, and collect participation plus survived-battle experience for a fight that
## never happened - costing nothing, repeatable forever.
##
## The rule now: a withdrawal is its own outcome. Soldiers who took the field record
## a battle fought, keep the kills they actually made and the damage they actually
## took, and gain experience for those kills and nothing else. It is not a battle
## survived, it pays no spoils, and it does not remove the enemy from the map.

const SEED := 60650
const RECRUITS := 8


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_immediate_retreat_pays_nothing()
	_test_retreat_cannot_be_farmed()
	_test_retreat_after_combat_keeps_the_facts()
	_test_timeout_freezes_the_field()
	_test_outcome_matrix()
	await _test_results_screen_renders_a_withdrawal()
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


## ---------- readings -----------------------------------------------------

func _player_kills(simulator: BattleSimulator) -> int:
	var total := 0
	for unit in simulator.units:
		if unit.side == BattleContext.SIDE_PLAYER:
			total += unit.kills
	return total


func _player_alive(simulator: BattleSimulator) -> int:
	return simulator.alive_units(BattleContext.SIDE_PLAYER).size()


func _enemy_alive(simulator: BattleSimulator) -> int:
	return simulator.alive_units(BattleContext.SIDE_ENEMY).size()


## Hit points of every unit, keyed by id. Used to prove nothing changed.
func _hp_map(simulator: BattleSimulator) -> Dictionary:
	var out := {}
	for unit in simulator.units:
		out[unit.id] = unit.hp
	return out


func _position_map(simulator: BattleSimulator) -> Dictionary:
	var out := {}
	for unit in simulator.units:
		out[unit.id] = unit.position
	return out


func _has_event(events: Array, type_name: String) -> bool:
	for event in events:
		if str(event.get("type", "")) == type_name:
			return true
	return false


## ---------- 1. the headline case -----------------------------------------

func _test_immediate_retreat_pays_nothing() -> void:
	section("withdrawal: immediate retreat with no combat at all")
	var state := _fresh_campaign("Retreat Farm", SEED, RECRUITS)
	var bundle := _make_battle(state)
	var context := bundle["context"] as BattleContext
	var simulator := bundle["simulator"] as BattleSimulator
	var world_party := bundle["world_party"] as WorldParty

	# The party takes the field and nothing else happens. This is the click-Retreat
	# case: the button is pressed before a blow is struck.
	simulator.start()
	var resolver := BattleResolver.build(state, GameManager.config())
	var gold_before := state.player_gold

	var result := resolver.build_result(context, simulator, "", 1.0, true)
	resolver.apply(result, context)

	equal(result.winner, BattleResult.WINNER_RETREAT, "the outcome is a withdrawal")
	check(result.is_withdrawal(), "the result is explicitly flagged as a withdrawal")
	check(not result.survival_credited(), "withdrawing is not counted as surviving a battle")
	equal(result.gold_total(), 0, "no gold is paid")
	equal(result.loot.size(), 0, "no loot is taken")
	equal(result.xp_awarded, 0, "no experience at all is awarded")
	equal(state.player_gold, gold_before, "the campaign's gold is untouched")

	for soldier in state.party_members(state.player_party):
		equal(soldier.xp, 0, "%s gains no XP for withdrawing" % soldier.full_name())
		equal(soldier.kills, 0, "%s records no kills" % soldier.full_name())
		equal(soldier.battles_survived, 0, "%s does not count this as a battle survived" % soldier.full_name())
		equal(soldier.level, 1, "%s does not level up" % soldier.full_name())
		# Taking the field is still a battle fought - that much is true and allowed.
		equal(soldier.battles_fought, 1, "%s is recorded as having taken the field" % soldier.full_name())

	var summary := resolver.last_battle_summary()
	equal(summary.get("winner"), BattleResult.WINNER_RETREAT, "the battle log records the withdrawal")
	equal(summary.get("withdrawal"), true, "and flags it as a withdrawal")

	# The enemy is untouched and still holds the field.
	check(world_party.is_available(), "the enemy party is still on the map")
	equal(state.active_member_count(state.party_of(world_party)), context.enemy_snapshot.size(),
		"not one enemy was harmed")
	greater(world_party.encounter_cooldown_until_hours, state.clock.total_hours(),
		"an encounter cooldown was set, so it cannot re-fire immediately")
	greater(state.world_position.distance_to(world_party.position), 0.0,
		"the party was pushed clear of the enemy")


## ---------- 2. the loop itself -------------------------------------------

## The exploit, run deliberately: attack, retreat, repeat, clearing the cooldown each
## time so the loop gets every chance to pay out. Nothing may accumulate.
func _test_retreat_cannot_be_farmed() -> void:
	section("withdrawal: the retreat loop pays nothing, however often it is run")
	var state := _fresh_campaign("Retreat Farm Loop", SEED + 1, RECRUITS)
	var config := GameManager.config()
	var gold_before := state.player_gold
	var attempts := 6

	for round_index in attempts:
		var bundle := _make_battle(state)
		var context := bundle["context"] as BattleContext
		var simulator := bundle["simulator"] as BattleSimulator
		var world_party := bundle["world_party"] as WorldParty
		# Hand the exploit the benefit of the doubt: no cooldown in its way.
		world_party.encounter_cooldown_until_hours = -1.0
		simulator.start()
		var resolver := BattleResolver.build(state, config)
		var result := resolver.build_result(context, simulator, "", 1.0, true)
		resolver.apply(result, context)

	for soldier in state.party_members(state.player_party):
		equal(soldier.xp, 0, "%s is still on 0 XP after %d withdrawals" % [soldier.full_name(), attempts])
		equal(soldier.kills, 0, "%s has no kills" % soldier.full_name())
		equal(soldier.battles_survived, 0, "%s has survived nothing" % soldier.full_name())
		equal(soldier.level, 1, "%s has not levelled" % soldier.full_name())
		equal(soldier.battles_fought, attempts,
			"%s took the field %d times" % [soldier.full_name(), attempts])

	equal(state.player_gold, gold_before, "the loop earned no gold")
	equal(int(state.flags.get("total_battle_gold", 0)), 0, "the campaign earned no battle gold")


## ---------- 3. breaking off from a real fight ----------------------------

## A withdrawal is not a get-out-of-jail card: what actually happened still happened.
func _test_retreat_after_combat_keeps_the_facts() -> void:
	section("withdrawal: a real fight, then breaking off")
	var state := _fresh_campaign("Retreat After Combat", SEED + 2, RECRUITS)
	var config := GameManager.config()
	var bundle := _make_battle(state)
	var context := bundle["context"] as BattleContext
	var simulator := bundle["simulator"] as BattleSimulator
	var world_party := bundle["world_party"] as WorldParty

	simulator.start()
	var guard := 0
	while guard < 4000 and _player_kills(simulator) == 0 and not simulator.is_finished():
		guard += 1
		simulator.step(0.05)
	greater(float(_player_kills(simulator)), 0.0, "the player's line drew blood before breaking off")
	check(not simulator.is_finished(), "the fight was still going when they broke off")

	# Take a real casualty too, so the withdrawal has a genuine loss to preserve.
	var victim: BattleUnit = null
	for unit in simulator.units:
		if unit.side == BattleContext.SIDE_PLAYER and unit.is_alive():
			victim = unit
			break
	not_null(victim, "a soldier was left to lose")
	if victim == null:
		return
	victim.take_damage(999999, -1)
	simulator.step(0.05)
	check(not victim.is_alive(), "the casualty fell before the retreat")

	var kills_before := _player_kills(simulator)
	var per_kill := config.get_int("xp.per_kill", 20)
	var gold_before := state.player_gold

	var resolver := BattleResolver.build(state, config)
	var result := resolver.build_result(context, simulator, "", simulator.elapsed, true)
	resolver.apply(result, context)

	equal(result.winner, BattleResult.WINNER_RETREAT, "broken off rather than decided on the field")
	equal(result.gold_total(), 0, "no gold for a withdrawal, however much blood was drawn")
	equal(result.loot.size(), 0, "no loot is taken")
	equal(result.xp_awarded, kills_before * per_kill,
		"withdrawal experience is exactly the kills actually made, and nothing else")
	equal(state.player_gold, gold_before, "the campaign's gold is untouched")

	# Real kills persist, and they are the only thing that paid.
	for entry in result.player_survivors:
		var soldier := state.soldier(str(entry.get("soldier_id", "")))
		not_null(soldier, "a surviving soldier is still on the books")
		if soldier == null:
			continue
		var kills := int(entry.get("kills", 0))
		equal(soldier.kills, kills, "%s keeps the %d kill(s) they made" % [soldier.full_name(), kills])
		equal(soldier.xp, kills * per_kill,
			"%s earned %d XP - kills only" % [soldier.full_name(), kills * per_kill])
		equal(soldier.battles_survived, 0,
			"%s did not survive a battle, they withdrew from one" % soldier.full_name())
		equal(soldier.battles_fought, 1, "%s is recorded as having fought" % soldier.full_name())
		greater(float(soldier.hp), 0.0, "%s is still standing" % soldier.full_name())

	# Real casualties persist.
	var fallen := state.fallen_members(state.player_party)
	check(fallen.size() >= 1, "the soldier lost before the retreat is still dead")
	for soldier in fallen:
		equal(soldier.status, Soldier.STATUS_DEAD, "%s is still dead" % soldier.full_name())
		equal(soldier.hp, 0, "%s still has no hit points" % soldier.full_name())
	equal(state.active_member_count(state.player_party), RECRUITS - fallen.size(),
		"the active force shrank by exactly the casualties taken")

	# The enemy held the field and is still out there.
	check(world_party.is_available(), "the enemy party is still on the map")
	greater(float(_enemy_alive(simulator)), 0.0, "the enemy still has soldiers standing")


## ---------- 4. timeout ---------------------------------------------------

## A timeout must freeze the battlefield. The old code finished the battle and then
## carried on processing the same step, so units could still move, strike, take
## damage and die after the fight had officially ended.
func _test_timeout_freezes_the_field() -> void:
	section("timeout: the battle stops dead when the clock runs out")
	var state := _fresh_campaign("Timeout Test", SEED + 3, 6)
	var bundle := _make_battle(state)
	var simulator := bundle["simulator"] as BattleSimulator

	# A short clock, so the timeout fires on a step this test controls.
	simulator.max_duration = 2.0
	simulator.start()
	# Let the lines close first, so units are genuinely in contact and would fight.
	for i in 20:
		if not simulator.is_finished():
			simulator.step(0.05)

	var hp_before := _hp_map(simulator)
	var positions_before := _position_map(simulator)

	# One step that sails well past the limit.
	var events := simulator.step(50.0)

	check(simulator.is_finished(), "the battle finished on timeout")
	equal(simulator.winner, "", "a timeout is a draw - nobody won")
	greater(simulator.elapsed, simulator.max_duration, "the clock really did run out")
	check(_has_event(events, "finished"), "the finish event was emitted")
	equal(_hp_map(simulator), hp_before, "no hit points changed on the timeout step")
	equal(_position_map(simulator), positions_before, "no unit moved on the timeout step")
	for event in events:
		not_equal(str(event.get("type", "")), "hit", "no attack landed after the timeout")
		not_equal(str(event.get("type", "")), "death", "nobody died after the timeout")
		not_equal(str(event.get("type", "")), "miss", "no attack was even attempted after the timeout")

	# And later steps cannot restart it.
	var events_after := simulator.step(10.0)
	equal(events_after.size(), 0, "a finished battle produces no further events")
	equal(_hp_map(simulator), hp_before, "hit points are unchanged on a later step")
	equal(_position_map(simulator), positions_before, "positions are unchanged on a later step")
	equal(simulator.winner, "", "the winner is still the draw it ended on")
	check(simulator.is_finished(), "the battle is still finished")


## ---------- 5. what the screen says --------------------------------------

## The results screen must [i]say[/i] it was a withdrawal, not merely carry the flag.
## A player who breaks off should not be shown a screen that reads like an ordinary
## battle, and the rules the game applies should be visible in the words it uses.
func _test_results_screen_renders_a_withdrawal() -> void:
	section("the results screen represents a withdrawal honestly")
	var state := _fresh_campaign("Withdrawal Screen", SEED + 8, RECRUITS)
	var bundle := _make_battle(state)
	var context := bundle["context"] as BattleContext
	var simulator := bundle["simulator"] as BattleSimulator
	simulator.start()
	simulator.step(0.05)

	var resolver := BattleResolver.build(state, GameManager.config())
	var result := resolver.build_result(context, simulator, "", 4.0, true)
	resolver.apply(result, context)

	var screen := await SceneManager.change_scene_and_wait("battle_results", {
		"result": result, "context": context,
	})
	not_null(screen, "the results screen opened")
	if screen == null:
		return
	await _tick()

	var shown: BattleResult = screen.call("displayed_result")
	not_null(shown, "and received the withdrawal result")
	if shown == null:
		return
	check(shown.is_withdrawal(), "the result it is holding is a withdrawal")

	var text := str(screen.call("displayed_text"))
	check(not text.contains("No battle result"), "the empty fallback is not showing")
	contains(text, shown.title(), "the outcome is rendered")
	contains(text, "not a battle survived", "the screen explains that breaking off is not survival")
	contains(text, "Nothing was taken", "and that no spoils were won - in words, since zero is not listed")
	check(not text.contains("gold\n"), "no gold line is rendered for a withdrawal")

	# Then back to the map, the way Continue would.
	var world := await SceneManager.change_scene_and_wait("world_map")
	not_null(world, "the world map reopened")


## ---------- 6. the outcome matrix ----------------------------------------

## Each of the four outcomes must behave deliberately. This pins down what each one
## does to gold, to experience, and to the enemy party.
func _test_outcome_matrix() -> void:
	section("outcome matrix: victory, defeat, draw, withdrawal")

	# --- victory: paid, credited, enemy destroyed.
	var won := _fresh_campaign("Matrix Victory", SEED + 4, RECRUITS)
	var won_bundle := _make_battle(won)
	var won_context := won_bundle["context"] as BattleContext
	var won_sim := won_bundle["simulator"] as BattleSimulator
	var won_world := won_bundle["world_party"] as WorldParty
	won_sim.start()
	for unit in won_sim.units:
		if unit.side == BattleContext.SIDE_ENEMY:
			unit.take_damage(999999, -1)
	won_sim.step(0.05)
	equal(won_sim.winner, BattleContext.SIDE_PLAYER, "clearing the enemy wins the field")
	var won_resolver := BattleResolver.build(won, GameManager.config())
	var won_gold_before := won.player_gold
	var victory := won_resolver.build_result(won_context, won_sim, won_sim.winner, won_sim.elapsed, false)
	won_resolver.apply(victory, won_context)
	check(victory.player_won(), "the result records a victory")
	check(victory.survival_credited(), "a victory credits survival")
	greater(float(victory.gold_total()), 0.0, "a victory pays spoils")
	greater(float(won.player_gold), float(won_gold_before), "and the gold reaches the campaign")
	for entry in victory.player_survivors:
		check(bool(entry.get("survival_credited", false)), "a victor's survival is credited")
	check(won_world.defeated, "the beaten enemy is removed from the map")

	# --- defeat: nothing paid, survivors credited with coming through it.
	var lost := _fresh_campaign("Matrix Defeat", SEED + 5, RECRUITS)
	var lost_bundle := _make_battle(lost)
	var lost_context := lost_bundle["context"] as BattleContext
	var lost_sim := lost_bundle["simulator"] as BattleSimulator
	var lost_world := lost_bundle["world_party"] as WorldParty
	lost_sim.start()
	for unit in lost_sim.units:
		if unit.side == BattleContext.SIDE_PLAYER:
			unit.take_damage(999999, -1)
	lost_sim.step(0.05)
	equal(lost_sim.winner, BattleContext.SIDE_ENEMY, "losing everyone hands the enemy the field")
	var lost_resolver := BattleResolver.build(lost, GameManager.config())
	var lost_gold_before := lost.player_gold
	var defeat := lost_resolver.build_result(lost_context, lost_sim, lost_sim.winner, lost_sim.elapsed, false)
	lost_resolver.apply(defeat, lost_context)
	check(defeat.enemy_won(), "the result records a defeat")
	check(defeat.party_wiped(), "the party was wiped out")
	equal(defeat.gold_total(), 0, "a defeat pays nothing")
	equal(lost.player_gold, lost_gold_before, "and the campaign's gold is untouched")
	check(lost_world.is_available(), "the enemy that held the field is still on the map")
	check(lost_world.encounter_cooldown_until_hours > lost.clock.total_hours(),
		"and a cooldown stops it re-firing immediately")

	# --- draw: nobody paid, nobody credited with a victory, nobody removed.
	var drawn := _fresh_campaign("Matrix Draw", SEED + 6, RECRUITS)
	var drawn_bundle := _make_battle(drawn)
	var drawn_context := drawn_bundle["context"] as BattleContext
	var drawn_sim := drawn_bundle["simulator"] as BattleSimulator
	var drawn_world := drawn_bundle["world_party"] as WorldParty
	drawn_sim.start()
	drawn_sim.step(0.05)
	var drawn_resolver := BattleResolver.build(drawn, GameManager.config())
	var drawn_gold_before := drawn.player_gold
	var draw := drawn_resolver.build_result(drawn_context, drawn_sim, "", 5.0, false)
	drawn_resolver.apply(draw, drawn_context)
	equal(draw.winner, BattleResult.WINNER_DRAW, "an undecided field is a draw")
	check(not draw.is_withdrawal(), "a draw is not a withdrawal")
	check(draw.survival_credited(), "taking part in a draw still credits coming through it")
	equal(draw.gold_total(), 0, "a draw pays no spoils")
	equal(drawn.player_gold, drawn_gold_before, "and the campaign's gold is untouched")
	check(drawn_world.is_available(), "the enemy is still on the map after a draw")

	# --- withdrawal: the strictest of the four.
	var broke := _fresh_campaign("Matrix Withdrawal", SEED + 7, RECRUITS)
	var broke_bundle := _make_battle(broke)
	var broke_context := broke_bundle["context"] as BattleContext
	var broke_sim := broke_bundle["simulator"] as BattleSimulator
	var broke_world := broke_bundle["world_party"] as WorldParty
	broke_sim.start()
	broke_sim.step(0.05)
	var broke_resolver := BattleResolver.build(broke, GameManager.config())
	var broke_gold_before := broke.player_gold
	var withdrawal := broke_resolver.build_result(broke_context, broke_sim, "", 5.0, true)
	broke_resolver.apply(withdrawal, broke_context)
	check(withdrawal.is_withdrawal(), "the result is flagged as a withdrawal")
	check(not withdrawal.survival_credited(), "withdrawal credits no survival")
	equal(withdrawal.gold_total(), 0, "a withdrawal pays no spoils")
	equal(broke.player_gold, broke_gold_before, "and the campaign's gold is untouched")
	check(broke_world.is_available(), "the enemy is still on the map after a withdrawal")
	equal(withdrawal.xp_awarded, 0, "an unengaged withdrawal earns no experience")
	for soldier in broke.party_members(broke.player_party):
		equal(soldier.battles_survived, 0, "%s survived nothing" % soldier.full_name())
		equal(soldier.battles_fought, 1, "%s did fight, though" % soldier.full_name())
