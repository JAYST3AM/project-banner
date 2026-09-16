extends TestCase
## Step 7.8 - formation-driven engagement and dynamic membership.
##
## [b]What this suite is for.[/b] The milestone moved the strategic half of target acquisition up
## to the body and left the tactical half with the soldier. The assertions here are that move's
## contract: a body picks an enemy body once and hands the answer down; a soldier is asked to
## look for its own opponent only when the fight could be about it; a soldier that is struck
## strikes back without being asked to look at all; and a body can be split, merged and re-rolled
## at runtime without a soldier being created, destroyed, duplicated or lost.
##
## [b]How to read it.[/b] Every test that is about the hierarchy runs with the layer on, which is
## the shipped default; the tests that are about the layer's [i]cost[/i] run it twice, once with
## the layer switched off, because the switch is what makes a comparison attributable. See D-105
## and D-106.

const SIDE_PLAYER := BattleContext.SIDE_PLAYER
const SIDE_ENEMY := BattleContext.SIDE_ENEMY
const SHOWCASE_SEED := 780780
const STEP := 0.05


func run() -> void:
	# The formation layer's own behaviour.
	_test_a_distant_body_picks_a_target()
	_test_distant_soldiers_do_not_search()
	_test_approaching_soldiers_stay_formation_driven()
	_test_contact_promotes_the_front()
	_test_rear_ranks_stay_formation_driven()
	_test_a_left_flank_is_answered()
	_test_a_right_flank_is_answered()
	_test_a_rank_taken_from_behind_strikes_back()
	_test_two_enemies_on_two_sides_are_both_answered()
	_test_a_dead_body_is_left_behind()
	_test_a_lapsing_order_falls_back_to_choosing()
	_test_an_explicit_target_is_not_second_guessed()
	_test_a_soldiers_own_order_beats_the_gate()
	_test_a_soldier_replaces_a_dead_opponent()
	_test_a_body_pushed_apart_disengages()
	_test_the_press_forward_cache_is_behaviour_identical()
	_test_the_gate_never_starves_a_soldier()
	_test_the_dead_do_not_look()
	_test_a_corpse_body_is_not_a_target()
	_test_sparse_contact_promotes_almost_nobody()
	_test_high_density_contact_keeps_the_share_small()
	_test_the_formation_target_tie_is_stable()
	_test_the_soldier_target_tie_is_stable()
	# Membership: split, merge, ownership.
	_test_split_while_distant()
	_test_split_while_approaching()
	_test_split_in_contact()
	_test_unequal_split()
	_test_arbitrary_subset_split()
	_test_split_halves_choose_their_own_enemies()
	_test_split_halves_move_independently()
	_test_one_half_can_disengage()
	_test_two_bodies_can_become_one()
	_test_nobody_stands_in_two_bodies()
	_test_no_soldier_is_lost_or_created()
	_test_invariants_survive_casualties()
	# The layers together.
	_test_the_hierarchy_cuts_the_look_count()
	_test_the_same_seed_fights_the_same_battle()
	_test_random_membership_transitions()
	_test_the_result_path_is_untouched()
	GameManager.end_campaign()
	_complete()


## ---------- fixtures ------------------------------------------------------

func _config() -> GameConfig:
	return GameManager.config()


func _catalog() -> FormationCatalog:
	return FormationCatalog.load_from()


## A battle of the showcase's own shape, which is the deployment every measurement in this
## milestone uses.
func _battle(per_side: int, seed_value: int = SHOWCASE_SEED, enabled: bool = true) -> Dictionary:
	var built := ShowcaseBattle.build(
		_config(), UnitCatalog.load_from(), _catalog(), per_side, seed_value)
	var simulator: BattleSimulator = built["simulator"]
	simulator.engagement_enabled = enabled
	simulator.profile_enabled = true
	simulator.reset_profile()
	simulator.reset_engagement_counters()
	simulator.start()
	return {
		"simulator": simulator,
		"bodies": simulator.formations,
		"player_ai": BattleAI.create(_config(), SIDE_PLAYER),
		"enemy_ai": BattleAI.create(_config(), SIDE_ENEMY),
	}


## Drive a battle for a number of ticks with both commanders thinking.
func _drive(bundle: Dictionary, ticks: int) -> void:
	var simulator: BattleSimulator = bundle["simulator"]
	for i in ticks:
		bundle["player_ai"].update(simulator, STEP)
		bundle["enemy_ai"].update(simulator, STEP)
		simulator.step(STEP)


## The press-forward gate is now decided once per body per step instead of once per soldier. The
## answers must be identical to the reference it replaced - which stays switchable in the same build -
## and the two battles must stay in lockstep, tick for tick. A change in behaviour would show up as
## soldiers standing in different places, which is why positions are compared and not only answers.
func _test_the_press_forward_cache_is_behaviour_identical() -> void:
	section("the press-forward cache answers what the reference answers")
	var cached := _battle(10)
	var reference := _battle(10)
	reference["simulator"].press_forward_cache_enabled = false
	check(cached["simulator"].press_forward_cache_enabled, "the cache is on in the battle that has it")
	check(not reference["simulator"].press_forward_cache_enabled, "and off in the reference")
	var compared := 0
	var disagreements := 0
	var pressed_disagreements := 0
	for tick in 40:
		_drive(cached, 1)
		_drive(reference, 1)
		# The counter is compared every tick, which is what catches the mid-loop case an auditor asked
		# for: a soldier early in the loop marking his body in contact, and a soldier later in the same
		# loop reading the gate. A frozen contact value would move one of these two numbers and not the
		# other, even though both battles end the tick in the same state.
		if cached["simulator"].upd_pressed_forward != reference["simulator"].upd_pressed_forward:
			pressed_disagreements += 1
		var cached_units: Array[BattleUnit] = cached["simulator"].units
		var reference_units: Array[BattleUnit] = reference["simulator"].units
		for i in mini(cached_units.size(), reference_units.size()):
			var a: BattleUnit = cached_units[i]
			var b: BattleUnit = reference_units[i]
			if a.formation_ref == null or b.formation_ref == null:
				continue
			compared += 1
			if cached["simulator"]._can_press_forward(a, a.formation_ref) \
					!= reference["simulator"]._can_press_forward(b, b.formation_ref):
				disagreements += 1
			if a.position.distance_squared_to(b.position) > 0.000001:
				disagreements += 1
	equal(disagreements, 0, "no soldier's press-forward answer or position differed from the reference")
	equal(pressed_disagreements, 0,
		"and the number of soldiers allowed to press forward matched on every tick, which is the mid-loop contact case")
	check(compared > 0, "and soldiers with bodies were actually compared")


func _bodies_of(bundle: Dictionary, side: String) -> Array[BattleFormation]:
	var out: Array[BattleFormation] = []
	for body in bundle["bodies"]:
		if body.side == side:
			out.append(body)
	return out


## The share of a body's soldiers the gate would let look for their own opponent, by asking the
## gate itself rather than by reading a flag: the flag is written on the soldiers' own awareness
## ticks and this question is about right now.
func _promoted_in(simulator: BattleSimulator, body: BattleFormation) -> int:
	var allowed := 0
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		if bool(simulator.call("_formation_driven_search_allowed", unit)):
			allowed += 1
	return allowed


