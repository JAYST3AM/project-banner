extends TestCase
## The arrows the compute battlefield flies: the pool's flight, its retirement, its cap.
##
## [b]What this guards.[/b] The compute field reads no hit events out of its simulation, so a shot
## is inferred from a damage tally and drawn as a shaft that must leave one man and arrive at
## another over a fixed flight. A pool that never retires its arrows leaks a shaft per shot; one
## that retires them early reads as a shot that missed; one that drops the newest instead of the
## oldest loses exactly the volley the player is watching. None of that shows up anywhere else.
##
## The drawing itself is windowed work (the pool is what a suite can hold); the look is the canvas
## battle's, deliberately - same flight, same shaft behind the head.


func run() -> void:
	await _tick()
	_test_a_shot_leaves_and_lands_where_it_was_aimed()
	_test_an_arrow_retires_when_it_lands_and_no_earlier()
	_test_the_pool_drops_the_oldest_when_it_is_full()
	_test_clearing_a_battle_leaves_nothing_in_the_air()
	_complete()


func _test_a_shot_leaves_and_lands_where_it_was_aimed() -> void:
	section("a shot's flight")
	var arrows := BattleArrows.new()
	arrows.spawn(Vector2(10.0, 20.0), Vector2(40.0, 20.0))
	equal(arrows.count(), 1, "one arrow is in the air")
	approx(arrows.progress(0), 0.0, 0.0001, "a fresh arrow has not moved")
	approx(arrows.head_at(0).x, 10.0, 0.0001, "its head starts where the shot was loosed")
	arrows.advance(BattleArrows.FLIGHT * 0.5)
	approx(arrows.progress(0), 0.5, 0.0001, "half its flight in, it is half way there")
	approx(arrows.head_at(0).x, 25.0, 0.0001, "and drawn there")
	equal(arrows.from_at(0), Vector2(10.0, 20.0), "the shot it was loosed from is remembered")
	equal(arrows.to_at(0), Vector2(40.0, 20.0), "and so is the man it was aimed at")


func _test_an_arrow_retires_when_it_lands_and_no_earlier() -> void:
	section("an arrow's life")
	var arrows := BattleArrows.new()
	arrows.spawn(Vector2.ZERO, Vector2(10.0, 0.0))
	arrows.advance(BattleArrows.FLIGHT * 0.9)
	equal(arrows.count(), 1, "just short of landing it is still in the air")
	approx(arrows.head_at(0).x, 9.0, 0.001, "at the man it was aimed at")
	arrows.advance(BattleArrows.FLIGHT * 0.2)
	equal(arrows.count(), 0, "past its flight time it is gone")
	# Two arrows at different ages retire independently: one landing must not take the other.
	arrows.spawn(Vector2.ZERO, Vector2(5.0, 0.0))
	arrows.spawn(Vector2.ZERO, Vector2(5.0, 0.0))
	arrows.advance(BattleArrows.FLIGHT * 0.5)
	arrows.spawn(Vector2.ZERO, Vector2(5.0, 0.0))
	arrows.advance(BattleArrows.FLIGHT * 0.6)
	equal(arrows.count(), 1, "the two older arrows landed, the newest is still flying")
	approx(arrows.progress(0), 0.6, 0.0001, "and it is that far into its own flight")


func _test_the_pool_drops_the_oldest_when_it_is_full() -> void:
	section("a full pool")
	var arrows := BattleArrows.new()
	for i in BattleArrows.CAP + 3:
		arrows.spawn(Vector2(float(i), 0.0), Vector2(float(i), 10.0))
	equal(arrows.count(), BattleArrows.CAP, "the pool holds its cap")
	approx(arrows.from_at(0).x, 3.0, 0.0001, "and the three oldest shots are the ones gone")


func _test_clearing_a_battle_leaves_nothing_in_the_air() -> void:
	section("the end of a battle")
	var arrows := BattleArrows.new()
	for i in 5:
		arrows.spawn(Vector2.ZERO, Vector2(float(i), 0.0))
	arrows.clear()
	equal(arrows.count(), 0, "cleared, the air is empty")
	arrows.advance(1.0)
	equal(arrows.count(), 0, "and advancing an empty pool is nothing")
