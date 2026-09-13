extends TestCase
## Runner self-test fixture - DO NOT add to the runner's SUITES list.
##
## Completes normally but asserts nothing at all. A suite that checks nothing cannot
## demonstrate anything, so this must be a failure rather than a vacuous pass.

func run() -> void:
	await _tick()
	_complete()
