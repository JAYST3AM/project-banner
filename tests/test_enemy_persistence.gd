extends TestCase
## Step 6.6: enemy soldiers are persistent people too.
##
## The bug this guards. [BattleResult] described enemy [i]dead[/i] but not enemy
## [i]survivors[/i], so [method BattleResolver.apply] wrote back only the deaths. A
## band that survived a fight - because the player withdrew, lost, or the clock ran
## out - returned to the campaign at full strength and was a completely fresh band
## the next time it was met. Every withdrawal was a free reset for the enemy, which
## meant the player could never actually wear a hostile party down.
##
## The main test walks all three boundaries in one pass:
## [codeblock]
##   battle -> campaign          (the fight's damage reaches the soldier)
##   campaign -> save/load       (and survives the game being closed)
##   campaign -> second battle   (and the next encounter starts from it)
## [/codeblock]
##
## It deliberately does not test [BattleResult] in isolation: a result object that
## describes damage correctly is worthless if nothing writes it back.

const SEED := 80880
const RECRUITS := 8


func run() -> void:
	await _tick()
	SaveManager.delete_all_saves()
	_test_same_enemy_fought_twice()
	_test_enemy_dead_keep_the_kills_they_made()
	_test_every_outcome_persists_enemy_state()
	_test_the_result_model_is_json_safe()
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
		state.settlement("greywatch").recruit_pool["peasant_recruit"] = 40
		var recruitment := RecruitmentService.build(state, GameManager.config())
		recruitment.recruit_many(state.settlement("greywatch"), "peasant_recruit", recruits)
	return state


func _first_available_party(state: CampaignState) -> WorldParty:
	for key in state.parties.keys():
		var candidate := state.parties[key] as WorldParty
		if candidate != null and candidate.is_available():
			return candidate
	return null


## A battle against one specific overworld party, with any cooldown cleared so the
## test controls the timing rather than the encounter rules.
func _make_battle(state: CampaignState, world_party: WorldParty) -> Dictionary:
	var config := GameManager.config()
	world_party.encounter_cooldown_until_hours = -1.0
	state.world_position = world_party.position
	var encounters := EncounterService.build(state, config)
	var context := encounters.build_context(world_party, true)
	var simulator := BattleSimulator.new(config, context.battle_seed)
	simulator.add_units(BattleSetup.build_units_prepared(context, config))
	return {"context": context, "simulator": simulator, "world_party": world_party}


func _unit_for(simulator: BattleSimulator, side: String, soldier_id: String) -> BattleUnit:
	for unit in simulator.units:
		if unit.side == side and unit.soldier_id == soldier_id:
			return unit
	return null


func _first_alive(simulator: BattleSimulator, side: String) -> BattleUnit:
	var living := simulator.alive_units(side)
	return living[0] if not living.is_empty() else null


func _snapshot_for(snapshot: Array[Dictionary], soldier_id: String) -> Dictionary:
	for entry in snapshot:
		if str(entry.get("soldier_id", "")) == soldier_id:
			return entry
	return {}


## ---------- 1. the headline boundary test --------------------------------

