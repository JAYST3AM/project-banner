extends TestCase
## Cohesion uses the real average soldier-to-slot error; it cannot create
## morale, casualties or animation state on its own.


func run() -> void:
	await _tick()
	_test_formed_armies_keep_full_speed()
	_test_scattered_armies_wait_for_their_ranks()
	_test_scale_is_bounded_and_monotonic()
	_complete()


func _test_formed_armies_keep_full_speed() -> void:
	section("tight formations move at the commanded rate")
	equal(BattleFormationCohesion.march_multiplier(0.0, 2.0), 1.0,
		"coherent soldiers march without slowdown")
	equal(BattleFormationCohesion.march_multiplier(1.5, 2.0), 1.0,
		"a little natural spacing variation is tolerated")


func _test_scattered_armies_wait_for_their_ranks() -> void:
	section("a body stops pulling stragglers endlessly through obstacles")
	var walking := BattleFormationCohesion.march_multiplier(2.5, 2.0)
	check(walking > 0.0 and walking < 1.0,
		"a moderately dispersed formation advances more carefully")
	equal(BattleFormationCohesion.march_multiplier(6.0, 2.0), 0.0,
		"an extremely dispersed formation waits for its men")
	equal(BattleFormationCohesion.march_multiplier(12.0, 2.0), 0.0,
		"more scattering never makes it walk faster")


func _test_scale_is_bounded_and_monotonic() -> void:
	section("cohesion multipliers remain stable for all unit spacings")
	for spacing in [0.0, 0.5, 1.2, 2.6, 5.0]:
		var previous := 1.0
		for i in 30:
			var scale := BattleFormationCohesion.march_multiplier(
				float(i) * maxf(0.1, spacing) * 0.15, spacing)
			check(scale >= 0.0 and scale <= 1.0,
				"cohesion speed stays within zero and full pace")
			check(scale <= previous + 0.0001,
				"worsening cohesion cannot accelerate a formation")
			previous = scale