func _distance_to_body(simulator: BattleSimulator, unit: BattleUnit, body: BattleFormation) -> float:
	return sqrt(body.bounds_distance_squared(unit.position))


## Kill every soldier of a given rank of a body, without pretending somebody did it.
func _kill_rank(simulator: BattleSimulator, body: BattleFormation, rank: int) -> int:
	var killed := 0
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		if unit.slot_index / maxi(1, body.file_count) == rank:
			unit.take_damage(unit.max_hp + 1, -1)
			killed += 1
	return killed


## ---------- the formation layer -------------------------------------------

func _test_a_distant_body_picks_a_target() -> void:
	section("a distant body picks the enemy body it is facing")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var ours := _bodies_of(bundle, SIDE_PLAYER)
	var theirs := _bodies_of(bundle, SIDE_ENEMY)
	simulator.call("_update_engagement")
	equal(ours.size(), 3, "three bodies a side, as the showcase deploys")
	var targeted := 0
	var facing := 0
	for body in ours:
		if body.target_formation_id != "":
			targeted += 1
		var target: BattleFormation = simulator.formation(body.target_formation_id)
		if target != null and target.side == SIDE_ENEMY and target.living_count > 0:
			facing += 1
	equal(targeted, 3, "every body named an enemy body before a blow was struck")
	equal(facing, 3, "and every one of them named a live enemy body of the other side")
	equal(int(simulator.engagement_report()["bodies_with_target"]), 6,
		"and both sides' bodies are counted: six in all")
	# Nearest by box, so the centre faces the centre rather than a wing.
	var centre: BattleFormation = null
	for body in ours:
		if body.id.contains("centre"):
			centre = body
	not_null(centre, "the deployment has a centre body")
	if centre != null:
		var target: BattleFormation = simulator.formation(centre.target_formation_id)
		not_null(target, "the centre's target resolves")
		if target != null:
			check(target.id.contains("centre"),
				"and it is the enemy centre, the nearest body of the other side (%s)" % target.id)


func _test_distant_soldiers_do_not_search() -> void:
	section("soldiers of a body that has not met the enemy do not look for their own")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 120)
	var report := simulator.target_report()
	equal(int(report["formation_enabled"]), 1, "the hierarchy is doing the thinking")
	equal(int(report["searches"]), 0, "and on the approach not one soldier looked for anybody")
	greater(float(report["formation_deferrals"]), 0.0,
		"because the bodies refused every look that came round (%d of them)" % int(report["formation_deferrals"]))


func _test_approaching_soldiers_stay_formation_driven() -> void:
	section("a soldier closing on the enemy but outside reach still dresses")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 200)
	var ours := _bodies_of(bundle, SIDE_PLAYER)
	var body: BattleFormation = ours[1]
	equal(int(body.engagement), BattleFormation.ENGAGEMENT_APPROACHING,
		"the wing is still approaching at tick %d" % simulator.tick_index)
	var promoted := _promoted_in(simulator, body)
	equal(promoted, 0, "and none of its %d soldiers was allowed to look for its own opponent" % body.living_count)
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		if unit.slot_index >= 0 and unit.slot_index < body.slots.size():
			less(unit.position.distance_to(body.slots[unit.slot_index]), 14.0,
				"a soldier is near its place anyway, because dressing is still its job")


func _test_contact_promotes_the_front() -> void:
	section("the men who can reach the enemy are the ones allowed to look")
	# Two deep blocks meeting each other, which is the moment target acquisition has to happen
	# in: the front ranks are in reach and the men behind them are not.
	var simulator := BattleSimulator.new(_config(), 4343)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 40.0), 0.0, 200, 0)
	var theirs := _add_body(simulator, "theirs", SIDE_ENEMY, Vector2(72.0, 40.0), PI, 200, 1000)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(int(ours.engagement) == BattleFormation.ENGAGEMENT_NEAR_CONTACT
			or int(ours.engagement) == BattleFormation.ENGAGEMENT_IN_CONTACT, true,
		"the two blocks report that they are at grips with each other")
	var promoted := _promoted_in(simulator, ours)
	var living := ours.living_count
	greater(float(promoted), 0.0, "the men who can reach the enemy may look for their own: %d of %d" % [
		promoted, living])
	less(float(promoted), float(living),
		"and the ones behind them may not, so this is a band rather than a whole body")
	# The promoted men really are the ones in front: nothing behind the band is looking.
	var deepest_promoted := -1
	var shallowest_unpromoted := 9999
	for unit_id in ours.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive() or ours.file_count <= 0:
			continue
		var rank := unit.slot_index / ours.file_count
		if bool(simulator.call("_formation_driven_search_allowed", unit)):
			deepest_promoted = maxi(deepest_promoted, rank)
		else:
			shallowest_unpromoted = mini(shallowest_unpromoted, rank)
	if deepest_promoted >= 0 and shallowest_unpromoted < 9999:
		less(float(deepest_promoted), float(shallowest_unpromoted),
			"and every promoted man is nearer the front than every man refused")


func _test_rear_ranks_stay_formation_driven() -> void:
	section("a soldier six ranks back is not asked which enemy it would like to fight")
	# A deep block with an enemy touching its front rank: the rear ranks are thirty units from
	# anybody, and what they are doing is dressing.
	var simulator := BattleSimulator.new(_config(), 4545)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 40.0), 0.0, 200, 0)
	_add_body(simulator, "theirs", SIDE_ENEMY, Vector2(76.0, 40.0), PI, 40, 1000)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	greater(float(ours.rank_count), 6.0, "the block is %d ranks deep" % ours.rank_count)
	var rear := 0
	var rear_looking := 0
	for unit_id in ours.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive() or ours.file_count <= 0:
			continue
		var rank := unit.slot_index / ours.file_count
		if rank < maxi(0, ours.rank_count - 3):
			continue
		rear += 1
		if bool(simulator.call("_formation_driven_search_allowed", unit)):
			rear_looking += 1
	greater(float(rear), 0.0, "there are rear ranks to ask about (%d soldiers in the last three)" % rear)
	equal(rear_looking, 0,
		"and not one of them is allowed to look for an opponent of its own while the fight is at the front")


func _test_a_left_flank_is_answered() -> void:
	section("a body taken on the left flank answers it")
	_flank_case(Vector2(0.0, -1.0), "left")


func _test_a_right_flank_is_answered() -> void:
	section("a body taken on the right flank answers it")
	_flank_case(Vector2(0.0, 1.0), "right")


