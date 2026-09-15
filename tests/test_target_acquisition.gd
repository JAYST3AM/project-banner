extends TestCase
## Step 7.4: target acquisition - how often a soldier looks, and who it keeps.
##
## The rules this suite exists to pin down:
## [br]- a soldier with an enemy in front of it keeps dealing with that enemy, and does
##   not ask the battlefield to tell it so;
## [br]- soldiers look on a staggered, deterministic, tick-based cadence, and no two
##   soldiers are obliged to look at the same moment;
## [br]- losing an opponent mid-swing is noticed at once; losing one that was never in
##   reach can wait its turn;
## [br]- an explicit order is never delayed, never overruled and never queued behind a
##   schedule;
## [br]- a remembered opponent is released when it dies or gets too far away, and a
##   soldier will not chase one across the battlefield;
## [br]- the search itself is unchanged - the milestone changed how often it is asked,
##   not what it answers;
## [br]- and none of it can produce a burst of simultaneous work, a battle that depends on
##   the order its roster happens to be stored in, or a frame spike.
##
## [b]On the numbers here.[/b] Several tests assert exact counts of searches over a known
## number of ticks. That is deliberate: the cadence is a contract, and a test that only
## asserts "fewer searches than before" would pass for a cadence of one, which is the
## behaviour this milestone removed. Where a count depends on which soldiers were alive
## and fighting, the test uses an inequality instead and says why.
##
## [b]On the semantic change.[/b] These tests describe behaviour that is deliberately
## different from Step 7.3, where every soldier asked for the nearest local enemy every
## tick. The difference is recorded in D-080 rather than hidden inside an optimisation.

const TICK := 0.05
const SEED := 74001

const PLAYER := BattleContext.SIDE_PLAYER
const ENEMY := BattleContext.SIDE_ENEMY


func run() -> void:
	await _tick()
	_test_a_remembered_opponent_is_kept()
	_test_the_fastest_path_is_the_enemy_in_front()
	_test_a_lost_opponent_in_reach_is_replaced_at_once()
	_test_a_lost_opponent_out_of_reach_waits_its_turn()
	_test_an_opponent_that_leaves_relevance_is_released()
	_test_an_explicit_order_is_never_delayed()
	_test_an_order_lapsing_falls_back_to_the_nearest_enemy()
	_test_a_new_enemy_is_noticed_within_the_cadence()
	_test_the_cadence_bounds_the_latency_at_every_interval()
	_test_searches_are_staggered_across_ticks()
	_test_the_schedule_does_not_depend_on_roster_order()
	_test_soldiers_far_from_the_fighting_do_not_search_every_tick()
	_test_a_proven_skip_never_misses_an_enemy()
	_test_a_wing_acquires_enemies_when_it_reaches_them()
	_test_two_similar_enemies_do_not_thrash()
	_test_cell_boundaries_are_not_awareness_blind_spots()
	_test_mass_target_death_is_bounded_and_deterministic()
	_test_a_wider_awareness_works_generically()
	_test_nothing_assumes_every_unit_is_melee()
	_test_the_search_itself_is_unchanged()
	_test_the_retention_path_allocates_nothing()
	_test_a_battle_with_a_cadence_is_deterministic()
	_test_immediate_reacquisition_can_be_switched_off()
	_test_every_soldier_tick_is_accounted_for()
	_test_the_report_counts_what_it_claims_to()
	_complete()


## ---------- fixtures -----------------------------------------------------

func _config() -> GameConfig:
	return GameManager.config()


## A soldier that is not going to fight unless a test asks it to. A reach this short keeps
## damage out of the tests that are about looking rather than hitting; a test that wants a
## fight gives its units a real reach.
##
## Speed is settable because several tests are about who a soldier is dealing with rather
## than about where it walks, and a soldier that stays exactly where it was put is the
## cleanest way to hold everything else still.
func _unit(id: int, side: String, position: Vector2, reach: float = 0.05, speed: float = 5.0) -> BattleUnit:
	var unit := BattleUnit.new()
	unit.id = id
	unit.side = side
	unit.soldier_id = "s_tgt_%d" % id
	unit.display_name = "Target %d" % id
	unit.max_hp = 1000
	unit.hp = 1000
	unit.attack = 1
	unit.defence = 0
	unit.move_speed = speed
	unit.attack_range = reach
	unit.attack_cooldown = 1.0
	unit.position = position
	return unit


## A simulator with the given roster already running. The interval is set before the
## roster is added, because that is where the awareness phases are handed out.
func _simulator(units: Array[BattleUnit], interval: int = 4) -> BattleSimulator:
	var simulator := BattleSimulator.new(_config(), SEED)
	simulator.target_reacquisition_ticks = interval
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()
	return simulator


## The same, with the counters switched on. Nothing else about it differs: the tests read
## the counters exactly as the benchmark does.
func _counting(units: Array[BattleUnit], interval: int = 4) -> BattleSimulator:
	var simulator := _simulator(units, interval)
	simulator.profile_enabled = true
	simulator.reset_profile()
	return simulator


## Two formed armies on a field sized for them, dressed on their slots, advancing. This is
## the shape a real battle starts in, and the shape the approach behaviour has to be
## judged in.
func _formed_army(per_side: int, gap: float, interval: int, seed_value: int = SEED) -> Dictionary:
	var config := _config()
	var field := Vector2(240.0, 160.0)
	var units: Array[BattleUnit] = []
	var next_id := 0
	var middle := field.x * 0.5
	for side_value in [PLAYER, ENEMY]:
		var side := str(side_value)
		var left := side == PLAYER
		var ranks := 4
		var files := maxi(1, per_side / ranks)
		for i in per_side:
			var file := i % files
			var rank := i / files
			# The front rank of each army stands half the gap from the middle of the field,
			# so `gap` really is the distance the two front ranks have to cross.
			var x := (middle - gap * 0.5) - float(rank) * 1.4 if left \
				else (middle + gap * 0.5) + float(rank) * 1.4
			var y := field.y * 0.2 + float(file) * (field.y * 0.6 / float(files))
			var unit := _unit(next_id, side, Vector2(x, y), 1.8)
			unit.max_hp = 40
			unit.hp = 40
			unit.attack = 5
			unit.defence = 2
			next_id += 1
			units.append(unit)

	var simulator := BattleSimulator.new(config, seed_value)
	simulator.field_size = field
	simulator.grid.configure(field, simulator.cell_size)
	simulator.overlap_grid.configure(field, simulator.overlap_cell_size)
	simulator.target_reacquisition_ticks = interval
	simulator.add_units(units)
	var bodies := BattleSetup.assign_default_formations(simulator, config)
	var ai := BattleAI.create(config)
	simulator.profile_enabled = true
	simulator.reset_profile()
	simulator.start()
	return {"simulator": simulator, "bodies": bodies, "ai": ai, "units": units}


