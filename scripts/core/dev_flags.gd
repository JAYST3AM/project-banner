class_name DevFlags
extends RefCounted
## Command-line switches for development and automated verification.
##
## These are the only way to get into gameplay without touching the mouse, which
## makes "does the real, rendered world map actually work?" testable:
##
## [codeblock]
## godotc --path "<project>" -- --autostart-campaign=999 --autotravel=brackenford
## [/codeblock]
##
## Everything here is inert unless the matching argument is passed, so shipping
## builds behave normally. Debug-only UI is gated separately by
## [code]debug.enabled[/code] in the config.

const AUTOSTART_PREFIX := "--autostart-campaign"
const AUTOTRAVEL_PREFIX := "--autotravel="


static func _user_args() -> PackedStringArray:
	return OS.get_cmdline_user_args()


## Returns {"enabled": bool, "name": String, "seed": int}.
static func autostart_campaign() -> Dictionary:
	var result := {"enabled": false, "name": "Dev Campaign", "seed": 0}
	for arg in _user_args():
		if arg == AUTOSTART_PREFIX or arg.begins_with(AUTOSTART_PREFIX + "="):
			result["enabled"] = true
			var value := arg.trim_prefix(AUTOSTART_PREFIX).trim_prefix("=")
			if not value.is_empty():
				result["name"] = "Dev Campaign %s" % value
				result["seed"] = int(value) if value.is_valid_int() else RngService.stable_hash(value)
			return result
	# Also honoured as a plain (non user) argument, so `godot --autostart-campaign`
	# works without the `--` separator.
	for arg in OS.get_cmdline_args():
		if arg == AUTOSTART_PREFIX or arg.begins_with(AUTOSTART_PREFIX + "="):
			result["enabled"] = true
			var raw := arg.trim_prefix(AUTOSTART_PREFIX).trim_prefix("=")
			if not raw.is_empty():
				result["name"] = "Dev Campaign %s" % raw
				result["seed"] = int(raw) if raw.is_valid_int() else RngService.stable_hash(raw)
			return result
	return result


## Settlement id the party should immediately set out for, or "".
static func autotravel_destination() -> String:
	for arg in _user_args():
		if arg.begins_with(AUTOTRAVEL_PREFIX):
			return arg.trim_prefix(AUTOTRAVEL_PREFIX)
	return ""