## A line of ours with its front to the east, and an enemy body parked on one flank of it. The
## nearest enemy is not the one it was facing, and its flanking soldiers must still be allowed to
## look - which is the whole reason the gate is a box distance rather than a frontage test.
func _flank_case(offset: Vector2, label: String) -> void:
	var simulator := BattleSimulator.new(_config(), 5150)
	var front := _add_body(simulator, "front", SIDE_PLAYER, Vector2(60.0, 40.0), 0.0, 60, 0)
	var ahead := _add_body(simulator, "ahead", SIDE_ENEMY, Vector2(140.0, 40.0), PI, 60, 100)
	var flank := _add_body(
		simulator, "flank", SIDE_ENEMY, Vector2(60.0, 40.0) + offset * 14.0, 0.0, 30, 200)
	simulator.start()
	simulator.call("_update_engagement")
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	not_equal(front.target_formation_id, "", "the body named a target at all")
	# The flanking body is nearer the flank than the one ahead is to the front, so the gate must
	# count it as nearby even though the body's strategic answer is the other one.
	check(front.nearby_enemy_ids.has(flank.id),
		"the %s-flank body is one it may have to answer to" % label)
	var answered := 0
	for unit_id in front.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		if _distance_to_body(simulator, unit, flank) <= front.contact_band:
			if bool(simulator.call("_formation_driven_search_allowed", unit)):
				answered += 1
	greater(float(answered), 0.0,
		"and %d of its soldiers are allowed to look while the enemy stands on that flank" % answered)
	# The men on the far side are not.
	var far_side := 0
	for unit_id in front.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		var offset_from_centre := unit.position - front.centre
		if offset_from_centre.dot(offset) < -8.0:
			if bool(simulator.call("_formation_driven_search_allowed", unit)):
				far_side += 1
	equal(far_side, 0, "while the other side of the body is not looking at anything")
	equal(ahead.living_count > 0, true, "and the body it chose is still standing there")


func _test_a_rank_taken_from_behind_strikes_back() -> void:
	section("a soldier struck from behind strikes back without being asked to look")
	var simulator := BattleSimulator.new(_config(), 6262)
	var body := _add_body(simulator, "line", SIDE_PLAYER, Vector2(60.0, 40.0), 0.0, 40, 0)
	var raider := _add_body(simulator, "raiders", SIDE_ENEMY, Vector2(140.0, 40.0), PI, 4, 100)
	simulator.profile_enabled = true
	simulator.reset_profile()
	simulator.start()
	simulator.call("_update_engagement")
	# A raider appears behind the line and strikes a rear-rank soldier.
	var victim: BattleUnit = null
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null and unit.is_alive() and unit.slot_index / maxi(1, body.file_count) >= 3:
			victim = unit
	if victim == null:
		check(false, "the fixture has a rear rank to strike")
		return
	raider_placeholder(simulator, raider, victim)
	var attack_simulator: BattleSimulator = simulator
	var attacker := _unit_at(simulator, raider, victim.position + Vector2(1.0, 0.0))
	not_null(attacker, "a raider was placed inside the soldier's reach, from behind")
	if attacker == null:
		return
	simulator.call("_attack", attacker, victim)
	equal(victim.last_attacker_id, attacker.id, "the blow was recorded against the soldier that took it")
	equal(victim.hp < victim.max_hp, true, "and the soldier was actually hurt")
	var retaliation: BattleUnit = simulator.call("_retaliation_target", victim)
	not_null(retaliation, "so the soldier strikes back without a search")
	if retaliation != null:
		equal(retaliation.id, attacker.id, "and it strikes back at the one that hit it")
	equal(victim.auto_target_id, attacker.id, "and keeps it as its opponent")
	equal(attack_simulator.engagement_report()["retaliations"] > 0, true,
		"which the report counted as a retaliation rather than a look")


## Park a body's soldiers on top of a point, so the geometric tests are about the gate rather
## than about a march.
func raider_placeholder(simulator: BattleSimulator, body: BattleFormation, target: BattleUnit) -> void:
	for i in body.unit_ids.size():
		var unit := simulator.find_unit(body.unit_ids[i])
		if unit != null:
			unit.position = target.position + Vector2(2.0 + float(i), -1.0)
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")


func _unit_at(simulator: BattleSimulator, body: BattleFormation, position: Vector2) -> BattleUnit:
	var best: BattleUnit = null
	var best_distance := INF
	for unit_id in body.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit == null or not unit.is_alive():
			continue
		var distance := unit.position.distance_to(position)
		if distance < best_distance:
			best_distance = distance
			best = unit
	return best


func _test_two_enemies_on_two_sides_are_both_answered() -> void:
	section("two bodies on two sides of one body are both answered")
	var simulator := BattleSimulator.new(_config(), 7373)
	var body := _add_body(simulator, "centre", SIDE_PLAYER, Vector2(60.0, 40.0), 0.0, 60, 0)
	_add_body(simulator, "east", SIDE_ENEMY, Vector2(78.0, 40.0), PI, 40, 100)
	_add_body(simulator, "north", SIDE_ENEMY, Vector2(60.0, 22.0), 0.0, 40, 200)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(body.nearby_enemy_ids.size(), 2, "both enemy bodies count as nearby")
	var answered_sides := 0
	for facing in [Vector2.RIGHT, Vector2.UP]:
		var found := 0
		for unit_id in body.unit_ids:
			var unit := simulator.find_unit(unit_id)
			if unit == null or not unit.is_alive():
				continue
			if unit.position.distance_to(body.centre) > 100.0:
				continue
			if (unit.position - body.centre).normalized().dot(facing) < 0.5:
				continue
			if bool(simulator.call("_formation_driven_search_allowed", unit)):
				found += 1
		if found > 0:
			answered_sides += 1
	equal(answered_sides, 2,
		"the soldiers facing each of the two enemies are allowed to look, without a global scan")


func _test_a_dead_body_is_left_behind() -> void:
	section("a wiped-out body stops being anybody's target")
	var simulator := BattleSimulator.new(_config(), 8484)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, 20, 0)
	var theirs := _add_body(simulator, "theirs", SIDE_ENEMY, Vector2(70.0, 30.0), PI, 20, 100)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(ours.target_formation_id, "theirs", "the nearest body was chosen")
	for unit_id in theirs.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null:
			unit.take_damage(unit.max_hp + 1, -1)
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(ours.target_formation_id, "", "and when it was wiped out the target was dropped")
	equal(int(ours.engagement), BattleFormation.ENGAGEMENT_NONE, "the body reports nothing to fight")
	equal(ours.nearby_enemy_ids.size(), 0, "and has nobody it might have to answer to")
	equal(simulator.check_membership_invariants().size(), 0,
		"with no complaint from the membership invariants about the corpse")


func _test_a_lapsing_order_falls_back_to_choosing() -> void:
	section("an order that cannot be carried out lapses rather than sticking")
	var simulator := BattleSimulator.new(_config(), 9595)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, 20, 0)
	var near := _add_body(simulator, "near", SIDE_ENEMY, Vector2(60.0, 30.0), PI, 10, 100)
	var far := _add_body(simulator, "far", SIDE_ENEMY, Vector2(120.0, 30.0), PI, 10, 200)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.set_engagement_target(ours, "far")
	equal(ours.target_formation_id, "far", "the explicit order was taken")
	equal(ours.target_explicit, true, "and is flagged as an order rather than a choice")
	for unit_id in far.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null:
			unit.take_damage(unit.max_hp + 1, -1)
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(ours.target_explicit, false, "when the named body is gone the order lapses")
	equal(ours.target_formation_id, "near", "and the body goes back to choosing, which finds 'near'")


