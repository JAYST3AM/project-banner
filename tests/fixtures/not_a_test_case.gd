extends RefCounted
## Runner self-test fixture - DO NOT add to the runner's SUITES list.
##
## A perfectly valid script that simply is not a test suite. Its constructor
## succeeds, so the runner's "did this build a TestCase?" guard is the only thing
## standing between it and a silent pass.

var not_a_test: bool = true