## ---------- a remembered opponent ----------------------------------------

## The rule at the centre of the milestone: the enemy in front of a soldier stays the
## enemy in front of it, and finding that out costs nothing at all.
func _test_a_remembered_opponent_is_kept() -> void:
	section("a soldier keeps the enemy in front of it")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 3.0)
	var enemy := _unit(1, ENEMY, Vector2(32.0, 30.0), 3.0)
	var simulator := _counting([soldier, enemy], 4)
	for i in 12:
		simulator.step(TICK)

	# Two enemies two units apart, each able to reach the other. Twelve ticks, and the
	# whole exchange costs two searches: one each, on the first tick either of them was
	# due to look. Everything after that is spent hitting the enemy already in front,
	# because for a soldier that can reach its opponent there is nothing a look could
	# discover that is worth the asking.
	equal(soldier.auto_target_id, 1, "the soldier is still dealing with the enemy in front of it")
	equal(enemy.auto_target_id, 0, "and the enemy is dealing with the soldier")
	equal(simulator.tgt_searches, 2, "twelve ticks of two soldiers cost two searches, not twenty-four")
	equal(simulator.tgt_soldier_ticks, 24, "twenty-four soldier-ticks were simulated")
	equal(simulator.tgt_retained_in_reach, 21, "twenty-one of them were spent on the enemy already in reach")
	equal(simulator.tgt_retained_held, 0, "and nobody was holding an opponent at a distance")
	equal(simulator.tgt_focus_fallbacks, 1, "one tick was answered by the cheap fallback, before the second look")
	equal(simulator.tgt_switches, 0, "nobody changed their mind")
	equal(int(simulator.target_report()["searches_avoided"]), 22, "so twenty-two searches did not happen")


## The other side of that rule, and the reason the cadence exists at all: an opponent that
## is not in reach is still re-examined, or a soldier would hold a stale answer forever.
func _test_the_fastest_path_is_the_enemy_in_front() -> void:
	section("an enemy in reach is the fastest path through target handling")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 3.0)
	var enemy := _unit(1, ENEMY, Vector2(32.0, 30.0), 3.0)
	var simulator := _counting([soldier, enemy], 4)
	for i in 12:
		simulator.step(TICK)
	equal(simulator.tgt_retained_held, 0, "an enemy in reach is never 'held at a distance'")
	greater(float(simulator.tgt_retained_in_reach), 18.0,
		"and the great majority of ticks went through the path that asks nothing")

	# The same two soldiers, out of reach of each other instead - and held still, so that
	# the counts are about the cadence rather than about two soldiers walking together.
	# Neither can hit anything, so both are re-examined on their own turn and both are
	# held in between.
	var watching := _unit(0, PLAYER, Vector2(30.0, 30.0), 0.05, 0.0)
	var watched := _unit(1, ENEMY, Vector2(36.0, 30.0), 0.05, 0.0)
	var slower := _counting([watching, watched], 4)
	for i in 12:
		slower.step(TICK)
	equal(slower.tgt_retained_in_reach, 0, "with nobody in reach, nothing went down that path")
	# Six looks over twelve ticks: the soldier on ticks 0, 4 and 8 and the enemy on 1, 5
	# and 9, with every tick in between spent holding the opponent already found.
	equal(slower.tgt_retained_held, 17, "and an opponent at a distance is held between looks")
	equal(slower.tgt_searches, 6, "with both soldiers looking on their own four-tick cadence")


## ---------- losing an opponent -------------------------------------------

## An opponent killed while the soldier could have struck it is a fight continuing, and
## the replacement is found in the same tick rather than at the next scheduled look.
func _test_a_lost_opponent_in_reach_is_replaced_at_once() -> void:
	section("a lost opponent in reach is replaced at once")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 3.0)
	var victim := _unit(1, ENEMY, Vector2(32.0, 30.0))
	var other := _unit(2, ENEMY, Vector2(36.0, 30.0))
	var simulator := _counting([soldier, victim, other], 8)
	simulator.step(TICK)
	equal(soldier.auto_target_id, 1, "the nearest enemy was acquired")
	equal(soldier.next_search_tick, 8, "and this soldier's next scheduled look is eight ticks away")

	victim.hp = 0
	victim.alive = false
	simulator.step(TICK)
	equal(simulator.tgt_invalid_dead, 1, "the death was noticed")
	equal(simulator.tgt_immediate_reacquires, 1, "and it was urgent, because it happened in reach")
	equal(soldier.auto_target_id, 2, "so the next enemy was taken in the same tick")
	equal(simulator.tgt_searches, 2, "which cost one search, brought forward off the cadence")


## The same loss at a distance is not urgent. Nothing was taken away from that soldier
## mid-swing, so it can wait its turn like everything else.
func _test_a_lost_opponent_out_of_reach_waits_its_turn() -> void:
	section("a lost opponent out of reach waits for the soldier's own turn")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 0.6)
	var victim := _unit(6, ENEMY, Vector2(36.0, 30.0), 0.6)
	var other := _unit(4, ENEMY, Vector2(38.0, 30.0), 0.6)
	var simulator := _counting([soldier, victim, other], 8)
	simulator.step(TICK)
	equal(soldier.auto_target_id, 6, "the enemy six units away was acquired")
	simulator.step(TICK)
	equal(simulator.tgt_searches, 1, "one search so far: nobody else's turn has come round")

	victim.hp = 0
	victim.alive = false
	simulator.step(TICK)
	equal(simulator.tgt_invalid_dead, 1, "the death was noticed")
	equal(simulator.tgt_immediate_reacquires, 0, "but it was not urgent: that enemy was never in reach")
	equal(simulator.tgt_searches, 1, "so nothing searched early")
	equal(soldier.auto_target_id, -1, "and the soldier is not holding an automatic opponent yet")

	# Its own turn is tick eight. Until then it is pointed at the fighting by its side,
	# which is the cheap answer, and it holds no opponent of its own.
	for i in 5:
		simulator.step(TICK)
	equal(soldier.auto_target_id, -1, "still waiting five ticks later, at tick seven")
	simulator.step(TICK)
	equal(soldier.auto_target_id, 4, "and at its own awareness tick it takes the nearest living enemy")