func _test_an_explicit_target_is_not_second_guessed() -> void:
	section("a body told what to fight does not drift onto something nearer")
	var simulator := BattleSimulator.new(_config(), 1717)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, 20, 0)
	_add_body(simulator, "near", SIDE_ENEMY, Vector2(52.0, 30.0), PI, 10, 100)
	var far := _add_body(simulator, "far", SIDE_ENEMY, Vector2(150.0, 30.0), PI, 10, 200)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.set_engagement_target(ours, "far")
	simulator.call("_update_engagement")
	equal(ours.target_formation_id, "far", "the body kept the body it was told to fight")
	for i in 30:
		simulator.step(STEP)
	equal(ours.target_formation_id, "far",
		"and still had it thirty ticks later, with a nearer enemy standing beside it")
	check(ours.nearby_enemy_ids.has("near"),
		"while the nearer body is still one its soldiers may answer to")
	equal(far.living_count > 0, true, "the ordered body is alive, so the order stands")


func _test_a_soldiers_own_order_beats_the_gate() -> void:
	section("a soldier given a target keeps it whatever its body is doing")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var victim: BattleUnit = null
	for unit_id in _bodies_of(bundle, SIDE_ENEMY)[2].unit_ids:
		victim = simulator.find_unit(unit_id)
		if victim != null:
			break
	not_null(victim, "there is an enemy to order a soldier at")
	if victim == null:
		return
	var soldier: BattleUnit = null
	for unit_id in _bodies_of(bundle, SIDE_PLAYER)[2].unit_ids:
		soldier = simulator.find_unit(unit_id)
		if soldier != null:
			break
	not_null(soldier, "and a soldier to give the order to")
	if soldier == null:
		return
	soldier.attack_order_target_id = victim.id
	simulator.reset_engagement_counters()
	equal(bool(simulator.call("_formation_driven_search_allowed", soldier)), true,
		"a soldier with an explicit order is allowed to look even on the approach")
	# The order is honoured by the soldier's own update, ahead of the automatic rule. Movement
	# is what shows it here: an ordered soldier faces what it was pointed at.
	simulator.call("_update_unit", soldier, STEP)
	var to_victim := (victim.position - soldier.position).normalized()
	greater(float(soldier.facing.dot(to_victim)), 0.99,
		"and it is facing the enemy it was pointed at, not the one its body is watching")


func _test_a_soldier_replaces_a_dead_opponent() -> void:
	section("a soldier whose opponent dies gets another, and soon")
	var simulator := BattleSimulator.new(_config(), 2828)
	var soldier := _unit(0, SIDE_PLAYER, Vector2(30.0, 30.0), 3.0)
	var first := _unit(1, SIDE_ENEMY, Vector2(32.0, 30.0))
	var second := _unit(2, SIDE_ENEMY, Vector2(34.0, 30.0))
	simulator.add_units([soldier, first, second])
	simulator.start()
	simulator.step(STEP)
	equal(soldier.auto_target_id, 1, "the nearest enemy was acquired")
	first.take_damage(first.max_hp + 1, soldier.id)
	var replacement: BattleUnit = simulator.call("_resolve_target", soldier)
	not_null(replacement, "and the dead one was replaced at once, without waiting for a cadence")
	if replacement != null:
		equal(replacement.id, 2, "with the next enemy along")


func _test_a_body_pushed_apart_disengages() -> void:
	section("a body that is pushed apart goes back to dressing when the fight lapses")
	var simulator := BattleSimulator.new(_config(), 3939)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, 20, 0)
	var theirs := _add_body(simulator, "theirs", SIDE_ENEMY, Vector2(48.0, 30.0), PI, 20, 100)
	simulator.start()
	var in_contact := 0
	for i in 60:
		simulator.step(STEP)
		if ours.in_contact:
			in_contact += 1
	greater(float(in_contact), 0.0, "the bodies fought for %d ticks of the first sixty" % in_contact)
	equal(int(ours.engagement), BattleFormation.ENGAGEMENT_IN_CONTACT,
		"and the body reported that it was fighting")
	# The enemy walks away: no more blows, and the bodies come apart.
	theirs.set_units(theirs.unit_ids)
	for unit_id in theirs.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null and unit.is_alive():
			unit.position += Vector2(60.0, 0.0)
	simulator.call("_refresh_summaries")
	simulator.step(STEP)
	theirs.order = BattleFormation.ORDER_HOLD
	for i in 80:
		simulator.step(STEP)
		if not ours.in_contact:
			break
	equal(ours.in_contact, false, "the fight stopped when the enemy left")
	check(int(ours.engagement) == BattleFormation.ENGAGEMENT_DISENGAGING
			or int(ours.engagement) == BattleFormation.ENGAGEMENT_APPROACHING,
		"and the body stopped calling itself engaged")


func _test_the_gate_never_starves_a_soldier() -> void:
	section("no soldier is refused a look while it could strike somebody")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var refused := 0
	var starving := 0
	for i in 900:
		_drive(bundle, 1)
		for unit in simulator.units:
			if not unit.is_alive() or unit.auto_target_id >= 0 or unit.attack_order_target_id >= 0:
				continue
			if bool(simulator.call("_formation_driven_search_allowed", unit)):
				continue
			refused += 1
			for other in simulator.units:
				if not other.is_alive() or other.side == unit.side:
					continue
				if unit.position.distance_to(other.position) <= unit.attack_range:
					starving += 1
					break
	greater(float(refused), 1000.0, "the bodies refused %d looks over the battle" % refused)
	equal(starving, 0,
		"and not one of them was refused to a soldier that could have struck somebody")


func _test_the_dead_do_not_look() -> void:
	section("a dead soldier is nobody's problem")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 600)
	var dead := 0
	for unit in simulator.units:
		if unit.is_alive():
			continue
		dead += 1
		equal(bool(simulator.call("_formation_driven_search_allowed", unit)), false,
			"a dead soldier is not allowed to look")
	greater(float(dead), 0.0, "and the battle had produced %d dead to ask about" % dead)


func _test_a_corpse_body_is_not_a_target() -> void:
	section("a body of corpses is not a target and does not think")
	var simulator := BattleSimulator.new(_config(), 4040)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, 10, 0)
	var theirs := _add_body(simulator, "theirs", SIDE_ENEMY, Vector2(60.0, 30.0), PI, 10, 100)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(ours.target_formation_id, "theirs", "the empty-of-nothing body was chosen")
	for unit_id in theirs.unit_ids:
		var unit := simulator.find_unit(unit_id)
		if unit != null:
			unit.take_damage(unit.max_hp + 1, -1)
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(theirs.living_count, 0, "the body is dead")
	equal(theirs.target_formation_id, "", "and a dead body does not name a target of its own")
	equal(int(theirs.engagement), BattleFormation.ENGAGEMENT_NONE, "nor a state")
	equal(ours.target_formation_id, "", "nor can it be named as anybody's target")


func _test_sparse_contact_promotes_almost_nobody() -> void:
	section("with contact on one small frontage, almost nobody is promoted")
	var simulator := BattleSimulator.new(_config(), 5151)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(60.0, 40.0), 0.0, 200, 0)
	# One enemy body touching the front rank of a deep block: the shape an envelopment starts
	# from, where the men at the front are in a fight and the men behind them are not.
	_add_body(simulator, "tip", SIDE_ENEMY, Vector2(78.0, 40.0), PI, 20, 300)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	var promoted := _promoted_in(simulator, ours)
	less(float(promoted), float(ours.living_count) * 0.35,
		"a single touching body promoted only %d of %d soldiers" % [promoted, ours.living_count])
	greater(float(promoted), 0.0, "but it did promote the ones that matter")