func _test_same_enemy_fought_twice() -> void:
	section("the same persistent enemy, fought twice, does not reset")
	var state := _fresh_campaign("Enemy Persistence", SEED, RECRUITS)
	var config := GameManager.config()

	# --- 1-3. pick one persistent enemy and record where they start -------------
	var world_party := _first_available_party(state)
	not_null(world_party, "there is a hostile party on the map")
	if world_party == null:
		return
	var enemy_party := state.party_of(world_party)
	var enemy_members := state.active_members(enemy_party)
	check(enemy_members.size() > 0, "the hostile party has soldiers in the campaign")
	if enemy_members.is_empty():
		return

	var target := enemy_members[0]
	var target_id := target.id
	var target_name := target.full_name()
	var original_hp := target.hp
	var original_max_hp := target.max_hp
	greater(float(original_hp), 1.0, "%s starts the campaign with hit points to lose" % target_name)

	# The value the test will hold the system to, as a fraction of the maximum so the
	# assertion is meaningful whatever the archetype's hit points happen to be.
	var reduced_hp := maxi(1, int(round(float(original_hp) * 0.23)))

	# --- 4. the first battle ----------------------------------------------------
	var bundle := _make_battle(state, world_party)
	var context := bundle["context"] as BattleContext
	var simulator := bundle["simulator"] as BattleSimulator

	# --- 5. damage exactly that enemy, without killing them ---------------------
	var unit := _unit_for(simulator, BattleContext.SIDE_ENEMY, target_id)
	not_null(unit, "%s is on the field of the first battle" % target_name)
	if unit == null:
		return
	equal(unit.hp, original_hp, "%s takes the field at full strength" % target_name)

	unit.take_damage(original_hp - reduced_hp, -1)
	equal(unit.hp, reduced_hp, "%s is reduced to %d hit points" % [target_name, reduced_hp])
	check(unit.is_alive(), "...and is still on their feet")

	# Let them earn a kill through the real attack path, so the number being persisted
	# is one the combat system actually produced rather than a value this test made up.
	# Hit chance is forced certain and the victim left on one hit point, so the kill is
	# deterministic; the crediting itself is the simulator's own code.
	simulator.base_hit_chance = 1.0
	var victim := _first_alive(simulator, BattleContext.SIDE_PLAYER)
	not_null(victim, "there is one of our soldiers to lose")
	if victim != null:
		victim.hp = 1
		simulator.call("_attack", unit, victim)
		check(not victim.is_alive(), "%s killed one of ours" % target_name)
		equal(unit.kills, 1, "%s is credited with the kill" % target_name)

	# --- 6-7. withdraw, and write the result back -------------------------------
	var resolver := BattleResolver.build(state, config)
	var result := resolver.build_result(context, simulator, "", simulator.elapsed, true)
	check(result.is_withdrawal(), "the fight ended in a withdrawal")
	var result_enemy_entry := _snapshot_for(result.enemy_survivors, target_id)
	check(not result_enemy_entry.is_empty(), "the result describes %s as a survivor" % target_name)
	equal(int(result_enemy_entry.get("hp", -1)), reduced_hp,
		"describing them at the hit points they actually have")
	resolver.apply(result, context)

	# --- 8. the campaign now holds the real post-battle state -------------------
	var after := state.soldier(target_id)
	not_null(after, "%s is still on the books" % target_name)
	if after == null:
		return
	equal(after.hp, reduced_hp,
		"THE BUG: %s keeps the damage taken, instead of healing to %d" % [target_name, original_hp])
	equal(after.kills, 1, "%s keeps the kill they made" % target_name)
	equal(after.battles_fought, 1, "%s is recorded as having taken the field" % target_name)
	equal(after.battles_survived, 0, "%s broke off, so did not survive it" % target_name)
	equal(after.status, Soldier.STATUS_ACTIVE, "%s is still alive" % target_name)
	check(after.history.size() > 0, "%s has a record of the fight" % target_name)
	check(world_party.is_available(), "the band is still on the map after a withdrawal")

	# --- 9-11. and it survives the campaign being closed and reopened -----------
	check(GameManager.save_campaign(), "the campaign saved")
	var reloaded := SaveManager.load_campaign(SaveManager.SLOT_DEFAULT, config)
	not_null(reloaded, "the campaign loaded in a fresh object graph")
	if reloaded == null:
		return
	var restored := reloaded.soldier(target_id)
	not_null(restored, "%s came back" % target_name)
	if restored == null:
		return
	equal(restored.hp, reduced_hp, "%s still has %d hit points after a reload" % [target_name, reduced_hp])
	equal(restored.kills, 1, "and still has the kill")
	equal(restored.battles_fought, 1, "and still has the battle")

	# --- 12-15. a second battle against the SAME band starts from that state ----
	var second_party := reloaded.world_party(world_party.id)
	not_null(second_party, "the same band is still on the map after the reload")
	if second_party == null:
		return
	check(second_party.is_available(), "and is available to be fought again")

	var second := _make_battle(reloaded, second_party)
	var second_context := second["context"] as BattleContext
	var second_snapshot := _snapshot_for(second_context.enemy_snapshot, target_id)
	check(not second_snapshot.is_empty(), "%s appears in the second battle" % target_name)
	if second_snapshot.is_empty():
		return
	equal(int(second_snapshot.get("hp", -1)), reduced_hp,
		"THE BUG: %s enters the second battle already hurt, not restored to %d" % [target_name, original_hp])
	equal(str(second_snapshot.get("soldier_id", "")), target_id, "and is the same persistent person")
	equal(str(second_snapshot.get("name", "")), target_name, "with the same name")
	equal(int(second_snapshot.get("max_hp", 0)), original_max_hp, "and the same maximum")

	# And the second battle's units are built from that state, not from the first
	# battle's leftovers - the boundary that actually matters.
	var second_simulator := second["simulator"] as BattleSimulator
	var second_unit := _unit_for(second_simulator, BattleContext.SIDE_ENEMY, target_id)
	not_null(second_unit, "%s took the field a second time" % target_name)
	if second_unit != null:
		equal(second_unit.hp, reduced_hp, "...still carrying the earlier wound")
		equal(second_unit.max_hp, original_max_hp, "...with an unchanged maximum")
	greater(float(second_context.enemy_snapshot.size()), 0.0, "the band still has soldiers")


