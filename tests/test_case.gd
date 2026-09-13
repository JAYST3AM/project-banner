class_name TestCase
extends RefCounted
## Base class for headless test suites.
##
## Suites are plain scripts that extend TestCase and override [method run].
## Every assertion records a failure instead of aborting, so one run reports
## every problem rather than only the first.
##
## [codeblock]
## extends TestCase
## func run() -> void:
##     await _tick()          # keeps run() a coroutine
##     check(1 + 1 == 2, "maths works")
## [/codeblock]

var suite_name: String = "unnamed suite"
var runner: Node = null
var failures: Array[String] = []
var checks: int = 0


## Override in every suite. Must contain at least one [code]await[/code] (use
## [method _tick]) so the runner can always await it as a coroutine.
func run() -> void:
	pass


func passed() -> bool:
	return failures.is_empty()


## Yield one frame. Also guarantees this suite's [method run] is a coroutine.
func _tick() -> void:
	await runner.get_tree().process_frame


func section(title: String) -> void:
	print("  [%s]" % title)


## ---------- assertions ---------------------------------------------------

func check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		_fail(message)
	return condition


func equal(actual: Variant, expected: Variant, message: String) -> bool:
	checks += 1
	if actual != expected:
		_fail("%s (expected %s, got %s)" % [message, _show(expected), _show(actual)])
		return false
	return true


func not_equal(actual: Variant, unexpected: Variant, message: String) -> bool:
	checks += 1
	if actual == unexpected:
		_fail("%s (value should not be %s)" % [message, _show(unexpected)])
		return false
	return true


func approx(actual: float, expected: float, tolerance: float, message: String) -> bool:
	checks += 1
	if absf(actual - expected) > tolerance:
		_fail("%s (expected ~%s, got %s)" % [message, expected, actual])
		return false
	return true


func greater(actual: float, threshold: float, message: String) -> bool:
	checks += 1
	if actual <= threshold:
		_fail("%s (expected > %s, got %s)" % [message, threshold, actual])
		return false
	return true


func less(actual: float, threshold: float, message: String) -> bool:
	checks += 1
	if actual >= threshold:
		_fail("%s (expected < %s, got %s)" % [message, threshold, actual])
		return false
	return true


func not_null(value: Variant, message: String) -> bool:
	checks += 1
	if value == null:
		_fail("%s (was null)" % message)
		return false
	return true


func is_null(value: Variant, message: String) -> bool:
	checks += 1
	if value != null:
		_fail("%s (expected null, got %s)" % [message, _show(value)])
		return false
	return true


func contains(haystack: String, needle: String, message: String) -> bool:
	checks += 1
	if not haystack.contains(needle):
		_fail("%s ('%s' not found in '%s')" % [message, needle, haystack])
		return false
	return true


func has_key(dictionary: Dictionary, key: Variant, message: String) -> bool:
	checks += 1
	if not dictionary.has(key):
		_fail("%s (missing key '%s' in %s)" % [message, _show(key), _show(dictionary.keys())])
		return false
	return true


func list_contains(list: Array, needle: Variant, message: String) -> bool:
	checks += 1
	if not list.has(needle):
		_fail("%s (%s not in %s)" % [message, _show(needle), _show(list)])
		return false
	return true


func _fail(message: String) -> void:
	failures.append(message)
	print("    FAIL  %s" % message)


func _show(value: Variant) -> String:
	var text := str(value)
	if text.length() > 160:
		text = text.substr(0, 157) + "..."
	return text