## A remembered opponent that walks out of relevance is released rather than chased, and
## an enemy beyond the search's own reach is never taken in the first place.
func _test_an_opponent_that_leaves_relevance_is_released() -> void:
	section("an opponent that gets too far away is let go")
	var soldier := _unit(0, PLAYER, Vector2(20.0, 30.0))
	var enemy := _unit(1, ENEMY, Vector2(24.0, 30.0))
	var simulator := _counting([soldier, enemy], 4)
	simulator.target_retention_radius = 8.0
	simulator.step(TICK)
	equal(soldier.auto_target_id, 1, "an enemy four units away is worth dealing with")

	# Fifty units away is beyond the widest rung of the ladder, so there is no question of
	# it being taken again - and taking it again is what "chasing it forever" would mean.
	enemy.position = Vector2(70.0, 30.0)
	simulator.step(TICK)
	equal(simulator.tgt_invalid_far, 1, "leaving the retention radius was noticed at once")
	equal(soldier.auto_target_id, -1, "and the opponent was released")
	for i in 20:
		simulator.step(TICK)
	equal(soldier.auto_target_id, -1, "twenty ticks later it has still not been taken")
	equal(simulator.tgt_invalid_far, 1, "and there was nothing left to release")

	# The boundary is the search's own reach and not a special case for distance: bring the
	# same enemy back inside the second rung and it is taken on the soldier's next look.
	enemy.position = Vector2(50.0, 30.0)
	var picked_up := false
	for i in 8:
		simulator.step(TICK)
		if soldier.auto_target_id == 1:
			picked_up = true
	check(picked_up, "an enemy inside the ladder's reach is picked up again")


## ---------- explicit orders ----------------------------------------------

## An order is a player instruction. It is answered on the tick it is given, and the
## soldier's own awareness clock does not advance while it holds.
func _test_an_explicit_order_is_never_delayed() -> void:
	section("an order never waits for a cadence")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 400.0)
	soldier.attack_cooldown = 0.05
	var nearer := _unit(1, ENEMY, Vector2(34.0, 30.0))
	var ordered := _unit(2, ENEMY, Vector2(60.0, 30.0))
	var simulator := _counting([soldier, nearer, ordered], 8)
	simulator.step(TICK)
	equal(soldier.auto_target_id, 1, "left alone, the nearest enemy is what a soldier faces")

	soldier.attack_order_target_id = 2
	var slot := soldier.next_search_tick
	var ordered_hp := ordered.hp
	var nearer_hp := nearer.hp
	simulator.step(TICK)
	less(float(ordered.hp), float(ordered_hp), "the ordered enemy is struck on the very first tick")
	equal(nearer.hp, nearer_hp, "and the nearer enemy is left alone")
	equal(soldier.next_search_tick, slot, "while no automatic look happened at all")
	greater(float(simulator.tgt_explicit_order_uses), 0.0, "the order is what the soldier used")

	# Nine more ticks: the soldier's scheduled slot comes and goes, and the order stands.
	for i in 9:
		simulator.step(TICK)
	equal(soldier.next_search_tick, slot, "nine ticks later the soldier has still not looked for itself")
	less(float(ordered.hp), float(ordered_hp), "and the ordered enemy kept taking blows")


## When an order lapses the soldier falls straight back on the automatic rule, with no
## idle tick in between.
func _test_an_order_lapsing_falls_back_to_the_nearest_enemy() -> void:
	section("an order that lapses hands back to the automatic rule")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 400.0)
	soldier.attack_cooldown = 5.0
	var first := _unit(1, ENEMY, Vector2(34.0, 30.0))
	var second := _unit(2, ENEMY, Vector2(38.0, 30.0))
	var simulator := _counting([soldier, first, second], 4)
	soldier.attack_order_target_id = 1
	simulator.step(TICK)
	equal(soldier.attack_order_target_id, 1, "the order is honoured")

	first.hp = 0
	first.alive = false
	simulator.step(TICK)
	equal(soldier.attack_order_target_id, -1, "a dead order is dropped, under the same rule as before")
	equal(simulator.tgt_order_clears, 1, "and that was counted")
	equal(soldier.auto_target_id, 2, "and the soldier is facing the nearest living enemy in the same tick")


## ---------- noticing a new enemy -----------------------------------------

## A soldier with nobody to fight finds out about an arrival inside one cadence, and the
## worst case is measured rather than hoped about.
func _test_a_new_enemy_is_noticed_within_the_cadence() -> void:
	section("an arriving enemy is noticed inside one cadence")
	var soldier := _unit(0, PLAYER, Vector2(20.0, 30.0))
	var arrival := _unit(1, ENEMY, Vector2(90.0, 30.0))
	var simulator := _counting([soldier, arrival], 4)
	for i in 6:
		simulator.step(TICK)
	equal(soldier.auto_target_id, -1, "ninety units away is nobody's business")

	arrival.position = Vector2(24.0, 30.0)
	var noticed := -1
	for i in 6:
		simulator.step(TICK)
		if soldier.auto_target_id == 1 and noticed < 0:
			noticed = i
	greater(float(noticed), -1.0, "the arrival was noticed")
	check(noticed <= 4, "inside one cadence of arriving (took %d ticks)" % noticed)


## The cadence is a latency bound, not merely a saving. At every interval, an enemy that
## arrives immediately after a soldier's scheduled look waits one cadence minus the tick
## it arrived on - and no longer.
func _test_the_cadence_bounds_the_latency_at_every_interval() -> void:
	section("the cadence is the worst-case latency at every interval")
	for interval in [1, 2, 3, 4, 6, 8]:
		var soldier := _unit(0, PLAYER, Vector2(20.0, 30.0))
		var arrival := _unit(1, ENEMY, Vector2(90.0, 30.0))
		var simulator := _counting([soldier, arrival], interval)
		# One tick past the soldier's first slot, so the arrival always lands as far from
		# a look as it can: this is the worst case, every time.
		for i in interval + 1:
			simulator.step(TICK)
		arrival.position = Vector2(24.0, 30.0)
		var ticks_to_notice := -1
		for i in interval + 1:
			simulator.step(TICK)
			if soldier.auto_target_id == 1:
				ticks_to_notice = i
				break
		equal(ticks_to_notice, interval - 1,
			"cadence %d: noticed on the scheduled look and not before" % interval)