func _test_high_density_contact_keeps_the_share_small() -> void:
	section("even in a general engagement the share of promoted soldiers is a band")
	var bundle := _battle(300)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 3200)
	var promoted := 0
	var living := 0
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		living += 1
		if unit.fdr_promoted:
			promoted += 1
	greater(float(living), 0.0, "the battle is still fighting at tick %d with %d standing" % [
		simulator.tick_index, living])
	less(float(promoted), float(living),
		"and in a general engagement %d of %d soldiers are in individual mode" % [promoted, living])
	# The running total the report quotes must agree with a fresh count, or the counter lies.
	var recounted := simulator.engagement_soldier_counts()
	equal(int(recounted["promoted"]), int(simulator.engagement_report()["running_promoted_total"]),
		"the running total of promoted soldiers matches a fresh count")


func _test_the_formation_target_tie_is_stable() -> void:
	section("two bodies the same distance away do not change places every check")
	var simulator := BattleSimulator.new(_config(), 6161)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(40.0, 30.0), 0.0, 20, 0)
	# Mirror-image enemies: the same distance either side, so only the tie-break decides.
	_add_body(simulator, "a", SIDE_ENEMY, Vector2(70.0, 10.0), PI, 10, 100)
	_add_body(simulator, "b", SIDE_ENEMY, Vector2(70.0, 50.0), PI, 10, 200)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	var chosen := ours.target_formation_id
	not_equal(chosen, "", "a tie was broken rather than left empty")
	var changes := 0
	for i in 40:
		ours.engagement_tick = 0
		simulator.engagement_recheck_ticks = 1
		simulator.call("_update_engagement")
		if ours.target_formation_id != chosen:
			changes += 1
	equal(changes, 0, "and forty further checks chose the same body every time (%s)" % chosen)


func _test_the_soldier_target_tie_is_stable() -> void:
	section("a soldier's target is decided by the same kind of stable tie-break")
	var simulator := BattleSimulator.new(_config(), 7171)
	var soldier := _unit(0, SIDE_PLAYER, Vector2(30.0, 30.0), 3.0)
	# Two enemies exactly as far away as each other.
	_unit_into(simulator, _unit(1, SIDE_ENEMY, Vector2(34.0, 26.0)))
	_unit_into(simulator, _unit(2, SIDE_ENEMY, Vector2(34.0, 34.0)))
	simulator.call("_rebuild_spatial", STEP)
	simulator.call("_refresh_focus")
	simulator.start()
	# The search is called directly: this test is about the tie-break the search makes, not
	# about when a soldier's awareness phase comes round.
	var chosen: BattleUnit = simulator.call("_search_for_target", soldier, null)
	not_null(chosen, "the search answered out of a tie")
	if chosen == null:
		return
	equal(soldier.auto_target_id, chosen.id, "and the answer was stored")
	greater(float(chosen.id), 0.0, "a target was chosen out of a tie")
	# And the same battle from the same seed chooses the same one.
	var twin := BattleSimulator.new(_config(), 7171)
	var twin_soldier := _unit(0, SIDE_PLAYER, Vector2(30.0, 30.0), 3.0)
	_unit_into(twin, _unit(1, SIDE_ENEMY, Vector2(34.0, 26.0)))
	_unit_into(twin, _unit(2, SIDE_ENEMY, Vector2(34.0, 34.0)))
	twin.call("_rebuild_spatial", STEP)
	twin.call("_refresh_focus")
	twin.start()
	var twin_chosen: BattleUnit = twin.call("_search_for_target", twin_soldier, null)
	not_null(twin_chosen, "and so did the twin")
	if twin_chosen == null:
		return
	equal(twin_chosen.id, chosen.id, "and the same seed chose the same one")


## ---------- membership ----------------------------------------------------

func _test_split_while_distant() -> void:
	section("a body can be split while it is crossing open ground")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var body := _bodies_of(bundle, SIDE_PLAYER)[0]
	var ids := _first_n(simulator, body, body.unit_ids.size() / 2)
	var before := _roster(simulator)
	var split := simulator.split_formation(body, ids, "player_centre_2")
	not_null(split, "the split happened")
	if split == null:
		return
	equal(simulator.formations.size(), 7, "there are seven bodies now")
	equal(body.unit_ids.size(), body.living_count if body.living_count > 0 else body.unit_ids.size(),
		"the body kept the soldiers that were not asked for")
	equal(_roster(simulator), before, "and not one soldier was created or destroyed")
	equal(simulator.check_membership_invariants().size(), 0, "the membership invariants hold")
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	not_equal(split.target_formation_id, "", "the new body chose a target of its own")
	not_equal(body.target_formation_id, "", "and so did the one it left")


func _test_split_while_approaching() -> void:
	section("both halves of a split keep marching, independently")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 200)
	var body := _bodies_of(bundle, SIDE_PLAYER)[1]
	var ids := _first_n(simulator, body, 10)
	var split := simulator.split_formation(body, ids, "player_left_2")
	not_null(split, "the wing was split while it was still approaching")
	if split == null:
		return
	split.order = BattleFormation.ORDER_MOVE
	split.steer_toward(split.anchor + Vector2(0.0, 40.0))
	var anchor_before := body.anchor
	_drive(bundle, 60)
	greater(split.anchor.distance_to(anchor_before), 0.0, "the detached half moved somewhere")
	var apart_early := split.anchor.distance_to(body.anchor)
	_drive(bundle, 120)
	var apart := split.anchor.distance_to(body.anchor)
	# The substance is that the halves part and keep parting. The first measurement matters because
	# D-108 changed how fast they do it: a soldier standing in his place now moves by his body's
	# step instead of overshooting toward his slot, so a detached half swings wide more slowly than
	# it used to. The old assertion read the distance once and demanded more than five units of it.
	greater(apart, apart_early, "the halves keep separating: %.1f units, then %.1f" % [apart_early, apart])
	greater(apart, 5.0, "and the two halves are now %.1f units apart" % apart)
	equal(simulator.check_membership_invariants().size(), 0, "with the invariants still holding")


func _test_split_in_contact() -> void:
	section("a body can be split in the middle of a fight")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var contact := false
	for i in 1200:
		_drive(bundle, 1)
		for body in _bodies_of(bundle, SIDE_PLAYER):
			if body.in_contact:
				contact = true
				break
		if contact:
			break
	equal(contact, true, "the armies met at tick %d" % simulator.tick_index)
	var body := _bodies_of(bundle, SIDE_PLAYER)[0]
	var target_before := body.target_formation_id
	var ids := _first_n(simulator, body, 15)
	var split := simulator.split_formation(body, ids, "player_centre_3")
	not_null(split, "the engaged body was split")
	if split == null:
		return
	equal(simulator.check_membership_invariants().size(), 0, "and the invariants survived the fight")
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(body.target_formation_id, target_before,
		"the body that stayed kept the enemy it was fighting")
	not_equal(split.target_formation_id, "", "and the half that left found its own")
	_drive(bundle, 40)
	equal(simulator.check_membership_invariants().size(), 0,
		"and forty ticks of fighting later the invariants still hold")


