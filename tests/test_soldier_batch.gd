extends TestCase
## The native soldier batch: the pool's determinism, the pass's decisions, and the boundaries.
##
## [b]What this guards.[/b] A native class added to a shared library that the whole project loads is
## the kind of thing that breaks silently - a pool that sums in a different order, a kernel that
## reads one array past its end, a pass whose answer depends on the number of workers. None of that
## shows up in a gameplay test. These assertions are deliberately synthetic: they build the arrays
## by hand so a failure says which soldier and which field, not "a battle disagreed somewhere".
##
## The live-battle equivalence (native against the sim's own functions, on a real 20K field) is
## measured by `scenes/dev/soldier_batch_bench.tscn`; this suite is the part CI can afford to run
## on every commit.

const RETENTION := 32.0
const KEEP := 1
const HOLD := 2
const DEFER := 3
const SEARCH := 4
const NONE := 0


func run() -> void:
	await _tick()
	_test_a_soldier_keeps_the_opponent_it_can_reach()
	_test_a_soldier_whose_turn_has_not_come_is_not_asked()
	_test_the_gate_defers_the_rank_that_is_not_in_the_fight()
	_test_the_dead_are_not_asked_and_a_corpse_is_not_an_opponent()
	_test_the_pool_is_deterministic_and_says_so()
	_test_the_same_soldiers_give_the_same_answers_at_any_worker_count()
	_test_a_batch_too_small_for_the_pool_is_run_alone()
	_test_a_mismatched_batch_is_refused_rather_than_read_past_its_end()
	_complete()


func _test_a_soldier_keeps_the_opponent_it_can_reach() -> void:
	section("a remembered opponent in reach is kept, and one out of reach is held")
	# The two distances the sim keeps apart, and the whole point of the pass: the retention
	# radius (32) says whether the opponent is still worth remembering at all, and the soldier's
	# own reach says whether it can strike it now or is walking to it.
	var batch := _run(_pair(2.0, 3.0), 1)
	equal(batch["decisions"][0], KEEP, "two units away with a reach of three: kept and struck")
	equal(batch["retained"][0], 1, "and pointed at the same opponent")
	equal(int(batch["stats"]["keep"]), 2,
		"both soldiers can strike each other, so both are kept, and the counter agrees")
	batch = _run(_pair(10.0, 3.0), 1)
	equal(batch["decisions"][0], HOLD, "ten units away with a reach of three: kept, and walked to")
	equal(batch["retained"][0], 1, "the opponent is still the one it remembers")
	batch = _run(_pair(31.0, 3.0), 1)
	equal(batch["decisions"][0], HOLD, "thirty-one units is still inside the retention radius")
	batch = _run(_pair(33.0, 3.0), 1)
	equal(batch["decisions"][0], SEARCH,
		"and thirty-three is not: the opponent is forgotten, and a due tick looks again")


func _test_a_soldier_whose_turn_has_not_come_is_not_asked() -> void:
	section("the cadence decides whether the question is asked at all")
	var decisions: PackedInt32Array = _run(_no_target(0), 1)["decisions"]
	equal(decisions[0], NONE, "no opponent, turn not due: nothing happens")
	decisions = _run(_no_target(1), 1)["decisions"]
	equal(decisions[0], SEARCH, "no body at all: the pre-formation rule is that a due tick looks")


func _test_the_gate_defers_the_rank_that_is_not_in_the_fight() -> void:
	section("a soldier in a body out of contact is refused its look")
	var arrays := _formed(false)
	var decisions: PackedInt32Array = _run(arrays, 1)["decisions"]
	equal(decisions[0], DEFER, "nothing near its body: the look is refused rather than made")
	var stats: Dictionary = _run(arrays, 1)["stats"]
	greater(float(stats["defer"]), 0.0, "and the refusal is counted")
	arrays = _formed(true)
	decisions = _run(arrays, 1)["decisions"]
	equal(decisions[0], SEARCH, "the same soldier with an enemy body on top of its own looks")
	arrays = _formed(false)
	arrays["struck"][0] = 1
	decisions = _run(arrays, 1)["decisions"]
	equal(decisions[0], SEARCH, "and a soldier that has just been struck looks even out of band")


func _test_the_dead_are_not_asked_and_a_corpse_is_not_an_opponent() -> void:
	section("the dead acquire nothing and are not acquired")
	var arrays := _pair(10.0, 1.0)
	arrays["alive"][0] = 0
	var decisions: PackedInt32Array = _run(arrays, 1)["decisions"]
	equal(decisions[0], NONE, "a dead soldier is never given a decision")
	arrays = _pair(10.0, 3.0)
	arrays["alive"][1] = 0
	arrays["due"][0] = 1
	decisions = _run(arrays, 1)["decisions"]
	not_equal(decisions[0], KEEP, "and a corpse is not something to keep fighting")
	not_equal(decisions[0], HOLD, "not even held")
	equal(decisions[0], SEARCH, "so the soldier is free to look again")


func _test_the_pool_is_deterministic_and_says_so() -> void:
	section("the same batch gives the same answer on any number of workers")
	var one := NativeSoldierBatch.new()
	one.setup(50000, 1, RETENTION)
	var many := NativeSoldierBatch.new()
	many.setup(50000, 0, RETENTION)
	greater(float(many.worker_count()), 1.0, "the default really does start workers")
	var first := one.probe_parallel_sum(50000)
	var second := many.probe_parallel_sum(50000)
	equal(first[0], second[0],
		"a reduction over the same batches is bit-identical at one worker and at %d" % int(second[2]))