## ---------- staggering ---------------------------------------------------

## The failure this milestone had to avoid: twenty thousand soldiers all deciding to look
## on the same tick. With phases taken from unit ids, every tick carries its own share.
func _test_searches_are_staggered_across_ticks() -> void:
	section("the army does not all look on the same tick")
	var units: Array[BattleUnit] = []
	for i in 24:
		var side := PLAYER if i % 2 == 0 else ENEMY
		units.append(_unit(i, side, Vector2(10.0 + float(i % 6) * 12.0, 10.0 + float(i / 6) * 12.0)))
	var simulator := _counting(units, 4)
	for unit in units:
		equal(unit.next_search_tick, unit.id % 4, "soldier %d: phase comes from its own id" % unit.id)

	# Twenty-four soldiers, a four-tick cadence, twelve ticks. A staggered schedule puts
	# six soldiers on every tick; a synchronised one would put twenty-four on every fourth
	# tick and none at all in between.
	var per_tick: Array[int] = []
	var previous := 0
	for i in 12:
		simulator.step(TICK)
		per_tick.append(simulator.tgt_searches - previous)
		previous = simulator.tgt_searches
	for i in per_tick.size():
		equal(per_tick[i], 6, "tick %d: six of twenty-four soldiers looked" % i)
	equal(simulator.tgt_searches, 72, "and seventy-two searches cover twelve ticks of twenty-four soldiers")


## A phase that depended on where a soldier sits in the roster would make the schedule a
## property of the list rather than of the soldier - and would change when the roster is
## built differently.
func _test_the_schedule_does_not_depend_on_roster_order() -> void:
	section("the schedule belongs to the soldier, not to the list")
	var forward_units := _army_roster(12)
	var backward_units := _army_roster(12)
	var reversed_units: Array[BattleUnit] = []
	for i in range(backward_units.size() - 1, -1, -1):
		reversed_units.append(backward_units[i])
	var forward := _counting(forward_units, 4)
	var backward := _counting(reversed_units, 4)

	var phases := {}
	for unit in backward.units:
		phases[unit.id] = unit.next_search_tick
	for unit in forward.units:
		# The claim is per soldier, not per position: the soldier with id 7 looks on the
		# same tick whichever way round the roster was handed over.
		equal(phases.get(unit.id, -1), unit.next_search_tick, "soldier %d: same phase either way" % unit.id)

	# And the whole schedule holds: the same number of looks over the same ticks.
	for i in 9:
		forward.step(TICK)
		backward.step(TICK)
	equal(backward.tgt_searches, forward.tgt_searches, "and the same number of searches happened either way")
	equal(forward.tgt_searches, 27, "twelve soldiers over nine ticks of a four-tick cadence")


## ---------- approach and contact -----------------------------------------