func _test_unequal_split() -> void:
	section("splits of any size are honoured, not only halves")
	var bundle := _battle(100)
	var simulator: BattleSimulator = bundle["simulator"]
	var body := _bodies_of(bundle, SIDE_PLAYER)[2]
	var total := body.unit_ids.size()
	var small := simulator.split_formation(body, _first_n(simulator, body, 3), "player_right_a")
	not_null(small, "three soldiers can leave a body of %d" % total)
	if small == null:
		return
	equal(small.unit_ids.size(), 3, "and the new body has exactly three")
	equal(body.unit_ids.size(), total - 3, "the old one has the rest")
	var big := simulator.split_formation(body, _first_n(simulator, body, total - 4), "player_right_b")
	not_null(big, "and all but a handful can leave")
	if big != null:
		equal(body.unit_ids.size(), 1, "leaving a body of one")
		equal(simulator.check_membership_invariants().size(), 0, "with the invariants holding")


func _test_arbitrary_subset_split() -> void:
	section("any subset of a body may be the one that leaves")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var body := _bodies_of(bundle, SIDE_PLAYER)[0]
	# Every fifth soldier, in the body's own order: not a half, not a prefix, not a rank.
	var ids: Array[int] = []
	for i in body.unit_ids.size():
		if i % 5 == 0:
			ids.append(body.unit_ids[i])
	greater(float(ids.size()), 0.0, "the subset has %d soldiers in it" % ids.size())
	var split := simulator.split_formation(body, ids, "player_centre_every5")
	not_null(split, "an arbitrary subset can be the half that leaves")
	if split == null:
		return
	for unit_id in ids:
		equal(split.has_unit(unit_id), true, "the subset holds what it asked for")
		equal(body.has_unit(unit_id), false, "and the body it left no longer does")
	equal(simulator.check_membership_invariants().size(), 0, "with no complaints")


func _test_split_halves_choose_their_own_enemies() -> void:
	section("the halves of a split are separate tactical actors")
	var simulator := BattleSimulator.new(_config(), 8181)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(60.0, 40.0), 0.0, 60, 0)
	_add_body(simulator, "east", SIDE_ENEMY, Vector2(95.0, 40.0), PI, 40, 100)
	var north := _add_body(simulator, "north", SIDE_ENEMY, Vector2(60.0, -10.0), 0.0, 40, 200)
	simulator.start()
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(ours.target_formation_id, "east", "the whole body chose the body it was facing")
	var north_half := simulator.split_formation(ours, _first_n(simulator, ours, 20), "north_half")
	not_null(north_half, "a quarter of it was detached towards the other enemy")
	if north_half == null:
		return
	simulator.set_engagement_target(north_half, "north")
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	equal(north_half.target_formation_id, "north", "the detached half was told to fight the north")
	equal(ours.target_formation_id, "east", "while the body it left still fights the east")
	equal(north.id, "north", "and the north body is a real body to fight")


func _test_split_halves_move_independently() -> void:
	section("the halves move to different places")
	var simulator := BattleSimulator.new(_config(), 9191)
	var ours := _add_body(simulator, "ours", SIDE_PLAYER, Vector2(60.0, 40.0), 0.0, 60, 0)
	# A battle with nobody on the other side is over on the first tick, so the fixture needs an
	# enemy to march away from.
	_add_body(simulator, "theirs", SIDE_ENEMY, Vector2(230.0, 100.0), PI, 10, 500)
	simulator.start()
	var half := simulator.split_formation(ours, _first_n(simulator, ours, 30), "detached")
	not_null(half, "the body was split")
	if half == null:
		return
	half.order = BattleFormation.ORDER_MOVE
	half.steer_toward(Vector2(60.0, 95.0))
	ours.order = BattleFormation.ORDER_MOVE
	ours.steer_toward(Vector2(120.0, 20.0))
	var ours_before := ours.anchor
	var half_before := half.anchor
	for i in 120:
		simulator.step(STEP)
	greater(half.anchor.distance_to(half_before), 5.0, "the detached half marched to its own order")
	greater(ours.anchor.distance_to(ours_before), 5.0, "and the body it left marched to a different one")
	greater(half.anchor.distance_to(ours.anchor), 40.0,
		"and they are now %.1f units apart" % half.anchor.distance_to(ours.anchor))
	greater(float(half.anchor.y - half_before.y), 5.0, "one went south")
	greater(float(ours.anchor.x - ours_before.x), 5.0, "and the other went east")


func _test_one_half_can_disengage() -> void:
	section("one half can be pulled out of a fight the other half stays in")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var contact := false
	for i in 1200:
		_drive(bundle, 1)
		for body in _bodies_of(bundle, SIDE_PLAYER):
			if body.in_contact:
				contact = true
				break
		if contact:
			break
	equal(contact, true, "the fight started")
	var body := _bodies_of(bundle, SIDE_PLAYER)[0]
	var half := simulator.split_formation(body, _first_n(simulator, body, 12), "withdrawing")
	not_null(half, "half of the engaged body was detached")
	if half == null:
		return
	half.order = BattleFormation.ORDER_MOVE
	half.steer_toward(half.anchor + Vector2(-60.0, 0.0))
	var before := half.anchor
	# No commander for this part: the battle's own AI would order the body straight back in.
	for i in 100:
		simulator.step(STEP)
	greater(float(before.x - half.anchor.x), 1.0,
		"the detached half withdrew %.1f units while the rest kept fighting" % (before.x - half.anchor.x))
	equal(simulator.check_membership_invariants().size(), 0, "with the invariants intact")


func _test_two_bodies_can_become_one() -> void:
	section("two bodies can be merged back into one")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var body := _bodies_of(bundle, SIDE_PLAYER)[0]
	var source_size := body.unit_ids.size()
	var ids := _first_n(simulator, body, 8)
	var split := simulator.split_formation(body, ids, "player_centre_tmp")
	not_null(split, "a body was split off")
	if split == null:
		return
	var roster := _roster(simulator)
	var health := _health_map(simulator)
	var kills := _kill_map(simulator)
	var merged := simulator.merge_formations(body, split)
	equal(merged, true, "the two bodies were merged")
	equal(simulator.formations.size(), 6, "and there are six bodies again")
	equal(body.unit_ids.size(), source_size, "the keeper's roll is the two rolls together")
	equal(_roster(simulator), roster, "no soldier was created or destroyed by the merge")
	equal(_health_map(simulator), health, "and every soldier kept its wounds")
	equal(_kill_map(simulator), kills, "and its kills")
	equal(simulator.check_membership_invariants().size(), 0, "the invariants hold after the merge")


func _test_nobody_stands_in_two_bodies() -> void:
	section("the ownership invariant holds through repeated surgery")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var bodies := _bodies_of(bundle, SIDE_PLAYER)
	var index := 0
	for round_index in 6:
		var body: BattleFormation = bodies[index % bodies.size()]
		if body.living_count < 4:
			index += 1
			continue
		var half := maxi(1, body.unit_ids.size() / 3)
		var ids := _first_n(simulator, body, half)
		var created := simulator.split_formation(body, ids, "split_%d" % round_index)
		if created != null:
			bodies.append(created)
			# And merge it straight back, so the next round starts from a different shape.
			simulator.merge_formations(bodies[0], created)
			bodies.erase(created)
		index += 1
	var problems := simulator.check_membership_invariants()
	equal(problems.size(), 0, "six rounds of splitting and merging left no complaints: %s" % str(problems))