func _test_the_same_soldiers_give_the_same_answers_at_any_worker_count() -> void:
	section("a pass's decisions do not depend on the pool")
	var arrays := _crowd(4000)
	var one := _run(arrays, 1)
	var many := _run(arrays, 0)
	var decided_one: PackedInt32Array = one["decisions"]
	var decided_many: PackedInt32Array = many["decisions"]
	equal(decided_one.size(), decided_many.size(), "both runs decided every soldier")
	var differences := 0
	for i in decided_one.size():
		if decided_one[i] != decided_many[i]:
			differences += 1
	equal(differences, 0, "and with no disagreement anywhere in the batch")
	equal(int(one["stats"]["keep"]) + int(one["stats"]["hold"]), int(many["stats"]["keep"]) + int(many["stats"]["hold"]),
		"the counters agree too, because they are merged in block order")


func _test_a_batch_too_small_for_the_pool_is_run_alone() -> void:
	section("a small batch does not wake the pool")
	var arrays := _crowd(64)
	var batch := _run(arrays, 0)
	equal(int(batch["stats"]["blocks"]), 1, "one block, run by the caller: no dispatch to pay for")


func _test_a_mismatched_batch_is_refused_rather_than_read_past_its_end() -> void:
	section("short arrays are refused, not read")
	var batch := NativeSoldierBatch.new()
	batch.setup(8, 1, RETENTION)
	var decisions := batch.run_awareness(
		PackedFloat32Array([0.0, 0.0]), # positions for one soldier, not for two
		PackedInt32Array([1, 1]), PackedInt32Array([0, 1]), PackedInt32Array([-1, -1]),
		PackedFloat32Array([2.0, 2.0]), PackedInt32Array([1, 1]), PackedInt32Array([0, 0]),
		PackedInt32Array([-1, -1]), PackedFloat32Array([4.0]), PackedFloat32Array([]),
		PackedInt32Array([0]), PackedInt32Array([0]))
	equal(decisions.size(), 0, "an answer of nothing rather than an out-of-bounds read")


## ---------- fixtures ------------------------------------------------------

## Two soldiers, the first remembering the second `distance` away, with `reach` for both, and a
## due awareness tick so the "nothing worth keeping" branch is exercised rather than skipped.
func _pair(distance: float, reach: float) -> Dictionary:
	var arrays := _crowd(2)
	arrays["due"][0] = 1
	arrays["positions"][0] = 0.0
	arrays["positions"][1] = 0.0
	arrays["positions"][2] = distance
	arrays["positions"][3] = 0.0
	arrays["targets"][0] = 1
	arrays["targets"][1] = 0
	arrays["reach"][0] = reach
	arrays["reach"][1] = reach
	return arrays


## One soldier with no opponent, due = `due`, in no body.
func _no_target(due: int) -> Dictionary:
	var arrays := _crowd(1)
	arrays["targets"][0] = -1
	arrays["due"][0] = due
	return arrays


## One soldier in a body, with (or without) an enemy body's box inside its band.
func _formed(enemy_nearby: bool) -> Dictionary:
	var arrays := _crowd(1)
	arrays["targets"][0] = -1
	arrays["due"][0] = 1
	arrays["bodies"][0] = 0
	arrays["bands"] = PackedFloat32Array([4.0])
	arrays["box_offsets"] = PackedInt32Array([0])
	if enemy_nearby:
		arrays["boxes"] = PackedFloat32Array([0.0, 0.0, 2.0, 2.0])
		arrays["box_counts"] = PackedInt32Array([1])
	else:
		arrays["boxes"] = PackedFloat32Array([900.0, 900.0, 902.0, 902.0])
		arrays["box_counts"] = PackedInt32Array([1])
	return arrays


## A batch of `count` soldiers arranged in facing lines, every other one due, so a pass has
## something of every decision in it.
func _crowd(count: int) -> Dictionary:
	var positions := PackedFloat32Array()
	positions.resize(count * 2)
	var alive := PackedInt32Array()
	alive.resize(count)
	var sides := PackedInt32Array()
	sides.resize(count)
	var targets := PackedInt32Array()
	targets.resize(count)
	var reach := PackedFloat32Array()
	reach.resize(count)
	var due := PackedInt32Array()
	due.resize(count)
	var struck := PackedInt32Array()
	struck.resize(count)
	var bodies := PackedInt32Array()
	bodies.resize(count)
	for i in count:
		positions[i * 2] = float(i % 100) * 2.0
		positions[i * 2 + 1] = float(i / 100) * 2.0
		alive[i] = 1
		sides[i] = i % 2
		targets[i] = -1
		reach[i] = 2.4
		due[i] = i % 4 if i % 2 == 0 else 0
		struck[i] = 0
		bodies[i] = -1
	return {
		"retention_sq": RETENTION * RETENTION,
		"positions": positions, "alive": alive, "sides": sides, "targets": targets,
		"reach": reach, "due": due, "struck": struck, "bodies": bodies,
		"bands": PackedFloat32Array(), "boxes": PackedFloat32Array(),
		"box_counts": PackedInt32Array(), "box_offsets": PackedInt32Array(),
	}


func _run(arrays: Dictionary, workers: int) -> Dictionary:
	var batch := NativeSoldierBatch.new()
	batch.setup(arrays["alive"].size(), workers, RETENTION)
	var decisions := batch.run_awareness(
		arrays["positions"], arrays["alive"], arrays["sides"], arrays["targets"],
		arrays["reach"], arrays["due"], arrays["struck"], arrays["bodies"],
		arrays["bands"], arrays["boxes"], arrays["box_counts"], arrays["box_offsets"])
	return {"decisions": decisions, "retained": batch.retained(), "stats": batch.stats()}