## ---------- 2. the dead --------------------------------------------------

## A hostile soldier who cut someone down before falling still did so - the same
## rule that already applied to the player's own casualties. _fallen_entry recorded
## the kills, and apply() then discarded them.
func _test_enemy_dead_keep_the_kills_they_made() -> void:
	section("enemy dead keep the kills they made before dying")
	var state := _fresh_campaign("Enemy Dead Facts", SEED + 1, RECRUITS)
	var config := GameManager.config()

	var world_party := _first_available_party(state)
	if world_party == null:
		check(false, "there was a hostile party to fight")
		return
	var enemy_party := state.party_of(world_party)
	var enemy_members := state.active_members(enemy_party)
	if enemy_members.is_empty():
		check(false, "the hostile party had soldiers")
		return
	var doomed := enemy_members[0]
	var doomed_id := doomed.id
	var doomed_name := doomed.full_name()
	equal(doomed.kills, 0, "%s starts with a clean record" % doomed_name)

	var bundle := _make_battle(state, world_party)
	var context := bundle["context"] as BattleContext
	var simulator := bundle["simulator"] as BattleSimulator
	var unit := _unit_for(simulator, BattleContext.SIDE_ENEMY, doomed_id)
	not_null(unit, "%s is on the field" % doomed_name)
	if unit == null:
		return

	# They kill one of ours...
	simulator.base_hit_chance = 1.0
	var victim := _first_alive(simulator, BattleContext.SIDE_PLAYER)
	if victim != null:
		victim.hp = 1
		simulator.call("_attack", unit, victim)
		equal(unit.kills, 1, "%s is credited with a kill" % doomed_name)

	# ...and then they fall.
	unit.take_damage(999999, -1)
	check(not unit.is_alive(), "%s fell in the fighting" % doomed_name)

	# Clear the rest of the field so the player wins outright.
	for other in simulator.units:
		if other.side == BattleContext.SIDE_ENEMY and other.is_alive():
			other.take_damage(999999, -1)
	# The simulator only evaluates victory while it is running, so it has to be
	# started before the step that detects the result.
	simulator.start()
	simulator.step(0.05)
	equal(simulator.winner, BattleContext.SIDE_PLAYER, "the player held the field")

	var resolver := BattleResolver.build(state, config)
	var result := resolver.build_result(context, simulator, simulator.winner, simulator.elapsed, false)
	var entry := _snapshot_for(result.enemy_dead, doomed_id)
	check(not entry.is_empty(), "the result records %s among the enemy dead" % doomed_name)
	equal(int(entry.get("kills", -1)), 1, "and records the kill they made")
	resolver.apply(result, context)

	var record := state.soldier(doomed_id)
	not_null(record, "%s is still on the books as a casualty" % doomed_name)
	if record == null:
		return
	equal(record.status, Soldier.STATUS_DEAD, "%s is dead" % doomed_name)
	equal(record.hp, 0, "%s has no hit points" % doomed_name)
	equal(record.battles_fought, 1, "%s is recorded as having fought" % doomed_name)
	equal(record.kills, 1, "THE BUG: %s keeps the kill they made before falling" % doomed_name)
	check(record.history.size() > 0, "%s has a record" % doomed_name)
	check(world_party.defeated, "the destroyed band is removed from the map")