func _test_no_soldier_is_lost_or_created() -> void:
	section("splitting and merging never changes the roster")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	var roster := _roster(simulator)
	var ids := _id_list(simulator)
	var body := _bodies_of(bundle, SIDE_PLAYER)[0]
	simulator.split_formation(body, _first_n(simulator, body, 20), "a")
	simulator.split_formation(body, _first_n(simulator, body, 10), "b")
	equal(_roster(simulator), roster, "the roster is what it was after two splits")
	equal(_id_list(simulator), ids, "and every soldier id is still present exactly once")
	equal(_duplicate_ids(simulator).size(), 0, "with no id appearing twice")


func _test_invariants_survive_casualties() -> void:
	section("the invariants survive a battle")
	var bundle := _battle(100)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 1500)
	var dead := 0
	for unit in simulator.units:
		if not unit.is_alive():
			dead += 1
	greater(float(dead), 0.0, "the battle produced %d casualties" % dead)
	var problems := simulator.check_membership_invariants()
	equal(problems.size(), 0, "and the membership invariants came through it: %s" % str(problems))


## ---------- the two layers together ---------------------------------------

func _test_the_hierarchy_cuts_the_look_count() -> void:
	section("the same battle, with and without the hierarchy, counted")
	var with := _count_searches(300, true)
	var without := _count_searches(300, false)
	print("      with the hierarchy: %.0f searches, %.0f deferrals, %.0f of %.0f soldiers in individual mode" % [
		with["searches"], with["deferrals"], with["promoted"], with["living"]])
	print("      without it:         %.0f searches, %.0f of %.0f soldiers in individual mode" % [
		without["searches"], without["promoted"], without["living"]])
	greater(float(without["searches"]), 0.0, "the baseline looked for opponents the old way")
	less(float(with["searches"]), float(without["searches"]),
		"and the hierarchy made fewer looks: %.0f against %.0f" % [with["searches"], without["searches"]])
	less(float(with["promoted"]), float(with["living"]),
		"with only some of the soldiers in individual mode at the end")
	equal(int(with["problems"]), 0, "and no membership complaint either way")
	equal(int(without["problems"]), 0, "in either mode")


func _count_searches(per_side: int, enabled: bool) -> Dictionary:
	var bundle := _battle(per_side, SHOWCASE_SEED, enabled)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 900)
	var report := simulator.target_report()
	var counts := simulator.engagement_soldier_counts()
	return {
		"searches": report["searches"],
		"deferrals": report["formation_deferrals"],
		"promoted": counts["promoted"],
		"living": simulator.alive_units().size(),
		"problems": simulator.check_membership_invariants().size(),
	}


func _test_the_same_seed_fights_the_same_battle() -> void:
	section("the same seed fights the same battle with the hierarchy on")
	var first := _digest_battle(300, true)
	var second := _digest_battle(300, true)
	equal(first, second, "two runs of one seed agree exactly")
	var baseline_first := _digest_battle(300, false)
	var baseline_second := _digest_battle(300, false)
	equal(baseline_first, baseline_second, "and so do two runs with the hierarchy switched off")


func _digest_battle(per_side: int, enabled: bool) -> Dictionary:
	var bundle := _battle(per_side, SHOWCASE_SEED, enabled)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 600)
	var digest: Array[int] = []
	for unit in simulator.units:
		digest.append(unit.hp if unit.is_alive() else -1)
		digest.append(int(unit.position.x))
		digest.append(int(unit.position.y))
	return {
		"tick": simulator.tick_index,
		"living_player": simulator.side_count(SIDE_PLAYER),
		"living_enemy": simulator.side_count(SIDE_ENEMY),
		"digest": digest,
	}


func _test_random_membership_transitions() -> void:
	section("thousands of random membership transitions hold every invariant")
	var simulator := BattleSimulator.new(_config(), 313131)
	var units: Array[BattleUnit] = []
	for i in 240:
		var unit := _unit(i, SIDE_PLAYER if i < 120 else SIDE_ENEMY,
			Vector2(30.0 + float(i % 120) * 0.7, 20.0 + float((120 - i % 120)) * 0.5), 2.0)
		units.append(unit)
	simulator.add_units(units)
	simulator.start()
	var bodies: Array[BattleFormation] = []
	var first := _add_body(simulator, "root", SIDE_PLAYER, Vector2(60.0, 30.0), 0.0, 60, 1000)
	var second := _add_body(simulator, "root_enemy", SIDE_ENEMY, Vector2(100.0, 30.0), PI, 60, 2000)
	bodies.append(first)
	bodies.append(second)
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")

	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED
	var roster_before := _roster(simulator)
	var ids_before := _id_list(simulator)
	var splits := 0
	var merges := 0
	var kills := 0
	var problems: Array[String] = []
	for step_index in 2000:
		var action := rng.randi_range(0, 5)
		match action:
			0, 1:
				# Split a random body by a random rule.
				var body: BattleFormation = bodies[rng.randi_range(0, bodies.size() - 1)]
				if body.living_count >= 3:
					var ids := _random_subset(simulator, body, rng)
					if ids.size() > 0 and ids.size() < body.unit_ids.size():
						var created := simulator.split_formation(body, ids, "r_%d" % step_index)
						if created != null:
							bodies.append(created)
							splits += 1
			2:
				# Merge two bodies of the same side.
				if bodies.size() >= 3:
					var a: BattleFormation = bodies[rng.randi_range(0, bodies.size() - 1)]
					var b: BattleFormation = bodies[rng.randi_range(0, bodies.size() - 1)]
					if a != b and a.side == b.side and b.living_count > 0 and a.living_count > 0:
						if simulator.merge_formations(a, b):
							bodies.erase(b)
							merges += 1
			3:
				# Kill a random soldier.
				var victim: BattleUnit = units[rng.randi_range(0, units.size() - 1)]
				if victim.is_alive():
					victim.take_damage(victim.max_hp + 1, -1)
					kills += 1
			4:
				# Move a body, so the geometry keeps changing under the gate.
				var body: BattleFormation = bodies[rng.randi_range(0, bodies.size() - 1)]
				body.anchor += Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-8.0, 8.0))
			5:
				# A tick, so the summaries and the engagement state move too.
				simulator.step(STEP)
		if step_index % 250 == 0:
			var found := simulator.check_membership_invariants()
			for problem in found:
				if not problems.has(problem):
					problems.append(problem)
	equal(problems.size(), 0,
		"two thousand transitions (%d splits, %d merges, %d deaths) left no complaint: %s" % [
			splits, merges, kills, str(problems.slice(0, 3))])
	equal(_roster(simulator), roster_before, "the roster is unchanged by all of it")
	equal(_id_list(simulator), ids_before, "and every soldier id is still there exactly once")
	equal(_duplicate_ids(simulator).size(), 0, "nobody is in two bodies")
	# And the same script run again produces the same result, because everything above is
	# deterministic given the seed.
	var repeat := _random_script_digest()
	equal(repeat, _random_script_digest(), "and the whole random script is reproducible")


