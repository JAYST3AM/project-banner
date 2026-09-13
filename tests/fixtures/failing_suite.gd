extends TestCase
## Runner self-test fixture - DO NOT add to the runner's SUITES list.
##
## Completes normally but records a failed assertion. Must be classified as failing,
## and must NOT be confused with the "broken" classification - it finished, it just
## found a real problem.

func run() -> void:
	await _tick()
	check(true, "a passing assertion")
	check(false, "a deliberately failing assertion")
	_complete()
