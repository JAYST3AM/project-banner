extends TestCase
## Runner self-test fixture - DO NOT add to the runner's SUITES list.
##
## A well-behaved suite: runs assertions, all of them pass, and reaches its
## completion marker. Must be classified as passing.

func run() -> void:
	await _tick()
	check(true, "a passing assertion")
	equal(2 + 2, 4, "arithmetic still works")
	not_null(self, "self is not null")
	_complete()