## The same random script as the test above, reduced to a digest, run twice.
func _random_script_digest() -> Dictionary:
	var simulator := BattleSimulator.new(_config(), 313131)
	var units: Array[BattleUnit] = []
	for i in 240:
		var unit := _unit(i, SIDE_PLAYER if i < 120 else SIDE_ENEMY,
			Vector2(30.0 + float(i % 120) * 0.7, 20.0 + float((120 - i % 120)) * 0.5), 2.0)
		units.append(unit)
	simulator.add_units(units)
	simulator.start()
	var bodies: Array[BattleFormation] = []
	bodies.append(_add_body(simulator, "root", SIDE_PLAYER, Vector2(60.0, 30.0), 0.0, 60, 1000))
	bodies.append(_add_body(simulator, "root_enemy", SIDE_ENEMY, Vector2(100.0, 30.0), PI, 60, 2000))
	simulator.call("_refresh_summaries")
	simulator.call("_update_engagement")
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED
	for step_index in 2000:
		var action := rng.randi_range(0, 5)
		match action:
			0, 1:
				var body: BattleFormation = bodies[rng.randi_range(0, bodies.size() - 1)]
				if body.living_count >= 3:
					var ids := _random_subset(simulator, body, rng)
					if ids.size() > 0 and ids.size() < body.unit_ids.size():
						var created := simulator.split_formation(body, ids, "r_%d" % step_index)
						if created != null:
							bodies.append(created)
			2:
				if bodies.size() >= 3:
					var a: BattleFormation = bodies[rng.randi_range(0, bodies.size() - 1)]
					var b: BattleFormation = bodies[rng.randi_range(0, bodies.size() - 1)]
					if a != b and a.side == b.side and b.living_count > 0 and a.living_count > 0:
						if simulator.merge_formations(a, b):
							bodies.erase(b)
			3:
				var victim: BattleUnit = units[rng.randi_range(0, units.size() - 1)]
				if victim.is_alive():
					victim.take_damage(victim.max_hp + 1, -1)
			4:
				var body: BattleFormation = bodies[rng.randi_range(0, bodies.size() - 1)]
				body.anchor += Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-8.0, 8.0))
			5:
				simulator.step(STEP)
	var digest: Array[int] = []
	for body in bodies:
		digest.append(body.unit_ids.size())
		digest.append(int(body.anchor.x * 100.0))
	for unit in units:
		digest.append(unit.hp if unit.is_alive() else -1)
	return {"bodies": bodies.size(), "digest": digest}


func _test_the_result_path_is_untouched() -> void:
	section("the result the campaign sees does not depend on any of this")
	var bundle := _battle(60)
	var simulator: BattleSimulator = bundle["simulator"]
	_drive(bundle, 400)
	var context := BattleContext.new()
	context.battle_id = "engagement_result"
	context.battle_seed = SHOWCASE_SEED
	context.enemy_display_name = "Bandits"
	var state := GameManager.new_campaign("Formation-Driven Engagement", SHOWCASE_SEED)
	var resolver := BattleResolver.build(state, _config())
	if resolver == null:
		check(false, "the resolver could be built")
		return
	var before := simulator.side_count(SIDE_PLAYER) + simulator.side_count(SIDE_ENEMY)
	var result: BattleResult = resolver.build_result(
		context, simulator, simulator.winner, simulator.elapsed, false)
	not_null(result, "a result could be built from a battle with the hierarchy on")
	equal(simulator.side_count(SIDE_PLAYER) + simulator.side_count(SIDE_ENEMY), before,
		"and building it changed nothing about the battle")
	equal(simulator.check_membership_invariants().size(), 0,
		"with the membership invariants still holding afterwards")


## ---------- small helpers -------------------------------------------------

func _unit(id: int, side: String, position: Vector2, reach: float = 0.05, speed: float = 5.0) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_eng_%d" % id
	unit.display_name = "Soldier %d" % id
	unit.max_hp = 40
	unit.hp = 40
	unit.attack = 5
	unit.defence = 2
	unit.move_speed = speed
	unit.attack_range = reach
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


func _unit_into(simulator: BattleSimulator, unit: BattleUnit) -> void:
	var roster := simulator.units
	roster.append(unit)
	simulator.add_units(roster)


## A body of probe soldiers on their own places: a line, ten files wide, facing east.
func _add_body(
	simulator: BattleSimulator,
	id: String,
	side: String,
	anchor: Vector2,
	facing: float,
	count: int,
	first_unit_id: int,
	speed: float = 5.0
) -> BattleFormation:
	var units: Array[BattleUnit] = []
	var ids: Array[int] = []
	for i in count:
		var unit_id := first_unit_id + i
		units.append(_unit(unit_id, side, anchor, 2.4, speed))
		ids.append(unit_id)
	var existing := simulator.units
	existing.append_array(units)
	simulator.add_units(existing)
	var formation := BattleFormation.create(
		id, side, anchor, facing, "line", _catalog(), _config())
	simulator.add_formation(formation)
	simulator.assign_formation(formation, ids)
	_dress(simulator, formation)
	return formation


func _dress(simulator: BattleSimulator, formation: BattleFormation) -> void:
	formation.ensure_slots()
	for i in formation.unit_ids.size():
		var unit := simulator.find_unit(formation.unit_ids[i])
		if unit != null:
			unit.position = formation.slots[i]
	simulator.call("_refresh_summaries")


func _first_n(simulator: BattleSimulator, body: BattleFormation, count: int) -> Array[int]:
	var ids: Array[int] = []
	for i in mini(count, body.unit_ids.size()):
		ids.append(body.unit_ids[i])
	return ids


func _random_subset(
	simulator: BattleSimulator, body: BattleFormation, rng: RandomNumberGenerator
) -> Array[int]:
	var ids: Array[int] = []
	for unit_id in body.unit_ids:
		if rng.randf() < 0.4:
			ids.append(unit_id)
	if ids.is_empty() and body.unit_ids.size() > 0:
		ids.append(body.unit_ids[0])
	return ids


## The roster as (soldier id -> unit id), which is what must not change across surgery.
func _roster(simulator: BattleSimulator) -> Dictionary:
	var out: Dictionary = {}
	for unit in simulator.units:
		out[unit.soldier_id] = unit.id
	return out


func _id_list(simulator: BattleSimulator) -> Array[int]:
	var out: Array[int] = []
	for unit in simulator.units:
		out.append(unit.id)
	out.sort()
	return out


func _duplicate_ids(simulator: BattleSimulator) -> Array[int]:
	var seen: Dictionary = {}
	var out: Array[int] = []
	for unit in simulator.units:
		if seen.has(unit.id):
			out.append(unit.id)
		seen[unit.id] = true
	return out


func _health_map(simulator: BattleSimulator) -> Dictionary:
	var out: Dictionary = {}
	for unit in simulator.units:
		out[unit.id] = unit.hp
	return out


func _kill_map(simulator: BattleSimulator) -> Dictionary:
	var out: Dictionary = {}
	for unit in simulator.units:
		out[unit.id] = unit.kills
	return out