## A soldier marching towards a battle it cannot see yet does not search for one every
## tick. That is the case the formation focus architecture exists for.
func _test_soldiers_far_from_the_fighting_do_not_search_every_tick() -> void:
	section("soldiers approaching a battle do not search every tick")
	var bundle := _formed_army(24, 120.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var soldiers := simulator.units.size()
	var bodies: Array[BattleFormation] = bundle["bodies"]
	var ai: BattleAI = bundle["ai"]

	var start := bodies[0].anchor
	for i in 60:
		ai.update(simulator, TICK)
		simulator.step(TICK)

	less(float(simulator.tgt_searches), float(soldiers * 20),
		"sixty ticks of %d soldiers cost far fewer searches than one each per tick" % soldiers)
	greater(float(bodies[0].anchor.x), float(start.x), "while the body kept advancing the whole time")
	greater(float(simulator.tgt_focus_fallbacks), 0.0, "and soldiers with nobody of their own used the cheap answer")

	# Which is also the case where the hierarchy earns its place, so it is the case that proves
	# the counters add up: every soldier-tick is exactly one of an order, an opponent in reach,
	# an opponent held, a look, the cheap answer, or a look the soldier's own body refused - and
	# nothing is counted twice. The sixth term is Step 7.8's: a soldier whose awareness came
	# round while its body was still marching is told to wait for its front rather than to ask
	# the battlefield a strategic question. See D-105.
	var report := simulator.target_report()
	var accounted := int(report["searches"]) + int(report["retained_in_reach"]) \
		+ int(report["retained_held"]) + int(report["focus_fallbacks"]) + int(report["explicit_order_uses"]) \
		+ int(report["formation_deferrals"])
	equal(accounted, int(report["soldier_ticks"]), "and every soldier-tick of the approach is accounted for")
	if simulator.engagement_enabled:
		greater(float(report["formation_deferrals"]), 0.0,
			"most of the approach was refused by the soldier's own body rather than looked at")
	else:
		greater(float(report["focus_proven"]), 0.0,
			"and with the hierarchy switched off the old proof did the skipping, as it did before")


## The cheapest look of all is the one that is not made. A soldier whose body's nearest
## enemy is further away than its own search could reach is pointed at the fighting instead
## of asking the battlefield a question whose answer is already known.
##
## This test does not check that the arithmetic is tidy. It checks the claim the optimisation
## rests on, in a live battle: that when the skip fires, there really is no enemy inside the
## soldier's own bound - checked against every enemy on the field, not against a sample.
func _test_a_proven_skip_never_misses_an_enemy() -> void:
	section("a skipped look would have found nobody")
	# A battlefield's width of open ground between the bodies, which is the case the proof
	# exists for: two armies that can see the shape of the fight but are nowhere near
	# touching it.
	var bundle := _formed_army(24, 120.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	var checked := 0
	var mistaken := 0
	for i in 200:
		ai.update(simulator, TICK)
		simulator.step(TICK)
		for unit in simulator.units:
			if not unit.is_alive() or unit.auto_target_id >= 0:
				continue
			if not bool(simulator.call("_focus_look_finds_nobody", unit)):
				continue
			checked += 1
			for other in simulator.units:
				if not other.is_alive() or other.side == unit.side:
					continue
				if unit.position.distance_to(other.position) <= simulator.target_search_max_radius:
					mistaken += 1
					break
	greater(float(checked), 100.0, "the proof fired plenty of times over two hundred ticks")
	equal(mistaken, 0, "and never once while an enemy stood inside the soldier's own reach")

	# The same guarantee, asked of the new layer rather than of the old proof: a soldier whose
	# look the hierarchy refused must not have been able to strike anybody. Checked tick by tick
	# against every enemy on the field, in a live formed battle - and it holds by construction,
	# because the band a refusal is measured against is never narrower than a weapon's reach.
	var refused := 0
	var starving := 0
	for i in 120:
		ai.update(simulator, TICK)
		simulator.step(TICK)
		for unit in simulator.units:
			if not unit.is_alive() or unit.auto_target_id >= 0 or unit.attack_order_target_id >= 0:
				continue
			if bool(simulator.call("_formation_driven_search_allowed", unit)):
				continue
			var body := unit.formation_ref
			if body != null and body.in_contact:
				continue
			refused += 1
			for other in simulator.units:
				if not other.is_alive() or other.side == unit.side:
					continue
				if unit.position.distance_to(other.position) <= unit.attack_range:
					starving += 1
					break
	if simulator.engagement_enabled:
		greater(float(refused), 100.0, "the hierarchy refused plenty of looks over the rest of the battle")
		equal(starving, 0,
			"and never once refused one to a soldier that could have struck somebody")


## And when the bodies do meet, the soldiers in them find each other - the cadence must
## not be a blindfold, and formation-local contact stays authoritative.
func _test_a_wing_acquires_enemies_when_it_reaches_them() -> void:
	section("a wing finds the enemy when it arrives")
	var bundle := _formed_army(24, 40.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var bodies: Array[BattleFormation] = bundle["bodies"]
	var ai: BattleAI = bundle["ai"]

	var contact_tick := -1
	for i in 400:
		ai.update(simulator, TICK)
		simulator.step(TICK)
		if contact_tick < 0:
			for body in bodies:
				if body.in_contact:
					contact_tick = i
	if contact_tick < 0:
		check(false, "the two armies never made contact")
		return
	greater(float(contact_tick), 0.0, "the armies met after %d ticks of marching" % contact_tick)
	greater(float(simulator.tgt_retained_in_reach), 0.0,
		"and once contact happened, soldiers were dealing with enemies in reach")
	greater(float(simulator.tgt_invalid_dead), 0.0, "and opponents were being killed and replaced")

	var holding := 0
	var fighting := 0
	for unit in simulator.units:
		if not unit.is_alive():
			continue
		if unit.auto_target_id >= 0:
			holding += 1
		if unit.side == PLAYER and unit.position.distance_to(bodies[0].anchor) < 8.0 and unit.auto_target_id >= 0:
			fighting += 1
	greater(float(holding), 0.0, "soldiers hold opponents of their own after contact: %d of them" % holding)
	greater(float(fighting), 0.0, "including soldiers at the front of a body that is fighting")


## ---------- hysteresis ---------------------------------------------------

## A valid opponent is not abandoned because something else is a hundredth of a unit
## closer, and it is abandoned when something else is unmistakably closer.
func _test_two_similar_enemies_do_not_thrash() -> void:
	section("a soldier does not swap opponents for nothing")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 0.05, 0.0)
	var first := _unit(1, ENEMY, Vector2(34.0, 30.0), 0.05, 0.0)
	var second := _unit(2, ENEMY, Vector2(33.8, 30.0), 0.05, 0.0)
	var simulator := _counting([soldier, first, second], 2)
	simulator.step(TICK)
	equal(soldier.auto_target_id, 2, "the nearest of two near-identical enemies is taken")
	equal(simulator.tgt_switches, 0, "which was an acquisition, not a change of mind")

	for i in 40:
		simulator.step(TICK)
	equal(soldier.auto_target_id, 2, "forty ticks later it is still the same enemy")
	equal(simulator.tgt_switches, 0, "and nothing thrashed")

	# Closer, but not by a quarter: not a reason to turn.
	first.position = Vector2(33.6, 30.0)
	for i in 4:
		simulator.step(TICK)
	equal(soldier.auto_target_id, 2, "a hair closer is not a reason to change")
	equal(simulator.tgt_switches, 0, "so no switch was counted")

	# Unmistakably closer: now it is.
	first.position = Vector2(30.5, 30.0)
	var switched := false
	for i in 4:
		simulator.step(TICK)
		if soldier.auto_target_id == 1:
			switched = true
	check(switched, "an enemy far closer does take over")
	equal(simulator.tgt_switches, 1, "and exactly one switch was counted")


## ---------- cell boundaries ----------------------------------------------

## A remembered opponent is not lost by walking into the next grid cell, and an enemy
## standing on the far side of a boundary is found like any other.
func _test_cell_boundaries_are_not_awareness_blind_spots() -> void:
	section("cell boundaries are not awareness blind spots")
	var cell := _config().get_float("battle.spatial_cell_size", 4.0)
	var soldier := _unit(0, PLAYER, Vector2(cell - 0.1, 10.0))
	var across := _unit(1, ENEMY, Vector2(cell + 0.1, 10.0))
	var simulator := _counting([soldier, across], 4)
	simulator.step(TICK)
	equal(soldier.auto_target_id, 1, "an enemy on the far side of a cell boundary is found")

	# Walk the soldier across the boundary while it holds that opponent.
	var before := soldier.auto_target_id
	for i in 6:
		soldier.position += Vector2(0.5, 0.0)
		simulator.step(TICK)
	equal(soldier.auto_target_id, before, "and crossing into another cell does not lose it")

	# A second pair, this time with the enemy exactly on the boundary and the soldier one
	# cell away, so the query has to consider both cells to answer at all.
	var seeker := _unit(10, PLAYER, Vector2(20.0, 30.0))
	var edge := _unit(11, ENEMY, Vector2(cell * 5.0, 30.0))
	var second := _counting([seeker, edge], 4)
	# The seeker's phase is its id modulo the cadence, so give its slot time to come round.
	for i in 3:
		second.step(TICK)
	equal(seeker.auto_target_id, 11, "an enemy exactly on a boundary is found as well")


## ---------- the death storm ----------------------------------------------

## The worst case the milestone has to survive: hundreds of soldiers losing the opponent
## they were fighting, all at once. The question is not whether it costs more - it must -
## but whether the cost is bounded by the fighting and spread rather than repeated.
func _test_mass_target_death_is_bounded_and_deterministic() -> void:
	section("a storm of target deaths is bounded")
	var first := _storm_run()
	var second := _storm_run()
	for key in first.keys():
		equal(second[key], first[key], "the same storm produced the same %s" % key)

	var front := int(first["front_rank"])
	var soldiers := int(first["soldiers"])
	equal(int(first["front_holding"]), front, "the whole front rank was holding an opponent before the storm")
	equal(int(first["immediate"]), front, "every soldier that lost an enemy mid-swing reacquired at once")
	equal(int(first["deferred"]), 0, "and no soldier whose loss was not urgent was brought forward")
	less(float(first["storm_searches"]), float(soldiers) * 0.75,
		"the storm tick carried far fewer searches than the army has soldiers (%d of %d)"
			% [int(first["storm_searches"]), soldiers])
	greater(float(first["settled_searches"]), 0.0, "while the very next tick went back to the schedule")
	less(float(first["settled_searches"]), float(first["storm_searches"]),
		"and cost less than the tick the storm landed on")


## ---------- future ranged units ------------------------------------------

## Nothing in the target path may assume a melee reach. A unit that declares a wider
## awareness searches wider, keeps what it finds further off, and does so without the
## algorithm knowing what it is carrying.
func _test_a_wider_awareness_works_generically() -> void:
	section("a wider awareness is a capability, not a weapon check")
	var ordinary := _unit(0, PLAYER, Vector2(20.0, 30.0))
	var far_sighted := _unit(1, PLAYER, Vector2(20.0, 40.0))
	far_sighted.awareness_radius = 40.0
	var distant := _unit(2, ENEMY, Vector2(56.0, 40.0))
	var simulator := _counting([ordinary, far_sighted, distant], 4)
	# Two ticks, so that both soldiers' awareness slots (ids 0 and 1) have come round.
	for i in 2:
		simulator.step(TICK)

	# Thirty-six units away: past the ordinary soldier's bound, and well inside the
	# far-sighted soldier's own search. Nothing about the unit's weapon is consulted - it
	# says how far it can see, and the search goes that far.
	equal(far_sighted.auto_target_id, 2, "the wider awareness found the enemy immediately")
	equal(ordinary.auto_target_id, -1, "the ordinary soldier has nobody inside its own bound")

	# The rung ladder is still what searches, so its shape is still worth pinning: the two
	# soldiers began on the first rung, and the ordinary one widened once and found nobody.
	equal(simulator.tgt_rung_hits[0], 2, "both soldiers began on the first rung")
	equal(simulator.tgt_rung_hits.size(), 2, "and the ordinary one had to widen its search")
	equal(simulator.tgt_rung_hits[1], 1, "which it did once, and found nobody")

	greater(float(simulator.call("_retention_radius_of", far_sighted)), 39.0,
		"a wider awareness also keeps what it finds further off")
	approx(float(simulator.call("_retention_radius_of", ordinary)), 32.0, 0.001,
		"and the ordinary soldier's retention is the configured one")


## The rule the brief states as "do not write if unit.type == archer", pinned two ways: as
## a lexical guard on the code that does the searching, and as a behavioural check that a
## unit's type name changes nothing about how far it can see.
func _test_nothing_assumes_every_unit_is_melee() -> void:
	section("the target path assumes no weapon at all")
	var file := FileAccess.open("res://scripts/battle/battle_simulator.gd", FileAccess.READ)
	not_null(file, "the simulator's source is readable")
	if file == null:
		return
	var source := file.get_as_text()
	# The comments in this file talk about archers and about melee reach deliberately -
	# that is what the next milestone brings. What must not appear is code that branches on
	# what a unit is carrying, so the patterns looked for are code-shaped rather than words.
	for forbidden in ['"archer"', "unit_type_id ==", "ranged =="]:
		check(not source.contains(forbidden), "the target path contains no '%s'" % forbidden)
	contains(source, "awareness_radius", "and reaches for a unit's own awareness instead")

	# Behaviourally: same stats, same place, different type names - identical looking.
	var spearman := _unit(0, PLAYER, Vector2(20.0, 20.0))
	spearman.unit_type_id = "peasant_recruit"
	var archer := _unit(1, PLAYER, Vector2(20.0, 40.0))
	archer.unit_type_id = "bandit_archer"
	var foe := _unit(2, ENEMY, Vector2(48.0, 30.0))
	var simulator := _counting([spearman, archer, foe], 4)
	for i in 2:
		simulator.step(TICK)
	equal(spearman.auto_target_id, 2, "the spearman found the enemy")
	equal(archer.auto_target_id, spearman.auto_target_id,
		"and a soldier called an archer behaves exactly like one called a spearman")
	equal(archer.awareness_radius, 0.0, "a wider look is given to a unit, never inferred from what it is called")


## The static search is the thing Step 7.4 did not change: it still answers exactly what
## a whole-field scan would have answered. What changed is that the answer is only asked
## for when it can change.
func _test_the_search_itself_is_unchanged() -> void:
	section("the search itself is unchanged")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 0.05, 0.0)
	var held := _unit(1, ENEMY, Vector2(34.0, 30.0), 0.05, 0.0)
	var later := _unit(2, ENEMY, Vector2(33.0, 30.0), 0.05, 0.0)
	var simulator := _counting([soldier, held, later], 8)
	simulator.step(TICK)
	equal(soldier.auto_target_id, 2, "the nearest enemy was taken to begin with")

	# Something nearer appears. The static search sees it at once, and the soldier does
	# not - which is the deliberate difference this milestone introduces and the reason
	# the cadence exists.
	var newcomer := _unit(3, ENEMY, Vector2(30.6, 30.0), 0.05, 0.0)
	# Appended directly rather than through add_units, because add_units would hand every
	# soldier a fresh awareness phase and this test is about a battle already in progress.
	simulator.units.append(newcomer)
	simulator.units_by_id()[3] = newcomer
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")

	equal(simulator.call("_choose_target", soldier), newcomer, "a fresh search finds the newcomer at once")
	equal(simulator.call("_resolve_target", soldier), later, "the soldier itself keeps dealing with its opponent")
	equal(soldier.auto_target_id, 2, "and says so")

	# Its scheduled look arrives and the newcomer is taken, because it is much closer.
	var took := false
	for i in 8:
		simulator.step(TICK)
		if soldier.auto_target_id == 3:
			took = true
	check(took, "and the scheduled look takes the clearly nearer enemy")


## ---------- allocations and instrumentation ------------------------------

## Target handling is a hot loop, so the path a retained opponent takes must not allocate.
## The steady state is what is measured: the first calls warm the scratch storage.
func _test_the_retention_path_allocates_nothing() -> void:
	section("keeping an opponent allocates nothing")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 3.0)
	var enemy := _unit(1, ENEMY, Vector2(32.0, 30.0), 3.0)
	var simulator := _counting([soldier, enemy], 4)
	for i in 20:
		simulator.step(TICK)
	for i in 200:
		simulator.call("_resolve_target", soldier)

	var before := Performance.get_monitor(Performance.MEMORY_STATIC)
	for i in 2000:
		simulator.call("_resolve_target", soldier)
	var after := Performance.get_monitor(Performance.MEMORY_STATIC)
	equal(int(after - before), 0, "two thousand resolutions allocated nothing")
	equal(soldier.auto_target_id, 1, "and the answer never wavered")