## ---------- 3. every outcome ---------------------------------------------

## Enemy state must be consistent with what actually happened, whichever way the
## fight ended. Each case damages one enemy to a known figure and then checks that
## the campaign agrees with the field.
func _test_every_outcome_persists_enemy_state() -> void:
	section("all four outcomes persist enemy post-battle state")
	_check_outcome("victory", SEED + 10)
	_check_outcome("defeat", SEED + 11)
	_check_outcome("draw", SEED + 12)
	_check_outcome("withdrawal", SEED + 13)


## Runs one forced outcome and asserts the damaged enemy's campaign record.
##
## [param outcome] is "victory" (all enemies down), "defeat" (all of ours down),
## "draw" (nobody decided it) or "withdrawal" (the player broke off).
func _check_outcome(outcome: String, seed_value: int) -> void:
	var state := _fresh_campaign("Outcome %s" % outcome, seed_value, RECRUITS)
	var config := GameManager.config()
	var world_party := _first_available_party(state)
	if world_party == null:
		check(false, "[%s] there was a hostile party to fight" % outcome)
		return
	var enemy_members := state.active_members(state.party_of(world_party))
	if enemy_members.is_empty():
		check(false, "[%s] the hostile party had soldiers" % outcome)
		return
	var target := enemy_members[0]
	var target_id := target.id
	var reduced_hp := maxi(1, int(round(float(target.hp) * 0.23)))

	var bundle := _make_battle(state, world_party)
	var context := bundle["context"] as BattleContext
	var simulator := bundle["simulator"] as BattleSimulator
	var unit := _unit_for(simulator, BattleContext.SIDE_ENEMY, target_id)
	if unit == null:
		check(false, "[%s] the target enemy was on the field" % outcome)
		return
	unit.take_damage(unit.hp - reduced_hp, -1)

	var retreated := outcome == "withdrawal"
	var winner_side := ""
	match outcome:
		"victory":
			# Everyone on the enemy side falls, the target included.
			for other in simulator.units:
				if other.side == BattleContext.SIDE_ENEMY:
					other.take_damage(999999, -1)
			# Victory is only evaluated while the simulator is running.
			simulator.start()
			simulator.step(0.05)
			winner_side = simulator.winner
			equal(winner_side, BattleContext.SIDE_PLAYER, "[%s] the player won the field" % outcome)
		"defeat":
			for other in simulator.units:
				if other.side == BattleContext.SIDE_PLAYER:
					other.take_damage(999999, -1)
			simulator.start()
			simulator.step(0.05)
			winner_side = simulator.winner
			equal(winner_side, BattleContext.SIDE_ENEMY, "[%s] the enemy won the field" % outcome)
		_:
			# "draw" and "withdrawal" both leave the field undecided: an empty winner
			# side is a draw, and the retreat flag overrides it.
			winner_side = ""

	var resolver := BattleResolver.build(state, config)
	var result := resolver.build_result(context, simulator, winner_side, simulator.elapsed, retreated)
	resolver.apply(result, context)

	var record := state.soldier(target_id)
	not_null(record, "[%s] the enemy soldier is still on the books" % outcome)
	if record == null:
		return
	equal(record.battles_fought, 1, "[%s] their battle was recorded" % outcome)

	if outcome == "victory":
		# A wiped enemy side leaves nothing standing, whatever was described.
		equal(record.status, Soldier.STATUS_DEAD, "[%s] the beaten enemy is dead" % outcome)
		equal(record.hp, 0, "[%s] with no hit points" % outcome)
		check(world_party.defeated, "[%s] and the band is gone from the map" % outcome)
		equal(_snapshot_for(result.enemy_survivors, target_id).is_empty(), true,
			"[%s] no enemy is described as surviving" % outcome)
		return

	# The other three all leave the enemy standing, so the damage must come back.
	equal(record.status, Soldier.STATUS_ACTIVE, "[%s] the enemy soldier is still alive" % outcome)
	equal(record.hp, reduced_hp,
		"[%s] and keeps exactly the hit points they had left (%d, not %d)" % [outcome, reduced_hp, unit.max_hp])
	check(world_party.is_available(), "[%s] the band is still on the map" % outcome)
	var entry := _snapshot_for(result.enemy_survivors, target_id)
	check(not entry.is_empty(), "[%s] the result describes them as a survivor" % outcome)
	equal(int(entry.get("hp", -1)), reduced_hp, "[%s] at their real hit points" % outcome)
	equal(bool(entry.get("survival_credited", false)), outcome != "withdrawal",
		"[%s] and survival credit follows the same rule as our own soldiers" % outcome)
	equal(record.battles_survived, 1 if outcome != "withdrawal" else 0,
		"[%s] which is what the campaign recorded" % outcome)


