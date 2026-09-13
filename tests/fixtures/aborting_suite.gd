extends TestCase
## Runner self-test fixture - DO NOT add to the runner's SUITES list.
##
## Records assertions successfully, then raises a genuine runtime error part-way
## through run(). The point is the shape of the failure: assertions ran and none of
## them failed, so a runner that only checked `checks > 0 and failures.is_empty()`
## would call this a PASS. It must instead be detected as broken, because the suite
## never reached its completion marker.

func run() -> void:
	await _tick()
	check(true, "first assertion runs")
	check(1 + 1 == 2, "second assertion runs")
	equal("a", "a", "third assertion runs")

	# A real runtime error, not a parse error: reading past the end of an empty
	# array aborts run() on this line. Everything after it is unreachable.
	var nothing: Array = []
	var doomed: int = nothing[3]
	check(doomed == 0, "this must never run")

	_complete()