## ---------- determinism ---------------------------------------------------

## The whole battle, not only its result: the same seed must produce the same target
## sequence tick for tick, and the same casualties, and the same amount of looking.
func _test_a_battle_with_a_cadence_is_deterministic() -> void:
	section("same seed, same battle, same targets")
	var first := _run_signature(SEED + 3, 300)
	var second := _run_signature(SEED + 3, 300)
	equal(second["targets"], first["targets"], "every soldier dealt with the same enemy on every tick")
	equal(second["deaths"], first["deaths"], "the casualties are identical")
	equal(second["kills"], first["kills"], "so are the kills")
	equal(second["searches"], first["searches"], "and so is how much looking was done")
	equal(second["switches"], first["switches"], "and how often anyone changed their mind")
	equal(second["immediates"], first["immediates"], "and how often a loss was urgent")
	greater(float(first["deaths"]), 0.0, "in a battle where people actually died")


## The knob exists because the rule it controls is a decision rather than an accident:
## with urgency switched off, a mid-swing loss waits for the soldier's own turn.
func _test_immediate_reacquisition_can_be_switched_off() -> void:
	section("the urgency rule can be switched off, and does only that")
	var soldier := _unit(0, PLAYER, Vector2(30.0, 30.0), 3.0)
	var victim := _unit(1, ENEMY, Vector2(32.0, 30.0))
	var other := _unit(2, ENEMY, Vector2(36.0, 30.0))
	var simulator := _counting([soldier, victim, other], 8)
	simulator.target_immediate_on_contact_loss = false
	simulator.step(TICK)
	equal(soldier.auto_target_id, 1, "the enemy in front was acquired")
	victim.hp = 0
	victim.alive = false
	simulator.step(TICK)
	equal(simulator.tgt_invalid_dead, 1, "the death was still noticed at once")
	equal(simulator.tgt_immediate_reacquires, 0, "but urgency is off, so nothing was brought forward")
	equal(soldier.auto_target_id, -1, "and the soldier is not holding anybody until its own turn")
	equal(simulator.tgt_searches, 1, "so only the original search happened")

	# Its own turn is tick eight of an eight-tick cadence, and it does not come sooner for
	# having been made urgent. This is the whole of what the knob changes.
	for i in 8:
		simulator.step(TICK)
	equal(soldier.auto_target_id, 2, "and at its own awareness tick it takes the nearest enemy")