## ---------- 4. the model -------------------------------------------------

## The result has to stay a plain, JSON-safe description - it is carried through a
## scene payload and written into the battle chronicle.
func _test_the_result_model_is_json_safe() -> void:
	section("BattleResult round-trips with enemy survivors")
	var state := _fresh_campaign("Result Model", SEED + 20, RECRUITS)
	var world_party := _first_available_party(state)
	if world_party == null:
		check(false, "there was a hostile party to fight")
		return

	var bundle := _make_battle(state, world_party)
	var context := bundle["context"] as BattleContext
	var simulator := bundle["simulator"] as BattleSimulator
	var target_id := str((context.enemy_snapshot[0] as Dictionary).get("soldier_id", ""))
	var unit := _unit_for(simulator, BattleContext.SIDE_ENEMY, target_id)
	if unit != null:
		unit.take_damage(1, -1)

	var resolver := BattleResolver.build(state, GameManager.config())
	var result := resolver.build_result(context, simulator, "", simulator.elapsed, true)
	greater(float(result.enemy_survivors.size()), 0.0, "the result lists enemy survivors")

	var text := JSON.stringify(result.to_dict())
	check(not text.is_empty(), "the result serialises")
	var parsed: Variant = JSON.parse_string(text)
	equal(typeof(parsed), TYPE_DICTIONARY, "and parses back as an object")
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var restored := BattleResult.from_dict(parsed as Dictionary)
	equal(restored.enemy_survivors.size(), result.enemy_survivors.size(),
		"every enemy survivor survives the round trip")
	equal(restored.total_enemy_kills(), result.total_enemy_kills(), "as do their kills")
	for entry in restored.enemy_survivors:
		has_key(entry, "soldier_id", "an enemy survivor entry names its soldier")
		has_key(entry, "hp", "carries their hit points")
		has_key(entry, "max_hp", "carries their maximum")
		has_key(entry, "kills", "carries their kills")

	# And describe-then-apply stays two phases: reading the result changed nothing.
	var before := state.soldier(target_id)
	if before != null and unit != null:
		equal(before.hp, unit.max_hp, "building a result still mutates nothing")
