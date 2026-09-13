extends TestCase
## Runner self-test fixture - DO NOT add to the runner's SUITES list.
##
## Returns early without reaching its completion marker, but without raising a
## runtime error. This is the same observable state a suite that aborted part-way
## leaves behind - some passing assertions, no marker - so it exercises the
## completion contract in a normal run with a completely clean log.

func run() -> void:
	await _tick()
	check(true, "an assertion that passes")
	check(2 > 1, "another assertion that passes")
	# Deliberately no _complete() here.
	return