## Every soldier-tick is accounted for by exactly one of the paths through target
## handling: an order, an opponent in reach, an opponent held, a scheduled look, or the
## cheap answer. If those ever stop adding up, a counter is lying and so is the report.
func _test_every_soldier_tick_is_accounted_for() -> void:
	section("every soldier-tick is accounted for")
	var bundle := _formed_army(24, 40.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	for i in 300:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	var report := simulator.target_report()
	var accounted := int(report["searches"]) + int(report["retained_in_reach"]) \
		+ int(report["retained_held"]) + int(report["focus_fallbacks"]) + int(report["explicit_order_uses"]) \
		+ int(report["formation_deferrals"])
	equal(accounted, int(report["soldier_ticks"]), "the six paths account for every soldier-tick")
	greater(float(report["retained_uses"]), float(report["searches"]) * 3.0,
		"and keeping an opponent is what most ticks were spent doing")


## ---------- the report ----------------------------------------------------

## The figures the milestone is judged on, and the shape of them: a fighting battle spends
## most of its ticks not looking, and rarely changes its mind.
func _test_the_report_counts_what_it_claims_to() -> void:
	section("the report says what the milestone needs to know")
	var bundle := _formed_army(24, 40.0, 4)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	for i in 300:
		ai.update(simulator, TICK)
		simulator.step(TICK)
	var report := simulator.target_report()

	for key in ["ticks", "soldier_ticks", "searches", "searches_per_tick", "successful_searches",
			"empty_searches", "retained_in_reach", "retained_held", "retained_uses",
			"searches_avoided", "searches_avoided_pct", "searches_per_soldier_second",
			"focus_fallbacks", "focus_per_tick", "explicit_order_uses", "order_clears",
			"formation_enabled", "formation_deferrals", "formation_gate_allowed",
			"formation_promoted", "formation_promotions", "formation_demotions",
			"formation_retaliations", "formation_bodies_targeted", "formation_bodies_engaged",
			"invalid_dead", "invalid_far", "invalid_gone", "invalid_side", "invalidations",
			"invalidations_per_tick", "immediate_reacquires", "scheduled_reacquires",
			"candidates", "candidates_per_search", "candidates_max", "acquisitions",
			"switches", "switches_per_1000_soldiers_second", "rung_hits", "cadence_ticks",
			"retention_radius", "switch_advantage", "simulated_seconds", "latency_samples",
			"latency_avg_ticks", "latency_worst_ticks", "latency_over_cadence",
			"focus_proven", "focus_proven_pct"]:
		has_key(report, key, "the report carries '%s'" % key)

	greater(float(report["searches_avoided_pct"]), 70.0, "most looks did not happen")
	greater(float(report["retained_uses"]), 0.0, "and opponents were retained instead")
	# What a fighting battle must still show: soldiers of their own accord acquiring opponents,
	# and keeping them while they are worth keeping. That a fight also *ends* - opponents dying
	# and being replaced - is measured where battles run to a result, in the Step 7.8 hardening
	# and engagement suites, because this fixture only fights for fifteen seconds. See D-105.
	greater(float(int(report["acquisitions"])), 0.0, "soldiers acquired opponents of their own")
	greater(float(int(report["retained_in_reach"])), 0.0,
		"and held them while they were in reach")
	greater(float(report["formation_deferrals"]), 0.0,
		"and the hierarchy was doing some of the looking's work for it")
	# A soldier can only change its mind while looking, so the churn figure is bounded by
	# the look count by construction rather than by luck.
	less(float(report["switches"]), float(report["searches"]) + 1.0,
		"nobody changed their mind more often than they looked")
	less(float(report["switches_per_1000_soldiers_second"]), 500.0,
		"and the churn rate stays small: %.1f changes per thousand soldiers per second"
			% float(report["switches_per_1000_soldiers_second"]))
	equal(int(report["cadence_ticks"]), 4, "the report names the cadence it was measured under")

	# The escalation ladder is still there and still used for the quiet cases.
	var rungs: Array = report["rung_hits"]
	check(rungs.size() >= 1, "the ladder recorded which rung answered")
	greater(float(rungs[0]), 0.0, "and the first rung answered something")


## ---------- helpers -------------------------------------------------------

## A dozen soldiers in two loose groups, laid out so that the same roster can be built in
## either order for the ordering test.
func _army_roster(count: int) -> Array[BattleUnit]:
	var units: Array[BattleUnit] = []
	for i in count:
		var side := PLAYER if i < count / 2 else ENEMY
		units.append(_unit(i, side, Vector2(20.0 + float(i % 4) * 15.0, 15.0 + float(i / 4) * 15.0)))
	return units


## One run of the death storm, reduced to the figures the test compares. Two lines of
## soldiers in contact, a third rank behind each, and then the entire front rank of one
## side is killed on a single tick.
##
## The front rank is what matters: those are the soldiers whose opponents were inside
## their reach, so they are the ones whose losses are urgent. The ranks behind them lose
## opponents too, and are deliberately left to wait for their own turn.
func _storm_run() -> Dictionary:
	var config := _config()
	var simulator := BattleSimulator.new(config, SEED + 11)
	simulator.profile_enabled = true
	var interval := 4
	simulator.target_reacquisition_ticks = interval
	var files := 30
	var units: Array[BattleUnit] = []
	var player_front: Array[BattleUnit] = []
	var enemy_front: Array[BattleUnit] = []
	var next_id := 0
	# Three ranks a side. Rank zero is the one facing the enemy, and the only one whose
	# opponents are inside its reach: the ranks behind it are two and a half units further
	# back, which is out of a one-point-eight-unit reach on purpose, so the storm has a
	# front to land on and a rear that has no reason to react to it.
	for rank_index in 3:
		for file in files:
			var y := 10.0 + float(file) * 1.4
			var player := _unit(next_id, PLAYER, Vector2(20.0 + float(2 - rank_index) * 1.4, y), 1.8, 0.0)
			next_id += 1
			units.append(player)
			var enemy := _unit(next_id, ENEMY, Vector2(24.5 + float(rank_index) * 1.4, y), 1.8, 0.0)
			next_id += 1
			units.append(enemy)
			if rank_index == 0:
				player_front.append(player)
				enemy_front.append(enemy)
	simulator.add_units(units)
	simulator.call("_rebuild_spatial", TICK)
	simulator.call("_refresh_focus")
	simulator.start()
	simulator.reset_profile()

	# Let the lines settle into contact and start fighting, so the front rank really is
	# holding opponents in reach before the storm.
	for i in 6:
		simulator.step(TICK)
	var front_holding := 0
	for unit in player_front:
		if unit.auto_target_id >= 0:
			front_holding += 1

	var searches_before := simulator.tgt_searches
	var immediates_before := simulator.tgt_immediate_reacquires
	for victim in enemy_front:
		victim.hp = 0
		victim.alive = false
	simulator.step(TICK)
	var storm_searches := simulator.tgt_searches - searches_before
	var immediate := simulator.tgt_immediate_reacquires - immediates_before

	# The very next tick, on its own: the schedule has already taken charge again.
	searches_before = simulator.tgt_searches
	immediates_before = simulator.tgt_immediate_reacquires
	simulator.step(TICK)
	var settled_searches := simulator.tgt_searches - searches_before
	var deferred := simulator.tgt_immediate_reacquires - immediates_before

	return {
		"soldiers": units.size(),
		"front_rank": player_front.size(),
		"front_holding": front_holding,
		"storm_searches": storm_searches,
		"settled_searches": settled_searches,
		"immediate": immediate,
		"deferred": deferred,
		"invalid_dead": simulator.tgt_invalid_dead,
		"searches": simulator.tgt_searches,
	}


## One deterministic battle run, reduced to a signature. The signature covers who every
## soldier was dealing with on every tick, which is the part this milestone changed: two
## runs that agreed on the casualties but disagreed on the target sequence would not be
## the same battle.
func _run_signature(seed_value: int, ticks: int) -> Dictionary:
	var bundle := _formed_army(20, 20.0, 4, seed_value)
	var simulator: BattleSimulator = bundle["simulator"]
	var ai: BattleAI = bundle["ai"]
	var parts := PackedStringArray()
	var deaths := 0
	var kills := 0
	for tick in ticks:
		if simulator.is_finished():
			break
		ai.update(simulator, TICK)
		for event in simulator.step(TICK):
			var kind := str(event.get("type", ""))
			if kind == "death":
				deaths += 1
			elif kind == "hit" and bool(event.get("killed", false)):
				kills += 1
		for unit in simulator.units:
			parts.append("%d:%d" % [unit.id, unit.auto_target_id])
	var report := simulator.target_report()
	return {
		"targets": "%08x" % RngService.stable_hash("|".join(parts)),
		"deaths": deaths,
		"kills": kills,
		"searches": int(report["searches"]),
		"switches": int(report["switches"]),
		"immediates": int(report["immediate_reacquires"]),
	}
